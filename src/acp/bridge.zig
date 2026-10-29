//! `synth remote bridge`: what `ssh <host>` runs at the far end. ACP on its
//! stdio, piped to a session on this machine: a `synth acp` child of its own,
//! or, for a session another process hosts, that session's socket.
//!
//! Only the requests that choose a session are read on the way through. A
//! session another process hosts is attached to on its socket, the child left
//! behind; a new session from there goes back to a child. Each new end hears
//! the client's `initialize` again, its answer kept from the client, which had
//! one already.

const std = @import("std");

const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const sockets = @import("sockets.zig");

const Bridge = @This();

allocator: std.mem.Allocator,
io: std.Io,
/// From the client, read on the bridge's own thread.
client_in: std.Io.File,
/// To the client, from either thread, under `client_mutex`.
client_out: std.Io.File,
client_mutex: std.Io.Mutex = .init,
client_buffer: [64 * 1024]u8 = undefined,
client_writer: std.Io.File.Writer = undefined,
client_gone: bool = false,
/// Where sessions hosted by other processes listen. Null reaches none.
socket_dir: ?[]const u8,
/// What starts a `synth acp` child.
spawner: Spawner,
/// Where a relative `cwd` in `session/new` is taken from.
home: []const u8,

far: ?*Far = null,
/// The client's `initialize` params, to say hello to each new end with.
hello: ?[]u8 = null,
next_hello: u64 = 1,

pub const Spawner = struct {
    context: *anyopaque,
    start: *const fn (context: *anyopaque) anyerror!Ends,
};

/// A session's end of the pipe. `input` and `output` are one file for a
/// socket.
pub const Ends = struct {
    input: std.Io.File,
    output: std.Io.File,
    child: ?std.process.Child = null,
};

/// The end in use, and the thread copying what it says to the client.
const Far = struct {
    bridge: *Bridge,
    ends: Ends,
    /// The session whose socket this is, owned. Null for a child.
    attached: ?[]u8 = null,
    thread: std.Thread = undefined,
    writer: std.Io.File.Writer = undefined,
    buffer: [64 * 1024]u8 = undefined,
    /// The id of the `initialize` this bridge sent, whose answer the client
    /// does not see. Set before the thread starts, cleared by it.
    swallow: ?[]u8 = null,
    /// Ended on purpose: its going quiet is not the session's.
    retired: std.atomic.Value(bool) = .init(false),
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, client_in: std.Io.File, client_out: std.Io.File, socket_dir: ?[]const u8, home: []const u8, spawner: Spawner) Bridge {
    return .{
        .allocator = allocator,
        .io = io,
        .client_in = client_in,
        .client_out = client_out,
        .socket_dir = socket_dir,
        .home = home,
        .spawner = spawner,
    };
}

/// Pipe until the client leaves. A session it had detached goes on.
pub fn run(self: *Bridge) !void {
    self.client_writer = self.client_out.writerStreaming(self.io, &self.client_buffer);
    defer if (self.hello) |hello| self.allocator.free(hello);
    defer if (self.far) |far| self.leave(far);

    var buffer: [64 * 1024]u8 = undefined;
    var reader = self.client_in.readerStreaming(self.io, &buffer);
    var lines: rpc.LineReader = .init(self.allocator);
    defer lines.deinit();
    while (try lines.next(&reader.interface)) |line| try self.route(line);
}

fn route(self: *Bridge, line: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = rpc.Message.parse(arena, try arena.dupe(u8, line)) catch return self.forward(line);
    const method = message.method orelse return self.forward(line);

    self.choose(arena, method, message.params) catch |err| {
        const id = message.id orelse return;
        return self.refuse(id, err);
    };
    if (std.mem.eql(u8, method, protocol.method.session_new)) {
        if (try self.rooted(arena, message)) |rewritten| return self.forward(rewritten);
    }
    return self.forward(line);
}

