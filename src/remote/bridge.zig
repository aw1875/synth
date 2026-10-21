//! `synth remote bridge`: this machine's session server on stdin and stdout,
//! started first when none is up. What `ssh <host>` runs at the far end, and
//! what a client on this machine runs to reach its own server.

const std = @import("std");

const Config = @import("../core/config.zig");
const Server = @import("server.zig");

/// How long a server just started may take to bind.
const start_timeout: std.Io.Duration = .fromSeconds(10);
const start_poll: std.Io.Duration = .fromMilliseconds(50);

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const path = try Server.socketPath(init.gpa, init.environ_map);
    defer init.gpa.free(path);

    if (!Server.probe(io, path)) try startServer(init, path);

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
    _ = try std.process.spawn(io, .{
        .argv = &.{ exe, "remote", "serve" },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    });

    var waited: std.Io.Duration = .zero;
    while (waited.nanoseconds < start_timeout.nanoseconds) : (waited.nanoseconds += start_poll.nanoseconds) {
        if (Server.probe(io, path)) return;
        try std.Io.sleep(io, start_poll, .awake);
    }

    var buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.print("the session server did not start; see {s}\n", .{log_path});
    try stderr.interface.flush();
    return error.ServerDidNotStart;
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
