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

stream_request: ?u64 = null,
thinking: Thought.Stream,
content: Thought.Stream,

/// What the server said for the person to read, oldest first. Owned.
notices: std.ArrayList([]u8) = .empty,
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
        .todos = .init(allocator),
        .provider = .{ .name = "", .userdata = self, .respond = answerNothing },
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
    self.waiting.deinit(self.allocator);
    self.thinking.deinit();
    self.content.deinit();
    self.todos.deinit();
    self.status_arena.deinit();
    self.allocator.free(self.host);
}

fn answerNothing(_: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
    return error.RemoteSession;
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

fn applySnapshot(self: *Mirror, snapshot: wire.Snapshot) !void {
    self.conversation.clear();
    for (snapshot.messages) |message| try self.conversation.adoptMessage(try message.toOwned(self.allocator));
    self.conversation.dropped += snapshot.dropped;
    try self.keepStatus(snapshot.status);
    if (snapshot.stream) |stream| try self.applyStream(stream);
}

fn applyMessage(self: *Mirror, message: wire.Message, changed: bool) !void {
    if (self.conversation.find(message.seq)) |held| {
        const replacement = try message.toOwned(self.allocator);
        held.deinit(self.allocator);
        held.* = replacement;
    } else if (!changed) {
        try self.conversation.adoptMessage(try message.toOwned(self.allocator));
    }
}

fn applyStream(self: *Mirror, stream: wire.Stream) !void {
    if (self.stream_request != stream.request) {
        self.thinking.deinit();
        self.thinking = .init(self.allocator, self.io);
        self.content.deinit();
        self.content = .init(self.allocator, self.io);
        self.stream_request = stream.request;
    }
    self.thinking.append(stream.thinking);
    self.content.append(stream.text);
    if (stream.closed and !self.thinking.isClosed()) self.thinking.close();
}

/// Copy a status into an arena of its own, so it outlives the frame.
fn keepStatus(self: *Mirror, status: wire.Status) !void {
    _ = self.status_arena.reset(.retain_capacity);
    const arena = self.status_arena.allocator();

    var kept = status;
    kept.label = try arena.dupe(u8, status.label);
    kept.title = try arena.dupe(u8, status.title);
    kept.handle = try arena.dupe(u8, status.handle);
    kept.agent = try arena.dupe(u8, status.agent);
    kept.model = try arena.dupe(u8, status.model);
    kept.provider = try arena.dupe(u8, status.provider);
    kept.todos = &.{};
    kept.notes = try dupeAll(arena, status.notes);
    kept.steering = try dupeAll(arena, status.steering);
    self.status = kept;

    try self.todos.replace(status.todos);
    self.provider.name = kept.provider;
    self.provider.model = kept.model;
    self.provider.context_limit = kept.context_limit;
}

fn dupeAll(arena: std.mem.Allocator, texts: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, texts.len);
    for (texts, out) |text, *copy| copy.* = try arena.dupe(u8, text);
    return out;
}

fn answered(self: *Mirror, id: u64, reply: @FieldType(wire.Down, "reply")) !void {
    const awaited = (self.waiting.fetchRemove(id) orelse return).value;
    if (!reply.ok) {
        if (awaited == .history) self.paging = false;
        const what = switch (awaited) {
            .command => |name| name,
            .tool_result => "loading a tool result",
            .thinking => "loading the reasoning",
            .history => "loading older messages",
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
                out.* = try message.toOwned(self.allocator);
                built += 1;
            }
            try self.conversation.prepend(owned);
        },
    }
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

pub fn useAgent(self: *Mirror, id: []const u8) !void {
    try self.send(.{ .use_agent = .{ .id = id } }, .{ .command = "Switching mode" });
}

pub fn switchModel(self: *Mirror, model: []const u8) !void {
    try self.send(.{ .set_model = .{ .model = model } }, .{ .command = "Switching model" });
}

/// Ask for the whole result behind a preview. It lands on a later poll.
pub fn loadToolResult(self: *Mirror, msg: *Conversation.Message, index: usize) !void {
    if (index >= msg.tool_calls.len) return;
    const call = msg.tool_calls[index];
    if (call.result_bytes <= Conversation.preview_bytes) return;
    if (call.result) |result| if (result.len >= call.result_bytes) return;
    if (self.isWaitingFor(.{ .tool_result = .{ .seq = msg.seq, .call = @intCast(index) } })) return;
    try self.send(.{ .load_tool_result = .{ .seq = msg.seq, .call = @intCast(index) } }, .{ .tool_result = .{ .seq = msg.seq, .call = @intCast(index) } });
}

pub fn loadThinking(self: *Mirror, msg: *Conversation.Message) !void {
    if (msg.thinking_bytes <= Conversation.preview_bytes) return;
    if (msg.thinking) |text| if (text.len >= msg.thinking_bytes) return;
    if (self.isWaitingFor(.{ .thinking = msg.seq })) return;
    try self.send(.{ .load_thinking = .{ .seq = msg.seq } }, .{ .thinking = msg.seq });
}

/// Ask for older messages. They land on a later poll, so this reports none.
pub fn pageHistory(self: *Mirror, limit: usize) !usize {
    if (self.paging) return 0;
    const before = self.conversation.firstSeq() orelse return 0;
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
