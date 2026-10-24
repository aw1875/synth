//! `synth remote bridge`: this machine's session server on stdin and stdout,
//! started first when none is up. What `ssh <host>` runs at the far end, and
//! what a client on this machine runs to reach its own server.

const std = @import("std");

const Config = @import("../core/config.zig");
const client = @import("client.zig");
const Server = @import("server.zig");

/// How long a server just started may take to bind.
const start_timeout: std.Io.Duration = .fromSeconds(10);
const start_poll: std.Io.Duration = .fromMilliseconds(50);

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const path = try Server.socketPath(init.gpa, init.environ_map);
    defer init.gpa.free(path);

    if (Server.probe(path)) try replaceOutdated(init, path) else try startServer(init, path);

    const stream = try (try std.Io.net.UnixAddress.init(path)).connect(io);
    defer stream.close(io);

    const up = try std.Thread.spawn(.{}, pumpUp, .{ io, stream });
    up.detach();
    pumpDown(io, stream) catch {};
    // The server hung up. Whatever stdin still holds has nowhere to go, and
    // the thread blocked reading it is not worth waiting for.
    std.process.exit(0);
}

/// Start `serve` detached from this process: its own process group, and no
/// stdio of ours, so the ssh channel closing takes nothing of it down. What it
/// says goes to a log beside the socket, which is where a failure to start is
/// explained.
fn startServer(init: std.process.Init, path: []const u8) !void {
    const io = init.io;
    const exe = try std.process.executablePathAlloc(io, init.gpa);
    defer init.gpa.free(exe);
    const log_path = try std.fs.path.join(init.gpa, &.{ std.fs.path.dirname(path) orelse ".", "server.log" });
    defer init.gpa.free(log_path);

    try Config.ensureDir(io, path);
    const log = try std.Io.Dir.cwd().createFile(io, log_path, .{});
    defer log.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    _ = try std.process.spawn(io, .{
        .argv = try serveCommand(arena_state.allocator(), init.environ_map, exe),
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    });

    var waited: std.Io.Duration = .zero;
    while (waited.nanoseconds < start_timeout.nanoseconds) : (waited.nanoseconds += start_poll.nanoseconds) {
        if (Server.probe(path)) return;
        try std.Io.sleep(io, start_poll, .awake);
    }

    var buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.print("the session server did not start; see {s}\n", .{log_path});
    try stderr.interface.flush();
    return error.ServerDidNotStart;
}

/// What starts the server. ssh runs a command with a bare environment, without
/// the `PATH` a login sets up, and the server passes its own on to every MCP
/// server and tool it runs; so a bridge ssh ran starts it under a login shell.
/// Started from a terminal, it keeps that terminal's environment, a nix shell
/// say, as a session run there always has.
fn serveCommand(arena: std.mem.Allocator, env: *const std.process.Environ.Map, exe: []const u8) ![]const []const u8 {
    const shell = env.get("SHELL") orelse "";
    const over_ssh = env.get("SSH_CONNECTION") != null and env.get("SSH_TTY") == null;
    if (!over_ssh or !std.fs.path.isAbsolute(shell)) return arena.dupe([]const u8, &.{ exe, "remote", "serve" });

    var script: std.Io.Writer.Allocating = .init(arena);
    try script.writer.writeAll("exec ");
    try quote(&script.writer, exe);
    try script.writer.writeAll(" remote serve");
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

test "a server ssh asked for starts under a login shell, one from a terminal as it is" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("SHELL", "/bin/zsh");

    const local = try serveCommand(arena, &env, "/opt/it's/synth");
    try testing.expectEqualStrings("/opt/it's/synth", local[0]);

    try env.put("SSH_CONNECTION", "10.0.0.2 51000 10.0.0.1 22");
    const remote = try serveCommand(arena, &env, "/opt/it's/synth");
    const expected = [_][]const u8{ "/bin/zsh", "-l", "-c", "exec '/opt/it'\\''s/synth' remote serve" };
    try testing.expectEqual(expected.len, remote.len);
    for (expected, remote) |want, got| try testing.expectEqualStrings(want, got);

    try env.put("SSH_TTY", "/dev/pts/3");
    const interactive = try serveCommand(arena, &env, "/opt/synth");
    try testing.expectEqual(@as(usize, 3), interactive.len);
}

/// This bridge is the newest program on the machine: whatever ssh or a
/// client just ran. A server started from an older one makes way for it,
/// unless that would cut someone off.
fn replaceOutdated(init: std.process.Init, path: []const u8) !void {
    const io = init.io;
    const stream = (try std.Io.net.UnixAddress.init(path)).connect(io) catch return;
    const connection = client.Connection.openStream(init.gpa, io, stream, null) catch {
        stream.close(io);
        return;
    };
    defer connection.close();
    if (!connection.outdated) return;

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    var failure: client.Diagnostic = .{};
    _ = connection.call(arena_state.allocator(), .{ .shutdown = .{} }, &failure) catch {
        var buffer: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &buffer);
        try stderr.interface.print("the session server here runs an older build ({s}); it is replaced once nothing is attached to it\n", .{failure.message});
        try stderr.interface.flush();
        return;
    };

    var waited: std.Io.Duration = .zero;
    while (Server.probe(path)) : (waited.nanoseconds += start_poll.nanoseconds) {
        if (waited.nanoseconds >= start_timeout.nanoseconds) return error.ServerDidNotStop;
        try std.Io.sleep(io, start_poll, .awake);
    }
    try startServer(init, path);
}

fn pumpDown(io: std.Io, stream: std.Io.net.Stream) !void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &write_buffer);
    try pump(&reader.interface, &stdout.interface);
}

/// stdin to the socket. Its end is the client leaving, which the server
/// hears as the socket closing for writes.
fn pumpUp(io: std.Io, stream: std.Io.net.Stream) void {
    var read_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &read_buffer);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    pump(&stdin.interface, &writer.interface) catch {};
    stream.shutdown(io, .send) catch {};
}

/// Copy whatever has arrived as soon as it has, rather than waiting to fill a
/// buffer: a line held back here is an event the client never sees.
fn pump(from: *std.Io.Reader, to: *std.Io.Writer) !void {
    while (true) {
        _ = from.stream(to, .unlimited) catch |err| switch (err) {
            error.EndOfStream => return to.flush(),
            else => return err,
        };
        try to.flush();
    }
}
