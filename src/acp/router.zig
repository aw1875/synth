//! ACP on one pipe, to sessions that each run in a process of their own: a
//! `synth acp --host` child, or, for a session another process hosts, that
//! session's socket.
//!
//! `synth acp` routes so for an editor, which may keep several sessions open
//! on one connection. `synth remote bridge`, what ssh runs at the far end,
//! keeps one at a time: the TUI it serves lets a session go as it opens the
//! next, as it does at home.
//!
//! Lines are read only to route them. Each new end hears the client's
//! `initialize` again, its answer kept from the client, which had one
//! already. Ends number their own requests of the client, so those are
//! renumbered on the way out and back again.

const std = @import("std");

const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const sockets = @import("sockets.zig");

const Router = @This();

allocator: std.mem.Allocator,
io: std.Io,
/// From the client, read on the router's own thread.
client_in: std.Io.File,
/// To the client, from any thread, under `client_mutex`.
client_out: std.Io.File,
client_mutex: std.Io.Mutex = .init,
client_buffer: [64 * 1024]u8 = undefined,
client_writer: std.Io.File.Writer = undefined,
client_gone: bool = false,
/// Where sessions hosted by other processes listen. Null reaches none.
socket_dir: ?[]const u8,
spawner: Spawner,
options: Options,

/// Guards `ends`, `asked`, `pending`, `next_id` and what each end hosts.
mutex: std.Io.Mutex = .init,
ends: std.ArrayList(*End) = .empty,
/// Requests the ends made of the client, by the id the client was shown.
asked: std.AutoHashMapUnmanaged(u64, Asked) = .empty,
/// Requests the client made, by their id as JSON, and who answers each.
pending: std.StringHashMapUnmanaged(Pending) = .empty,
next_id: u64 = 1,
/// The client's `initialize` params, to say hello to each new end with.
/// The router's thread alone uses it.
hello: ?[]u8 = null,

pub const Options = struct {
    /// One session at a time: opening another lets the last one go.
    exclusive: bool = false,
    /// Where a relative `cwd` in `session/new` is taken from. Null leaves it
    /// to the agent, which refuses one.
    home: ?[]const u8 = null,
};

pub const Spawner = struct {
    context: *anyopaque,
    start: *const fn (context: *anyopaque) anyerror!Pipe,
};

/// A session's end of the pipe. `input` and `output` are one file for a
/// socket.
pub const Pipe = struct {
    input: std.Io.File,
    output: std.Io.File,
    child: ?std.process.Child = null,
};

const Asked = struct { end: *End, id: []u8 };

const Pending = struct {
    end: *End,
    kind: enum { other, opens, closes } = .other,
};

