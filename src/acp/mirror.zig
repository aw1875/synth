//! A session hosted by an ACP agent, mirrored here for a TUI to draw.
//!
//! A reader thread parses what the agent sends and queues it. `poll`, on the
//! thread that draws, applies the queue - to the transcript it was handed, the
//! status, the streaming request - so nothing the TUI reads changes under it.
//! Requests go straight out, and their replies come back through the queue.

const std = @import("std");

const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const synth = @import("synth.zig");
const updates = @import("updates.zig");
const Connection = @import("connection.zig");
const sockets = @import("sockets.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const skill = @import("../core/skill.zig");
const todo = @import("../core/todo.zig");
const mcp_tools = @import("../tools/mcp.zig");
const Loop = @import("../agent/loop.zig");
const Thought = @import("../agent/thought.zig");
const Provider = @import("../provider/provider.zig");

const Mirror = @This();

allocator: std.mem.Allocator,
io: std.Io,
/// Null for a mirror with nothing behind it: see `offline`.
connection: ?*Connection,
/// The transcript the TUI draws, kept in step with the agent's. Borrowed.
conversation: *Conversation,
host: []const u8,
/// Where sessions hosted by other processes listen, to attach to them there.
socket_dir: ?[]const u8 = null,
reader: std.Thread = undefined,

inbox_mutex: std.Io.Mutex = .init,
inbox: std.DoublyLinkedList = .{},
/// Queued when the reader stops. Made up front, so losing the connection is
/// always heard about.
lost: *Inbound,

/// The last status, its strings in `status_arena`.
status: synth.Status = .{},
status_arena: std.heap.ArenaAllocator,
todos: todo.List,
/// What the sidebar and the composer read about the model. Never asked
/// anything: the agent's own client answers the turns.
provider: Provider,

/// The skills the agent offers, from the last snapshot, in `skills_arena`.
/// Only what describes them: running one is the agent's job.
skills: []const skill.Skill = &.{},
skill_paths: []const []const u8 = &.{},
skills_arena: std.heap.ArenaAllocator,

stream_request: ?u64 = null,
thinking: Thought.Stream,
content: Thought.Stream,

/// What the agent said for the person to read, oldest first. Owned.
notices: std.ArrayList([]u8) = .empty,
/// Answers to requests the TUI is waiting to show, oldest first. Owned.
answers: std.ArrayList(Answer) = .empty,
/// A snapshot replaced the transcript since the TUI last asked.
switched: bool = false,
/// The session open has anything in it.
spoken: bool = false,
/// The session goes on after we leave.
detached: bool = false,
/// Requests sent and not yet answered, by id.
waiting: std.AutoHashMapUnmanaged(i64, Awaited) = .empty,
/// The request out for the call waiting on a person. Owned.
asked: ?Asked = null,
/// A decision or an answer given before the request it settles arrived.
/// Owned.
early: ?Early = null,
paging: bool = false,
/// The agent has gone; requests go nowhere now.
ended: bool = false,
lost_heard: bool = false,

const Asked = struct {
    id: rpc.Id,
    call: []u8,
    on: union(enum) {
        decision,
        /// The answers the question's form offers to pick from.
        answer: [][]u8,
    },
};

const Early = union(enum) {
    decision: Loop.Decision,
    answer: []u8,
};

const Awaited = union(enum) {
    /// A request, named for the notice should it fail.
    command: []const u8,
    /// A prompt, answered once its turn is over.
    prompt,
    tool_result: struct { seq: u64, call: u32 },
    attachment: struct { seq: u64, index: u32 },
    thinking: u64,
    history,
    /// Stored sessions, at most this many of them.
    sessions: usize,
    /// The query, owned, to say what was searched for.
    search: []const u8,
    models,
    files,
    providers,
    /// The call whose subagent, by the TUI's own numbering.
    subagent: struct { seq: u64, call: u32 },
    detach,
};

/// What a request the TUI made came back with, for it to show.
pub const Answer = union(enum) {
    /// The project's stored sessions. Ids are the agent's, so zero here.
    sessions: []Database.SessionInfo,
    search: struct { query: []u8, hits: []Database.Hit },
    /// A subagent's transcript, for the call `call` of message `seq` as the
    /// TUI numbers it. Owned, numbered as the transcript is shown.
    subagent: struct { seq: u64, call: u32, live: bool, messages: []Conversation.Message },
    /// Each provider the agent knows, in an arena of their own.
    providers: struct { arena: std.heap.ArenaAllocator, states: []const synth.ProviderState },
    /// The project's files, for `@` mentions.
    files: [][]const u8,
    /// The models the agent's provider offers, in an arena of their own.
    models: struct { arena: std.heap.ArenaAllocator, models: synth.Models },
    /// The session will go on without us: time to leave.
    detached,

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
            .subagent => |transcript| {
                for (transcript.messages) |*msg| msg.deinit(allocator);
                allocator.free(transcript.messages);
            },
            .files => |paths| {
                for (paths) |path| allocator.free(path);
                allocator.free(paths);
            },
            .detached => {},
        }
    }
};

/// One message off the wire, in an arena of its own.
const Inbound = struct {
    arena: std.heap.ArenaAllocator,
    message: rpc.Message = .{},
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

/// Which session to open: a new one in a directory, a stored one, or the
/// one last spoken in in a directory's project, else a new one there.
pub const Target = union(enum) {
    new: []const u8,
    load: Stored,
    latest: []const u8,

    pub const Stored = struct {
        handle: []const u8,
        cwd: []const u8 = "",
        /// Hosted by another process, so attached to there.
        live: bool = false,
    };
};

/// Say hello to the agent at the far end of `connection`, open `target`, and
/// fill `conversation` from its snapshot. A stored session another process
/// hosts is attached to on its socket in `socket_dir` instead, and
/// `connection` closed. The mirror owns the connection either way.
pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: *Connection,
    conversation: *Conversation,
    host: []const u8,
    socket_dir: ?[]const u8,
    target: Target,
    failure: ?*Connection.Diagnostic,
) !*Mirror {
    const self = create(allocator, io, connection, conversation, host) catch |err| {
        connection.close();
        return err;
    };
    errdefer self.destroy();
    errdefer self.connection.?.close();
    self.socket_dir = socket_dir;

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stored: ?Target.Stored = switch (target) {
        .new => null,
        .load => |named| named,
        .latest => |cwd| blk: {
            try connection.initialize(arena, failure);
            break :blk try latestIn(connection, arena, cwd, failure);
        },
    };
    const elsewhere = if (stored) |named| try self.reach(named.handle) else null;
    if (elsewhere) |reached| {
        connection.close();
        self.connection = reached;
    }
    if (target != .latest or elsewhere != null) try self.connection.?.initialize(arena, failure);

    const cwd = switch (target) {
        .new, .latest => |dir| dir,
        .load => |named| named.cwd,
    };
    const id = if (stored) |named| try loadSession(self.connection.?, named) else try newSession(self.connection.?, cwd);
    var held = try awaitOpened(allocator, self.connection.?, id, failure);
    try self.applyAll(&held);
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
    return self;
}

