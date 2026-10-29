//! An ACP agent hosting one session at a time, for whoever is connected: the
//! TUI that spawned it, or an editor.
//!
//! The session is driven from one thread, which owns its loop, the database
//! connection and the provider client, and is the only thread that touches
//! them. Each connection has a reader thread, which parses messages into the
//! inbox, and a writer thread, which drains one outbox. Replies and
//! notifications share that outbox, so a client sees them in the order they
//! were made.

const std = @import("std");

const pkg = @import("pkg");
const mcp = @import("mcp");

const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const synth = @import("synth.zig");
const Providers = @import("providers.zig");
const Config = @import("../core/config.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const mention = @import("../core/mention.zig");
const Project = @import("../core/project.zig");
const skill = @import("../core/skill.zig");
const project_files = @import("../core/files.zig");
const agents = @import("../agent/agent.zig");
const Loop = @import("../agent/loop.zig");
const Stack = @import("../agent/stack.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const SignInTask = @import("../provider/chatgpt_sign_in.zig");
const SignOutTask = @import("../provider/chatgpt_sign_out.zig");
const Provider = @import("../provider/provider.zig");
const skill_tool = @import("../tools/skill.zig");

const Agent = @This();

/// Messages a session keeps in memory, as the TUI does. Older ones stay in
/// the database and page back in on request.
const max_messages: usize = 200;

/// How often a busy session is polled. An idle one sleeps until told to act.
const poll_interval: std.Io.Duration = .fromMilliseconds(20);

/// What a client may have queued and unsent before it is cut off, rather
/// than the agent holding an unbounded backlog for it.
const max_outbox_bytes: usize = 64 * 1024 * 1024;

/// Sessions `session/list` returns.
const listed_sessions: usize = 50;

/// Where the session's provider client comes from.
pub const Source = union(enum) {
    /// The real thing, which a session may switch to another provider.
    providers: *Providers,
    /// A provider no session can switch away from. For tests.
    provider: Provider,
};

pub const Options = struct {
    config: *const Config,
    /// Used from the session's thread only.
    db: *Database,
    source: Source,
    home: ?[]const u8 = null,
    /// Where MCP tokens and on/off choices are kept.
    mcp_auth_path: ?[]const u8 = null,
};

allocator: std.mem.Allocator,
io: std.Io,
options: Options,

/// Guards `connections`, `inbox` and `live`.
mutex: std.Io.Mutex = .init,
connections: std.ArrayList(*Connection) = .empty,
inbox: std.DoublyLinkedList = .{},
/// Raised for every message in, and every connection lost.
wake: std.Io.Event = .unset,
/// The live session's handle and project root, for what is answered off the
/// session's thread.
live: ?struct { handle: []u8, root: []u8 } = null,

session: ?*Session = null,
/// The permission request out for the call waiting on a decision.
asked: ?Asked = null,
/// Prompts answered when the turn they started or steered ends.
prompts: std.ArrayList(Prompting) = .empty,
next_id: i64 = 1,

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) Agent {
    return .{ .allocator = allocator, .io = io, .options = options };
}

/// Join every connection and end the session. Called once `serve` returns.
pub fn deinit(self: *Agent) void {
    self.closeSession();
    for (self.connections.items) |connection| connection.destroy();
    self.connections.deinit(self.allocator);
    var leftover = self.inbox;
    while (leftover.popFirst()) |node| Inbound.of(node).destroy();
    self.prompts.deinit(self.allocator);
}

/// Speak ACP over a pair of files, until `input` ends. Both are closed with
/// the connection, once if they are the same.
pub fn connect(self: *Agent, input: std.Io.File, output: std.Io.File) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.connections.ensureUnusedCapacity(self.allocator, 1);
    self.connections.appendAssumeCapacity(try Connection.create(self, input, output));
}

/// Answer the connections until the last of them has gone.
pub fn serve(self: *Agent) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();

    while (true) {
        self.wake.reset();
        var gone = self.finishedConnections() catch std.ArrayList(*Connection).empty;
        defer gone.deinit(self.allocator);
        self.drainInbox();
        for (gone.items) |connection| self.drop(connection);
        if (self.connectionCount() == 0) return;

        const arena = arena_state.allocator();
        if (self.session) |session| {
            session.step();
            session.publish(arena, true) catch |err| self.noticeFmt("Could not report progress: {s}", .{@errorName(err)});
            self.settleApproval(arena);
            self.settlePrompts();
        }
        _ = arena_state.reset(.retain_capacity);

        const busy = if (self.session) |session| session.busy() else false;
        if (busy) {
            self.wake.waitTimeout(self.io, .{ .duration = .{ .raw = poll_interval, .clock = .awake } }) catch {};
        } else {
            self.wake.waitUncancelable(self.io);
        }
    }
}

fn connectionCount(self: *Agent) usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.connections.items.len;
}

/// The connections whose reader has finished. Taken before the inbox is
/// drained: a reader finishes after queueing its last message, so nothing
/// of theirs is left behind once they are dropped.
fn finishedConnections(self: *Agent) !std.ArrayList(*Connection) {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var out: std.ArrayList(*Connection) = .empty;
    for (self.connections.items) |connection| {
        if (connection.finished.load(.acquire)) try out.append(self.allocator, connection);
    }
    return out;
}

/// Forget a connection that has gone, and free it.
fn drop(self: *Agent, connection: *Connection) void {
    if (self.asked) |*asked| asked.forget(connection);
    var at: usize = 0;
    while (at < self.prompts.items.len) {
        if (self.prompts.items[at].connection == connection) {
            var gone = self.prompts.orderedRemove(at);
            gone.deinit(self.allocator);
        } else at += 1;
    }
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = std.mem.indexOfScalar(*Connection, self.connections.items, connection).?;
        _ = self.connections.swapRemove(index);
    }
    connection.destroy();
}

fn post(self: *Agent, inbound: *Inbound) void {
    self.mutex.lockUncancelable(self.io);
    self.inbox.append(&inbound.node);
    self.mutex.unlock(self.io);
    self.wake.set(self.io);
}

fn drainInbox(self: *Agent) void {
    var taken = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const taken = self.inbox;
        self.inbox = .{};
        break :blk taken;
    };
    while (taken.popFirst()) |node| {
        const inbound = Inbound.of(node);
        defer inbound.destroy();
        self.dispatch(inbound);
    }
}

fn dispatch(self: *Agent, inbound: *Inbound) void {
    const message = inbound.message;
    const connection = inbound.connection;
    const arena = inbound.arena.allocator();
    const method = message.method orelse return self.answered(connection, message);
    self.perform(connection, message.id, method, message.params, arena) catch |err| {
        const id = message.id orelse return self.noticeFmt("{s} failed: {s}", .{ method, describe(err) });
        switch (err) {
            error.InvalidParams => connection.fail(id, rpc.code.invalid_params, "invalid params"),
            error.MethodNotFound => connection.fail(id, rpc.code.method_not_found, "unknown method"),
            error.NotInitialized => connection.fail(id, rpc.code.invalid_request, "initialize first"),
            else => connection.fail(id, rpc.code.internal_error, describe(err)),
        }
    };
}

fn perform(self: *Agent, connection: *Connection, id: ?rpc.Id, method: []const u8, params: ?std.json.Value, arena: std.mem.Allocator) !void {
    const eql = std.mem.eql;
    if (eql(u8, method, protocol.method.initialize)) return self.initialize(connection, try need(id), try rpc.parse(protocol.Initialize, arena, params));
    if (!connection.initialized) {
        if (id == null) return;
        return error.NotInitialized;
    }

    if (eql(u8, method, protocol.method.session_cancel)) {
        const session = try self.sessionFor((try rpc.parse(protocol.SessionId, arena, params)).sessionId);
        if (session.stack.loop.isBusy()) try session.stack.loop.cancel();
        return;
    }
    if (eql(u8, method, protocol.method.cancel_request)) {
        return self.cancelPrompt(connection, (try rpc.parse(protocol.CancelRequest, arena, params)).requestId);
    }
    const asked = try need(id);
    if (eql(u8, method, protocol.method.session_new)) {
        const request = try rpc.parse(protocol.NewSession, arena, params);
        if (!std.fs.path.isAbsolute(request.cwd)) return error.RelativeCwd;
        const session = try self.open(request.cwd, null);
        return connection.reply(asked, protocol.SessionSetup{
            .sessionId = session.handle,
            .modes = session.modes(),
            .configOptions = try session.configOptions(arena),
        });
    }
    if (eql(u8, method, protocol.method.session_load)) {
        const request = try rpc.parse(protocol.LoadSession, arena, params);
        const session = try self.open(request.cwd, request.sessionId);
        return connection.reply(asked, protocol.Loaded{
            .modes = session.modes(),
            .configOptions = try session.configOptions(arena),
        });
    }
    if (eql(u8, method, protocol.method.session_list)) {
        return connection.reply(asked, try self.listSessions(arena, try rpc.parse(protocol.ListSessions, arena, params)));
    }
    if (eql(u8, method, protocol.method.session_close)) {
        _ = try self.sessionFor((try rpc.parse(protocol.SessionId, arena, params)).sessionId);
        self.closeSession();
        return connection.reply(asked, .{});
    }
    if (eql(u8, method, protocol.method.session_prompt)) {
        const request = try rpc.parse(protocol.Prompt, arena, params);
        try (try self.sessionFor(request.sessionId)).prompt(arena, request.prompt);
        const owned = try Prompting.init(self.allocator, connection, asked);
        self.prompts.append(self.allocator, owned) catch |err| {
            var unsent = owned;
            unsent.deinit(self.allocator);
            return err;
        };
        return;
    }
    if (eql(u8, method, protocol.method.session_set_mode)) {
        const request = try rpc.parse(protocol.SetMode, arena, params);
        const session = try self.sessionFor(request.sessionId);
        if (session.stack.loop.isBusy()) return error.Busy;
        try session.stack.loop.useAgent(request.modeId);
        return connection.reply(asked, .{});
    }
    if (eql(u8, method, protocol.method.session_set_config_option)) {
        const request = try rpc.parse(protocol.SetConfigOption, arena, params);
        const session = try self.sessionFor(request.sessionId);
        try session.setConfigOption(request);
        return connection.reply(asked, protocol.ConfigOptions{ .configOptions = try session.configOptions(arena) });
    }
    if (std.mem.startsWith(u8, method, "_synth/")) return self.performSynth(connection, asked, method, params, arena);
    return error.MethodNotFound;
}

