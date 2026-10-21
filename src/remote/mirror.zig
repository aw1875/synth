//! A session on a server, mirrored here for a TUI to draw.
//!
//! A reader thread decodes what the server sends and queues it. `poll`, on the
//! thread that draws, applies the queue - to the transcript it was handed, the
//! status, the streaming request - so nothing the TUI reads changes under it.
//! Commands go straight out, and their replies come back through the queue.

const std = @import("std");

const wire = @import("wire.zig");
const client = @import("client.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const skill = @import("../core/skill.zig");
const mcp_tools = @import("../tools/mcp.zig");
const todo = @import("../core/todo.zig");
const Loop = @import("../agent/loop.zig");
const Thought = @import("../agent/thought.zig");
const Provider = @import("../provider/provider.zig");

const Mirror = @This();

allocator: std.mem.Allocator,
io: std.Io,
connection: *client.Connection,
/// The transcript the TUI draws, kept in step with the server's. Borrowed.
conversation: *Conversation,
host: []const u8,
reader: std.Thread = undefined,

inbox_mutex: std.Io.Mutex = .init,
inbox: std.DoublyLinkedList = .{},
/// Queued when the reader stops. Made up front, so losing the connection is
/// always heard about.
lost: *Inbound,

/// The last status, its strings in `status_arena`.
status: wire.Status = .{},
status_arena: std.heap.ArenaAllocator,
todos: todo.List,
/// What the sidebar and the composer read about the model. Never asked
/// anything: the server's own client answers the turns.
provider: Provider,

/// The skills the server offers, from the last snapshot, in `skills_arena`.
/// Only what describes them: running one is the server's job.
skills: []const skill.Skill = &.{},
skill_paths: []const []const u8 = &.{},
skills_arena: std.heap.ArenaAllocator,

stream_request: ?u64 = null,
thinking: Thought.Stream,
content: Thought.Stream,

/// What the server said for the person to read, oldest first. Owned.
notices: std.ArrayList([]u8) = .empty,
/// Answers to requests the TUI is waiting to show, oldest first. Owned.
answers: std.ArrayList(Answer) = .empty,
/// A snapshot replaced the transcript since the TUI last asked.
switched: bool = false,
/// Requests sent and not yet answered, by id.
waiting: std.AutoHashMapUnmanaged(u64, Awaited) = .empty,
paging: bool = false,
/// The session ended or the connection did; commands go nowhere now.
ended: bool = false,
lost_heard: bool = false,

const Awaited = union(enum) {
    /// A command, named for the notice should it fail.
    command: []const u8,
    tool_result: struct { seq: u64, call: u32 },
    thinking: u64,
    history,
    sessions,
    /// The query, owned, to say what was searched for.
    search: []const u8,
    /// A session opened to attach once it is up.
    fresh,
    models,
    files,
    providers,
};

/// What a request the TUI made came back with, for it to show.
pub const Answer = union(enum) {
    /// The project's stored sessions. Ids are the server's, so zero here.
    sessions: []Database.SessionInfo,
    search: struct { query: []u8, hits: []Database.Hit },
    /// Each provider the server knows, in an arena of their own.
    providers: struct { arena: std.heap.ArenaAllocator, states: []const wire.ProviderState },
    /// The project's files, for `@` mentions.
    files: [][]const u8,
    /// The models the server's provider offers, in an arena of their own.
    models: struct { arena: std.heap.ArenaAllocator, models: wire.Models },

    pub fn deinit(self: Answer, allocator: std.mem.Allocator) void {
        switch (self) {
            .sessions => |sessions| {
                for (sessions) |info| info.deinit(allocator);
                allocator.free(sessions);
            },
            .search => |found| {
                for (found.hits) |hit| hit.deinit(allocator);
                allocator.free(found.hits);
                allocator.free(found.query);
            },
            .models => |offer| {
                var arena = offer.arena;
                arena.deinit();
            },
            .providers => |known| {
                var arena = known.arena;
                arena.deinit();
            },
            .files => |paths| {
                for (paths) |path| allocator.free(path);
                allocator.free(paths);
            },
        }
    }
};

/// One frame off the wire, in an arena of its own.
const Inbound = struct {
    arena: std.heap.ArenaAllocator,
    frame: ?wire.Frame(wire.Down) = null,
    node: std.DoublyLinkedList.Node = .{},

    fn create(allocator: std.mem.Allocator) !*Inbound {
        const self = try allocator.create(Inbound);
        self.* = .{ .arena = .init(allocator) };
        return self;
    }

    fn destroy(self: *Inbound) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// Attach to `handle` on the far end of `connection`, and fill
/// `conversation` from the snapshot. The mirror owns the connection once this
/// succeeds; until then it is still the caller's.
pub fn attach(
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: *client.Connection,
    conversation: *Conversation,
    host: []const u8,
    handle: []const u8,
    failure: ?*client.Diagnostic,
) !*Mirror {
    const self = try allocator.create(Mirror);
    errdefer allocator.destroy(self);
    const lost = try Inbound.create(allocator);
    errdefer lost.destroy();
    self.* = .{
        .allocator = allocator,
        .io = io,
        .connection = connection,
        .conversation = conversation,
        .host = try allocator.dupe(u8, host),
        .lost = lost,
        .status_arena = .init(allocator),
        .skills_arena = .init(allocator),
        .todos = .init(allocator),
        .provider = .{ .name = "", .userdata = self, .respond = answerNothing, .efforts = effortsOffered },
        .thinking = .init(allocator, io),
        .content = .init(allocator, io),
    };
    errdefer self.freeState();

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const id = try connection.send(.{ .attach = .{ .handle = handle } });
    while (try connection.next(arena_state.allocator())) |frame| {
        if (frame.body == .snapshot) try self.applySnapshot(frame.body.snapshot);
        if (frame.body != .reply or frame.id != id) continue;
        if (frame.body.reply.ok) break;
        if (failure) |d| d.say("{s}: {s}", .{ host, frame.body.reply.@"error" orelse "refused" });
        return error.Refused;
    } else return error.ConnectionLost;

    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
    return self;
}

/// Leave the session, which carries on without us, and hang up.
pub fn detach(self: *Mirror) void {
    self.connection.interrupt();
    self.reader.join();
    while (self.inbox.popFirst()) |node| {
        const inbound: *Inbound = @fieldParentPtr("node", node);
        if (inbound != self.lost) inbound.destroy();
    }
    self.lost.destroy();
    self.connection.close();
    self.freeState();
    self.allocator.destroy(self);
}

fn freeState(self: *Mirror) void {
    for (self.notices.items) |notice| self.allocator.free(notice);
    self.notices.deinit(self.allocator);
    for (self.answers.items) |unshown| unshown.deinit(self.allocator);
    self.answers.deinit(self.allocator);
    var awaited = self.waiting.valueIterator();
    while (awaited.next()) |entry| if (entry.* == .search) self.allocator.free(entry.search);
    self.waiting.deinit(self.allocator);
    self.thinking.deinit();
    self.content.deinit();
    self.todos.deinit();
    self.status_arena.deinit();
    self.skills_arena.deinit();
    self.allocator.free(self.host);
}

fn answerNothing(_: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
    return error.RemoteSession;
}

/// Only the current model's levels are known here, which is all `/effort`
/// asks about; the model picker brings each model's own.
fn effortsOffered(ptr: *anyopaque, model: []const u8) Provider.Efforts {
    const self: *Mirror = @ptrCast(@alignCast(ptr));
    if (!std.mem.eql(u8, model, self.status.model)) return .{};
    return .{ .levels = self.status.efforts, .default = self.status.effort };
}

fn readLoop(self: *Mirror) void {
    while (true) {
        const inbound = Inbound.create(self.allocator) catch break;
        const frame = self.connection.next(inbound.arena.allocator()) catch null;
        inbound.frame = frame orelse {
            inbound.destroy();
            break;
        };
        self.queue(inbound);
    }
    self.queue(self.lost);
}

fn queue(self: *Mirror, inbound: *Inbound) void {
    self.inbox_mutex.lockUncancelable(self.io);
    defer self.inbox_mutex.unlock(self.io);
    self.inbox.append(&inbound.node);
}

/// Apply everything the server has said since the last call. Returns whether
/// anything changed.
pub fn poll(self: *Mirror) !bool {
    self.inbox_mutex.lockUncancelable(self.io);
    var received = self.inbox;
    self.inbox = .{};
    self.inbox_mutex.unlock(self.io);

    var changed = false;
    while (received.popFirst()) |node| {
        const inbound: *Inbound = @fieldParentPtr("node", node);
        if (inbound == self.lost) {
            // Left queued for `detach`, which frees it last.
            self.queue(inbound);
            if (self.lost_heard) return changed;
            self.lost_heard = true;
            if (!self.ended) try self.say("Lost the connection to {s}.", .{self.host});
            self.ended = true;
            return true;
        }
        defer inbound.destroy();
        try self.apply(inbound.frame.?);
        changed = true;
    }
    return changed;
}

fn apply(self: *Mirror, frame: wire.Frame(wire.Down)) !void {
    switch (frame.body) {
        .hello => {},
        .snapshot => |snapshot| try self.applySnapshot(snapshot),
        .appended => |appended| try self.applyMessage(appended.message, false),
        .updated => |updated| try self.applyMessage(updated.message, true),
        .stream => |stream| try self.applyStream(stream),
        .status => |status| try self.keepStatus(status),
        .notice => |notice| try self.say("{s}", .{notice.text}),
        .ended => {
            self.ended = true;
            try self.say("The session was stopped on {s}.", .{self.host});
        },
        .reply => |reply| try self.answered(frame.id orelse return, reply),
    }
}

/// Server message `seq` is numbered `(seq + 1) << note_bits` here, leaving
/// room before each for the notes the TUI appends itself - `/help`, `/search`
/// - which would otherwise take the next server message's number. Small, since
/// `Model.widgetKey` keeps only 31 bits of a number.
const note_bits = 8;

fn localSeq(seq: u64) u64 {
    return (seq + 1) << note_bits;
}

/// The server message a local number names, or the one after it for a note.
fn serverSeq(seq: u64) u64 {
    return ((seq + (1 << note_bits) - 1) >> note_bits) -| 1;
}

fn own(self: *Mirror, message: wire.Message) !Conversation.Message {
    var owned = try message.toOwned(self.allocator);
    owned.seq = localSeq(message.seq);
    return owned;
}

/// Every snapshot replaces what was there: the first one, or one for
/// another session attached on the same connection.
fn applySnapshot(self: *Mirror, snapshot: wire.Snapshot) !void {
    self.conversation.clear();
    self.resetStreams(null);
    self.switched = true;
    for (snapshot.messages) |message| try self.conversation.adoptMessage(try self.own(message));
    self.conversation.dropped += snapshot.dropped;
    try self.keepStatus(snapshot.status);
    if (snapshot.stream) |stream| try self.applyStream(stream);
    try self.keepSkills(snapshot.skills);
}

fn keepSkills(self: *Mirror, offered: wire.Skills) !void {
    self.skills = &.{};
    self.skill_paths = &.{};
    _ = self.skills_arena.reset(.retain_capacity);
    const arena = self.skills_arena.allocator();

    const kept = try arena.alloc(skill.Skill, offered.found.len);
    for (offered.found, kept) |found, *out| out.* = .{
        .id = try arena.dupe(u8, found.id),
        .name = try arena.dupe(u8, found.name),
        .description = try arena.dupe(u8, found.description),
        .dir = try arena.dupe(u8, found.dir),
        .body = "",
    };
    self.skill_paths = try dupeAll(arena, offered.looked_in);
    self.skills = kept;
}

fn applyMessage(self: *Mirror, message: wire.Message, changed: bool) !void {
    if (self.conversation.find(localSeq(message.seq))) |held| {
        const replacement = try self.own(message);
        held.deinit(self.allocator);
        held.* = replacement;
    } else if (!changed) {
        try self.conversation.adoptMessage(try self.own(message));
    }
}

fn applyStream(self: *Mirror, stream: wire.Stream) !void {
    if (self.stream_request != stream.request) self.resetStreams(stream.request);
    self.thinking.append(stream.thinking);
    self.content.append(stream.text);
    if (stream.closed and !self.thinking.isClosed()) self.thinking.close();
}

fn resetStreams(self: *Mirror, request: ?u64) void {
    self.thinking.deinit();
    self.thinking = .init(self.allocator, self.io);
    self.content.deinit();
    self.content = .init(self.allocator, self.io);
    self.stream_request = request;
}

/// Copy a status into an arena of its own, so it outlives the frame.
fn keepStatus(self: *Mirror, status: wire.Status) !void {
    _ = self.status_arena.reset(.retain_capacity);
    const arena = self.status_arena.allocator();

    var kept = status;
    kept.label = try arena.dupe(u8, status.label);
    kept.title = try arena.dupe(u8, status.title);
    kept.handle = try arena.dupe(u8, status.handle);
    kept.root = try arena.dupe(u8, status.root);
    kept.agent = try arena.dupe(u8, status.agent);
    kept.model = try arena.dupe(u8, status.model);
    kept.provider = try arena.dupe(u8, status.provider);
    kept.provider_id = try arena.dupe(u8, status.provider_id);
    if (status.sign_in) |sign_in| kept.sign_in = .{ .url = try arena.dupe(u8, sign_in.url), .port = sign_in.port };
    kept.effort = try arena.dupe(u8, status.effort);
    kept.efforts = try dupeAll(arena, status.efforts);
    kept.todos = &.{};
    const servers = try arena.alloc(mcp_tools.Status, status.mcp.len);
    for (status.mcp, servers) |server, *copy| copy.* = .{
        .name = try arena.dupe(u8, server.name),
        .state = server.state,
        .reason = try arena.dupe(u8, server.reason),
    };
    kept.mcp = servers;
    kept.pending_seq = if (status.pending_seq) |seq| localSeq(seq) else null;
    kept.notes = try dupeAll(arena, status.notes);
    kept.steering = try dupeAll(arena, status.steering);
    self.status = kept;

    try self.todos.replace(status.todos);
    self.provider.name = kept.provider;
    self.provider.model = kept.model;
    self.provider.context_limit = kept.context_limit;
    self.provider.effort = kept.effort;
}

fn dupeAll(arena: std.mem.Allocator, texts: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, texts.len);
    for (texts, out) |text, *copy| copy.* = try arena.dupe(u8, text);
    return out;
}

fn answered(self: *Mirror, id: u64, reply: @FieldType(wire.Down, "reply")) !void {
    const awaited = (self.waiting.fetchRemove(id) orelse return).value;
    defer if (awaited == .search) self.allocator.free(awaited.search);
    if (!reply.ok) {
        if (awaited == .history) self.paging = false;
        const what = switch (awaited) {
            .command => |name| name,
            .tool_result => "loading a tool result",
            .thinking => "loading the reasoning",
            .history => "loading older messages",
            .sessions => "listing the sessions",
            .search => "searching",
            .fresh => "starting a session",
            .models => "listing the models",
            .files => "listing the files",
            .providers => "listing the providers",
        };
        return self.say("{s} failed on {s}: {s}", .{ what, self.host, reply.@"error" orelse "no reason given" });
    }

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    switch (awaited) {
        .command => {},
        .tool_result => |at| {
            const text = try wire.parseResult([]const u8, arena, reply.result);
            const msg = self.conversation.find(at.seq) orelse return;
            if (at.call >= msg.tool_calls.len) return;
            const call = &msg.tool_calls[at.call];
            const full = try self.allocator.dupe(u8, text);
            if (call.result) |old| self.allocator.free(old);
            call.result = full;
        },
        .thinking => |seq| {
            const text = try wire.parseResult([]const u8, arena, reply.result);
            const msg = self.conversation.find(seq) orelse return;
            const full = try self.allocator.dupe(u8, text);
            if (msg.thinking) |old| self.allocator.free(old);
            msg.thinking = full;
        },
        .history => {
            self.paging = false;
            const older = try wire.parseResult([]const wire.Message, arena, reply.result);
            const owned = try arena.alloc(Conversation.Message, older.len);
            var built: usize = 0;
            errdefer for (owned[0..built]) |*msg| msg.deinit(self.allocator);
            for (older, owned) |message, *out| {
                out.* = try self.own(message);
                built += 1;
            }
            try self.conversation.prepend(owned);
        },
        .sessions => {
            const stored = try wire.parseResult([]const wire.Stored, arena, reply.result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            self.answers.appendAssumeCapacity(.{ .sessions = try ownSessions(self.allocator, stored) });
        },
        .search => |query| {
            const hits = try wire.parseResult([]const wire.Hit, arena, reply.result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            const copy = try self.allocator.dupe(u8, query);
            errdefer self.allocator.free(copy);
            self.answers.appendAssumeCapacity(.{ .search = .{ .query = copy, .hits = try ownHits(self.allocator, hits) } });
        },
        .providers => {
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            var kept: std.heap.ArenaAllocator = .init(self.allocator);
            errdefer kept.deinit();
            const states = try wire.parseResult([]const wire.ProviderState, kept.allocator(), reply.result);
            self.answers.appendAssumeCapacity(.{ .providers = .{ .arena = kept, .states = states } });
        },
        .files => {
            const paths = try wire.parseResult([]const []const u8, arena, reply.result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            self.answers.appendAssumeCapacity(.{ .files = try dupeEach(self.allocator, paths) });
        },
        .models => {
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            var kept: std.heap.ArenaAllocator = .init(self.allocator);
            errdefer kept.deinit();
            const models = try wire.parseResult(wire.Models, kept.allocator(), reply.result);
            self.answers.appendAssumeCapacity(.{ .models = .{ .arena = kept, .models = models } });
        },
        .fresh => {
            const opened = try wire.parseResult(wire.Summary, arena, reply.result);
            try self.switchTo(opened.handle);
        },
    }
}

fn dupeEach(allocator: std.mem.Allocator, texts: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, texts.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |text| allocator.free(text);
        allocator.free(out);
    }
    for (texts, out) |text, *copy| {
        copy.* = try allocator.dupe(u8, text);
        copied += 1;
    }
    return out;
}

fn ownSessions(allocator: std.mem.Allocator, stored: []const wire.Stored) ![]Database.SessionInfo {
    const out = try allocator.alloc(Database.SessionInfo, stored.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |info| info.deinit(allocator);
        allocator.free(out);
    }
    for (stored, out) |session, *info| {
        const public_id = try allocator.dupe(u8, session.handle);
        errdefer allocator.free(public_id);
        info.* = .{
            .id = 0,
            .public_id = public_id,
            .title = try allocator.dupe(u8, session.title),
            .updated_at = session.updated_at,
            .messages = session.messages,
        };
        built += 1;
    }
    return out;
}

fn ownHits(allocator: std.mem.Allocator, hits: []const wire.Hit) ![]Database.Hit {
    const out = try allocator.alloc(Database.Hit, hits.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |hit| hit.deinit(allocator);
        allocator.free(out);
    }
    for (hits, out) |hit, *owned| {
        owned.* = try ownHit(allocator, hit);
        built += 1;
    }
    return out;
}

fn ownHit(allocator: std.mem.Allocator, hit: wire.Hit) !Database.Hit {
    const public_id = try allocator.dupe(u8, hit.handle);
    errdefer allocator.free(public_id);
    const title = try allocator.dupe(u8, hit.title);
    errdefer allocator.free(title);
    const role = try allocator.dupe(u8, hit.role);
    errdefer allocator.free(role);
    return .{
        .session_id = 0,
        .public_id = public_id,
        .title = title,
        .seq = 0,
        .role = role,
        .created_at = 0,
        .excerpt = try allocator.dupe(u8, hit.excerpt),
    };
}

fn say(self: *Mirror, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(self.allocator, fmt, args);
    errdefer self.allocator.free(text);
    try self.notices.append(self.allocator, text);
}

fn send(self: *Mirror, body: wire.Up, awaited: Awaited) !void {
    if (self.ended) return error.SessionEnded;
    try self.waiting.ensureUnusedCapacity(self.allocator, 1);
    const id = try self.connection.send(body);
    self.waiting.putAssumeCapacity(id, awaited);
}

pub fn isBusy(self: *const Mirror) bool {
    return self.status.state != .idle;
}

pub fn label(self: *const Mirror) []const u8 {
    return self.status.label;
}

/// The reasoning of the request running now, or null between requests.
pub fn thoughts(self: *Mirror) ?*Thought.Stream {
    return if (self.streaming()) &self.thinking else null;
}

pub fn streamingText(self: *Mirror) ?*Thought.Stream {
    return if (self.streaming()) &self.content else null;
}

/// Whether the streams hold the request running now, not one long done.
fn streaming(self: *const Mirror) bool {
    const request = self.status.request orelse return false;
    const held = self.stream_request orelse return false;
    return request == held;
}

pub fn pendingCall(self: *Mirror) ?*Conversation.ToolCall {
    const seq = self.status.pending_seq orelse return null;
    const index = self.status.pending_call orelse return null;
    const msg = self.conversation.find(seq) orelse return null;
    if (index >= msg.tool_calls.len) return null;
    return &msg.tool_calls[index];
}

pub fn toolNote(self: *const Mirror, seq: u64, index: usize) ?[]const u8 {
    if (self.status.pending_seq != seq or index >= self.status.notes.len) return null;
    const text = self.status.notes[index];
    return if (text.len == 0) null else text;
}

/// Whether a snapshot replaced the transcript since the last call.
pub fn takeSwitched(self: *Mirror) bool {
    defer self.switched = false;
    return self.switched;
}

/// The oldest answer not yet shown, which the caller frees.
pub fn takeAnswer(self: *Mirror) ?Answer {
    if (self.answers.items.len == 0) return null;
    return self.answers.orderedRemove(0);
}

/// The oldest notice not yet shown, which the caller frees.
pub fn takeNotice(self: *Mirror) ?[]u8 {
    if (self.notices.items.len == 0) return null;
    return self.notices.orderedRemove(0);
}

pub fn submit(self: *Mirror, prompt: []const u8, extras: Loop.Extras) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const attachments = try arena_state.allocator().alloc(wire.Attachment, extras.attachments.len);
    for (extras.attachments, attachments) |attachment, *out| out.* = .{
        .path = attachment.path,
        .content = attachment.content,
        .content_bytes = attachment.content_bytes,
    };
    try self.send(.{ .submit = .{ .text = prompt, .attachments = attachments, .images = extras.images } }, .{ .command = "Sending the prompt" });
}

/// Whether the text went in as steering. Only while busy: otherwise it is a
/// prompt of its own, which is the caller's to send.
pub fn steer(self: *Mirror, text: []const u8) !bool {
    if (!self.isBusy()) return false;
    try self.send(.{ .steer = .{ .text = text } }, .{ .command = "Steering" });
    return true;
}

pub fn answer(self: *Mirror, text: []const u8) !void {
    try self.send(.{ .answer = .{ .text = text } }, .{ .command = "Answering" });
}

pub fn cancel(self: *Mirror) !void {
    try self.send(.{ .cancel = .{} }, .{ .command = "Cancelling" });
}

pub fn decide(self: *Mirror, decision: Loop.Decision) !void {
    try self.send(.{ .decide = .{ .decision = decision } }, .{ .command = "Deciding" });
}

pub fn compact(self: *Mirror) !void {
    try self.send(.{ .compact = .{} }, .{ .command = "Compacting" });
}

pub fn rename(self: *Mirror, title: []const u8) !void {
    try self.send(.{ .rename = .{ .title = title } }, .{ .command = "Renaming" });
}

/// Start a turn on one of the server's skills, as typed: `/id args`.
pub fn runSkill(self: *Mirror, line: []const u8) !void {
    try self.send(.{ .run_skill = .{ .line = line } }, .{ .command = "Running the skill" });
}

pub fn useAgent(self: *Mirror, id: []const u8) !void {
    try self.send(.{ .use_agent = .{ .agent = id } }, .{ .command = "Switching mode" });
}

/// Switch the server's model, to run at `effort`, or at the level last
/// chosen for it when that is null.
pub fn switchModel(self: *Mirror, model: []const u8, effort: ?[]const u8, provider_id: ?[]const u8) !void {
    try self.send(.{ .set_model = .{ .model = model, .effort = effort, .provider_id = provider_id } }, .{ .command = "Switching model" });
}

/// Ask what providers the server knows. They land on a later poll.
pub fn listProviders(self: *Mirror) !void {
    try self.send(.{ .providers = .{} }, .providers);
}

/// Point the session at a provider. A ChatGPT sign-in it needs shows up in
/// the status until it settles.
pub fn connectProvider(self: *Mirror, id: []const u8, host: []const u8, key: ?[]const u8) !void {
    try self.send(.{ .connect_provider = .{ .provider = id, .host = host, .key = key } }, .{ .command = "Connecting" });
}

pub fn toggleMcp(self: *Mirror, name: []const u8) !void {
    try self.send(.{ .toggle_mcp = .{ .name = name } }, .{ .command = "Toggling the MCP server" });
}

pub fn cancelSignIn(self: *Mirror) !void {
    try self.send(.{ .cancel_sign_in = .{} }, .{ .command = "Cancelling the sign-in" });
}

pub fn signOut(self: *Mirror) !void {
    try self.send(.{ .sign_out = .{} }, .{ .command = "Signing out" });
}

pub fn setEffort(self: *Mirror, level: []const u8) !void {
    try self.send(.{ .set_effort = .{ .effort = level } }, .{ .command = "Setting the effort" });
}

/// Ask for the project's files, unless that is already on its way. They
/// land on a later poll.
pub fn listFiles(self: *Mirror) !void {
    if (self.isWaitingFor(.files)) return;
    try self.send(.{ .files = .{} }, .files);
}

/// Ask what models the server's provider offers. They land on a later poll.
pub fn listModels(self: *Mirror, recent: usize) !void {
    try self.send(.{ .models = .{ .recent = @intCast(recent) } }, .models);
}

/// Ask for the whole result behind a preview. It lands on a later poll.
pub fn loadToolResult(self: *Mirror, msg: *Conversation.Message, index: usize) !void {
    if (index >= msg.tool_calls.len) return;
    const call = msg.tool_calls[index];
    if (call.result_bytes <= Conversation.preview_bytes) return;
    if (call.result) |result| if (result.len >= call.result_bytes) return;
    if (self.isWaitingFor(.{ .tool_result = .{ .seq = msg.seq, .call = @intCast(index) } })) return;
    try self.send(.{ .load_tool_result = .{ .seq = serverSeq(msg.seq), .call = @intCast(index) } }, .{ .tool_result = .{ .seq = msg.seq, .call = @intCast(index) } });
}

pub fn loadThinking(self: *Mirror, msg: *Conversation.Message) !void {
    if (msg.thinking_bytes <= Conversation.preview_bytes) return;
    if (msg.thinking) |text| if (text.len >= msg.thinking_bytes) return;
    if (self.isWaitingFor(.{ .thinking = msg.seq })) return;
    try self.send(.{ .load_thinking = .{ .seq = serverSeq(msg.seq) } }, .{ .thinking = msg.seq });
}

/// Drive another session on the server instead. Its snapshot replaces the
/// transcript on a later poll; this one carries on there without us.
pub fn switchTo(self: *Mirror, handle: []const u8) !void {
    try self.send(.{ .attach = .{ .handle = handle } }, .{ .command = "Switching session" });
}

/// Start a session in this one's directory, and switch to it once it is up.
pub fn startFresh(self: *Mirror) !void {
    try self.send(.{ .open = .{ .root = self.status.root } }, .fresh);
}

/// Ask for the project's stored sessions. They land on a later poll.
pub fn listSessions(self: *Mirror, limit: usize) !void {
    try self.send(.{ .sessions = .{ .limit = @intCast(limit) } }, .sessions);
}

/// Search the project's transcripts. The hits land on a later poll.
pub fn search(self: *Mirror, query: []const u8, limit: usize) !void {
    const owned = try self.allocator.dupe(u8, query);
    errdefer self.allocator.free(owned);
    try self.send(.{ .search = .{ .query = query, .limit = @intCast(limit) } }, .{ .search = owned });
}

/// Ask for older messages. They land on a later poll, so this reports none.
pub fn pageHistory(self: *Mirror, limit: usize) !usize {
    if (self.paging) return 0;
    const before = serverSeq(self.conversation.firstSeq() orelse return 0);
    if (before == 0) return 0;
    try self.send(.{ .page_history = .{ .before_seq = before, .limit = @intCast(limit) } }, .history);
    self.paging = true;
    return 0;
}

fn isWaitingFor(self: *const Mirror, wanted: Awaited) bool {
    var it = self.waiting.valueIterator();
    while (it.next()) |awaited| {
        if (std.meta.eql(awaited.*, wanted)) return true;
    }
    return false;
}

const Server = @import("server.zig");
const project_files = @import("../core/files.zig");

/// A mirror of a fresh session on `fixture`'s server, into `convo`.
fn attachFresh(fixture: *Server.Fixture, convo: *Conversation) !*Mirror {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const stream = try (try std.Io.net.UnixAddress.init(fixture.server.path)).connect(testing.io);
    const connection = try client.Connection.openStream(testing.allocator, testing.io, stream, null);
    errdefer connection.close();
    const opened = try wire.parseResult(wire.Summary, arena_state.allocator(), try connection.call(arena_state.allocator(), .{ .open = .{ .root = fixture.project } }, null));
    return attach(testing.allocator, testing.io, connection, convo, "test", opened.handle, null);
}

/// Poll until `done` says so, or fail after a few seconds.
fn pollUntil(mirror: *Mirror, comptime done: fn (*Mirror) bool) !void {
    for (0..500) |_| {
        _ = try mirror.poll();
        if (done(mirror)) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

fn awaitingApproval(mirror: *Mirror) bool {
    return mirror.status.state == .awaiting_approval;
}

fn finishedOne(mirror: *Mirror) bool {
    return mirror.status.state == .idle and mirror.status.finished == 1;
}

fn hasEnded(mirror: *Mirror) bool {
    return mirror.ended;
}

test "a mirror follows a turn, and its approval is answered from here" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    try testing.expectEqual(@as(usize, 0), convo.messages.items.len);
    try testing.expect(!try mirror.steer("not busy, so not steering"));

    try mirror.submit("make a note", .{});
    try pollUntil(mirror, awaitingApproval);
    const asked = mirror.pendingCall().?;
    try testing.expectEqualStrings("write", asked.name);
    try testing.expectEqual(Conversation.Role.user, convo.messages.items[0].role);
    try testing.expectEqualStrings("make a note", convo.messages.items[0].text);

    try mirror.decide(.once);
    try pollUntil(mirror, finishedOne);
    try testing.expectEqual(@as(?Loop.Outcome, .done), mirror.status.outcome);
    try testing.expect(mirror.pendingCall() == null);
    try testing.expect(mirror.thoughts() == null);

    const replied = for (convo.messages.items) |msg| {
        if (std.mem.eql(u8, msg.text, "done")) break true;
    } else false;
    try testing.expect(replied);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, convo.messages.items[1].tool_calls[0].status);

    try testing.expectEqual(convo.messages.items[convo.messages.items.len - 1].seq + 1, convo.next_seq);
}

test "a mirror hears its session stop, and says so once" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const stream = try (try std.Io.net.UnixAddress.init(fixture.server.path)).connect(testing.io);
    const other = try client.Connection.openStream(testing.allocator, testing.io, stream, null);
    defer other.close();
    _ = try other.call(arena_state.allocator(), .{ .stop = .{ .handle = mirror.status.handle } }, null);

    try pollUntil(mirror, hasEnded);
    const notice = mirror.takeNotice().?;
    defer testing.allocator.free(notice);
    try testing.expect(std.mem.indexOf(u8, notice, "stopped") != null);
    try testing.expectError(error.SessionEnded, mirror.submit("anyone there?", .{}));
}

/// Poll until the mirror is on `handle`, or on any other session than it.
fn pollUntilOn(mirror: *Mirror, handle: []const u8, on: bool) !void {
    for (0..500) |_| {
        _ = try mirror.poll();
        if (std.mem.eql(u8, mirror.status.handle, handle) == on) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

fn pollForAnswer(mirror: *Mirror) !Answer {
    for (0..500) |_| {
        _ = try mirror.poll();
        if (mirror.takeAnswer()) |found| return found;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

test "a mirror starts afresh, finds its old session, and goes back to it" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    const first = try testing.allocator.dupe(u8, mirror.status.handle);
    defer testing.allocator.free(first);
    try mirror.submit("make a note", .{});
    try pollUntil(mirror, awaitingApproval);
    try mirror.decide(.once);
    try pollUntil(mirror, finishedOne);
    const held = convo.messages.items.len;
    _ = mirror.takeSwitched();

    try mirror.startFresh();
    try pollUntilOn(mirror, first, false);
    try testing.expect(mirror.takeSwitched());
    try testing.expectEqual(@as(usize, 0), convo.messages.items.len);
    try testing.expectEqualStrings(fixture.project, mirror.status.root);

    try mirror.listSessions(10);
    const listed = try pollForAnswer(mirror);
    defer listed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), listed.sessions.len);
    try testing.expectEqualStrings(first, listed.sessions[0].public_id);

    try mirror.search("make a note", 10);
    const found = try pollForAnswer(mirror);
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings("make a note", found.search.query);
    try testing.expectEqualStrings(first, found.search.hits[0].public_id);

    try mirror.switchTo(first);
    try pollUntilOn(mirror, first, true);
    try testing.expectEqual(held, convo.messages.items.len);
    try testing.expectEqual(@as(u64, 1), mirror.status.finished);
}

test "a note written here keeps its place when the server's next message lands" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    _ = try convo.append(.{ .role = .assistant, .text = "a note from /help" });

    try mirror.submit("make a note", .{});
    try pollUntil(mirror, awaitingApproval);
    try testing.expectEqualStrings("a note from /help", convo.messages.items[0].text);
    try testing.expectEqualStrings("make a note", convo.messages.items[1].text);
    try testing.expectEqualStrings("write", mirror.pendingCall().?.name);

    try mirror.decide(.once);
    try pollUntil(mirror, finishedOne);
    try testing.expectEqualStrings("a note from /help", convo.messages.items[0].text);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, convo.messages.items[2].tool_calls[0].status);
}