/// Make the end ready for `method`: a child to begin with, the socket of a
/// session another process hosts for `session/load`, and a child again for
/// `session/new` from a socket.
fn choose(self: *Bridge, arena: std.mem.Allocator, method: []const u8, params: ?std.json.Value) !void {
    const eql = std.mem.eql;
    if (eql(u8, method, protocol.method.initialize)) {
        const kept = try std.json.Stringify.valueAlloc(self.allocator, params orelse .null, .{});
        if (self.hello) |old| self.allocator.free(old);
        self.hello = kept;
        if (self.far == null) try self.useChild(false);
        return;
    }
    if (self.far == null) try self.useChild(false);
    const far = self.far.?;
    if (eql(u8, method, protocol.method.session_load)) {
        const handle = (try rpc.parse(protocol.LoadSession, arena, params)).sessionId;
        if (far.attached) |current| if (eql(u8, current, handle)) return;
        if (try self.reach(handle)) |socket| return self.attach(socket, handle);
        if (far.attached != null) try self.useChild(true);
        return;
    }
    if (eql(u8, method, protocol.method.session_new) and far.attached != null) try self.useChild(true);
}

/// `session/new` with a relative `cwd` re-sent with it under this machine's
/// home: the client cannot know where that is. Null when it needs nothing.
fn rooted(self: *Bridge, arena: std.mem.Allocator, message: rpc.Message) !?[]const u8 {
    const request = try rpc.parse(protocol.NewSession, arena, message.params);
    const cwd = try resolveCwd(arena, self.home, request.cwd) orelse return null;
    var params = message.params.?;
    try params.object.put(arena, "cwd", .{ .string = cwd });
    var out: std.Io.Writer.Allocating = .init(arena);
    try rpc.request(&out.writer, message.id orelse return error.InvalidRequest, protocol.method.session_new, params);
    return std.mem.trimEnd(u8, out.written(), "\n");
}

/// `cwd` under `home` when it is relative, `~` or `~/...` included; null when
/// it is absolute already.
pub fn resolveCwd(arena: std.mem.Allocator, home: []const u8, cwd: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(cwd)) return null;
    if (std.mem.eql(u8, cwd, "~") or cwd.len == 0) return try arena.dupe(u8, home);
    const rest = if (std.mem.startsWith(u8, cwd, "~/")) cwd[2..] else cwd;
    return try std.fs.path.join(arena, &.{ home, rest });
}

fn reach(self: *Bridge, handle: []const u8) !?std.Io.File {
    const socket_dir = self.socket_dir orelse return null;
    const path = try sockets.pathFor(self.allocator, socket_dir, handle);
    defer self.allocator.free(path);
    return sockets.connect(path) catch |err| switch (err) {
        error.NotListening => null,
        else => err,
    };
}

fn useChild(self: *Bridge, replacing: bool) !void {
    const ends = try self.spawner.start(self.spawner.context);
    try self.replace(ends, null, replacing);
}

fn attach(self: *Bridge, socket: std.Io.File, handle: []const u8) !void {
    const owned = self.allocator.dupe(u8, handle) catch |err| {
        socket.close(self.io);
        return err;
    };
    try self.replace(.{ .input = socket, .output = socket }, owned, true);
}

/// Put `ends` in place of the end in use, saying hello to it when `hello_again`.
/// The old end is let go first, so what it says last reaches the client
/// before anything of the new one's.
fn replace(self: *Bridge, ends: Ends, attached: ?[]u8, hello_again: bool) !void {
    const far = self.allocator.create(Far) catch |err| {
        var unused = ends;
        closeEnds(self.io, &unused, false);
        if (attached) |handle| self.allocator.free(handle);
        return err;
    };
    far.* = .{ .bridge = self, .ends = ends, .attached = attached };
    far.writer = ends.input.writerStreaming(self.io, &far.buffer);
    errdefer self.drop(far, false);

    if (self.far) |old| {
        self.far = null;
        self.retire(old);
    }
    if (hello_again) if (self.hello) |hello| try self.greet(far, hello);
    far.thread = try std.Thread.spawn(.{}, pump, .{far});
    self.far = far;
}

fn greet(self: *Bridge, far: *Far, hello: []const u8) !void {
    const id = try std.fmt.allocPrint(self.allocator, "_synth/bridge/{d}", .{self.next_hello});
    self.next_hello += 1;
    far.swallow = id;
    const params = try std.json.parseFromSlice(std.json.Value, self.allocator, hello, .{});
    defer params.deinit();
    try rpc.request(&far.writer.interface, .{ .string = id }, protocol.method.initialize, params.value);
    try far.writer.interface.flush();
}

fn forward(self: *Bridge, line: []const u8) !void {
    const far = self.far orelse return;
    far.writer.interface.writeAll(line) catch return;
    far.writer.interface.writeByte('\n') catch return;
    far.writer.interface.flush() catch return;
}