/// A request from synth's extension. Each names the session it is for.
fn performSynth(self: *Agent, connection: *Connection, id: rpc.Id, method: []const u8, params: ?std.json.Value, arena: std.mem.Allocator) !void {
    const eql = std.mem.eql;
    const m = synth.method;
    const session = try self.sessionFor((try rpc.parse(protocol.SessionId, arena, params)).sessionId);
    const loop = &session.stack.loop;

    if (eql(u8, method, m.answer)) {
        try loop.answer((try rpc.parse(synth.Answer, arena, params)).text);
    } else if (eql(u8, method, m.compact)) {
        try loop.compact();
    } else if (eql(u8, method, m.rename)) {
        try loop.rename((try rpc.parse(synth.Rename, arena, params)).title);
    } else if (eql(u8, method, m.providers)) {
        return connection.reply(id, try (try session.providerSource()).states(arena, self.options.db));
    } else if (eql(u8, method, m.connect_provider)) {
        const asked = try rpc.parse(synth.ConnectProvider, arena, params);
        try session.connectProvider(asked.provider, asked.host, asked.key);
    } else if (eql(u8, method, m.cancel_sign_in)) {
        if (session.sign_in) |task| task.cancel();
    } else if (eql(u8, method, m.sign_out)) {
        try session.signOut();
    } else if (eql(u8, method, m.toggle_mcp)) {
        try session.toggleMcp((try rpc.parse(synth.ToggleMcp, arena, params)).name);
    } else if (eql(u8, method, m.models)) {
        return connection.reply(id, try session.models(arena, (try rpc.parse(synth.ListModels, arena, params)).recent));
    } else if (eql(u8, method, m.load_tool_result)) {
        const asked = try rpc.parse(synth.LoadToolResult, arena, params);
        return connection.reply(id, try session.loadToolResult(arena, asked.seq, asked.call));
    } else if (eql(u8, method, m.load_attachment)) {
        const asked = try rpc.parse(synth.LoadAttachment, arena, params);
        return connection.reply(id, try session.loadAttachment(arena, asked.seq, asked.index));
    } else if (eql(u8, method, m.load_thinking)) {
        return connection.reply(id, try session.loadThinking(arena, (try rpc.parse(synth.LoadThinking, arena, params)).seq));
    } else if (eql(u8, method, m.subagent)) {
        const asked = try rpc.parse(synth.Subagent, arena, params);
        return connection.reply(id, try session.subagentTranscript(arena, asked.seq, asked.call));
    } else if (eql(u8, method, m.page_history)) {
        const asked = try rpc.parse(synth.PageHistory, arena, params);
        return connection.reply(id, try session.loadHistory(arena, asked.before_seq, asked.limit));
    } else if (eql(u8, method, m.search)) {
        const asked = try rpc.parse(synth.Search, arena, params);
        return connection.reply(id, try session.search(arena, asked.query, asked.limit));
    } else return error.MethodNotFound;
    connection.reply(id, .{});
}

fn need(id: ?rpc.Id) !rpc.Id {
    return id orelse error.InvalidRequest;
}

fn initialize(self: *Agent, connection: *Connection, id: rpc.Id, request: protocol.Initialize) !void {
    _ = self;
    const asked = if (request._meta) |meta| meta.synth else null;
    if (asked) |hello| {
        if (hello.protocol != synth.version) {
            var buffer: [96]u8 = undefined;
            const reason = std.fmt.bufPrint(&buffer, "synth extension {d} asked for, this agent speaks {d}", .{ hello.protocol, synth.version }) catch "synth extension version mismatch";
            return connection.fail(id, rpc.code.invalid_params, reason);
        }
    }
    connection.initialized = true;
    connection.dialect = if (asked != null) .synth else .standard;
    connection.reply(id, protocol.Initialized{
        .agentInfo = .{ .name = pkg.name, .version = pkg.version },
        ._meta = if (asked != null) .{ .synth = .{ .protocol = synth.version } } else null,
    });
}

/// The live session, when `id` names it.
fn sessionFor(self: *Agent, id: []const u8) !*Session {
    const session = self.session orelse return error.UnknownSession;
    if (!std.mem.eql(u8, session.handle, id)) return error.UnknownSession;
    return session;
}

/// Make the session in `cwd` - a new one, or the stored one `handle` names -
/// the live one, and send every synth client its snapshot. A session already
/// live is kept rather than built again.
fn open(self: *Agent, cwd: []const u8, handle: ?[]const u8) !*Session {
    if (handle) |wanted| {
        if (self.session) |session| {
            if (std.mem.eql(u8, session.handle, wanted)) {
                try self.sendSnapshots(session);
                return session;
            }
        }
    }
    if (self.options.source == .providers) {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        try self.options.source.providers.start(arena_state.allocator(), self.options.db);
    }

    const db = self.options.db;
    const id: i64, const where: []const u8 = if (handle) |wanted| blk: {
        const id = try db.sessionByHandle(wanted) orelse return error.UnknownSession;
        break :blk .{ id, try db.sessionCwd(id, self.allocator) };
    } else blk: {
        const resolved = try std.Io.Dir.cwd().realPathFileAlloc(self.io, cwd, self.allocator);
        defer self.allocator.free(resolved);
        const real = try self.allocator.dupe(u8, resolved);
        errdefer self.allocator.free(real);
        var project = try Project.detect(self.allocator, self.io, real);
        defer project.deinit(self.allocator);
        const project_id = try db.resolveProject(project.root, "git", project.name());
        break :blk .{ try db.createSession(project_id, real, self.sourceModel()), real };
    };
    defer self.allocator.free(where);

    self.closeSession();
    const session = Session.create(self, id, where) catch |err| {
        if (handle == null) db.deleteSession(id) catch {};
        return err;
    };
    self.session = session;
    try self.share(session);

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    try session.publish(arena_state.allocator(), false);
    try self.sendSnapshots(session);
    return session;
}

/// The model a new session starts on.
fn sourceModel(self: *Agent) []const u8 {
    return switch (self.options.source) {
        .providers => |providers| providers.backend.model(),
        .provider => |provider| provider.model,
    };
}

fn share(self: *Agent, session: *Session) !void {
    const handle = try self.allocator.dupe(u8, session.handle);
    errdefer self.allocator.free(handle);
    const root = try self.allocator.dupe(u8, session.stack.project.root);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.live = .{ .handle = handle, .root = root };
}

fn unshare(self: *Agent) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const live = self.live orelse return;
    self.allocator.free(live.handle);
    self.allocator.free(live.root);
    self.live = null;
}

/// End the live session, answering whatever was waiting on it.
fn closeSession(self: *Agent) void {
    const session = self.session orelse return;
    self.withdraw();
    for (self.prompts.items) |*waiting| {
        waiting.connection.reply(waiting.id, protocol.Prompted{ .stopReason = .cancelled });
        waiting.deinit(self.allocator);
    }
    self.prompts.clearRetainingCapacity();
    self.unshare();
    self.session = null;
    session.destroy();
}

fn sendSnapshots(self: *Agent, session: *Session) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const snapshot = try session.snapshot(arena_state.allocator());
    var encoded: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try rpc.notify(&encoded.writer, synth.method.snapshot, snapshot);
    self.pushSynth(encoded.written());
}

/// Send a line to every client speaking synth's extension.
fn pushSynth(self: *Agent, line: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items) |connection| {
        if (connection.dialect == .synth) connection.push(line);
    }
}

fn notifySynth(self: *Agent, method: []const u8, params: anytype) void {
    var encoded: std.Io.Writer.Allocating = .init(self.allocator);
    defer encoded.deinit();
    rpc.notify(&encoded.writer, method, params) catch return;
    self.pushSynth(encoded.written());
}

fn noticeFmt(self: *Agent, comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch fmt;
    self.notice(text);
}

fn notice(self: *Agent, text: []const u8) void {
    const session = self.session orelse return;
    self.notifySynth(synth.method.notice, synth.Notice{ .sessionId = session.handle, .text = text });
}

/// Answer the prompts waiting on the session once it has nothing left to do
/// for them, with how the last turn ended.
fn settlePrompts(self: *Agent) void {
    if (self.prompts.items.len == 0) return;
    const session = self.session orelse return;
    const loop = &session.stack.loop;
    if (loop.isBusy() or loop.pendingSteering().len > 0) return;

    const outcome = loop.outcome orelse .done;
    for (self.prompts.items) |*waiting| {
        switch (outcome) {
            .done => waiting.connection.reply(waiting.id, protocol.Prompted{ .stopReason = .end_turn }),
            .cancelled => waiting.connection.reply(waiting.id, protocol.Prompted{ .stopReason = .cancelled }),
            .halted => waiting.connection.reply(waiting.id, protocol.Prompted{ .stopReason = .max_turn_requests }),
            .failed => waiting.connection.fail(waiting.id, rpc.code.internal_error, if (loop.last_error) |err| describe(err) else "the turn failed"),
        }
        waiting.deinit(self.allocator);
    }
    self.prompts.clearRetainingCapacity();
}

/// `$/cancel_request` for a prompt: it is answered at once, and the turn
/// left running. `session/cancel` is what stops a turn.
fn cancelPrompt(self: *Agent, connection: *Connection, request: std.json.Value) void {
    const id = rpc.Id.from(request) orelse return;
    for (self.prompts.items, 0..) |*waiting, at| {
        if (waiting.connection != connection or !waiting.id.eql(id)) continue;
        connection.fail(waiting.id, rpc.code.request_cancelled, "cancelled");
        var gone = self.prompts.orderedRemove(at);
        gone.deinit(self.allocator);
        return;
    }
}

/// Ask every client about the call waiting on a decision, once; and take the
/// question back from all of them once it is no longer waiting.
fn settleApproval(self: *Agent, arena: std.mem.Allocator) void {
    const session = self.session orelse return self.withdraw();
    const waiting = session.waitingCall();
    if (self.asked) |asked| {
        if (waiting != null and asked.seq == waiting.?.seq and asked.call == waiting.?.call) return;
        self.withdraw();
    }
    const call = waiting orelse return;
    self.ask(arena, session, call) catch |err| self.noticeFmt("Could not ask for approval: {s}", .{@errorName(err)});
}