/// Read until the agent answers request `id`, which opens a session,
/// returning what came before the answer to be applied in order.
fn awaitOpened(allocator: std.mem.Allocator, connection: *Connection, id: rpc.Id, failure: ?*Connection.Diagnostic) !std.DoublyLinkedList {
    var held: std.DoublyLinkedList = .{};
    errdefer discard(&held);
    while (true) {
        const inbound = try Inbound.create(allocator);
        inbound.message = (connection.next(inbound.arena.allocator()) catch |err| {
            inbound.destroy();
            return err;
        }) orelse {
            inbound.destroy();
            return error.ConnectionLost;
        };
        const message = inbound.message;
        if (message.method != null or message.id == null or !message.id.?.eql(id)) {
            held.append(&inbound.node);
            continue;
        }
        defer inbound.destroy();
        const err = message.err orelse return held;
        if (failure) |d| d.say("{s}", .{err.message});
        return error.Refused;
    }
}

fn applyAll(self: *Mirror, held: *std.DoublyLinkedList) !void {
    errdefer discard(held);
    while (held.popFirst()) |node| {
        const inbound: *Inbound = @fieldParentPtr("node", node);
        defer inbound.destroy();
        try self.apply(inbound.message);
    }
}

fn discard(held: *std.DoublyLinkedList) void {
    while (held.popFirst()) |node| {
        const inbound: *Inbound = @fieldParentPtr("node", node);
        inbound.destroy();
    }
}

/// A connection to the process hosting session `handle`, or null when none
/// listens for it.
fn reach(self: *Mirror, handle: []const u8) !?*Connection {
    const socket_dir = self.socket_dir orelse return null;
    const path = try sockets.pathFor(self.allocator, socket_dir, handle);
    defer self.allocator.free(path);
    const socket = sockets.connect(path) catch |err| switch (err) {
        error.NotListening => return null,
        else => return err,
    };
    errdefer socket.close(self.io);
    return try Connection.overSocket(self.allocator, self.io, socket);
}

/// Whether a session another process hosts is attached to here, rather than
/// through the agent at the far end.
pub fn attachesHere(self: *const Mirror) bool {
    return self.socket_dir != null;
}

/// Leave this session for `handle`, which another process hosts, attaching
/// to it there. This one ends as quitting would end it. Failing, it stays.
pub fn attach(self: *Mirror, handle: []const u8) !void {
    var failure: Connection.Diagnostic = .{};
    self.attachTo(handle, &failure) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.NotListening => return self.say("Attaching to {s} failed: it is not running", .{handle}),
        else => return self.say("Attaching to {s} failed: {s}", .{
            handle,
            if (failure.message.len > 0) failure.message else @errorName(err),
        }),
    };
}

fn attachTo(self: *Mirror, handle: []const u8, failure: *Connection.Diagnostic) !void {
    const old = try self.live();
    const elsewhere = try self.reach(handle) orelse return error.NotListening;
    var held = blk: {
        errdefer elsewhere.close();
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        try elsewhere.initialize(arena_state.allocator(), failure);
        const id = try loadSession(elsewhere, .{ .handle = handle });
        break :blk try awaitOpened(self.allocator, elsewhere, id, failure);
    };
    errdefer discard(&held);

    old.interrupt();
    self.reader.join();
    old.close();
    self.connection = elsewhere;
    self.forgetConnection();
    try self.applyAll(&held);
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
}

/// Drop what was waiting on the connection just replaced: its queue, its
/// requests, the question it asked.
fn forgetConnection(self: *Mirror) void {
    while (self.inbox.popFirst()) |node| {
        const inbound: *Inbound = @fieldParentPtr("node", node);
        if (inbound != self.lost) inbound.destroy();
    }
    var waited = self.waiting.valueIterator();
    while (waited.next()) |awaited| if (awaited.* == .search) self.allocator.free(awaited.search);
    self.waiting.clearRetainingCapacity();
    self.forgetAsked();
    self.forgetEarly();
    self.paging = false;
    self.ended = false;
    self.lost_heard = false;
}

fn newSession(connection: *Connection, cwd: []const u8) !rpc.Id {
    return connection.request(protocol.method.session_new, protocol.NewSession{ .cwd = cwd });
}

fn loadSession(connection: *Connection, stored: Target.Stored) !rpc.Id {
    return connection.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = stored.handle, .cwd = stored.cwd });
}

/// The session last spoken in in `cwd`'s project, if there is one.
fn latestIn(connection: *Connection, arena: std.mem.Allocator, cwd: []const u8, failure: ?*Connection.Diagnostic) !?Target.Stored {
    const result = try connection.call(arena, protocol.method.session_list, protocol.ListSessions{ .cwd = cwd }, failure);
    const listed = try rpc.parse(protocol.SessionList, arena, result);
    if (listed.sessions.len == 0) return null;
    const latest = listed.sessions[0];
    return .{ .handle = latest.sessionId, .cwd = cwd, .live = if (latest._meta) |meta| meta.synth.live else false };
}

/// A mirror with no agent behind it, whose status a test sets by hand to
/// draw a session that is not there. Every request fails as if the agent
/// had gone.
pub fn offline(allocator: std.mem.Allocator, io: std.Io, conversation: *Conversation, host: []const u8) !*Mirror {
    const self = try create(allocator, io, null, conversation, host);
    self.ended = true;
    return self;
}

fn create(allocator: std.mem.Allocator, io: std.Io, connection: ?*Connection, conversation: *Conversation, host: []const u8) !*Mirror {
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
    return self;
}