fn refuse(self: *Bridge, id: rpc.Id, err: anyerror) void {
    var message: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "the bridge could not reach a session: {s}", .{@errorName(err)}) catch "the bridge could not reach a session";
    self.client_mutex.lockUncancelable(self.io);
    defer self.client_mutex.unlock(self.io);
    if (self.client_gone) return;
    rpc.fail(&self.client_writer.interface, id, rpc.code.internal_error, text) catch return;
    self.client_writer.interface.flush() catch {};
}

/// End an end on purpose, a child included, waiting until it has had its
/// say.
fn retire(self: *Bridge, far: *Far) void {
    far.retired.store(true, .release);
    hangUp(self.io, &far.ends);
    far.thread.join();
    self.drop(far, true);
}

/// Leave the end in use as the client leaves: a session it had detached
/// goes on, and nothing waits for it.
fn leave(self: *Bridge, far: *Far) void {
    self.far = null;
    far.retired.store(true, .release);
    hangUp(self.io, &far.ends);
    far.thread.join();
    self.drop(far, false);
}

fn drop(self: *Bridge, far: *Far, wait: bool) void {
    closeEnds(self.io, &far.ends, wait);
    if (far.attached) |handle| self.allocator.free(handle);
    if (far.swallow) |id| self.allocator.free(id);
    self.allocator.destroy(far);
}

/// Tell the far end we are done: end of input to a child, a hang-up to a
/// socket. Its output ends once it has said what it had left to say.
fn hangUp(io: std.Io, ends: *Ends) void {
    if (ends.child) |*child| {
        if (child.stdin) |stdin| stdin.close(io);
        child.stdin = null;
        return;
    }
    _ = std.posix.system.shutdown(ends.input.handle, std.posix.SHUT.RDWR);
}

fn closeEnds(io: std.Io, ends: *Ends, wait: bool) void {
    if (ends.child) |*child| {
        hangUp(io, ends);
        if (wait) {
            _ = child.wait(io) catch {};
        } else if (child.stdout) |stdout| stdout.close(io);
        return;
    }
    ends.input.close(io);
    if (ends.output.handle != ends.input.handle) ends.output.close(io);
}

/// What the far end says, to the client, a line at a time as it arrives.
/// Its going quiet unasked is the session's end: the client is told by its
/// input ending.
fn pump(far: *Far) void {
    const self = far.bridge;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = far.ends.output.readerStreaming(self.io, &buffer);
    var lines: rpc.LineReader = .init(self.allocator);
    defer lines.deinit();
    while (true) {
        const line = (lines.next(&reader.interface) catch null) orelse break;
        if (far.swallow) |id| if (answers(self.allocator, line, id)) {
            self.allocator.free(id);
            far.swallow = null;
            continue;
        };
        self.client_mutex.lockUncancelable(self.io);
        defer self.client_mutex.unlock(self.io);
        if (self.client_gone) continue;
        self.client_writer.interface.writeAll(line) catch continue;
        self.client_writer.interface.writeByte('\n') catch continue;
        self.client_writer.interface.flush() catch continue;
    }
    if (far.retired.load(.acquire)) return;
    self.client_mutex.lockUncancelable(self.io);
    defer self.client_mutex.unlock(self.io);
    self.client_gone = true;
    _ = std.posix.system.shutdown(self.client_out.handle, std.posix.SHUT.WR);
    self.client_out.close(self.io);
}

fn answers(allocator: std.mem.Allocator, line: []const u8, id: []const u8) bool {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = rpc.Message.parse(arena, arena.dupe(u8, line) catch return false) catch return false;
    if (message.method != null) return false;
    const replied = message.id orelse return false;
    return replied.eql(.{ .string = id });
}

/// The bridge on this process's stdio.
pub fn main(process: std.process.Init) !void {
    const allocator = process.gpa;
    const io = process.io;
    const socket_dir = try sockets.dir(allocator, process.environ_map);
    defer allocator.free(socket_dir);
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    const home = process.environ_map.get("HOME") orelse "/";

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    var children: Children = .{
        .io = io,
        .argv = try acpCommand(arena_state.allocator(), process.environ_map, exe),
        .home = home,
    };
    var bridge: Bridge = .init(allocator, io, .stdin(), .stdout(), socket_dir, home, .{ .context = &children, .start = Children.start });
    try bridge.run();
}

