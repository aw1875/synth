//! `synth remote list|new|stop <host>`: one request to a host's server, its
//! answer printed, and out.

const std = @import("std");

const wire = @import("wire.zig");
const client = @import("client.zig");
const humanize = @import("../core/humanize.zig");

/// Stored sessions offered beside the live ones.
pub const stored_offered: u32 = 9;

pub fn list(init: std.process.Init, host: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failure: client.Diagnostic = .{};
    const connection = try connect(init, host, &failure) orelse return;
    defer connection.close();
    const result = connection.call(arena, .{ .list = .{ .stored = stored_offered } }, &failure) catch |err| return refused(init.io, host, err, &failure);
    const sessions = try wire.parseResult([]const wire.Summary, arena, result);

    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    if (sessions.len == 0) try out.interface.print("no sessions on {s} yet\n", .{host});
    const now = std.Io.Clock.now(.real, init.io).toMilliseconds();
    for (sessions) |session| {
        try printSummary(&out.interface, session, now);
        try out.interface.writeByte('\n');
    }
    try out.interface.flush();
}

pub fn new(init: std.process.Init, host: []const u8, root: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failure: client.Diagnostic = .{};
    const connection = try connect(init, host, &failure) orelse return;
    defer connection.close();
    const result = connection.call(arena, .{ .open = .{ .root = root } }, &failure) catch |err| return refused(init.io, host, err, &failure);
    const session = try wire.parseResult(wire.Summary, arena, result);

    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try printSummary(&out.interface, session, std.Io.Clock.now(.real, init.io).toMilliseconds());
    try out.interface.writeByte('\n');
    try out.interface.flush();
}

pub fn stop(init: std.process.Init, host: []const u8, handle: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();

    var failure: client.Diagnostic = .{};
    const connection = try connect(init, host, &failure) orelse return;
    defer connection.close();
    _ = connection.call(arena_state.allocator(), .{ .stop = .{ .handle = handle } }, &failure) catch |err| return refused(init.io, host, err, &failure);

    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try out.interface.print("stopped {s}\n", .{handle});
    try out.interface.flush();
}

/// The connection, or null once the reason it could not be had is printed.
fn connect(init: std.process.Init, host: []const u8, failure: *client.Diagnostic) !?*client.Connection {
    return client.Connection.open(init.gpa, init.io, host, failure) catch |err| switch (err) {
        error.NoAnswer, error.ProtocolMismatch => {
            try complain(init.io, "{s}", .{failure.message});
            return null;
        },
        else => return err,
    };
}

/// Say why the server said no, or pass on a failure it never got to answer.
fn refused(io: std.Io, host: []const u8, err: anyerror, failure: *const client.Diagnostic) !void {
    switch (err) {
        error.Refused => try complain(io, "{s}: {s}", .{ host, failure.message }),
        error.ConnectionLost => try complain(io, "{s} hung up", .{host}),
        else => return err,
    }
}

fn complain(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print(fmt ++ "\n", args);
    try out.interface.flush();
}

/// One session on one line: its handle, where it runs, what it is doing or
/// when it last did anything, and its title. `now` in milliseconds.
pub fn printSummary(out: *std.Io.Writer, session: wire.Summary, now: i64) !void {
    try out.print("{s}  {s}  ", .{ session.handle, session.root });
    if (session.live) {
        const state = if (session.state == .idle) "idle" else session.state.label();
        try out.print("live, {s}, {d} attached", .{ state, session.clients });
    } else {
        var buffer: [humanize.ago_bytes]u8 = undefined;
        try out.print("stored, {s}", .{humanize.ago(&buffer, @intCast(@max(0, now - session.updated_at)))});
    }
    if (session.title.len > 0) try out.print("  \"{s}\"", .{session.title});
}