/// A process at the far end, and the thread copying what it says to the
/// client.
const End = struct {
    router: *Router,
    pipe: Pipe,
    /// The session it hosts, or is opening, owned.
    handle: ?[]u8 = null,
    /// A socket to a session another process hosts.
    attached: bool = false,
    /// Asked to open a session, not yet answered.
    opening: bool = false,
    /// Stopped unasked. The router's thread lets it go.
    gone: bool = false,
    /// Ended on purpose: its going quiet is not the session's.
    retired: std.atomic.Value(bool) = .init(false),
    /// The id of the `initialize` the router sent it, owned, whose answer
    /// the client does not see.
    swallow: ?[]u8 = null,
    thread: std.Thread = undefined,
    writer: std.Io.File.Writer = undefined,
    buffer: [64 * 1024]u8 = undefined,

    fn spare(self: *const End) bool {
        return !self.attached and !self.gone and !self.opening and self.handle == null;
    }

    fn hosts(self: *const End, handle: []const u8) bool {
        const hosted = self.handle orelse return false;
        return !self.gone and std.mem.eql(u8, hosted, handle);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    client_in: std.Io.File,
    client_out: std.Io.File,
    socket_dir: ?[]const u8,
    spawner: Spawner,
    options: Options,
) Router {
    return .{
        .allocator = allocator,
        .io = io,
        .client_in = client_in,
        .client_out = client_out,
        .socket_dir = socket_dir,
        .spawner = spawner,
        .options = options,
    };
}

/// Pipe until the client leaves. A session it had detached goes on.
pub fn run(self: *Router) !void {
    self.client_writer = self.client_out.writerStreaming(self.io, &self.client_buffer);
    defer self.deinit();

    var buffer: [64 * 1024]u8 = undefined;
    var reader = self.client_in.readerStreaming(self.io, &buffer);
    var lines: rpc.LineReader = .init(self.allocator);
    defer lines.deinit();
    while (try lines.next(&reader.interface)) |line| try self.route(line);
}

fn deinit(self: *Router) void {
    for (self.ends.items) |end| self.leave(end);
    self.ends.deinit(self.allocator);
    var asked = self.asked.valueIterator();
    while (asked.next()) |entry| self.allocator.free(entry.id);
    self.asked.deinit(self.allocator);
    var pending = self.pending.keyIterator();
    while (pending.next()) |key| self.allocator.free(key.*);
    self.pending.deinit(self.allocator);
    if (self.hello) |hello| self.allocator.free(hello);
}

fn route(self: *Router, line: []const u8) !void {
    self.reap();
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return;
    if (parsed != .object) return;
    const message = parsed.object;
    const id = message.get("id");
    const method = stringOf(message.get("method")) orelse {
        if (id) |answered| try self.answer(arena, parsed, answered);
        return;
    };
    const params = message.get("params");
    if (std.mem.eql(u8, method, protocol.method.cancel_request)) return self.cancel(arena, line, params);

    const end = self.endFor(arena, method, params) catch |err| {
        if (id) |asking| self.refuse(asking, err);
        return;
    };
    if (id) |asking| try self.expect(arena, asking, end, method);
    self.reap();
    if (std.mem.eql(u8, method, protocol.method.session_new)) {
        if (try self.rooted(arena, parsed)) |rewritten| return self.send(end, rewritten);
    }
    self.send(end, line);
}

/// The end `method` goes to, made ready for it: a child for a new session,
/// the socket of a session another process hosts, or the end already
/// hosting the session the request names.
fn endFor(self: *Router, arena: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !*End {
    const eql = std.mem.eql;
    if (eql(u8, method, protocol.method.initialize)) {
        const first = self.ends.items.len == 0;
        const end = if (first) try self.start(null, false) else try self.anyEnd();
        const kept = try std.json.Stringify.valueAlloc(self.allocator, params orelse .null, .{});
        if (self.hello) |old| self.allocator.free(old);
        self.hello = kept;
        return end;
    }
    if (eql(u8, method, protocol.method.session_new)) return self.forNew();
    if (eql(u8, method, protocol.method.session_load)) {
        return self.forLoad((try rpc.parse(protocol.LoadSession, arena, params)).sessionId);
    }
    if (stringOf(fieldOf(params, "sessionId"))) |handle| {
        return self.hosting(handle) orelse error.UnknownSession;
    }
    return self.anyEnd();
}

fn forNew(self: *Router) !*End {
    const end = if (self.options.exclusive) blk: {
        if (self.current()) |end| if (!end.attached) break :blk end;
        break :blk try self.start(null, true);
    } else self.spare() orelse try self.start(null, true);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    end.opening = true;
    self.letOthersGo(end);
    return end;
}

fn forLoad(self: *Router, handle: []const u8) !*End {
    if (self.hosting(handle)) |end| return end;
    const end = if (try self.reach(handle)) |socket|
        try self.start(.{ .input = socket, .output = socket }, true)
    else if (self.options.exclusive) blk: {
        if (self.current()) |end| if (!end.attached) break :blk end;
        break :blk try self.start(null, true);
    } else self.spare() orelse try self.start(null, true);

    const owned = try self.allocator.dupe(u8, handle);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (end.handle) |old| self.allocator.free(old);
    end.handle = owned;
    end.opening = true;
    self.letOthersGo(end);
    return end;
}

/// In exclusive mode, every end but `kept`. Called under `mutex`; the ends
/// go once the request is on its way.
fn letOthersGo(self: *Router, kept: *End) void {
    if (!self.options.exclusive) return;
    for (self.ends.items) |end| {
        if (end != kept) dismiss(end);
    }
}

/// Mark `end` to be let go on purpose. Called under `mutex`.
fn dismiss(end: *End) void {
    end.gone = true;
    end.retired.store(true, .release);
}

fn hosting(self: *Router, handle: []const u8) ?*End {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.ends.items) |end| {
        if (end.hosts(handle)) return end;
    }
    return null;
}

fn spare(self: *Router) ?*End {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.ends.items) |end| {
        if (end.spare()) return end;
    }
    return null;
}