/// `synth acp` children, started in the home directory: a session's own
/// directory is its `cwd`, not the process's.
const Children = struct {
    io: std.Io,
    argv: []const []const u8,
    home: []const u8,

    fn start(context: *anyopaque) anyerror!Ends {
        const self: *Children = @ptrCast(@alignCast(context));
        const child = try std.process.spawn(self.io, .{
            .argv = self.argv,
            .cwd = .{ .path = self.home },
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
fn acpCommand(arena: std.mem.Allocator, env: *const std.process.Environ.Map, exe: []const u8) ![]const []const u8 {
    const shell = env.get("SHELL") orelse "";
    const over_ssh = env.get("SSH_CONNECTION") != null and env.get("SSH_TTY") == null;
    if (!over_ssh or !std.fs.path.isAbsolute(shell)) return arena.dupe([]const u8, &.{ exe, "acp" });

    var script: std.Io.Writer.Allocating = .init(arena);
    try script.writer.writeAll("exec ");
    try quote(&script.writer, exe);
    try script.writer.writeAll(" acp");
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

    const local = try acpCommand(arena, &env, "/opt/it's/synth");
    try testing.expectEqualStrings("/opt/it's/synth", local[0]);

    try env.put("SSH_CONNECTION", "10.0.0.2 51000 10.0.0.1 22");
    const remote = try acpCommand(arena, &env, "/opt/it's/synth");
    const expected = [_][]const u8{ "/bin/zsh", "-l", "-c", "exec '/opt/it'\\''s/synth' acp" };
    try testing.expectEqual(expected.len, remote.len);
    for (expected, remote) |want, got| try testing.expectEqualStrings(want, got);

    try env.put("SSH_TTY", "/dev/pts/3");
    try testing.expectEqual(@as(usize, 2), (try acpCommand(arena, &env, "/opt/synth")).len);
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

/// A child for each spawn: a fresh agent, as a fresh `synth acp` would be.
const Fixtures = struct {
    fixtures: std.ArrayList(*Agent.Fixture) = .empty,

    fn start(context: *anyopaque) anyerror!Ends {
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

test "a bridge pipes to a child, attaches to a session hosted elsewhere, and goes back for a new one" {
    const hosting = try Agent.Fixture.create();
    defer hosting.destroy();
    const socket_dir = try std.fs.path.join(hosting.arena.allocator(), &.{ std.fs.path.dirname(hosting.project).?, "sockets" });
    hosting.agent.options.socket_dir = socket_dir;
    const host = try hosting.connect();
    defer host.close();
    try host.initialize(true);
    const handle = try hosting.arena.allocator().dupe(u8, (try host.open(hosting.project)).sessionId);

    var children: Fixtures = .{};
    defer children.deinit();
    var fds: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS) return error.SocketPair;
    const ours: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    var bridge: Bridge = .init(testing.allocator, testing.io, ours, ours, socket_dir, "/nowhere", .{ .context = &children, .start = Fixtures.start });
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *Bridge) void {
            b.run() catch {};
            b.client_in.close(b.io);
        }
    }.run, .{&bridge});
    defer thread.join();

    const client = try Agent.Client.create(.{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    defer client.close();
    const timeout: std.os.linux.timeval = .{ .sec = 10, .usec = 0 };
    _ = std.os.linux.setsockopt(fds[0], std.os.linux.SOL.SOCKET, std.os.linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(std.os.linux.timeval));

    try client.initialize(true);
    const fresh = try client.arena.allocator().dupe(u8, (try client.open(children.fixtures.items[0].project)).sessionId);
    try testing.expectEqual(1, children.fixtures.items.len);

    const load = try client.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = handle });
    const snapshot = try rpc.parse(synth.Snapshot, client.arena.allocator(), (try client.awaitMethod(synth.method.snapshot)).params);
    try testing.expectEqualStrings(handle, snapshot.sessionId);
    _ = try client.expectResult(load);

    const elsewhere = try client.request(protocol.method.session_load, protocol.LoadSession{ .sessionId = fresh });
    try testing.expectEqualStrings("no such session", (try client.expectError(elsewhere)).message);
    try testing.expectEqual(2, children.fixtures.items.len);
    _ = try client.open(children.fixtures.items[1].project);
    try testing.expectEqual(2, children.fixtures.items.len);
}