/// Hang up. A session in an agent of its own ends with the connection.
pub fn close(self: *Mirror) void {
    if (self.connection) |connection| {
        connection.interrupt();
        self.reader.join();
        connection.close();
    }
    self.destroy();
}

/// Free what `create` made, the connection aside.
fn destroy(self: *Mirror) void {
    while (self.inbox.popFirst()) |node| {
        const inbound: *Inbound = @fieldParentPtr("node", node);
        if (inbound != self.lost) inbound.destroy();
    }
    self.lost.destroy();
    self.forgetAsked();
    self.forgetEarly();
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
    self.allocator.destroy(self);
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
        const message = self.connection.?.next(inbound.arena.allocator()) catch null;
        inbound.message = message orelse {
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

/// Apply everything the agent has said since the last call. Returns whether
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
            // Left queued for `close`, which frees it last.
            self.queue(inbound);
            if (self.lost_heard) return changed;
            self.lost_heard = true;
            self.ended = true;
            if (self.socket_dir != null) {
                try self.say("The agent running this session has stopped. Pick it up again with: synth --session {s}", .{self.status.handle});
            } else {
                try self.say("The connection to {s} was lost. Pick the session up again with: synth remote connect {s} {s}", .{ self.host, self.host, self.status.handle });
            }
            return true;
        }
        defer inbound.destroy();
        try self.apply(inbound.message);
        changed = true;
    }
    return changed;
}

fn apply(self: *Mirror, message: rpc.Message) !void {
    const method = message.method orelse {
        const id = message.id orelse return;
        return self.answered(id, message);
    };
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const eql = std.mem.eql;
    const m = synth.method;

    if (eql(u8, method, m.snapshot)) return self.applySnapshot(try rpc.parse(synth.Snapshot, arena, message.params));
    if (eql(u8, method, protocol.method.session_request_permission)) return self.keepPermission(message, arena);
    if (eql(u8, method, protocol.method.elicitation_create)) return self.keepQuestion(message, arena);
    if (eql(u8, method, protocol.method.cancel_request)) {
        const withdrawn = try rpc.parse(protocol.CancelRequest, arena, message.params);
        const asked = self.asked orelse return;
        if (rpc.Id.from(withdrawn.requestId)) |id| if (id.eql(asked.id)) self.forgetAsked();
        return;
    }
    if (!self.isCurrent(message.params)) return;
    if (eql(u8, method, m.appended)) return self.applyMessage((try rpc.parse(synth.Appended, arena, message.params)).message, false);
    if (eql(u8, method, m.updated)) return self.applyMessage((try rpc.parse(synth.Appended, arena, message.params)).message, true);
    if (eql(u8, method, m.stream)) return self.applyStream((try rpc.parse(synth.StreamUpdate, arena, message.params)).stream);
    if (eql(u8, method, m.status)) return self.keepStatus((try rpc.parse(synth.StatusUpdate, arena, message.params)).status);
    if (eql(u8, method, m.notice)) return self.say("{s}", .{(try rpc.parse(synth.Notice, arena, message.params)).text});
    if (message.id) |id| if (self.connection) |connection| {
        try connection.fail(id, rpc.code.method_not_found, "this client does not take that request");
    };
}

/// Whether a notification is about the session open here, and not one the
/// agent has since moved on from.
fn isCurrent(self: *const Mirror, params: ?std.json.Value) bool {
    const value = params orelse return false;
    if (value != .object) return false;
    const session = value.object.get("sessionId") orelse return false;
    return session == .string and std.mem.eql(u8, session.string, self.status.handle);
}

fn keepPermission(self: *Mirror, message: rpc.Message, arena: std.mem.Allocator) !void {
    const id = message.id orelse return;
    const asked = try rpc.parse(protocol.RequestPermission, arena, message.params);
    try self.hold(id, asked.toolCall.toolCallId, .decision);
}

fn keepQuestion(self: *Mirror, message: rpc.Message, arena: std.mem.Allocator) !void {
    const id = message.id orelse return;
    const asked = try rpc.parse(protocol.FormElicitation(updates.Question), arena, message.params);
    const offered = asked.requestedSchema.properties.answer.oneOf orelse &.{};
    const choices = try self.allocator.alloc([]u8, offered.len);
    var kept: usize = 0;
    errdefer {
        for (choices[0..kept]) |choice| self.allocator.free(choice);
        self.allocator.free(choices);
    }
    for (offered, choices) |option, *choice| {
        choice.* = try self.allocator.dupe(u8, option.@"const");
        kept += 1;
    }
    try self.hold(id, asked.toolCallId orelse "", .{ .answer = choices });
}

/// Keep the request out for the waiting call, taking `on` over, and settle
/// it at once if the person got there first.
fn hold(self: *Mirror, id: rpc.Id, call: []const u8, on: @FieldType(Asked, "on")) !void {
    errdefer if (on == .answer) freeAll(self.allocator, on.answer);
    const owned_call = try self.allocator.dupe(u8, call);
    errdefer self.allocator.free(owned_call);
    const owned: rpc.Id = switch (id) {
        .number => id,
        .string => |text| .{ .string = try self.allocator.dupe(u8, text) },
    };
    self.forgetAsked();
    self.asked = .{ .id = owned, .call = owned_call, .on = on };

    const early = self.early orelse return;
    self.early = null;
    switch (early) {
        .decision => |decision| if (on == .decision) try self.decide(decision),
        .answer => |text| {
            defer self.allocator.free(text);
            if (on == .answer) try self.answer(text);
        },
    }
}

fn forgetAsked(self: *Mirror) void {
    const asked = self.asked orelse return;
    if (asked.id == .string) self.allocator.free(asked.id.string);
    self.allocator.free(asked.call);
    if (asked.on == .answer) freeAll(self.allocator, asked.on.answer);
    self.asked = null;
}

fn forgetEarly(self: *Mirror) void {
    const early = self.early orelse return;
    if (early == .answer) self.allocator.free(early.answer);
    self.early = null;
}

fn freeAll(allocator: std.mem.Allocator, texts: [][]u8) void {
    for (texts) |text| allocator.free(text);
    allocator.free(texts);
}

/// Agent message `seq` is numbered `(seq + 1) << note_bits` here, leaving
/// room before each for the notes the TUI appends itself - `/help`, `/search`
/// - which would otherwise take the next agent message's number. Small, since
/// `Model.widgetKey` keeps only 31 bits of a number.
const note_bits = 8;