fn current(self: *Router) ?*End {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.ends.items) |end| {
        if (!end.gone) return end;
    }
    return null;
}

/// An end for a request that names no session: one with none, else any.
fn anyEnd(self: *Router) !*End {
    if (self.spare()) |end| return end;
    return self.current() orelse self.start(null, true);
}

fn reach(self: *Router, handle: []const u8) !?std.Io.File {
    const socket_dir = self.socket_dir orelse return null;
    const path = try sockets.pathFor(self.allocator, socket_dir, handle);
    defer self.allocator.free(path);
    return sockets.connect(path) catch |err| switch (err) {
        error.NotListening => null,
        else => err,
    };
}

/// A new end on `pipe`, a child when null, said hello to when `hello_again`.
fn start(self: *Router, given: ?Pipe, hello_again: bool) !*End {
    const pipe = given orelse try self.spawner.start(self.spawner.context);
    const end = self.allocator.create(End) catch |err| {
        var unused = pipe;
        closePipe(self.io, &unused, false);
        return err;
    };
    end.* = .{ .router = self, .pipe = pipe, .attached = given != null };
    end.writer = pipe.input.writerStreaming(self.io, &end.buffer);
    errdefer self.drop(end, false);

    if (hello_again) if (self.hello) |hello| try self.greet(end, hello);
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.ends.append(self.allocator, end);
    }
    end.thread = std.Thread.spawn(.{}, pump, .{end}) catch |err| {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.ends.pop();
        return err;
    };
    return end;
}

fn greet(self: *Router, end: *End, hello: []const u8) !void {
    const id = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        defer self.next_id += 1;
        break :blk try std.fmt.allocPrint(self.allocator, "_synth/router/{d}", .{self.next_id});
    };
    end.swallow = id;
    const params = try std.json.parseFromSlice(std.json.Value, self.allocator, hello, .{});
    defer params.deinit();
    try rpc.request(&end.writer.interface, .{ .string = id }, protocol.method.initialize, params.value);
    try end.writer.interface.flush();
}

/// Let go of the ends that stopped or were told to go, and of every spare
/// child but one: closing sessions leaves them behind.
fn reap(self: *Router) void {
    var spares: usize = 0;
    var index: usize = 0;
    while (index < self.ends.items.len) {
        const end = self.ends.items[index];
        self.mutex.lockUncancelable(self.io);
        const extra = end.spare() and spares > 0;
        if (end.spare()) spares += 1;
        const gone = end.gone or extra;
        if (gone) _ = self.ends.orderedRemove(index);
        self.mutex.unlock(self.io);
        if (!gone) {
            index += 1;
            continue;
        }
        self.retire(end);
    }
}

/// End `end` on purpose, a child included, waiting until it has had its
/// say.
fn retire(self: *Router, end: *End) void {
    end.retired.store(true, .release);
    hangUp(self.io, &end.pipe);
    end.thread.join();
    self.forget(end);
    self.drop(end, true);
}

/// Leave `end` as the client leaves: a session it had detached goes on, and
/// nothing waits for it.
fn leave(self: *Router, end: *End) void {
    end.retired.store(true, .release);
    hangUp(self.io, &end.pipe);
    end.thread.join();
    self.drop(end, false);
}

/// Drop what is waiting on `end`, which is going.
fn forget(self: *Router, end: *End) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var asked = self.asked.iterator();
    while (asked.next()) |entry| {
        if (entry.value_ptr.end != end) continue;
        self.allocator.free(entry.value_ptr.id);
        self.asked.removeByPtr(entry.key_ptr);
        asked = self.asked.iterator();
    }
    var pending = self.pending.iterator();
    while (pending.next()) |entry| {
        if (entry.value_ptr.end != end) continue;
        const key = entry.key_ptr.*;
        self.pending.removeByPtr(entry.key_ptr);
        self.allocator.free(key);
        pending = self.pending.iterator();
    }
}