fn ask(self: *Agent, arena: std.mem.Allocator, session: *Session, waiting: Session.Waiting) !void {
    const params: protocol.RequestPermission = .{
        .sessionId = session.handle,
        .toolCall = .{
            .toolCallId = try toolCallId(arena, waiting.seq, waiting.call),
            .title = waiting.tool.name,
            .status = .pending,
            .rawInput = std.json.parseFromSliceLeaky(std.json.Value, arena, waiting.tool.arguments, .{}) catch null,
        },
        .options = &permission_options,
    };

    var asked: Asked = .{ .seq = waiting.seq, .call = waiting.call };
    errdefer asked.deinit(self.allocator);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items) |connection| {
        if (!connection.initialized) continue;
        const id = self.next_id;
        self.next_id += 1;
        try asked.requests.append(self.allocator, .{ .connection = connection, .id = id });
        connection.request(.{ .number = id }, protocol.method.session_request_permission, params);
    }
    self.asked = asked;
}

/// Take back every permission request still out.
fn withdraw(self: *Agent) void {
    var asked = self.asked orelse return;
    self.asked = null;
    defer asked.deinit(self.allocator);
    for (asked.requests.items) |out| {
        out.connection.notify(protocol.method.cancel_request, protocol.CancelRequest{ .requestId = .{ .integer = out.id } });
    }
}

const permission_options = [_]protocol.PermissionOption{
    .{ .optionId = "once", .name = "Allow once", .kind = .allow_once },
    .{ .optionId = "always", .name = "Always allow", .kind = .allow_always },
    .{ .optionId = "deny", .name = "Deny", .kind = .reject_once },
};

/// A reply from a client: the only requests the agent makes are permission
/// requests, and only the one still out for the waiting call counts.
fn answered(self: *Agent, connection: *Connection, message: rpc.Message) void {
    const id = message.id orelse return;
    const asked = if (self.asked) |*asked| asked else return;
    const index = asked.find(connection, id) orelse return;
    if (message.err != null) return;
    const chosen = protocol.chosenOption(message.result) orelse return;
    const decision = std.meta.stringToEnum(Loop.Decision, chosen) orelse return;
    const session = self.session orelse return;

    _ = asked.requests.swapRemove(index);
    self.withdraw();
    session.stack.loop.decide(decision) catch |err| self.noticeFmt("Could not decide: {s}", .{@errorName(err)});
}

/// What `session/list` returns: the sessions stored for the project holding
/// `cwd`, or every project's when it names none.
fn listSessions(self: *Agent, arena: std.mem.Allocator, request: protocol.ListSessions) !protocol.SessionList {
    const db = self.options.db;
    const cwd = request.cwd orelse {
        const recent = try db.recentSessions(arena, listed_sessions);
        const out = try arena.alloc(protocol.SessionInfo, recent.len);
        for (recent, out) |info, *listed| listed.* = .{
            .sessionId = info.public_id,
            .cwd = info.cwd,
            .title = if (info.title.len > 0) info.title else null,
            .updatedAt = try isoTime(arena, info.updated_at),
            ._meta = .{ .synth = .{ .messages = info.messages, .updated_at = info.updated_at } },
        };
        return .{ .sessions = out };
    };

    var project = try Project.detect(self.allocator, self.io, cwd);
    defer project.deinit(self.allocator);
    const project_id = try db.resolveProject(project.root, "git", project.name());
    const stored = try db.listSessions(arena, project_id, listed_sessions);
    const out = try arena.alloc(protocol.SessionInfo, stored.len);
    for (stored, out) |info, *listed| listed.* = .{
        .sessionId = info.public_id,
        .cwd = try arena.dupe(u8, cwd),
        .title = if (info.title.len > 0) info.title else null,
        .updatedAt = try isoTime(arena, info.updated_at),
        ._meta = .{ .synth = .{ .messages = info.messages, .updated_at = info.updated_at } },
    };
    return .{ .sessions = out };
}

/// Milliseconds since the epoch, as ISO 8601 in UTC.
fn isoTime(arena: std.mem.Allocator, ms: i64) ![]const u8 {
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(ms, std.time.ms_per_s))) };
    const day = seconds.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year,
        date.month.numeric(),
        date.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

/// How ACP names a tool call: its message, then its place in that message.
/// A provider's own call ids repeat from turn to turn.
pub fn toolCallId(arena: std.mem.Allocator, seq: u64, call: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}.{d}", .{ seq, call });
}

/// Why a request failed, for the person who made it.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownSession => "no such session",
        error.RelativeCwd => "cwd must be an absolute path",
        error.FileNotFound => "no such directory",
        error.NotDir => "not a directory",
        error.ModelFixed => "this provider has only the one model",
        error.Busy => "finish the turn first",
        error.UnknownSkill => "no such skill",
        error.UnknownConfigOption => "no such setting",
        error.ProviderFixed => "this agent's provider is fixed",
        error.UnknownProvider => "no such provider",
        error.NoCredentialStore => "no ChatGPT credential file could be opened",
        error.UnknownServer => "no such MCP server",
        error.UnknownAttachment => "no such attachment",
        error.NoTranscript => "that call left no transcript",
        error.StillConnecting => "still connecting - try again in a moment",
        error.NoMcpState => "no MCP state file, so this cannot be remembered",
        error.InvalidRequest => "a request needs an id",
        else => @errorName(err),
    };
}

/// A prompt waiting on the end of its turn.
const Prompting = struct {
    connection: *Connection,
    /// Owned.
    id: rpc.Id,

    fn init(allocator: std.mem.Allocator, connection: *Connection, id: rpc.Id) !Prompting {
        return .{ .connection = connection, .id = switch (id) {
            .number => id,
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
        } };
    }

    fn deinit(self: *Prompting, allocator: std.mem.Allocator) void {
        if (self.id == .string) allocator.free(self.id.string);
    }
};

/// The call a permission request is out for, and the request each client
/// was sent.
const Asked = struct {
    seq: u64,
    call: usize,
    requests: std.ArrayList(struct { connection: *Connection, id: i64 }) = .empty,

    fn deinit(self: *Asked, allocator: std.mem.Allocator) void {
        self.requests.deinit(allocator);
    }

    fn find(self: *const Asked, connection: *Connection, id: rpc.Id) ?usize {
        for (self.requests.items, 0..) |out, at| {
            if (out.connection == connection and id.eql(.{ .number = out.id })) return at;
        }
        return null;
    }

    fn forget(self: *Asked, connection: *Connection) void {
        var at: usize = 0;
        while (at < self.requests.items.len) {
            if (self.requests.items[at].connection == connection) {
                _ = self.requests.swapRemove(at);
            } else at += 1;
        }
    }
};

/// A message from a client, parsed into an arena of its own so it outlives
/// the reader's buffer.
const Inbound = struct {
    arena: std.heap.ArenaAllocator,
    connection: *Connection,
    message: rpc.Message = .{},
    node: std.DoublyLinkedList.Node = .{},

    fn create(allocator: std.mem.Allocator, connection: *Connection) !*Inbound {
        const self = try allocator.create(Inbound);
        self.* = .{ .arena = .init(allocator), .connection = connection };
        return self;
    }

    fn of(node: *std.DoublyLinkedList.Node) *Inbound {
        return @fieldParentPtr("node", node);
    }

    fn destroy(self: *Inbound) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// One client.
const Connection = struct {
    agent: *Agent,
    input: std.Io.File,
    output: std.Io.File,
    reader_thread: std.Thread = undefined,
    writer_thread: std.Thread = undefined,
    read_buffer: [64 * 1024]u8 = undefined,
    lines: rpc.LineReader,
    /// Raised once the reader is done with everything but being freed.
    finished: std.atomic.Value(bool) = .init(false),
    /// Set by `initialize`. Session's thread only.
    initialized: bool = false,
    dialect: enum { standard, synth } = .standard,

    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    outbox: std.ArrayList([]u8) = .empty,
    outbox_bytes: usize = 0,
    /// No more is sent: the client fell too far behind, or is going.
    closing: bool = false,

    fn create(agent: *Agent, input: std.Io.File, output: std.Io.File) !*Connection {
        const allocator = agent.allocator;
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{ .agent = agent, .input = input, .output = output, .lines = .init(allocator) };
        errdefer self.lines.deinit();

        self.writer_thread = try std.Thread.spawn(.{}, writeLoop, .{self});
        errdefer {
            self.close();
            self.writer_thread.join();
        }
        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    /// Join both threads and free. The reader must have finished.
    fn destroy(self: *Connection) void {
        const allocator = self.agent.allocator;
        const io = self.agent.io;
        self.reader_thread.join();
        self.close();
        self.writer_thread.join();
        self.input.close(io);
        if (self.output.handle != self.input.handle) self.output.close(io);
        for (self.outbox.items) |line| allocator.free(line);
        self.outbox.deinit(allocator);
        self.lines.deinit();
        allocator.destroy(self);
    }

    fn close(self: *Connection) void {
        const io = self.agent.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closing = true;
        self.ready.signal(io);
    }

    /// Queue an encoded line. A client that has fallen too far behind is
    /// sent nothing more.
    fn push(self: *Connection, line: []const u8) void {
        const io = self.agent.io;
        const allocator = self.agent.allocator;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) return;
        if (self.outbox_bytes + line.len > max_outbox_bytes) return self.overflow();

        const copy = allocator.dupe(u8, line) catch return self.overflow();
        self.outbox.append(allocator, copy) catch {
            allocator.free(copy);
            return self.overflow();
        };
        self.outbox_bytes += copy.len;
        self.ready.signal(io);
    }

    /// Called with the mutex held.
    fn overflow(self: *Connection) void {
        self.closing = true;
        self.ready.signal(self.agent.io);
    }

    fn cutOff(self: *Connection) void {
        self.mutex.lockUncancelable(self.agent.io);
        defer self.mutex.unlock(self.agent.io);
        self.overflow();
    }

    fn reply(self: *Connection, id: rpc.Id, value: anytype) void {
        var encoded: std.Io.Writer.Allocating = .init(self.agent.allocator);
        defer encoded.deinit();
        rpc.result(&encoded.writer, id, value) catch return self.cutOff();
        self.push(encoded.written());
    }

    fn fail(self: *Connection, id: ?rpc.Id, error_code: i64, message: []const u8) void {
        var encoded: std.Io.Writer.Allocating = .init(self.agent.allocator);
        defer encoded.deinit();
        rpc.fail(&encoded.writer, id, error_code, message) catch return self.cutOff();
        self.push(encoded.written());
    }

    fn notify(self: *Connection, method: []const u8, params: anytype) void {
        var encoded: std.Io.Writer.Allocating = .init(self.agent.allocator);
        defer encoded.deinit();
        rpc.notify(&encoded.writer, method, params) catch return self.cutOff();
        self.push(encoded.written());
    }

    fn request(self: *Connection, id: rpc.Id, method: []const u8, params: anytype) void {
        var encoded: std.Io.Writer.Allocating = .init(self.agent.allocator);
        defer encoded.deinit();
        rpc.request(&encoded.writer, id, method, params) catch return self.cutOff();
        self.push(encoded.written());
    }

    fn writeLoop(self: *Connection) void {
        const io = self.agent.io;
        const allocator = self.agent.allocator;
        var buffer: [64 * 1024]u8 = undefined;
        var writer = self.output.writerStreaming(io, &buffer);
        var batch: std.ArrayList([]u8) = .empty;
        defer batch.deinit(allocator);

        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.outbox.items.len == 0 and !self.closing) self.ready.waitUncancelable(io, &self.mutex);
            if (self.outbox.items.len == 0) {
                self.mutex.unlock(io);
                return;
            }
            std.mem.swap(std.ArrayList([]u8), &batch, &self.outbox);
            self.outbox_bytes = 0;
            self.mutex.unlock(io);

            defer {
                for (batch.items) |line| allocator.free(line);
                batch.clearRetainingCapacity();
            }
            for (batch.items) |line| writer.interface.writeAll(line) catch return self.cutOff();
            writer.interface.flush() catch return self.cutOff();
        }
    }

    fn readLoop(self: *Connection) void {
        defer self.agent.wake.set(self.agent.io);
        defer self.finished.store(true, .release);

        var reader = self.input.readerStreaming(self.agent.io, &self.read_buffer);
        while (true) {
            const line = (self.lines.next(&reader.interface) catch return) orelse return;
            self.take(line) catch return;
        }
    }

    fn take(self: *Connection, line: []const u8) !void {
        const inbound = try Inbound.create(self.agent.allocator, self);
        var posted = false;
        defer if (!posted) inbound.destroy();
        const arena = inbound.arena.allocator();

        inbound.message = rpc.Message.parse(arena, try arena.dupe(u8, line)) catch {
            return self.fail(null, rpc.code.parse_error, "malformed message");
        };
        const method = inbound.message.method orelse "";
        if (std.mem.eql(u8, method, synth.method.files)) return self.listFiles(inbound.message, arena);
        posted = true;
        self.agent.post(inbound);
    }

    /// Answered here rather than on the session's thread: a large tree takes
    /// a while, and a turn should not wait on it.
    fn listFiles(self: *Connection, message: rpc.Message, arena: std.mem.Allocator) void {
        const id = message.id orelse return;
        const asked = rpc.parse(protocol.SessionId, arena, message.params) catch {
            return self.fail(id, rpc.code.invalid_params, "invalid params");
        };
        const root = self.agent.liveRoot(arena, asked.sessionId) catch |err| return self.fail(id, rpc.code.internal_error, describe(err));
        const files = project_files.list(arena, self.agent.io, root, .{ .directories = true }) catch |err| {
            return self.fail(id, rpc.code.internal_error, describe(err));
        };
        self.reply(id, files);
    }
};