test "a server number survives the trip here and back, and a note maps to the message after it" {
    const testing = std.testing;
    for ([_]u64{ 0, 1, 41, 1 << 22 }) |seq| try testing.expectEqual(seq, serverSeq(localSeq(seq)));
    try testing.expectEqual(@as(u64, 0), serverSeq(0));
    try testing.expectEqual(@as(u64, 0), serverSeq(3));
    try testing.expectEqual(@as(u64, 8), serverSeq(localSeq(7) + 1));
}

fn runsHigh(mirror: *Mirror) bool {
    return std.mem.eql(u8, mirror.provider.effort, "high");
}

test "a mirror lists the server's models, and its provider answers for the effort" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    try testing.expectEqual(@as(usize, 2), mirror.provider.effortsFor("scripted").levels.len);
    try testing.expectEqual(@as(usize, 0), mirror.provider.effortsFor("bigger").levels.len);

    try mirror.setEffort("high");
    try pollUntil(mirror, runsHigh);

    try mirror.listModels(5);
    const listed = try pollForAnswer(mirror);
    defer listed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), listed.models.models.offered.len);
    try testing.expectEqualStrings("high", listed.models.models.offered[0].effort);
}

test "a mirror lists its session's project files" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try fixture.tmp.dir.deleteTree(testing.io, "project/.git");
    if (!try project_files.initRepo(fixture.project)) return error.SkipZigTest;
    try fixture.tmp.dir.createDirPath(testing.io, "project/src");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "project/src/notes.md", .data = "hi" });
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const here = try project_files.list(arena_state.allocator(), testing.io, fixture.project, .{ .directories = true });
    try testing.expectEqualStrings("src/", here[0]);

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    try mirror.listFiles();
    try mirror.listFiles();
    const listed = try pollForAnswer(mirror);
    defer listed.deinit(testing.allocator);
    try testing.expectEqual(here.len, listed.files.len);
    for (here, listed.files) |expected, got| try testing.expectEqualStrings(expected, got);
    try testing.expect(mirror.takeAnswer() == null);
}

test "a mirror offers the server's skills, and running one sends the server's instructions" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "project/.agents/skills/release");
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/.agents/skills/release/SKILL.md",
        .data = "---\ndescription: Cut a release\n---\nTag it and push.\n",
    });

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    try testing.expectEqual(@as(usize, 1), mirror.skills.len);
    try testing.expectEqualStrings("release", mirror.skills[0].id);
    try testing.expectEqualStrings("Cut a release", mirror.skills[0].description);
    try testing.expect(mirror.skill_paths.len > 0);

    try mirror.runSkill("/release 2.1");
    try pollUntil(mirror, awaitingApproval);
    const asked = convo.messages.items[0];
    try testing.expectEqualStrings("/release 2.1", asked.text);
    try testing.expect(std.mem.indexOf(u8, asked.attachments[0].content, "Tag it and push.") != null);
}

fn planning(mirror: *Mirror) bool {
    return std.mem.eql(u8, mirror.status.agent, "plan");
}

test "a mirror switches its session's mode" {
    const testing = std.testing;
    const fixture = try Server.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try attachFresh(fixture, &convo);
    defer mirror.detach();
    try testing.expectEqualStrings("build", mirror.status.agent);
    try mirror.useAgent("plan");
    try pollUntil(mirror, planning);
}