fn drop(self: *Router, end: *End, wait: bool) void {
    closePipe(self.io, &end.pipe, wait);
    if (end.handle) |handle| self.allocator.free(handle);
    if (end.swallow) |id| self.allocator.free(id);
    self.allocator.destroy(end);
}

/// Remember who answers the client's request `id`.
fn expect(self: *Router, arena: std.mem.Allocator, id: std.json.Value, end: *End, method: []const u8) !void {
    const key = try self.allocator.dupe(u8, try std.json.Stringify.valueAlloc(arena, id, .{}));
    errdefer self.allocator.free(key);
    const eql = std.mem.eql;
    const kind: @FieldType(Pending, "kind") = if (eql(u8, method, protocol.method.session_new) or eql(u8, method, protocol.method.session_load))
        .opens
    else if (eql(u8, method, protocol.method.session_close))
        .closes
    else
        .other;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const slot = try self.pending.getOrPut(self.allocator, key);
    if (slot.found_existing) self.allocator.free(key);
    slot.value_ptr.* = .{ .end = end, .kind = kind };
}

/// The client's answer to a request an end made: back to that end, under
/// the id it gave.
fn answer(self: *Router, arena: std.mem.Allocator, parsed: std.json.Value, id: std.json.Value) !void {
    if (id != .integer or id.integer < 0) return;
    const entry = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        break :blk self.asked.fetchRemove(@intCast(id.integer)) orelse return;
    };
    const asked = entry.value;
    defer self.allocator.free(asked.id);
    var message = parsed;
    try message.object.put(arena, "id", try std.json.parseFromSliceLeaky(std.json.Value, arena, asked.id, .{}));
    self.send(asked.end, try std.json.Stringify.valueAlloc(arena, message, .{}));
}

/// The client taking back a request: to the end answering it.
fn cancel(self: *Router, arena: std.mem.Allocator, line: []const u8, params: ?std.json.Value) !void {
    const id = fieldOf(params, "requestId") orelse return;
    const key = try std.json.Stringify.valueAlloc(arena, id, .{});
    const end = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        break :blk (self.pending.get(key) orelse return).end;
    };
    self.send(end, line);
}

/// `session/new` with a relative `cwd` re-sent with it under `home`: the
/// client cannot know where that is. Null when it needs nothing.
fn rooted(self: *Router, arena: std.mem.Allocator, parsed: std.json.Value) !?[]const u8 {
    const home = self.options.home orelse return null;
    var params = parsed.object.get("params") orelse return null;
    const cwd = stringOf(fieldOf(params, "cwd")) orelse return null;
    const resolved = try resolveCwd(arena, home, cwd) orelse return null;
    try params.object.put(arena, "cwd", .{ .string = resolved });
    var message = parsed;
    try message.object.put(arena, "params", params);
    return try std.json.Stringify.valueAlloc(arena, message, .{});
}

/// `cwd` under `home` when it is relative, `~` or `~/...` included; null when
/// it is absolute already.
pub fn resolveCwd(arena: std.mem.Allocator, home: []const u8, cwd: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(cwd)) return null;
    if (std.mem.eql(u8, cwd, "~") or cwd.len == 0) return try arena.dupe(u8, home);
    const rest = if (std.mem.startsWith(u8, cwd, "~/")) cwd[2..] else cwd;
    return try std.fs.path.join(arena, &.{ home, rest });
}

fn send(self: *Router, end: *End, line: []const u8) void {
    _ = self;
    end.writer.interface.writeAll(line) catch return;
    end.writer.interface.writeByte('\n') catch return;
    end.writer.interface.flush() catch return;
}