/// The live session's project root, when `handle` names it.
fn liveRoot(self: *Agent, arena: std.mem.Allocator, handle: []const u8) ![]const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const live = self.live orelse return error.UnknownSession;
    if (!std.mem.eql(u8, live.handle, handle)) return error.UnknownSession;
    return arena.dupe(u8, live.root);
}

/// Everything the live session owns. Touched from the session's thread only.
const Session = struct {
    agent: *Agent,
    allocator: std.mem.Allocator,
    io: std.Io,
    id: i64,
    handle: []const u8,
    cwd: []const u8,
    mcp_auth: ?mcp.Auth = null,
    sign_in: ?*SignInTask = null,
    sign_out: ?*SignOutTask = null,
    stack: *Stack,
    /// Every message sent, by seq, with a signature of the parts of it that
    /// change after it is appended.
    sent: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// The status as last sent, encoded.
    sent_status: std.ArrayList(u8) = .empty,
    /// The request whose stream was last sent, and how far.
    stream_request: u64 = 0,
    stream_thinking: usize = 0,
    stream_text: usize = 0,
    stream_closed: bool = false,

    fn create(agent: *Agent, id: i64, cwd: []const u8) !*Session {
        const allocator = agent.allocator;
        const io = agent.io;
        const options = agent.options;
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const handle = try options.db.sessionPublicId(id, allocator);
        errdefer allocator.free(handle);
        const owned_cwd = try allocator.dupe(u8, cwd);
        errdefer allocator.free(owned_cwd);
        self.* = .{ .agent = agent, .allocator = allocator, .io = io, .id = id, .handle = handle, .cwd = owned_cwd, .stack = undefined };

        if (options.mcp_auth_path) |path| {
            self.mcp_auth = mcp.Auth.load(allocator, io, path) catch mcp.Auth.init(allocator);
        }
        errdefer if (self.mcp_auth) |*store| store.deinit();

        self.stack = try Stack.create(allocator, io, .{
            .config = options.config,
            .provider = switch (options.source) {
                .providers => |providers| providers.backend.provider(),
                .provider => |provider| provider,
            },
            .backend = switch (options.source) {
                .providers => |providers| providers.backend,
                .provider => null,
            },
            .cwd = owned_cwd,
            .home = options.home,
            .db = options.db,
            .mcp_auth = if (self.mcp_auth) |*store| store else null,
            .mcp_connect = .background,
        });
        errdefer self.stack.destroy();
        self.stack.convo.max_messages = max_messages;
        try self.stack.loop.resumeSession(id, max_messages);
        self.restoreEffort();
        return self;
    }

    fn destroy(self: *Session) void {
        if (self.sign_in) |task| task.abandon();
        if (self.sign_out) |task| task.abandon();
        // Opening a session makes its row up front; one never spoken in is not worth keeping.
        if (self.stack.convo.totalCount() == 0) self.agent.options.db.deleteSession(self.id) catch {};
        self.stack.loop.requestStop();
        self.stack.destroy();
        if (self.mcp_auth) |*store| store.deinit();
        self.sent.deinit(self.allocator);
        self.sent_status.deinit(self.allocator);
        self.allocator.free(self.handle);
        self.allocator.free(self.cwd);
        self.allocator.destroy(self);
    }

    fn busy(self: *Session) bool {
        return self.stack.loop.isBusy() or self.stack.runner.busy() or self.sign_in != null or
            self.sign_out != null or self.stack.mcp_host.connecting();
    }

    fn notice(self: *Session, comptime fmt: []const u8, args: anytype) void {
        self.agent.noticeFmt(fmt, args);
    }

    /// Advance the session, and do what a TUI's tick does for a local one:
    /// compact when the context is filling, and start the next turn from
    /// whatever was typed while the last one ran.
    fn step(self: *Session) void {
        const loop = &self.stack.loop;
        _ = self.stack.runner.poll() catch |err| self.notice("Subagent failed: {s}", .{@errorName(err)});
        _ = loop.poll() catch |err| self.notice("The turn failed: {s}", .{@errorName(err)});

        if (loop.takeHookNotice()) |text| {
            defer self.allocator.free(text);
            self.agent.notice(text);
        }
        self.settleSignOut();
        self.settleMcp();
        if (loop.isBusy()) return;
        self.settleSignIn();
        if (loop.shouldCompact()) {
            loop.compact() catch |err| self.notice("Could not compact: {s}", .{@errorName(err)});
            return;
        }
        if (loop.takeSteering()) |taken| {
            var next = taken;
            defer next.deinit(loop.allocator);
            loop.submit(next.prompt, next.asExtras()) catch |err| self.notice("Could not start the next turn: {s}", .{@errorName(err)});
        }
    }

    /// Start a turn on `blocks`, or steer the one running. A prompt of
    /// `/skill args` runs that skill.
    fn prompt(self: *Session, arena: std.mem.Allocator, blocks: []const std.json.Value) !void {
        var text: std.ArrayList(u8) = .empty;
        var attachments: std.ArrayList(mention.Attachment) = .empty;
        var images: std.ArrayList([]const u8) = .empty;
        for (blocks) |block| switch (protocol.Content.of(block)) {
            .text => |part| {
                if (text.items.len > 0) try text.append(arena, '\n');
                try text.appendSlice(arena, part);
            },
            .image => |data| try images.append(arena, data),
            .resource => |resource| try attachments.append(arena, .{ .path = resource.path, .content = resource.text }),
            .other => {},
        };

        const loop = &self.stack.loop;
        if (std.mem.startsWith(u8, text.items, "/")) {
            if (skill.findIn(self.stack.skills.skills, skill.idOf(text.items))) |found| {
                if (loop.isBusy()) return error.Busy;
                try attachments.append(arena, .{
                    .path = try std.fs.path.join(arena, &.{ found.dir, skill.file_name }),
                    .content = try skill_tool.render(arena, found),
                });
                return loop.submit(text.items, .{ .attachments = attachments.items, .images = images.items });
            }
        }
        const extras: Loop.Extras = .{ .attachments = attachments.items, .images = images.items };
        if (!try loop.steer(text.items, extras)) try loop.submit(text.items, extras);
    }

    const Waiting = struct { seq: u64, call: usize, tool: *const Conversation.ToolCall };

    /// The call waiting on a decision, if one is.
    fn waitingCall(self: *Session) ?Waiting {
        const loop = &self.stack.loop;
        if (loop.state != .awaiting_approval) return null;
        const seq = loop.pending_seq orelse return null;
        const call = loop.firstPending() orelse return null;
        const msg = self.held(seq) orelse return null;
        if (call >= msg.tool_calls.len) return null;
        return .{ .seq = seq, .call = call, .tool = &msg.tool_calls[call] };
    }

    fn modes(self: *Session) protocol.Modes {
        return .{ .currentModeId = self.stack.loop.agent.id, .availableModes = &mode_list };
    }

    const mode_list = blk: {
        var out: [agents.all.len]protocol.Mode = undefined;
        for (agents.all, &out) |agent, *mode| mode.* = .{ .id = agent.id, .name = agent.label, .description = agent.description };
        break :blk out;
    };

    /// The model, and its reasoning effort where it offers a choice. Only the
    /// model in use is listed: asking the provider for the rest is a round
    /// trip, which `_synth/models` makes on request.
    fn configOptions(self: *Session, arena: std.mem.Allocator) ![]const protocol.ConfigOption {
        const provider = self.stack.loop.provider;
        var out: std.ArrayList(protocol.ConfigOption) = .empty;
        const model = try arena.alloc(protocol.ConfigValue, 1);
        model[0] = .{ .value = provider.model, .name = provider.model };
        try out.append(arena, .{ .id = protocol.config_model, .name = "Model", .category = "model", .currentValue = provider.model, .options = model });

        const levels = provider.effortsFor(provider.model).levels;
        if (levels.len > 0) {
            const efforts = try arena.alloc(protocol.ConfigValue, levels.len);
            for (levels, efforts) |level, *value| value.* = .{ .value = level, .name = level };
            try out.append(arena, .{ .id = protocol.config_effort, .name = "Effort", .category = "thought_level", .currentValue = provider.effort, .options = efforts });
        }
        return out.items;
    }

    fn setConfigOption(self: *Session, request: protocol.SetConfigOption) !void {
        const loop = &self.stack.loop;
        if (std.mem.eql(u8, request.configId, protocol.config_effort)) {
            if (loop.isBusy()) return error.Busy;
            return self.chooseEffort(request.value);
        }
        if (!std.mem.eql(u8, request.configId, protocol.config_model)) return error.UnknownConfigOption;

        const extra: synth.SetModel = if (request._meta) |meta| meta.synth orelse .{} else .{};
        const provider_id = self.providerId();
        const switching = if (extra.provider) |wanted| !std.mem.eql(u8, wanted, provider_id) else false;
        if (switching) {
            if (loop.isBusy()) return error.Busy;
            try self.useProvider(catalog.find(extra.provider.?) orelse return error.UnknownProvider, null, null);
        }
        try loop.switchModel(request.value);
        self.rememberModel();
        if (extra.effort) |level| try self.chooseEffort(level) else self.restoreEffort();
        if (switching) self.announceProvider();
    }

    /// Catalog id of the provider the session answers through, which the
    /// effort chosen for each of its models is remembered under.
    fn providerId(self: *Session) []const u8 {
        return switch (self.agent.options.source) {
            .providers => |providers| providers.active_id,
            .provider => "",
        };
    }

    fn providerSource(self: *Session) !*Providers {
        return switch (self.agent.options.source) {
            .providers => |providers| providers,
            .provider => error.ProviderFixed,
        };
    }

    /// Send whatever changed since the last call: new and changed messages,
    /// the streaming request, and the status. With `send` false, only note
    /// it as sent, for a snapshot about to carry it.
    fn publish(self: *Session, arena: std.mem.Allocator, send: bool) !void {
        const convo = &self.stack.convo;
        for (convo.messages.items) |*msg| {
            const mark = signature(msg);
            const entry = try self.sent.getOrPut(self.allocator, msg.seq);
            if (entry.found_existing and entry.value_ptr.* == mark) continue;
            if (send) {
                const params: synth.Appended = .{ .sessionId = self.handle, .message = try synth.Message.from(arena, msg) };
                self.agent.notifySynth(if (entry.found_existing) synth.method.updated else synth.method.appended, params);
            }
            entry.value_ptr.* = mark;
        }
        if (self.sent.count() > convo.messages.items.len) try self.forgetTrimmed(arena);

        try self.publishStream(arena, send);

        var encoded: std.Io.Writer.Allocating = .init(arena);
        try rpc.notify(&encoded.writer, synth.method.status, synth.StatusUpdate{ .sessionId = self.handle, .status = try self.currentStatus(arena) });
        if (!std.mem.eql(u8, encoded.written(), self.sent_status.items)) {
            if (send) self.agent.pushSynth(encoded.written());
            self.sent_status.clearRetainingCapacity();
            try self.sent_status.appendSlice(self.allocator, encoded.written());
        }
    }

    fn forgetTrimmed(self: *Session, arena: std.mem.Allocator) !void {
        const first = self.stack.convo.firstSeq() orelse std.math.maxInt(u64);
        var trimmed: std.ArrayList(u64) = .empty;
        var it = self.sent.keyIterator();
        while (it.next()) |seq| {
            if (seq.* < first) try trimmed.append(arena, seq.*);
        }
        for (trimmed.items) |seq| _ = self.sent.remove(seq);
    }

    fn publishStream(self: *Session, arena: std.mem.Allocator, send: bool) !void {
        const loop = &self.stack.loop;
        const request = loop.request orelse return;
        if (loop.requests_started != self.stream_request) {
            self.stream_request = loop.requests_started;
            self.stream_thinking = 0;
            self.stream_text = 0;
            self.stream_closed = false;
        }
        const thinking = try request.thoughts.copyRange(arena, self.stream_thinking, null);
        const text = try request.content.copyRange(arena, self.stream_text, null);
        const closed = request.thoughts.isClosed();
        if (thinking.len == 0 and text.len == 0 and closed == self.stream_closed) return;

        if (send) self.agent.notifySynth(synth.method.stream, synth.StreamUpdate{ .sessionId = self.handle, .stream = .{
            .request = self.stream_request,
            .thinking = thinking,
            .text = text,
            .closed = closed,
        } });
        self.stream_thinking += thinking.len;
        self.stream_text += text.len;
        self.stream_closed = closed;
    }

    /// Everything a synth client needs to draw the session, cut at the point
    /// the events after it start from.
    fn snapshot(self: *Session, arena: std.mem.Allocator) !synth.Snapshot {
        const messages = self.stack.convo.messages.items;
        const wired = try arena.alloc(synth.Message, messages.len);
        for (messages, wired) |*msg, *out| out.* = try synth.Message.from(arena, msg);

        const loop = &self.stack.loop;
        const stream: ?synth.Stream = if (loop.request) |request| .{
            .request = self.stream_request,
            .thinking = try request.thoughts.copyRange(arena, 0, self.stream_thinking),
            .text = try request.content.copyRange(arena, 0, self.stream_text),
            .closed = self.stream_closed,
        } else null;

        const skills = try arena.alloc(synth.Skill, self.stack.skills.skills.len);
        for (self.stack.skills.skills, skills) |found, *out| out.* = .{
            .id = found.id,
            .name = found.name,
            .description = found.description,
            .dir = found.dir,
        };

        return .{
            .sessionId = self.handle,
            .status = try self.currentStatus(arena),
            .messages = wired,
            .dropped = self.stack.convo.dropped,
            .stream = stream,
            .skills = .{ .found = skills, .looked_in = self.stack.skills.paths },
        };
    }

    fn currentStatus(self: *Session, arena: std.mem.Allocator) !synth.Status {
        const loop = &self.stack.loop;
        const pending_call = loop.firstPending();

        var notes: []const []const u8 = &.{};
        if (loop.pending_seq) |seq| {
            const texts = try arena.alloc([]const u8, loop.notes.len);
            for (texts, 0..) |*text, index| text.* = loop.toolNote(seq, index) orelse "";
            notes = texts;
        }
        const steering = try arena.alloc([]const u8, loop.pendingSteering().len);
        for (loop.pendingSteering(), steering) |submission, *text| text.* = submission.prompt;

        return .{
            .state = loop.state,
            .label = loop.label(),
            .title = loop.title(),
            .handle = self.handle,
            .root = self.cwd,
            .project = self.stack.project.root,
            .branch = self.stack.project.branch orelse "",
            .agent = loop.agent.id,
            .model = loop.provider.model,
            .provider = loop.provider.name,
            .provider_id = self.providerId(),
            .provider_missing = if (self.providerSource()) |providers| providers.isMissing() else |_| false,
            .sign_in = if (self.sign_in) |task| .{ .url = task.sign_in.url, .port = task.sign_in.callbackPort() } else null,
            .chatgpt_signed_in = self.chatgptSignedIn(),
            .context_limit = loop.provider.context_limit,
            .vision = loop.provider.vision,
            .switchable = loop.provider.switchable(),
            .effort = loop.provider.effort,
            .efforts = loop.provider.effortsFor(loop.provider.model).levels,
            .usage = loop.usage,
            .todos = loop.todos.items.items,
            .mcp = try self.stack.mcp_host.statuses(arena),
            .pending_seq = loop.pending_seq,
            .pending_call = if (pending_call) |index| @intCast(index) else null,
            .pending_description = self.pendingDescription(),
            .notes = notes,
            .steering = steering,
            .outcome = loop.outcome,
            .request = if (loop.request != null) loop.requests_started else null,
            .finished = loop.finished,
        };
    }

    fn chatgptSignedIn(self: *Session) bool {
        const providers = self.providerSource() catch return false;
        const store = providers.chatgpt orelse return false;
        return store.isSignedIn();
    }

    fn pendingDescription(self: *Session) []const u8 {
        const waiting = self.pendingTool() orelse return "";
        const definition = self.stack.registry.get(waiting.name) orelse return "";
        return definition.description;
    }

    fn pendingTool(self: *Session) ?*const Conversation.ToolCall {
        const loop = &self.stack.loop;
        const index = loop.firstPending() orelse return null;
        const seq = loop.pending_seq orelse return null;
        const msg = self.held(seq) orelse return null;
        if (index >= msg.tool_calls.len) return null;
        return &msg.tool_calls[index];
    }

    fn loadToolResult(self: *Session, arena: std.mem.Allocator, seq: u64, index: u32) ![]const u8 {
        if (self.held(seq)) |msg| {
            if (index >= msg.tool_calls.len) return error.UnknownToolCall;
            const call = msg.tool_calls[index];
            if (call.result) |result| {
                if (result.len >= call.result_bytes) return result;
            }
        }
        const session_id = self.stack.loop.session_id orelse return error.UnknownMessage;
        return try self.agent.options.db.loadToolResult(arena, session_id, @intCast(seq), index) orelse error.UnknownToolCall;
    }

    fn loadAttachment(self: *Session, arena: std.mem.Allocator, seq: u64, index: u32) ![]const u8 {
        if (self.held(seq)) |msg| {
            if (index >= msg.attachments.len) return error.UnknownAttachment;
            if (!msg.attachments[index].shortened()) return msg.attachments[index].content;
        }
        const session_id = self.stack.loop.session_id orelse return error.UnknownMessage;
        return try self.agent.options.db.loadAttachment(arena, session_id, @intCast(seq), index) orelse error.UnknownAttachment;
    }

    fn loadThinking(self: *Session, arena: std.mem.Allocator, seq: u64) ![]const u8 {
        if (self.held(seq)) |msg| {
            if (msg.thinking) |text| {
                if (text.len >= msg.thinking_bytes) return text;
            }
        }
        const session_id = self.stack.loop.session_id orelse return error.UnknownMessage;
        return try self.agent.options.db.loadThinking(arena, session_id, @intCast(seq)) orelse "";
    }

    fn loadHistory(self: *Session, arena: std.mem.Allocator, before_seq: u64, limit: u32) ![]const synth.Message {
        const session_id = self.stack.loop.session_id orelse return &.{};
        const loaded = try self.agent.options.db.loadMessages(arena, session_id, @intCast(before_seq), limit);
        std.mem.reverse(Conversation.Message, loaded);
        const out = try arena.alloc(synth.Message, loaded.len);
        for (loaded, out) |*msg, *wired| wired.* = try synth.Message.from(arena, msg);
        return out;
    }

    fn connectProvider(self: *Session, id: []const u8, at: []const u8, key: ?[]const u8) !void {
        const providers = try self.providerSource();
        if (self.stack.loop.isBusy()) return error.Busy;
        const entry = catalog.find(id) orelse return error.UnknownProvider;
        if (entry.key == .oauth and !entry.ready(providers.auth, providers.chatgpt)) return self.beginSignIn(providers);
        try self.useProvider(entry, at, key);
        self.announceProvider();
    }

    /// Point the session at a provider, at `host` or the one it was last
    /// reached at, and remember it as the choice for sessions to come.
    fn useProvider(self: *Session, entry: catalog.Entry, at: ?[]const u8, key: ?[]const u8) !void {
        const providers = try self.providerSource();
        const db = self.agent.options.db;
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const where = at orelse try Providers.hostOf(arena_state.allocator(), db, entry);

        const loop = &self.stack.loop;
        loop.provider = try providers.connect(entry, where, key);
        try loop.setModel(loop.provider.model);
        db.setProviderHost(entry.id, where) catch |err| self.notice("Could not remember the host: {s}", .{@errorName(err)});
        db.setActiveProvider(entry.id) catch |err| self.notice("Could not remember the provider: {s}", .{@errorName(err)});
        self.restoreEffort();
    }

    fn announceProvider(self: *Session) void {
        const providers = self.providerSource() catch return;
        const entry = catalog.findOrDefault(providers.active_id);
        const model = self.stack.loop.provider.model;
        if (entry.key == .oauth) return self.notice("Connected to your {s}, running {s}.", .{ entry.label, model });
        self.notice("Connected {s} at {s}, running {s}.", .{ entry.label, providers.backend.currentHost(), model });
    }

    fn beginSignIn(self: *Session, providers: *Providers) !void {
        if (self.sign_in != null) return;
        const store = providers.chatgpt orelse return error.NoCredentialStore;
        self.sign_in = SignInTask.start(self.allocator, self.io, store) catch |err| {
            return self.notice("{s}", .{SignInTask.explain(err)});
        };
    }

    /// Once the browser has come back, between turns: connect, or say why not.
    fn settleSignIn(self: *Session) void {
        const task = self.sign_in orelse return;
        if (!task.isFinished()) return;
        self.sign_in = null;
        task.finish() catch |err| return self.notice("{s}", .{SignInTask.explain(err)});

        const entry = catalog.find(catalog.chatgpt_id).?;
        self.useProvider(entry, entry.host, null) catch |err| {
            return self.notice("Could not reach {s}: {s}", .{ entry.label, @errorName(err) });
        };
        self.announceProvider();
        self.welcomeToPlanUsage();
    }

    /// Said once, the first time this installation signs in.
    fn welcomeToPlanUsage(self: *Session) void {
        const db = self.agent.options.db;
        const welcomed_key = "chatgpt:welcomed";
        var buffer: [16]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const welcomed = db.setting(fixed.allocator(), welcomed_key) catch "";
        if (welcomed.len > 0) return;
        self.notice("You're using your ChatGPT plan. Requests in synth count toward its usage. Manage usage with /usage or at {s}", .{chatgpt_auth.usage_url});
        db.setSetting(welcomed_key, "1") catch {};
    }

    fn signOut(self: *Session) !void {
        const providers = try self.providerSource();
        const store = providers.chatgpt orelse return error.NoCredentialStore;
        if (self.sign_out != null) return;
        if (!store.isSignedIn()) return self.notice("Not signed in to ChatGPT.", .{});
        self.sign_out = try SignOutTask.start(self.allocator, self.io, store);
    }

    fn settleSignOut(self: *Session) void {
        const task = self.sign_out orelse return;
        if (!task.isFinished()) return;
        self.sign_out = null;
        const confirmed = task.finish() catch |err| return self.notice("Could not sign out of ChatGPT: {s}", .{@errorName(err)});
        self.notice("{s}", .{if (confirmed)
            "Signed out of ChatGPT."
        else
            "Signed out of ChatGPT here, but OpenAI did not confirm it. You can disconnect synth in ChatGPT settings."});

        const providers = self.providerSource() catch return;
        providers.signedOut();
        if (std.mem.eql(u8, providers.active_id, catalog.chatgpt_id)) {
            self.agent.options.db.setActiveProvider("") catch |err| self.notice("Could not clear the provider: {s}", .{@errorName(err)});
        }
    }

    fn toggleMcp(self: *Session, name: []const u8) !void {
        const mcp_host = &self.stack.mcp_host;
        const server = for (mcp_host.servers) |server| {
            if (std.mem.eql(u8, server.name, name)) break server;
        } else return error.UnknownServer;
        if (mcp_host.connecting()) return error.StillConnecting;
        const store = mcp_host.auth orelse return error.NoMcpState;

        const wanted = mcp_host.wants(server);
        try store.setEnabled(server.name, !wanted);
        store.save(self.io, null) catch |err| self.notice("Could not remember that: {s}", .{@errorName(err)});
        if (wanted) {
            if (mcp_host.disconnect(&self.stack.registry, server.name)) try self.stack.loop.useAgent(self.stack.loop.agent.id);
        } else {
            try mcp_host.beginConnectAll(mcp_host.servers, mcp_host.client);
        }
    }

    /// Once servers turned on have been reached: offer their tools, and say
    /// which would not come up.
    fn settleMcp(self: *Session) void {
        const mcp_host = &self.stack.mcp_host;
        if (!mcp_host.settled()) return;
        const added = mcp_host.install(&self.stack.registry) catch 0;
        if (added > 0) self.stack.loop.useAgent(self.stack.loop.agent.id) catch |err| {
            self.notice("Could not offer the new tools: {s}", .{@errorName(err)});
        };
        for (mcp_host.failures.items) |failure| self.notice("MCP server {s} failed: {s}", .{ failure.server, failure.reason });
    }

    /// Have sessions to come start on the model this one switched to.
    fn rememberModel(self: *Session) void {
        const model = self.stack.loop.provider.model;
        if (model.len == 0) return;
        const key = std.fmt.allocPrint(self.allocator, "model:{s}", .{self.providerId()}) catch return;
        defer self.allocator.free(key);
        self.agent.options.db.setSetting(key, model) catch |err| self.notice("Could not remember the model: {s}", .{@errorName(err)});
    }

    /// Put the model back on the effort last chosen for it, or its default.
    fn restoreEffort(self: *Session) void {
        const loop = &self.stack.loop;
        const remembered = self.agent.options.db.rememberedEffort(self.allocator, self.providerId(), loop.provider.model) catch "";
        defer self.allocator.free(remembered);
        loop.setEffort(remembered);
    }

    fn chooseEffort(self: *Session, level: []const u8) !void {
        const loop = &self.stack.loop;
        loop.setEffort(level);
        try self.agent.options.db.rememberEffort(self.allocator, self.providerId(), loop.provider.model, level);
    }

    fn models(self: *Session, arena: std.mem.Allocator, recent: u32) !synth.Models {
        const provider = self.stack.loop.provider;
        const db = self.agent.options.db;
        const offered = switch (self.agent.options.source) {
            .providers => |providers| try providers.offered(arena, db, provider),
            .provider => try Providers.offeredBy(arena, db, "", provider.name, provider),
        };
        const project_id = self.stack.loop.project_id orelse return .{ .offered = offered };
        return .{ .offered = offered, .recent = try db.recentModels(arena, project_id, recent) };
    }

    fn search(self: *Session, arena: std.mem.Allocator, query: []const u8, limit: u32) ![]const synth.Hit {
        const project_id = self.stack.loop.project_id orelse return &.{};
        const hits = try self.agent.options.db.search(arena, project_id, query, limit);
        const out = try arena.alloc(synth.Hit, hits.len);
        for (hits, out) |hit, *wired| wired.* = .{
            .handle = hit.public_id,
            .title = hit.title,
            .role = hit.role,
            .excerpt = hit.excerpt,
        };
        return out;
    }

    /// The transcript of the subagent call `index` of message `seq` ran: in
    /// memory while it runs, from the database once it has answered.
    fn subagentTranscript(self: *Session, arena: std.mem.Allocator, seq: u64, index: u32) !synth.Transcript {
        const loop = &self.stack.loop;
        if (loop.pending_seq == seq) {
            if (self.stack.runner.viewable(index)) |child| {
                const messages = child.convo.messages.items;
                const out = try arena.alloc(synth.Message, messages.len);
                for (messages, out) |*msg, *wired| wired.* = try synth.Message.from(arena, msg);
                return .{ .live = true, .messages = out };
            }
        }

        const db = self.agent.options.db;
        const session_id = loop.session_id orelse return error.NoTranscript;
        const message = try db.messageId(session_id, @intCast(seq)) orelse return error.NoTranscript;
        const call = try db.toolCallId(message, index) orelse return error.NoTranscript;
        const child = try db.subagentSession(call) orelse return error.NoTranscript;
        const loaded = try db.loadMessages(arena, child, std.math.maxInt(i64), max_messages);
        std.mem.reverse(Conversation.Message, loaded);
        const out = try arena.alloc(synth.Message, loaded.len);
        for (loaded, out) |*msg, *wired| wired.* = try synth.Message.from(arena, msg);
        return .{ .messages = out };
    }

    fn held(self: *Session, seq: u64) ?*const Conversation.Message {
        for (self.stack.convo.messages.items) |*msg| {
            if (msg.seq == seq) return msg;
        }
        return null;
    }
};

