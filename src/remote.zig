//! `synth remote ...`: the sessions on a host, reached through `synth remote
//! bridge` there. ssh starts before the TUI takes the terminal over, so a
//! password or host-key prompt works the way it always does.

const std = @import("std");

const pkg = @import("pkg");

const cli = @import("cli.zig");
const bridge = @import("acp/bridge.zig");
const Connection = @import("acp/connection.zig");
const Mirror = @import("acp/mirror.zig");
const protocol = @import("acp/protocol.zig");
const rpc = @import("acp/rpc.zig");
const synth = @import("acp/synth.zig");
const humanize = @import("core/humanize.zig");
const tui_drive = @import("tui/drive.zig");

pub fn run(init: std.process.Init, command: cli.Command.Remote) !void {
    switch (command) {
        .bridge => try bridge.main(init),
        .list => |host| try list(init, host),
        .connect => |asked| try connect(init, asked.host, asked.session),
        .new => |asked| try drive(init, asked.host, try Connection.toHost(init.gpa, init.io, asked.host), .{ .new = asked.dir }),
    }
}

fn list(init: std.process.Init, host: []const u8) !void {
    const connection = try Connection.toHost(init.gpa, init.io, host);
    defer connection.close();
    const sessions = try listed(init, connection, host) orelse return;

    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    if (sessions.len == 0) {
        try out.interface.print("no sessions on {s} yet\n", .{host});
    } else {
        try printSessions(&out.interface, init.io, sessions);
    }
    try out.interface.flush();
}

/// Drive `session` on `host`, or one picked from those there when none is
/// named.
fn connect(init: std.process.Init, host: []const u8, session: ?[]const u8) !void {
    const connection = try Connection.toHost(init.gpa, init.io, host);
    const handle = session orelse blk: {
        const sessions = listed(init, connection, host) catch |err| {
            connection.close();
            return err;
        };
        const chosen = if (sessions) |found| try choose(init.io, host, found) else null;
        break :blk chosen orelse {
            connection.close();
            return;
        };
    };
    try drive(init, host, connection, .{ .load = .{ .handle = handle } });
}

fn drive(init: std.process.Init, host: []const u8, connection: *Connection, target: Mirror.Target) !void {
    const left = try tui_drive.drive(init, connection, host, target, .{ .attach_here = false }) orelse return;
    if (left.spoken or left.detached) try tui_drive.sayFarewell(init.io, host, left);
}

/// Every project's sessions on the far end, newest first. Null, having said
/// why, when it would not list them.
fn listed(init: std.process.Init, connection: *Connection, host: []const u8) !?[]const protocol.SessionInfo {
    const arena = init.arena.allocator();
    var failure: Connection.Diagnostic = .{};
    connection.initialize(arena, &failure) catch |err| switch (err) {
        error.Refused, error.ConnectionLost => {
            try complain(init.io, "{s}: {s}", .{ host, failure.message });
            return null;
        },
        else => return err,
    };
    const answer = connection.call(arena, protocol.method.session_list, protocol.ListSessions{}, &failure) catch |err| switch (err) {
        error.Refused, error.ConnectionLost => {
            try complain(init.io, "{s}: {s}", .{ host, if (failure.message.len > 0) failure.message else "the agent did not answer" });
            return null;
        },
        else => return err,
    };
    return (try rpc.parse(protocol.SessionList, arena, answer)).sessions;
}

fn printSessions(out: *std.Io.Writer, io: std.Io, sessions: []const protocol.SessionInfo) !void {
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    for (sessions, 1..) |session, number| {
        const stored: synth.Stored = if (session._meta) |meta| meta.synth else .{};
        try out.print("  {d:>2}  {s}  {s}\n", .{ number, session.sessionId, session.title orelse "untitled" });
        var stamp: [humanize.ago_bytes]u8 = undefined;
        const when = if (stored.live) "running" else humanize.ago(&stamp, @intCast(@max(0, now - stored.updated_at)));
        try out.print("      {s} · {d} msgs · {s}\n", .{ session.cwd, stored.messages, when });
    }
}

/// The session to drive when none was named: the one running, or one picked
/// from the list. Null, having said why, when there is nothing to pick or
/// no one to pick it.
fn choose(io: std.Io, host: []const u8, sessions: []const protocol.SessionInfo) !?[]const u8 {
    if (sessions.len == 0) {
        try complain(io, "no sessions on {s} yet; start one with: {s} remote new {s} [dir]", .{ host, pkg.name, host });
        return null;
    }
    var running: ?[]const u8 = null;
    var count: usize = 0;
    for (sessions) |session| {
        const live = if (session._meta) |meta| meta.synth.live else false;
        if (!live) continue;
        running = session.sessionId;
        count += 1;
    }
    if (count == 1) return running;

    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print("Sessions on {s}:\n", .{host});
    try printSessions(&out.interface, io, sessions);
    if (!try std.Io.File.stdin().isTty(io)) {
        try out.interface.print("name one: {s} remote connect {s} <session>\n", .{ pkg.name, host });
        try out.interface.flush();
        return null;
    }
    try out.interface.writeAll("Open which? [1] ");
    try out.interface.flush();

    var line_buffer: [64]u8 = undefined;
    var in = std.Io.File.stdin().reader(io, &line_buffer);
    const line = (in.interface.takeDelimiter('\n') catch return null) orelse return null;
    const answer = std.mem.trim(u8, line, " \t\r");
    if (answer.len == 0) return sessions[0].sessionId;
    const number = std.fmt.parseInt(usize, answer, 10) catch 0;
    if (number == 0 or number > sessions.len) {
        try complain(io, "no session {s}", .{answer});
        return null;
    }
    return sessions[number - 1].sessionId;
}

fn complain(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print(fmt ++ "\n", args);
    try out.interface.flush();
}