fn refuse(self: *Router, id: std.json.Value, err: anyerror) void {
    const text = switch (err) {
        error.UnknownSession => "no such session",
        error.SessionStopped => "the session's agent stopped",
        else => @errorName(err),
    };
    self.toClient(struct {
        id: rpc.Id,
        text: []const u8,
        fn write(context: @This(), w: *std.Io.Writer) !void {
            try rpc.fail(w, context.id, rpc.code.internal_error, context.text);
        }
    }{ .id = rpc.Id.from(id) orelse return, .text = text });
}

/// Write to the client, unless it has gone.
fn toClient(self: *Router, writing: anytype) void {
    self.client_mutex.lockUncancelable(self.io);
    defer self.client_mutex.unlock(self.io);
    if (self.client_gone) return;
    writing.write(&self.client_writer.interface) catch return;
    self.client_writer.interface.flush() catch {};
}

const Line = struct {
    text: []const u8,
    fn write(self: Line, w: *std.Io.Writer) !void {
        try w.writeAll(self.text);
        try w.writeByte('\n');
    }
};

/// Tell the far end we are done: end of input to a child, a hang-up to a
/// socket. Its output ends once it has said what it had left to say.
fn hangUp(io: std.Io, pipe: *Pipe) void {
    if (pipe.child) |*child| {
        if (child.stdin) |stdin| stdin.close(io);
        child.stdin = null;
        return;
    }
    _ = std.posix.system.shutdown(pipe.input.handle, std.posix.SHUT.RDWR);
}

fn closePipe(io: std.Io, pipe: *Pipe, wait: bool) void {
    if (pipe.child) |*child| {
        hangUp(io, pipe);
        if (wait) {
            _ = child.wait(io) catch {};
        } else if (child.stdout) |stdout| stdout.close(io);
        return;
    }
    pipe.input.close(io);
    if (pipe.output.handle != pipe.input.handle) pipe.output.close(io);
}

/// What the far end says, to the client, a line at a time as it arrives.
/// Its going quiet unasked is the session's end: in exclusive mode the
/// client is told by its input ending, otherwise by its requests to that
/// session failing.
fn pump(end: *End) void {
    const self = end.router;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = end.pipe.output.readerStreaming(self.io, &buffer);
    var lines: rpc.LineReader = .init(self.allocator);
    defer lines.deinit();
    while (true) {
        const line = (lines.next(&reader.interface) catch null) orelse break;
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const out = self.outbound(arena_state.allocator(), end, line) catch line;
        if (out.len > 0) self.toClient(Line{ .text = out });
    }
    if (end.retired.load(.acquire)) return;

    self.mutex.lockUncancelable(self.io);
    end.gone = true;
    self.mutex.unlock(self.io);
    self.failPending(end);
    if (!self.options.exclusive) return;
    self.client_mutex.lockUncancelable(self.io);
    defer self.client_mutex.unlock(self.io);
    self.client_gone = true;
    _ = std.posix.system.shutdown(self.client_out.handle, std.posix.SHUT.WR);
    self.client_out.close(self.io);
}

/// `line` as the client is to see it: an end's request renumbered, the
/// answer to a greeting dropped (empty), the rest as it is. Answers that
/// open or close a session say which session the end now hosts.
fn outbound(self: *Router, arena: std.mem.Allocator, end: *End, line: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, line, "\"id\"") == null and std.mem.indexOf(u8, line, protocol.method.cancel_request) == null) return line;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return line;
    if (parsed != .object) return line;
    var message = parsed;
    const method = stringOf(message.object.get("method"));
    const id = message.object.get("id");

    if (method) |name| {
        if (id) |asking| {
            const original = try self.allocator.dupe(u8, try std.json.Stringify.valueAlloc(arena, asking, .{}));
            errdefer self.allocator.free(original);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const shown = self.next_id;
            try self.asked.put(self.allocator, shown, .{ .end = end, .id = original });
            self.next_id += 1;
            try message.object.put(arena, "id", .{ .integer = @intCast(shown) });
            return std.json.Stringify.valueAlloc(arena, message, .{});
        }
        if (!std.mem.eql(u8, name, protocol.method.cancel_request)) return line;
        var params = message.object.get("params") orelse return line;
        const withdrawn = try std.json.Stringify.valueAlloc(arena, fieldOf(params, "requestId") orelse return line, .{});
        const shown = self.takeAsked(end, withdrawn) orelse return line;
        try params.object.put(arena, "requestId", .{ .integer = @intCast(shown) });
        try message.object.put(arena, "params", params);
        return std.json.Stringify.valueAlloc(arena, message, .{});
    }

    const answered = id orelse return line;
    const key = try std.json.Stringify.valueAlloc(arena, answered, .{});
    if (end.swallow) |swallowed| if (answered == .string and std.mem.eql(u8, answered.string, swallowed)) {
        self.allocator.free(swallowed);
        end.swallow = null;
        return "";
    };
    self.settle(end, key, message);
    return line;
}