/// What can change about a message once it is in the transcript: calls
/// settle, and heavy bodies shrink to previews once they are persisted.
fn signature(msg: *const Conversation.Message) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, msg.text.len);
    std.hash.autoHash(&hasher, if (msg.thinking) |text| text.len else 0);
    std.hash.autoHash(&hasher, msg.thinking_ms);
    for (msg.tool_calls) |call| {
        std.hash.autoHash(&hasher, call.status);
        std.hash.autoHash(&hasher, if (call.result) |result| result.len else 0);
        std.hash.autoHash(&hasher, call.result_bytes);
        std.hash.autoHash(&hasher, call.elapsed_ms);
    }
    for (msg.attachments) |attachment| std.hash.autoHash(&hasher, attachment.content.len);
    return hasher.final();
}

const testing = std.testing;
const linux = std.os.linux;

/// Answers the first turn by thinking aloud and asking to write a note, and
/// the second, once the note is written, with "done". Each answer waits on
/// `gate` after the thinking, so a test can catch a request mid-stream. Offers
/// two models, each at two efforts; only the first can be shown images.
pub const Script = struct {
    gate: std.Io.Event = .is_set,
    model: []const u8 = offered[0],
    effort: []const u8 = "",

    const offered = [_][]const u8{ "scripted", "bigger" };
    const levels = [_][]const u8{ "low", "high" };

    pub fn provider(self: *Script) Provider {
        return .{
            .name = "script",
            .model = self.model,
            .userdata = self,
            .respond = respond,
            .list_models = listModels,
            .set_model = setModel,
            .refresh = refresh,
            .efforts = efforts,
            .set_effort = setEffort,
        };
    }

    fn listModels(_: *anyopaque, allocator: std.mem.Allocator) ![][]const u8 {
        const names = try allocator.alloc([]const u8, offered.len);
        for (offered, names) |name, *copy| copy.* = try allocator.dupe(u8, name);
        return names;
    }

    fn setModel(ptr: *anyopaque, name: []const u8) !Provider.Current {
        const self: *Script = @ptrCast(@alignCast(ptr));
        self.model = for (offered) |known| {
            if (std.mem.eql(u8, known, name)) break known;
        } else return error.UnknownModel;
        return refresh(ptr);
    }

    fn refresh(ptr: *anyopaque) Provider.Current {
        const self: *Script = @ptrCast(@alignCast(ptr));
        return .{
            .model = self.model,
            .name = "script",
            .vision = std.mem.eql(u8, self.model, offered[0]),
            .effort = efforts(ptr, self.model).pick(self.effort),
        };
    }

    fn efforts(_: *anyopaque, _: []const u8) Provider.Efforts {
        return .{ .levels = &levels, .default = levels[0] };
    }

    fn setEffort(ptr: *anyopaque, level: []const u8) void {
        const self: *Script = @ptrCast(@alignCast(ptr));
        self.effort = efforts(ptr, self.model).pick(level);
    }

    fn respond(ptr: *anyopaque, convo: *Conversation, _: Provider.Turn, allocator: std.mem.Allocator, sink: ?Provider.Sink) !Provider.Reply {
        const self: *Script = @ptrCast(@alignCast(ptr));
        if (sink) |s| {
            s.onThinking(s.userdata, "weighing it up");
            s.onThinkingDone(s.userdata);
        }
        self.gate.waitUncancelable(testing.io);
        const last = convo.last();
        if (last != null and last.?.role == .tool) return .{ .text = try allocator.dupe(u8, "done") };

        const calls = try allocator.alloc(Conversation.ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call-1"),
            .name = try allocator.dupe(u8, "write"),
            .arguments = try allocator.dupe(u8, "{\"path\":\"note.txt\",\"content\":\"acp\"}"),
        };
        return .{ .text = try allocator.dupe(u8, "Let me write that down."), .tool_calls = calls };
    }
};