fn localSeq(seq: u64) u64 {
    return (seq + 1) << note_bits;
}

/// The agent message a local number names, or the one after it for a note.
fn agentSeq(seq: u64) u64 {
    return ((seq + (1 << note_bits) - 1) >> note_bits) -| 1;
}

fn own(self: *Mirror, message: synth.Message) !Conversation.Message {
    var owned = try message.toOwned(self.allocator);
    owned.seq = localSeq(message.seq);
    return owned;
}

/// Every snapshot replaces what was there: the first one, or one for
/// another session opened on the same agent.
fn applySnapshot(self: *Mirror, snapshot: synth.Snapshot) !void {
    self.conversation.clear();
    self.resetStreams(null);
    self.forgetAsked();
    self.forgetEarly();
    self.switched = true;
    for (snapshot.messages) |message| try self.conversation.adoptMessage(try self.own(message));
    self.conversation.dropped += snapshot.dropped;
    self.spoken = snapshot.messages.len > 0 or snapshot.dropped > 0;
    try self.keepStatus(snapshot.status);
    if (snapshot.stream) |stream| try self.applyStream(stream);
    try self.keepSkills(snapshot.skills);
}

fn keepSkills(self: *Mirror, offered: synth.Skills) !void {
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

fn applyMessage(self: *Mirror, message: synth.Message, changed: bool) !void {
    if (self.conversation.find(localSeq(message.seq))) |held| {
        const replacement = try self.own(message);
        held.deinit(self.allocator);
        held.* = replacement;
    } else if (!changed) {
        try self.conversation.adoptMessage(try self.own(message));
        self.spoken = true;
    }
}

fn applyStream(self: *Mirror, stream: synth.Stream) !void {
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

/// Copy a status into an arena of its own, so it outlives the message.
fn keepStatus(self: *Mirror, status: synth.Status) !void {
    _ = self.status_arena.reset(.retain_capacity);
    const arena = self.status_arena.allocator();

    var kept = status;
    kept.label = try arena.dupe(u8, status.label);
    kept.pending_description = try arena.dupe(u8, status.pending_description);
    kept.title = try arena.dupe(u8, status.title);
    kept.handle = try arena.dupe(u8, status.handle);
    kept.root = try arena.dupe(u8, status.root);
    kept.project = try arena.dupe(u8, status.project);
    kept.branch = try arena.dupe(u8, status.branch);
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
    if (self.early) |early| {
        const still = switch (early) {
            .decision => kept.state == .awaiting_approval,
            .answer => kept.state == .awaiting_answer,
        };
        if (!still) self.forgetEarly();
    }

    try self.todos.replace(status.todos);
    self.provider.name = kept.provider;
    self.provider.model = kept.model;
    self.provider.context_limit = kept.context_limit;
    self.provider.vision = kept.vision;
    self.provider.effort = kept.effort;
}

fn dupeAll(arena: std.mem.Allocator, texts: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, texts.len);
    for (texts, out) |text, *copy| copy.* = try arena.dupe(u8, text);
    return out;
}

fn answered(self: *Mirror, id: rpc.Id, message: rpc.Message) !void {
    const number = switch (id) {
        .number => |n| n,
        .string => return,
    };
    const awaited = (self.waiting.fetchRemove(number) orelse return).value;
    defer if (awaited == .search) self.allocator.free(awaited.search);
    if (message.err) |err| {
        if (awaited == .history) self.paging = false;
        // A turn that failed has said so in the transcript already.
        if (awaited == .prompt and self.status.outcome == .failed) return;
        const what = switch (awaited) {
            .command => |name| name,
            .prompt => "Sending the prompt",
            .tool_result => "loading a tool result",
            .attachment => "loading an attachment",
            .thinking => "loading the reasoning",
            .history => "loading older messages",
            .sessions => "listing the sessions",
            .search => "searching",
            .models => "listing the models",
            .files => "listing the files",
            .providers => "listing the providers",
            .subagent => "loading the subagent's transcript",
            .detach => "Detaching",
        };
        return self.say("{s} failed: {s}", .{ what, err.message });
    }

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = message.result;
    switch (awaited) {
        .command, .prompt => {},
        .tool_result => |at| {
            const text = try rpc.parse([]const u8, arena, result);
            const msg = self.conversation.find(at.seq) orelse return;
            if (at.call >= msg.tool_calls.len) return;
            const call = &msg.tool_calls[at.call];
            const full = try self.allocator.dupe(u8, text);
            if (call.result) |old| self.allocator.free(old);
            call.result = full;
        },
        .attachment => |at| {
            const text = try rpc.parse([]const u8, arena, result);
            const msg = self.conversation.find(at.seq) orelse return;
            if (at.index >= msg.attachments.len) return;
            const attachment = &msg.attachments[at.index];
            const full = try self.allocator.dupe(u8, text);
            self.allocator.free(attachment.content);
            attachment.content = full;
        },
        .thinking => |seq| {
            const text = try rpc.parse([]const u8, arena, result);
            const msg = self.conversation.find(seq) orelse return;
            const full = try self.allocator.dupe(u8, text);
            if (msg.thinking) |old| self.allocator.free(old);
            msg.thinking = full;
        },
        .history => {
            self.paging = false;
            const older = try rpc.parse([]const synth.Message, arena, result);
            const owned = try arena.alloc(Conversation.Message, older.len);
            var built: usize = 0;
            errdefer for (owned[0..built]) |*msg| msg.deinit(self.allocator);
            for (older, owned) |held, *out| {
                out.* = try self.own(held);
                built += 1;
            }
            try self.conversation.prepend(owned);
        },
        .detach => {
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            (try self.live()).detached = true;
            self.detached = true;
            self.answers.appendAssumeCapacity(.detached);
        },
        .sessions => |limit| {
            const listed = try rpc.parse(protocol.SessionList, arena, result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            const kept = listed.sessions[0..@min(limit, listed.sessions.len)];
            self.answers.appendAssumeCapacity(.{ .sessions = try ownSessions(self.allocator, kept) });
        },
        .search => |query| {
            const hits = try rpc.parse([]const synth.Hit, arena, result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            const copy = try self.allocator.dupe(u8, query);
            errdefer self.allocator.free(copy);
            self.answers.appendAssumeCapacity(.{ .search = .{ .query = copy, .hits = try ownHits(self.allocator, hits) } });
        },
        .subagent => |at| {
            const transcript = try rpc.parse(synth.Transcript, arena, result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            const messages = try self.allocator.alloc(Conversation.Message, transcript.messages.len);
            var built: usize = 0;
            errdefer {
                for (messages[0..built]) |*msg| msg.deinit(self.allocator);
                self.allocator.free(messages);
            }
            for (transcript.messages, messages) |held, *out| {
                out.* = try held.toOwned(self.allocator);
                built += 1;
            }
            self.answers.appendAssumeCapacity(.{ .subagent = .{ .seq = at.seq, .call = at.call, .live = transcript.live, .messages = messages } });
        },
        .providers => {
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            var kept: std.heap.ArenaAllocator = .init(self.allocator);
            errdefer kept.deinit();
            const states = try rpc.parse([]const synth.ProviderState, kept.allocator(), result);
            self.answers.appendAssumeCapacity(.{ .providers = .{ .arena = kept, .states = states } });
        },
        .files => {
            const paths = try rpc.parse([]const []const u8, arena, result);
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            self.answers.appendAssumeCapacity(.{ .files = try dupeEach(self.allocator, paths) });
        },
        .models => {
            try self.answers.ensureUnusedCapacity(self.allocator, 1);
            var kept: std.heap.ArenaAllocator = .init(self.allocator);
            errdefer kept.deinit();
            const models = try rpc.parse(synth.Models, kept.allocator(), result);
            self.answers.appendAssumeCapacity(.{ .models = .{ .arena = kept, .models = models } });
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

fn ownSessions(allocator: std.mem.Allocator, listed: []const protocol.SessionInfo) ![]Database.SessionInfo {
    const out = try allocator.alloc(Database.SessionInfo, listed.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |info| info.deinit(allocator);
        allocator.free(out);
    }
    for (listed, out) |session, *info| {
        const stored: synth.Stored = if (session._meta) |meta| meta.synth else .{};
        const public_id = try allocator.dupe(u8, session.sessionId);
        errdefer allocator.free(public_id);
        info.* = .{
            .id = 0,
            .public_id = public_id,
            .title = try allocator.dupe(u8, session.title orelse ""),
            .updated_at = stored.updated_at,
            .messages = stored.messages,
            .live = stored.live,
        };
        built += 1;
    }
    return out;
}

fn ownHits(allocator: std.mem.Allocator, hits: []const synth.Hit) ![]Database.Hit {
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

fn ownHit(allocator: std.mem.Allocator, hit: synth.Hit) !Database.Hit {
    const public_id = try allocator.dupe(u8, hit.handle);
    errdefer allocator.free(public_id);
    const named = try allocator.dupe(u8, hit.title);
    errdefer allocator.free(named);
    const role = try allocator.dupe(u8, hit.role);
    errdefer allocator.free(role);
    return .{
        .session_id = 0,
        .public_id = public_id,
        .title = named,
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

fn live(self: *Mirror) !*Connection {
    if (self.ended) return error.SessionEnded;
    return self.connection orelse error.SessionEnded;
}

fn send(self: *Mirror, method: []const u8, params: anytype, awaited: Awaited) !void {
    const connection = try self.live();
    try self.waiting.ensureUnusedCapacity(self.allocator, 1);
    const id = try connection.request(method, params);
    self.waiting.putAssumeCapacity(id.number, awaited);
}

pub fn isBusy(self: *const Mirror) bool {
    return self.status.state != .idle;
}

pub fn state(self: *const Mirror) Loop.State {
    return self.status.state;
}

pub fn title(self: *const Mirror) []const u8 {
    return self.status.title;
}

pub fn agentId(self: *const Mirror) []const u8 {
    return self.status.agent;
}

pub fn usage(self: *const Mirror) Loop.Usage {
    return self.status.usage;
}

pub fn outcome(self: *const Mirror) ?Loop.Outcome {
    return self.status.outcome;
}

/// Turns finished so far, to tell a new ending from one already seen.
pub fn finishedTurns(self: *const Mirror) u64 {
    return self.status.finished;
}

/// The message whose calls are being decided or run, as numbered here.
pub fn pendingSeq(self: *const Mirror) ?u64 {
    return self.status.pending_seq;
}

/// The call waiting on a decision, by index into the pending message's.
pub fn firstPending(self: *const Mirror) ?usize {
    return if (self.status.pending_call) |index| index else null;
}

/// Prompts typed while busy, waiting for the next step.
pub fn pendingSteering(self: *const Mirror) []const []const u8 {
    return self.status.steering;
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

/// Start a turn, or steer the one running.
pub fn submit(self: *Mirror, prompt: []const u8, extras: Loop.Extras) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const blocks = try arena_state.allocator().alloc(protocol.Content, 1 + extras.attachments.len + extras.images.len);
    blocks[0] = .{ .text = prompt };
    for (extras.attachments, blocks[1..][0..extras.attachments.len]) |attachment, *block| {
        block.* = .{ .resource = .{ .path = attachment.path, .text = attachment.content } };
    }
    for (extras.images, blocks[1 + extras.attachments.len ..]) |image, *block| block.* = .{ .image = image };
    try self.send(protocol.method.session_prompt, .{ .sessionId = self.status.handle, .prompt = blocks }, .prompt);
}

/// Whether the text went in as steering. Only while busy: otherwise it is a
/// prompt of its own, which is the caller's to send.
pub fn steer(self: *Mirror, text: []const u8) !bool {
    if (!self.isBusy()) return false;
    try self.submit(text, .{});
    return true;
}

/// Answer the question out for the call waiting on an answer, or the one
/// on its way when the status already says a question is waiting. An
/// answer that is not one the form offers goes in its field for the
/// person's own.
pub fn answer(self: *Mirror, text: []const u8) !void {
    const connection = try self.live();
    const asked = self.asked orelse {
        if (self.status.state != .awaiting_answer) return error.NothingToAnswer;
        self.forgetEarly();
        self.early = .{ .answer = try self.allocator.dupe(u8, text) };
        return;
    };
    const choices = switch (asked.on) {
        .answer => |choices| choices,
        .decision => return error.NothingToAnswer,
    };
    const offered = choices.len == 0 or for (choices) |choice| {
        if (std.mem.eql(u8, choice, text)) break true;
    } else false;
    const filled: updates.Question.Filled = if (offered) .{ .answer = text } else .{ .other = text };
    try connection.reply(asked.id, protocol.Elicited(updates.Question.Filled){ .action = "accept", .content = filled });
    self.forgetAsked();
}

pub fn cancel(self: *Mirror) !void {
    try (try self.live()).notify(protocol.method.session_cancel, protocol.SessionId{ .sessionId = self.status.handle });
}

/// Answer the permission request out for the call waiting on a decision,
/// or the one on its way when the status already says a call is waiting.
pub fn decide(self: *Mirror, decision: Loop.Decision) !void {
    const connection = try self.live();
    const asked = self.asked orelse {
        if (self.status.state != .awaiting_approval) return error.NothingToDecide;
        self.forgetEarly();
        self.early = .{ .decision = decision };
        return;
    };
    if (asked.on != .decision) return error.NothingToDecide;
    try connection.reply(asked.id, .{ .outcome = .{ .outcome = "selected", .optionId = @tagName(decision) } });
    self.forgetAsked();
}

pub fn compact(self: *Mirror) !void {
    try self.send(synth.method.compact, protocol.SessionId{ .sessionId = self.status.handle }, .{ .command = "Compacting" });
}

pub fn rename(self: *Mirror, name: []const u8) !void {
    try self.send(synth.method.rename, synth.Rename{ .sessionId = self.status.handle, .title = name }, .{ .command = "Renaming" });
}

/// Start a turn on one of the agent's skills, as typed: `/id args`.
pub fn runSkill(self: *Mirror, line: []const u8) !void {
    try self.submit(line, .{});
}

pub fn useAgent(self: *Mirror, id: []const u8) !void {
    try self.send(protocol.method.session_set_mode, protocol.SetMode{ .sessionId = self.status.handle, .modeId = id }, .{ .command = "Switching mode" });
}

/// Switch the agent's model, to run at `effort`, or at the level last chosen
/// for it when that is null.
pub fn switchModel(self: *Mirror, model: []const u8, effort: ?[]const u8, provider_id: ?[]const u8) !void {
    try self.send(protocol.method.session_set_config_option, protocol.SetConfigOption{
        .sessionId = self.status.handle,
        .configId = protocol.config_model,
        .value = model,
        ._meta = .{ .synth = .{ .effort = effort, .provider = provider_id } },
    }, .{ .command = "Switching model" });
}

/// Ask what providers the agent knows. They land on a later poll.
pub fn listProviders(self: *Mirror) !void {
    try self.send(synth.method.providers, protocol.SessionId{ .sessionId = self.status.handle }, .providers);
}

/// Point the session at a provider. A ChatGPT sign-in it needs shows up in
/// the status until it settles.
pub fn connectProvider(self: *Mirror, id: []const u8, host: []const u8, key: ?[]const u8) !void {
    try self.send(synth.method.connect_provider, synth.ConnectProvider{ .sessionId = self.status.handle, .provider = id, .host = host, .key = key }, .{ .command = "Connecting" });
}

pub fn toggleMcp(self: *Mirror, name: []const u8) !void {
    try self.send(synth.method.toggle_mcp, synth.ToggleMcp{ .sessionId = self.status.handle, .name = name }, .{ .command = "Toggling the MCP server" });
}

pub fn cancelSignIn(self: *Mirror) !void {
    try self.send(synth.method.cancel_sign_in, protocol.SessionId{ .sessionId = self.status.handle }, .{ .command = "Cancelling the sign-in" });
}

pub fn signOut(self: *Mirror) !void {
    try self.send(synth.method.sign_out, protocol.SessionId{ .sessionId = self.status.handle }, .{ .command = "Signing out" });
}

pub fn setEffort(self: *Mirror, level: []const u8) !void {
    try self.send(protocol.method.session_set_config_option, protocol.SetConfigOption{
        .sessionId = self.status.handle,
        .configId = protocol.config_effort,
        .value = level,
    }, .{ .command = "Setting the effort" });
}

/// Ask for the project's files, unless that is already on its way. They
/// land on a later poll.
pub fn listFiles(self: *Mirror) !void {
    if (self.isWaitingFor(.files)) return;
    try self.send(synth.method.files, protocol.SessionId{ .sessionId = self.status.handle }, .files);
}

/// Ask what models the agent's provider offers. They land on a later poll.
pub fn listModels(self: *Mirror, recent: usize) !void {
    try self.send(synth.method.models, synth.ListModels{ .sessionId = self.status.handle, .recent = @intCast(recent) }, .models);
}

/// Ask for the whole result behind a preview. It lands on a later poll.
pub fn loadToolResult(self: *Mirror, msg: *Conversation.Message, index: usize) !void {
    if (index >= msg.tool_calls.len) return;
    const call = msg.tool_calls[index];
    if (call.result_bytes <= Conversation.preview_bytes) return;
    if (call.result) |result| if (result.len >= call.result_bytes) return;
    const wanted: Awaited = .{ .tool_result = .{ .seq = msg.seq, .call = @intCast(index) } };
    if (self.isWaitingFor(wanted)) return;
    try self.send(synth.method.load_tool_result, synth.LoadToolResult{ .sessionId = self.status.handle, .seq = agentSeq(msg.seq), .call = @intCast(index) }, wanted);
}

/// Ask for the whole of an attachment held back as a preview. It lands on a
/// later poll.
pub fn loadAttachment(self: *Mirror, msg: *Conversation.Message, index: usize) !void {
    if (index >= msg.attachments.len or !msg.attachments[index].shortened()) return;
    const wanted: Awaited = .{ .attachment = .{ .seq = msg.seq, .index = @intCast(index) } };
    if (self.isWaitingFor(wanted)) return;
    try self.send(synth.method.load_attachment, synth.LoadAttachment{ .sessionId = self.status.handle, .seq = agentSeq(msg.seq), .index = @intCast(index) }, wanted);
}

pub fn loadThinking(self: *Mirror, msg: *Conversation.Message) !void {
    if (msg.thinking_bytes <= Conversation.preview_bytes) return;
    if (msg.thinking) |text| if (text.len >= msg.thinking_bytes) return;
    if (self.isWaitingFor(.{ .thinking = msg.seq })) return;
    try self.send(synth.method.load_thinking, synth.LoadThinking{ .sessionId = self.status.handle, .seq = agentSeq(msg.seq) }, .{ .thinking = msg.seq });
}

/// Open a stored session instead. Its snapshot replaces the transcript on a
/// later poll, and this one ends.
pub fn switchTo(self: *Mirror, handle: []const u8) !void {
    try self.send(protocol.method.session_load, protocol.LoadSession{ .sessionId = handle, .cwd = self.status.root }, .{ .command = "Switching session" });
}

/// Start a session in this one's directory instead. Its snapshot replaces
/// the transcript on a later poll.
pub fn startFresh(self: *Mirror) !void {
    try self.send(protocol.method.session_new, protocol.NewSession{ .cwd = self.status.root }, .{ .command = "Starting a session" });
}

/// Ask the agent to keep the session running once we leave. Its answer says
/// when to.
pub fn detach(self: *Mirror) !void {
    try self.send(synth.method.detach, protocol.SessionId{ .sessionId = self.status.handle }, .detach);
}

/// Ask for the project's stored sessions. They land on a later poll.
pub fn listSessions(self: *Mirror, limit: usize) !void {
    try self.send(protocol.method.session_list, protocol.ListSessions{ .cwd = self.status.root }, .{ .sessions = limit });
}

/// Search the project's transcripts. The hits land on a later poll.
pub fn search(self: *Mirror, query: []const u8, limit: usize) !void {
    const owned = try self.allocator.dupe(u8, query);
    errdefer self.allocator.free(owned);
    try self.send(synth.method.search, synth.Search{ .sessionId = self.status.handle, .query = query, .limit = @intCast(limit) }, .{ .search = owned });
}

/// Ask for the transcript of the subagent that call `call` of message `seq`
/// ran, unless that is already on its way. It lands on a later poll.
pub fn loadSubagent(self: *Mirror, seq: u64, call: u32) !void {
    const wanted: Awaited = .{ .subagent = .{ .seq = seq, .call = call } };
    if (self.isWaitingFor(wanted)) return;
    try self.send(synth.method.subagent, synth.Subagent{ .sessionId = self.status.handle, .seq = agentSeq(seq), .call = call }, wanted);
}

/// Ask for older messages. They land on a later poll, so this reports none.
pub fn pageHistory(self: *Mirror, limit: usize) !usize {
    if (self.paging) return 0;
    const before = agentSeq(self.conversation.firstSeq() orelse return 0);
    if (before == 0) return 0;
    try self.send(synth.method.page_history, synth.PageHistory{ .sessionId = self.status.handle, .before_seq = before, .limit = @intCast(limit) }, .history);
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

const testing = std.testing;
const Agent = @import("agent.zig");
const project_files = @import("../core/files.zig");

/// A mirror of a fresh session on `fixture`'s agent, into `convo`.
fn openFresh(fixture: *Agent.Fixture, convo: *Conversation) !*Mirror {
    const connection = try Connection.overSocket(testing.allocator, testing.io, try fixture.socket());
    return open(testing.allocator, testing.io, connection, convo, Connection.here, null, .{ .new = fixture.project }, null);
}

/// Poll until `done` says so, or fail after a few seconds.
fn pollUntil(mirror: *Mirror, comptime done: fn (*Mirror) bool) !void {
    for (0..500) |_| {
        _ = try mirror.poll();
        if (done(mirror)) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

/// Waiting on a decision, with the permission request for it here.
fn awaitingApproval(mirror: *Mirror) bool {
    return mirror.status.state == .awaiting_approval and mirror.asked != null;
}

fn finishedOne(mirror: *Mirror) bool {
    return mirror.status.state == .idle and mirror.status.finished == 1;
}

/// The agent reports a turn over a moment before it answers the prompt.
fn finishedAndAnswered(mirror: *Mirror) bool {
    return finishedOne(mirror) and mirror.waiting.count() == 0;
}

fn awaitingAnswer(mirror: *Mirror) bool {
    return mirror.status.state == .awaiting_answer;
}

test "a question is answered from here, whether or not its request has arrived yet" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try testing.expectError(error.NothingToAnswer, mirror.answer("too soon"));

    try mirror.submit("ask me", .{});
    try pollUntil(mirror, awaitingAnswer);
    try testing.expectError(error.NothingToDecide, mirror.decide(.once));
    try mirror.answer("green");
    try pollUntil(mirror, finishedOne);
    try testing.expectEqual(@as(?Loop.Outcome, .done), mirror.status.outcome);
    try testing.expectEqualStrings("green", convo.messages.items[1].tool_calls[0].result.?);
    try testing.expect(mirror.asked == null and mirror.early == null);
}

test "a mirror follows a turn, and its approval is answered from here" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try testing.expectEqual(@as(usize, 0), convo.messages.items.len);
    try testing.expect(!try mirror.steer("not busy, so not steering"));
    try testing.expectError(error.NothingToDecide, mirror.decide(.once));

    try mirror.submit("make a note", .{});
    try pollUntil(mirror, awaitingApproval);
    const asked = mirror.pendingCall().?;
    try testing.expectEqualStrings("write", asked.name);
    try testing.expectEqual(Conversation.Role.user, convo.messages.items[0].role);
    try testing.expectEqualStrings("make a note", convo.messages.items[0].text);

    try mirror.decide(.once);
    try pollUntil(mirror, finishedAndAnswered);
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

fn cancelled(mirror: *Mirror) bool {
    return mirror.status.state == .idle and mirror.status.outcome == .cancelled;
}

test "a cancelled turn takes its question back from the mirror" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try mirror.submit("make a note", .{});
    try pollUntil(mirror, awaitingApproval);
    try mirror.cancel();
    try pollUntil(mirror, cancelled);
    try testing.expect(mirror.asked == null);
    try testing.expectError(error.NothingToDecide, mirror.decide(.once));
}

/// Poll until the mirror is on `handle`, or on any other session than it.
fn pollUntilOn(mirror: *Mirror, handle: []const u8, on: bool) !void {
    for (0..500) |_| {
        _ = try mirror.poll();
        if (std.mem.eql(u8, mirror.status.handle, handle) == on) return;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

fn pollForAnswer(mirror: *Mirror) !Answer {
    for (0..500) |_| {
        _ = try mirror.poll();
        if (mirror.takeAnswer()) |found| return found;
        try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

test "a mirror starts afresh, finds its old session, and goes back to it" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
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
    try testing.expect(listed.sessions[0].messages >= 4);

    try mirror.search("make a note", 10);
    const found = try pollForAnswer(mirror);
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings("make a note", found.search.query);
    try testing.expectEqualStrings(first, found.search.hits[0].public_id);

    try mirror.switchTo(first);
    try pollUntilOn(mirror, first, true);
    try testing.expectEqual(held, convo.messages.items.len);
}

test "a note written here keeps its place when the agent's next message lands" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
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

test "an agent's number survives the trip here and back, and a note maps to the message after it" {
    for ([_]u64{ 0, 1, 41, 1 << 22 }) |seq| try testing.expectEqual(seq, agentSeq(localSeq(seq)));
    try testing.expectEqual(@as(u64, 0), agentSeq(0));
    try testing.expectEqual(@as(u64, 0), agentSeq(3));
    try testing.expectEqual(@as(u64, 8), agentSeq(localSeq(7) + 1));
}

fn textOnly(mirror: *Mirror) bool {
    return !mirror.provider.vision;
}

fn runsHigh(mirror: *Mirror) bool {
    return std.mem.eql(u8, mirror.provider.effort, "high");
}

test "a mirror switches model and effort, and lists the agent's models" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try testing.expect(mirror.provider.vision);
    try testing.expectEqual(@as(usize, 2), mirror.provider.effortsFor("scripted").levels.len);
    try testing.expectEqual(@as(usize, 0), mirror.provider.effortsFor("bigger").levels.len);

    try mirror.setEffort("high");
    try pollUntil(mirror, runsHigh);
    try mirror.switchModel("bigger", null, null);
    try pollUntil(mirror, textOnly);

    try mirror.listModels(5);
    const listed = try pollForAnswer(mirror);
    defer listed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), listed.models.models.offered.len);
}

test "a mirror lists its session's project files" {
    const fixture = try Agent.Fixture.create();
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

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try mirror.listFiles();
    try mirror.listFiles();
    const listed = try pollForAnswer(mirror);
    defer listed.deinit(testing.allocator);
    try testing.expectEqual(here.len, listed.files.len);
    for (here, listed.files) |expected, got| try testing.expectEqualStrings(expected, got);
    try testing.expect(mirror.takeAnswer() == null);
}

test "a mirror offers the agent's skills, and running one sends the agent's instructions" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "project/.agents/skills/release");
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/.agents/skills/release/SKILL.md",
        .data = "---\ndescription: Cut a release\n---\nTag it and push.\n",
    });

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
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
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try testing.expectEqualStrings("build", mirror.status.agent);
    try mirror.useAgent("plan");
    try pollUntil(mirror, planning);
}

fn hasNotice(mirror: *Mirror) bool {
    return mirror.notices.items.len > 0;
}

test "a mirror loads the transcript a subagent call left" {
    const fixture = try Agent.Fixture.create();
    defer fixture.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const mirror = try openFresh(fixture, &convo);
    defer mirror.close();
    try mirror.submit("make a note", .{});
    try pollUntil(mirror, awaitingApproval);
    try mirror.decide(.once);
    try pollUntil(mirror, finishedOne);
    const asking = convo.messages.items[1];
    try testing.expectEqualStrings("write", asking.tool_calls[0].name);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const db_path = try std.fs.path.join(arena_state.allocator(), &.{ std.fs.path.dirname(fixture.project).?, "synth.db" });
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();
    const session = (try db.sessionByHandle(mirror.status.handle)).?;
    const message = (try db.messageId(session, @intCast(agentSeq(asking.seq)))).?;
    const call = (try db.toolCallId(message, 0)).?;
    const project = try db.resolveProject(fixture.project, "git", "project");
    const child = try db.createSubagentSession(project, fixture.project, "scripted", session, call);
    _ = try db.appendMessage(child, 0, "user", "look around", null, 0);
    _ = try db.appendMessage(child, 1, "assistant", "found it", null, 0);

    try mirror.loadSubagent(asking.seq, 0);
    const loaded = try pollForAnswer(mirror);
    defer loaded.deinit(testing.allocator);
    try testing.expect(!loaded.subagent.live);
    try testing.expectEqual(asking.seq, loaded.subagent.seq);
    try testing.expectEqual(@as(usize, 2), loaded.subagent.messages.len);
    try testing.expectEqualStrings("look around", loaded.subagent.messages[0].text);
    try testing.expectEqualStrings("found it", loaded.subagent.messages[1].text);

    try mirror.loadSubagent(asking.seq, 5);
    try pollUntil(mirror, hasNotice);
    const notice = mirror.takeNotice().?;
    defer testing.allocator.free(notice);
    try testing.expect(std.mem.indexOf(u8, notice, "no transcript") != null);
}

test "a session another process hosts is attached to on its socket, opening or switching" {
    const hosting = try Agent.Fixture.create();
    defer hosting.destroy();
    const socket_dir = try std.fs.path.join(hosting.arena.allocator(), &.{ std.fs.path.dirname(hosting.project).?, "sockets" });
    hosting.agent.options.socket_dir = socket_dir;
    const host = try hosting.connect();
    defer host.close();
    try host.initialize(true);
    const handle = try hosting.arena.allocator().dupe(u8, (try host.open(hosting.project)).sessionId);

    const other = try Agent.Fixture.create();
    defer other.destroy();
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    const opened = try open(testing.allocator, testing.io, try Connection.overSocket(testing.allocator, testing.io, try other.socket()), &convo, Connection.here, socket_dir, .{ .load = .{ .handle = handle } }, null);
    try testing.expectEqualStrings(handle, opened.status.handle);
    opened.close();

    const switching = try openFresh(other, &convo);
    defer switching.close();
    switching.socket_dir = socket_dir;
    try switching.attach("ses_nowhere");
    const refused = switching.takeNotice().?;
    defer testing.allocator.free(refused);
    try testing.expectEqualStrings("Attaching to ses_nowhere failed: it is not running", refused);
    try switching.attach(handle);
    try testing.expectEqualStrings(handle, switching.status.handle);
    try testing.expect(switching.takeSwitched());
}