/// The id the client was shown for `end`'s request `original`, forgotten
/// now that it is taken back.
fn takeAsked(self: *Router, end: *End, original: []const u8) ?u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    var asked = self.asked.iterator();
    while (asked.next()) |entry| {
        if (entry.value_ptr.end != end or !std.mem.eql(u8, entry.value_ptr.id, original)) continue;
        const shown = entry.key_ptr.*;
        self.allocator.free(entry.value_ptr.id);
        self.asked.removeByPtr(entry.key_ptr);
        return shown;
    }
    return null;
}

/// The client's request `key` answered: what it did to the session `end`
/// hosts.
fn settle(self: *Router, end: *End, key: []const u8, message: std.json.Value) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = self.pending.fetchRemove(key) orelse return;
    self.allocator.free(entry.key);
    const failed = message.object.get("error") != null;
    switch (entry.value.kind) {
        .other => {},
        .opens => {
            end.opening = false;
            if (failed) {
                if (end.handle) |handle| self.allocator.free(handle);
                end.handle = null;
                if (end.attached) dismiss(end);
                return;
            }
            const opened = stringOf(fieldOf(message.object.get("result"), "sessionId")) orelse return;
            const owned = self.allocator.dupe(u8, opened) catch return;
            if (end.handle) |handle| self.allocator.free(handle);
            end.handle = owned;
        },
        .closes => if (!failed) {
            if (end.handle) |handle| self.allocator.free(handle);
            end.handle = null;
            if (end.attached) dismiss(end);
        },
    }
}

/// Fail what the client is waiting on from `end`, which stopped.
fn failPending(self: *Router, end: *End) void {
    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| self.allocator.free(id);
        ids.deinit(self.allocator);
    }
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var pending = self.pending.iterator();
        while (pending.next()) |entry| {
            if (entry.value_ptr.end != end) continue;
            const key = entry.key_ptr.*;
            self.pending.removeByPtr(entry.key_ptr);
            ids.append(self.allocator, key) catch self.allocator.free(key);
            pending = self.pending.iterator();
        }
    }
    for (ids.items) |key| {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, key, .{}) catch continue;
        defer parsed.deinit();
        self.refuse(parsed.value, error.SessionStopped);
    }
}

fn fieldOf(value: ?std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value orelse return null) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

/// `synth remote bridge` on this process's stdio: one session at a time,
/// relative directories taken from home.
pub fn bridge(process: std.process.Init) !void {
    const home = process.environ_map.get("HOME") orelse "/";
    var arena_state: std.heap.ArenaAllocator = .init(process.gpa);
    defer arena_state.deinit();
    const exe = try std.process.executablePathAlloc(process.io, arena_state.allocator());
    var children: Children = .{
        .io = process.io,
        .argv = try hostCommand(arena_state.allocator(), process.environ_map, exe),
        .cwd = home,
    };
    try serve(process, &children, .{ .exclusive = true, .home = home });
}

/// `synth acp` on this process's stdio: a session a child.
pub fn front(process: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(process.gpa);
    defer arena_state.deinit();
    const exe = try std.process.executablePathAlloc(process.io, arena_state.allocator());
    var children: Children = .{
        .io = process.io,
        .argv = try arena_state.allocator().dupe([]const u8, &.{ exe, "acp", "--host" }),
    };
    try serve(process, &children, .{});
}

fn serve(process: std.process.Init, children: *Children, options: Options) !void {
    const socket_dir = try sockets.dir(process.gpa, process.environ_map);
    defer process.gpa.free(socket_dir);
    var router: Router = .init(process.gpa, process.io, .stdin(), .stdout(), socket_dir, .{ .context = children, .start = Children.start }, options);
    try router.run();
}