/// An agent in a scratch directory, with sessions in `project/` answered
/// through `Script`, serving on its own thread. For tests, here and of the
/// clients.
pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    config: Config,
    script: Script,
    db: Database,
    project: []const u8,
    agent: Agent,
    thread: std.Thread,

    pub fn create() !*Fixture {
        const allocator = testing.allocator;
        const io = testing.io;
        const self = try allocator.create(Fixture);
        errdefer allocator.destroy(self);
        self.script = .{};
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = .init(allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.config = .{ .arena = .init(allocator) };
        errdefer self.config.arena.deinit();

        // Its own repository, or the project would be the one these tests live in.
        try self.tmp.dir.createDirPath(io, "project/.git");
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try arena.dupe(u8, buffer[0..try self.tmp.dir.realPath(io, &buffer)]);
        self.project = try std.fs.path.join(arena, &.{ dir, "project" });

        self.db = try Database.init(allocator, io, try std.fs.path.join(arena, &.{ dir, "synth.db" }));
        errdefer self.db.deinit();
        self.agent = .init(allocator, io, .{
            .config = &self.config,
            .db = &self.db,
            .source = .{ .provider = self.script.provider() },
        });
        return self;
    }

    /// A new client, connected over a socket pair.
    pub fn connect(self: *Fixture) !*Client {
        const far = try self.socket();
        errdefer far.close(testing.io);
        return Client.create(far);
    }

    /// The far end of a new connection to the agent, which the caller owns.
    /// The first starts the agent.
    pub fn socket(self: *Fixture) !std.Io.File {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.SocketPair;
        const ours: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        const theirs: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
        errdefer theirs.close(testing.io);
        const first = self.agent.connectionCount() == 0;
        self.agent.connect(ours, ours) catch |err| {
            ours.close(testing.io);
            return err;
        };
        if (first) self.thread = try std.Thread.spawn(.{}, Agent.serve, .{&self.agent});

        // A missing message fails the test rather than hanging it.
        const timeout: linux.timeval = .{ .sec = 10, .usec = 0 };
        _ = linux.setsockopt(theirs.handle, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
        return theirs;
    }

    /// Every client must have closed: the agent serves until the last one has.
    pub fn destroy(self: *Fixture) void {
        self.thread.join();
        self.agent.deinit();
        self.db.deinit();
        self.config.arena.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }
};

/// The far end of a connection, reading messages as they come.
pub const Client = struct {
    file: std.Io.File,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [4096]u8 = undefined,
    lines: rpc.LineReader,
    arena: std.heap.ArenaAllocator,
    next_id: i64 = 1,

    fn create(file: std.Io.File) !*Client {
        const self = try testing.allocator.create(Client);
        self.* = .{ .file = file, .reader = undefined, .writer = undefined, .lines = .init(testing.allocator), .arena = .init(testing.allocator) };
        self.reader = file.readerStreaming(testing.io, &self.read_buffer);
        self.writer = file.writerStreaming(testing.io, &self.write_buffer);
        return self;
    }

    /// Hang up, which the agent sees as the end of its input.
    pub fn close(self: *Client) void {
        _ = linux.shutdown(self.file.handle, linux.SHUT.RDWR);
        self.file.close(testing.io);
        self.lines.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    pub fn request(self: *Client, method: []const u8, params: anytype) !rpc.Id {
        const id: rpc.Id = .{ .number = self.next_id };
        self.next_id += 1;
        try rpc.request(&self.writer.interface, id, method, params);
        try self.writer.interface.flush();
        return id;
    }

    pub fn notify(self: *Client, method: []const u8, params: anytype) !void {
        try rpc.notify(&self.writer.interface, method, params);
        try self.writer.interface.flush();
    }

    pub fn answer(self: *Client, id: rpc.Id, value: anytype) !void {
        try rpc.result(&self.writer.interface, id, value);
        try self.writer.interface.flush();
    }

    /// The next message, or `error.Closed` once the agent hangs up.
    pub fn next(self: *Client) !rpc.Message {
        const arena = self.arena.allocator();
        const line = try self.lines.next(&self.reader.interface) orelse return error.Closed;
        return rpc.Message.parse(arena, try arena.dupe(u8, line));
    }

    /// Read until the reply to `id`, which must be a success.
    pub fn expectResult(self: *Client, id: rpc.Id) !std.json.Value {
        while (true) {
            const message = try self.next();
            if (message.method != null or message.id == null or !message.id.?.eql(id)) continue;
            if (message.err) |err| {
                std.debug.print("request failed: {s}\n", .{err.message});
                return error.RequestFailed;
            }
            return message.result orelse .null;
        }
    }

    pub fn expectError(self: *Client, id: rpc.Id) !rpc.ErrorObject {
        while (true) {
            const message = try self.next();
            if (message.method != null or message.id == null or !message.id.?.eql(id)) continue;
            return message.err orelse error.ExpectedError;
        }
    }

    /// Read until a notification or request for `method`.
    pub fn awaitMethod(self: *Client, method: []const u8) !rpc.Message {
        while (true) {
            const message = try self.next();
            if (std.mem.eql(u8, message.method orelse "", method)) return message;
        }
    }

    /// Read until a status matching `wanted`, returning it.
    pub fn awaitStatus(self: *Client, wanted: anytype) !synth.Status {
        while (true) {
            const message = try self.awaitMethod(synth.method.status);
            const status = (try rpc.parse(synth.StatusUpdate, self.arena.allocator(), message.params)).status;
            if (wanted.matches(status)) return status;
        }
    }

    pub fn initialize(self: *Client, speaks_synth: bool) !void {
        const id = try self.request(protocol.method.initialize, protocol.Initialize{
            .protocolVersion = protocol.version,
            .clientInfo = .{ .name = "test" },
            ._meta = if (speaks_synth) .{ .synth = .{ .protocol = synth.version } } else null,
        });
        const result = try rpc.parse(protocol.Initialized, self.arena.allocator(), try self.expectResult(id));
        try testing.expectEqual(protocol.version, result.protocolVersion);
    }

    /// Open a session in `cwd`, returning the snapshot that comes before the
    /// reply.
    pub fn open(self: *Client, cwd: []const u8) !synth.Snapshot {
        const id = try self.request(protocol.method.session_new, protocol.NewSession{ .cwd = cwd });
        const message = try self.next();
        try testing.expectEqualStrings(synth.method.snapshot, message.method.?);
        const snapshot = try rpc.parse(synth.Snapshot, self.arena.allocator(), message.params);
        const setup = try rpc.parse(protocol.SessionSetup, self.arena.allocator(), try self.expectResult(id));
        try testing.expectEqualStrings(snapshot.sessionId, setup.sessionId);
        return snapshot;
    }

    pub fn prompt(self: *Client, session: []const u8, text: []const u8) !rpc.Id {
        return self.request(protocol.method.session_prompt, .{
            .sessionId = session,
            .prompt = .{.{ .type = "text", .text = text }},
        });
    }

    /// Read until a permission request, returning its id and the call it
    /// asks about.
    pub fn awaitPermission(self: *Client) !struct { id: rpc.Id, call: []const u8 } {
        const message = try self.awaitMethod(protocol.method.session_request_permission);
        const asked = try rpc.parse(protocol.RequestPermission, self.arena.allocator(), message.params);
        return .{ .id = message.id.?, .call = asked.toolCall.toolCallId };
    }

    pub fn choose(self: *Client, id: rpc.Id, option: []const u8) !void {
        try self.answer(id, .{ .outcome = .{ .outcome = "selected", .optionId = option } });
    }

    pub fn stopReason(self: *Client, id: rpc.Id) !protocol.StopReason {
        return (try rpc.parse(protocol.Prompted, self.arena.allocator(), try self.expectResult(id))).stopReason;
    }
};

test "a synth client opens a session and has its snapshot before the reply" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();

    const early = try client.request(protocol.method.session_new, protocol.NewSession{ .cwd = fixture.project });
    try testing.expectEqual(rpc.code.invalid_request, (try client.expectError(early)).code);
    try client.initialize(true);

    const snapshot = try client.open(fixture.project);
    try testing.expect(std.mem.startsWith(u8, snapshot.sessionId, "ses_"));
    try testing.expectEqualStrings(fixture.project, snapshot.status.root);
    try testing.expectEqual(Loop.State.idle, snapshot.status.state);
    try testing.expectEqual(@as(usize, 0), snapshot.messages.len);

    const unknown = try client.request("session/fly", .{});
    try testing.expectEqual(rpc.code.method_not_found, (try client.expectError(unknown)).code);
    const relative = try client.request(protocol.method.session_new, protocol.NewSession{ .cwd = "project" });
    try testing.expectEqualStrings("cwd must be an absolute path", (try client.expectError(relative)).message);
}

test "a turn runs, its approval asked as a permission request and its prompt answered at the end" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.initialize(true);
    const session = (try client.open(fixture.project)).sessionId;
    const arena = client.arena.allocator();

    fixture.script.gate.reset();
    const prompted = try client.prompt(session, "make a note");
    var thinking: std.ArrayList(u8) = .empty;
    while (!std.mem.eql(u8, thinking.items, "weighing it up")) {
        const message = try client.awaitMethod(synth.method.stream);
        const update = try rpc.parse(synth.StreamUpdate, arena, message.params);
        try thinking.appendSlice(arena, update.stream.thinking);
    }
    fixture.script.gate.set(testing.io);

    const status = try client.awaitStatus(struct {
        fn matches(_: @This(), got: synth.Status) bool {
            return got.state == .awaiting_approval;
        }
    }{});
    const asked = try client.awaitPermission();
    try testing.expectEqualStrings(try toolCallId(arena, status.pending_seq.?, 0), asked.call);

    try client.choose(asked.id, "once");
    try testing.expectEqual(protocol.StopReason.end_turn, try client.stopReason(prompted));

    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(arena, &.{ fixture.project, "note.txt" }), arena, .limited(64));
    try testing.expectEqualStrings("acp", written);

    const loaded = try client.request(synth.method.load_tool_result, synth.LoadToolResult{ .sessionId = session, .seq = status.pending_seq.?, .call = 0 });
    try testing.expect((try client.expectResult(loaded)).string.len > 0);
}