/// `synth acp --host` children. A session's directory is its `cwd`, not the
/// process's, so the bridge starts them at home.
const Children = struct {
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,

    fn start(context: *anyopaque) anyerror!Pipe {
        const self: *Children = @ptrCast(@alignCast(context));
        const child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .cwd = if (self.cwd) |path| .{ .path = path } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{ .input = child.stdin.?, .output = child.stdout.?, .child = child };
    }
};

/// What starts a session. ssh runs a command with a bare environment, without
/// the `PATH` a login sets up, and a session passes its own on to every MCP
/// server and tool it runs; so a bridge ssh ran starts sessions under a login
/// shell. Started from a terminal, it keeps that terminal's environment, a
/// nix shell say, as a session run there always has.
fn hostCommand(arena: std.mem.Allocator, env: *const std.process.Environ.Map, exe: []const u8) ![]const []const u8 {
    const shell = env.get("SHELL") orelse "";
    const over_ssh = env.get("SSH_CONNECTION") != null and env.get("SSH_TTY") == null;
    if (!over_ssh or !std.fs.path.isAbsolute(shell)) return arena.dupe([]const u8, &.{ exe, "acp", "--host" });

    var script: std.Io.Writer.Allocating = .init(arena);
    try script.writer.writeAll("exec ");
    try quote(&script.writer, exe);
    try script.writer.writeAll(" acp --host");
    return arena.dupe([]const u8, &.{ shell, "-l", "-c", script.written() });
}

/// Single quotes, each one inside closed, escaped and reopened: read the same
/// by sh, bash, zsh and fish.
fn quote(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('\'');
    for (text) |c| {
        if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}

const testing = std.testing;
const Agent = @import("agent.zig");
const synth = @import("synth.zig");

test "a session ssh asked for starts under a login shell, one from a terminal as it is" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/zsh");

    const local = try hostCommand(arena, &env, "/opt/it's/synth");
    try testing.expectEqualStrings("/opt/it's/synth", local[0]);
    try testing.expectEqualStrings("--host", local[2]);

    try env.put("SSH_CONNECTION", "10.0.0.2 51000 10.0.0.1 22");
    const remote = try hostCommand(arena, &env, "/opt/it's/synth");
    const expected = [_][]const u8{ "/bin/zsh", "-l", "-c", "exec '/opt/it'\\''s/synth' acp --host" };
    try testing.expectEqual(expected.len, remote.len);
    for (expected, remote) |want, got| try testing.expectEqualStrings(want, got);

    try env.put("SSH_TTY", "/dev/pts/3");
    try testing.expectEqual(@as(usize, 3), (try hostCommand(arena, &env, "/opt/synth")).len);
}

test "a relative directory is taken from the far end's home" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(null, try resolveCwd(arena, "/home/me", "/srv/app"));
    try testing.expectEqualStrings("/home/me", (try resolveCwd(arena, "/home/me", "~")).?);
    try testing.expectEqualStrings("/home/me/code/app", (try resolveCwd(arena, "/home/me", "~/code/app")).?);
    try testing.expectEqualStrings("/home/me/code", (try resolveCwd(arena, "/home/me", "code")).?);
}

/// A child for each spawn: a fresh agent, as a fresh `synth acp --host` would
/// be.
const Fixtures = struct {
    fixtures: std.ArrayList(*Agent.Fixture) = .empty,

    fn start(context: *anyopaque) anyerror!Pipe {
        const self: *Fixtures = @ptrCast(@alignCast(context));
        const fixture = try Agent.Fixture.create();
        errdefer fixture.destroy();
        try self.fixtures.append(testing.allocator, fixture);
        const far = try fixture.socket();
        return .{ .input = far, .output = far };
    }

    fn deinit(self: *Fixtures) void {
        for (self.fixtures.items) |fixture| fixture.destroy();
        self.fixtures.deinit(testing.allocator);
    }
};