test "a prompt sent while busy steers the turn, and both are answered when it ends" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.initialize(true);
    const session = (try client.open(fixture.project)).sessionId;

    fixture.script.gate.reset();
    const first = try client.prompt(session, "make a note");
    const second = try client.request(protocol.method.session_prompt, .{
        .sessionId = session,
        .prompt = .{
            .{ .type = "text", .text = "and this" },
            .{ .type = "resource", .resource = .{ .uri = "pasted", .text = "a long paste" } },
        },
    });
    _ = try client.awaitStatus(struct {
        fn matches(_: @This(), got: synth.Status) bool {
            return got.steering.len == 1;
        }
    }{});
    fixture.script.gate.set(testing.io);
    try client.choose((try client.awaitPermission()).id, "once");

    const steered = while (true) {
        const message = try client.awaitMethod(synth.method.appended);
        const appended = try rpc.parse(synth.Appended, client.arena.allocator(), message.params);
        if (std.mem.eql(u8, appended.message.text, "and this")) break appended.message;
    };
    try testing.expectEqualStrings("a long paste", steered.attachments[0].content);
    try client.choose((try client.awaitPermission()).id, "deny");
    try testing.expectEqual(protocol.StopReason.end_turn, try client.stopReason(first));
    try testing.expectEqual(protocol.StopReason.end_turn, try client.stopReason(second));
}

test "the first answer to a permission request wins, and the rest are taken back" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const first = try fixture.connect();
    defer first.close();
    const second = try fixture.connect();
    defer second.close();
    try first.initialize(true);
    try second.initialize(false);
    const session = (try first.open(fixture.project)).sessionId;

    const prompted = try first.prompt(session, "make a note");
    const mine = try first.awaitPermission();
    const theirs = try second.awaitPermission();
    try testing.expectEqualStrings(mine.call, theirs.call);

    try second.choose(theirs.id, "once");
    const withdrawn = try first.awaitMethod(protocol.method.cancel_request);
    const cancel = try rpc.parse(protocol.CancelRequest, first.arena.allocator(), withdrawn.params);
    try testing.expect(mine.id.eql(rpc.Id.from(cancel.requestId).?));

    try first.choose(mine.id, "deny");
    try testing.expectEqual(protocol.StopReason.end_turn, try first.stopReason(prompted));
    const written = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(first.arena.allocator(), &.{ fixture.project, "note.txt" }), first.arena.allocator(), .limited(64));
    try testing.expectEqualStrings("acp", written);
}

test "a cancelled turn takes its permission request back and answers its prompt cancelled" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.initialize(true);
    const session = (try client.open(fixture.project)).sessionId;

    const prompted = try client.prompt(session, "make a note");
    const asked = try client.awaitPermission();
    try client.notify(protocol.method.session_cancel, protocol.SessionId{ .sessionId = session });
    _ = try client.awaitMethod(protocol.method.cancel_request);
    try client.choose(asked.id, "once");
    try testing.expectEqual(protocol.StopReason.cancelled, try client.stopReason(prompted));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, try std.fs.path.join(client.arena.allocator(), &.{ fixture.project, "note.txt" }), .{}));
}

test "a client that did not ask for synth's extension is sent none of it" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.initialize(false);

    const id = try client.request(protocol.method.session_new, protocol.NewSession{ .cwd = fixture.project });
    const message = try client.next();
    try testing.expect(message.method == null);
    try testing.expect(message.id.?.eql(id));
    const setup = try rpc.parse(protocol.SessionSetup, client.arena.allocator(), message.result);
    try testing.expectEqualStrings(agents.default_id, setup.modes.?.currentModeId);
    try testing.expectEqualStrings("scripted", setup.configOptions[0].currentValue);
}

test "a model and its effort are chosen through config options, and remembered" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.initialize(true);
    const snapshot = try client.open(fixture.project);
    const session = snapshot.sessionId;
    try testing.expect(snapshot.status.switchable);
    try testing.expectEqualStrings("low", snapshot.status.effort);
    const arena = client.arena.allocator();

    const set = struct {
        fn run(c: *Client, id: []const u8, config: []const u8, value: []const u8) !protocol.ConfigOptions {
            const asked = try c.request(protocol.method.session_set_config_option, protocol.SetConfigOption{ .sessionId = id, .configId = config, .value = value });
            return rpc.parse(protocol.ConfigOptions, c.arena.allocator(), try c.expectResult(asked));
        }
    }.run;
    try testing.expectEqualStrings("high", (try set(client, session, protocol.config_effort, "high")).configOptions[1].currentValue);
    const bigger = try set(client, session, protocol.config_model, "bigger");
    try testing.expectEqualStrings("bigger", bigger.configOptions[0].currentValue);
    try testing.expectEqualStrings("low", bigger.configOptions[1].currentValue);
    try testing.expectEqualStrings("high", (try set(client, session, protocol.config_model, "scripted")).configOptions[1].currentValue);

    const listed = try client.request(synth.method.models, synth.ListModels{ .sessionId = session });
    const models = try rpc.parse(synth.Models, arena, try client.expectResult(listed));
    try testing.expectEqual(@as(usize, 2), models.offered.len);
    try testing.expectEqualStrings("high", models.offered[0].effort);

    const missing = try client.request(protocol.method.session_set_config_option, protocol.SetConfigOption{ .sessionId = session, .configId = protocol.config_model, .value = "missing" });
    try testing.expectEqualStrings("UnknownModel", (try client.expectError(missing)).message);
}

test "a session is listed once spoken in, loads back with its transcript, and an empty one is not kept" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.initialize(true);
    const arena = client.arena.allocator();
    const session = (try client.open(fixture.project)).sessionId;

    const prompted = try client.prompt(session, "make a note");
    try client.choose((try client.awaitPermission()).id, "once");
    _ = try client.stopReason(prompted);
    const empty = (try client.open(fixture.project)).sessionId;

    const list = struct {
        fn run(c: *Client, cwd: ?[]const u8) !protocol.SessionList {
            const asked = try c.request(protocol.method.session_list, protocol.ListSessions{ .cwd = cwd });
            return rpc.parse(protocol.SessionList, c.arena.allocator(), try c.expectResult(asked));
        }
    }.run;
    const listed = try list(client, fixture.project);
    try testing.expectEqual(@as(usize, 1), listed.sessions.len);
    try testing.expectEqualStrings(session, listed.sessions[0].sessionId);
    try testing.expect(listed.sessions[0]._meta.?.synth.messages >= 4);
    try testing.expect(std.mem.endsWith(u8, listed.sessions[0].updatedAt.?, "Z"));

    const load = try client.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = session, .cwd = fixture.project });
    const reloaded = try rpc.parse(synth.Snapshot, arena, (try client.awaitMethod(synth.method.snapshot)).params);
    _ = try client.expectResult(load);
    try testing.expectEqualStrings(session, reloaded.sessionId);
    try testing.expect(reloaded.messages.len >= 4);

    const gone = try client.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = empty, .cwd = fixture.project });
    try testing.expectEqualStrings("no such session", (try client.expectError(gone)).message);
    try testing.expectEqual(@as(usize, 1), (try list(client, null)).sessions.len);
}