/// A router on one end of a socket pair, run on a thread, and a client on
/// the other end.
const Rig = struct {
    children: Fixtures = .{},
    router: Router = undefined,
    thread: std.Thread = undefined,
    client: *Agent.Client = undefined,

    fn start(self: *Rig, socket_dir: ?[]const u8, options: Options) !void {
        const linux = std.os.linux;
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.SocketPair;
        const ours: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
        self.router = .init(testing.allocator, testing.io, ours, ours, socket_dir, .{ .context = &self.children, .start = Fixtures.start }, options);
        self.thread = try std.Thread.spawn(.{}, struct {
            fn run(router: *Router) void {
                router.run() catch {};
                router.client_in.close(router.io);
            }
        }.run, .{&self.router});
        self.client = try Agent.Client.create(.{ .handle = fds[0], .flags = .{ .nonblocking = false } });
        const timeout: linux.timeval = .{ .sec = 10, .usec = 0 };
        _ = linux.setsockopt(fds[0], linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
    }

    fn stop(self: *Rig) void {
        self.client.close();
        self.thread.join();
        self.children.deinit();
    }
};

test "the bridge pipes to a child, attaches to a session hosted elsewhere, and goes back for a new one" {
    const elsewhere_host = try Agent.Fixture.create();
    defer elsewhere_host.destroy();
    const socket_dir = try std.fs.path.join(elsewhere_host.arena.allocator(), &.{ std.fs.path.dirname(elsewhere_host.project).?, "sockets" });
    elsewhere_host.agent.options.socket_dir = socket_dir;
    const host = try elsewhere_host.connect();
    defer host.close();
    try host.initialize(true);
    const handle = try elsewhere_host.arena.allocator().dupe(u8, (try host.open(elsewhere_host.project)).sessionId);

    var rig: Rig = .{};
    try rig.start(socket_dir, .{ .exclusive = true, .home = "/nowhere" });
    defer rig.stop();
    const client = rig.client;
    const children = &rig.children.fixtures;

    try client.initialize(true);
    const fresh = try client.arena.allocator().dupe(u8, (try client.open(children.items[0].project)).sessionId);
    try testing.expectEqual(1, children.items.len);

    const load = try client.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = handle });
    const snapshot = try rpc.parse(synth.Snapshot, client.arena.allocator(), (try client.awaitMethod(synth.method.snapshot)).params);
    try testing.expectEqualStrings(handle, snapshot.sessionId);
    _ = try client.expectResult(load);

    const elsewhere = try client.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = fresh });
    try testing.expectEqualStrings("no such session", (try client.expectError(elsewhere)).message);
    try testing.expectEqual(2, children.items.len);
    _ = try client.open(children.items[1].project);
    try testing.expectEqual(2, children.items.len);
}

test "sessions opened on one connection each get a child, and answers find their way back" {
    var rig: Rig = .{};
    try rig.start(null, .{});
    defer rig.stop();
    const client = rig.client;
    const children = &rig.children.fixtures;
    const arena = client.arena.allocator();

    try client.initialize(true);
    const project = try arena.dupe(u8, children.items[0].project);
    const first = try arena.dupe(u8, (try client.open(project)).sessionId);
    const second = try arena.dupe(u8, (try client.open(project)).sessionId);
    try testing.expectEqual(2, children.items.len);

    const first_turn = try client.prompt(first, "make a note");
    const first_asked = try client.awaitPermission();
    const second_turn = try client.prompt(second, "make a note");
    const second_asked = try client.awaitPermission();
    try testing.expect(!first_asked.id.eql(second_asked.id));

    try client.choose(second_asked.id, "once");
    try testing.expectEqual(protocol.StopReason.end_turn, try client.stopReason(second_turn));
    try client.choose(first_asked.id, "deny");
    try testing.expectEqual(protocol.StopReason.end_turn, try client.stopReason(first_turn));

    _ = try client.expectResult(try client.request(protocol.method.session_close, protocol.SessionId{ .sessionId = first }));
    const closed = try client.prompt(first, "anyone there?");
    try testing.expectEqualStrings("no such session", (try client.expectError(closed)).message);

    _ = try client.open(project);
    try testing.expectEqual(2, children.items.len);
}
