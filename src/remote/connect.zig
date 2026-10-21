//! `synth remote connect <host> [session]`: the TUI, driving a session that
//! runs on a host. ssh starts before the terminal is taken over, so a password
//! or host-key prompt works the way it always does.

const std = @import("std");

const pkg = @import("pkg");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const client = @import("client.zig");
const wire = @import("wire.zig");
const Mirror = @import("mirror.zig");
const verbs = @import("verbs.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const tui_app = @import("../tui/app.zig");
const tui_bell = @import("../tui/bell.zig");
const tui_commands = @import("../tui/commands.zig");
const Input = @import("../tui/input.zig");
const Model = @import("../tui/model.zig");
const themes = @import("../tui/themes.zig");

pub fn run(init: std.process.Init, host: []const u8, requested: ?[]const u8) !void {
    const io = init.io;
    const allocator = init.gpa;

    var failure: client.Diagnostic = .{};
    const connection = client.Connection.open(allocator, io, host, &failure) catch |err| switch (err) {
        error.NoAnswer, error.ProtocolMismatch => return complain(io, "{s}", .{failure.message}),
        else => return err,
    };

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const listed = connection.call(arena, .{ .list = .{ .stored = verbs.stored_offered } }, &failure) catch |err| {
        connection.close();
        return err;
    };
    const sessions = try wire.parseResult([]const wire.Summary, arena, listed);
    const handle = requested orelse (try choose(io, host, sessions)) orelse {
        connection.close();
        return;
    };

    // Printed once the TUI has given the terminal back, or it would be drawn
    // on the screen it is about to leave.
    const left = try drive(init, connection, host, handle, .{}) orelse return;
    if (left.live) {
        var farewell: [512]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &farewell);
        try out.interface.print(
            \\
            \\Session {1s} carries on on {0s}
            \\  {2s} remote connect {0s} {1s}   come back to it
            \\
        , .{ host, left.handle, pkg.name });
        try out.interface.flush();
    }
}

pub const Options = struct {
    /// Switch the session to this model once attached.
    model: ?[]const u8 = null,
};

/// How a TUI left its session.
pub const Left = struct {
    /// The session is still running on the host.
    live: bool,
    /// Its handle, in the process arena: `/sessions` may have moved the TUI
    /// on from the one it started on.
    handle: []const u8,
    /// It has anything in it worth coming back to.
    spoken: bool,
};

/// Run the TUI on `handle`, taking `connection` over. Null, having said why,
/// when the session could not be attached.
pub fn drive(
    init: std.process.Init,
    connection: *client.Connection,
    host: []const u8,
    handle: []const u8,
    options: Options,
) !?Left {
    const io = init.io;
    const allocator = init.gpa;
    var attached = false;
    defer if (!attached) connection.close();

    var config = try Config.open(allocator, io, init.environ_map);
    defer config.deinit();
    var db: ?Database = Database.init(allocator, io, config.database_path) catch null;
    defer if (db) |*settings| settings.deinit();
    if (db) |*settings| {
        var buffer: [64]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        _ = themes.apply(settings.setting(fixed.allocator(), "theme") catch "");
    }

    const model = try allocator.create(Model);
    defer allocator.destroy(model);
    model.* = .{
        .io = io,
        .allocator = allocator,
        .conversation = .init(allocator),
        .provider = undefined,
        .input = Input.init(allocator),
        .cwd = try allocator.dupe(u8, ""),
        .cwd_display = try allocator.dupe(u8, host),
        .environ = init.environ_map,
        .bell = config.bell,
        .prune_policy = config.prune,
        .db = if (db) |*settings| settings else null,
    };

    var failure: client.Diagnostic = .{};
    const mirror = Mirror.attach(allocator, io, connection, &model.conversation, host, handle, &failure) catch |err| {
        model.conversation.deinit();
        model.input.deinit();
        allocator.free(model.cwd);
        allocator.free(model.cwd_display);
        if (err != error.Refused) return err;
        try complain(io, "{s}", .{failure.message});
        return null;
    };
    attached = true;
    model.remote = mirror;
    model.provider = mirror.provider;
    if (options.model) |name| try mirror.switchModel(name, null, null);

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, init.environ_map, &buffer);
    defer app.deinit();
    model.app = &app;

    try tui_app.wire(model);
    defer model.deinit();
    tui_bell.askForFocusReports(&app);
    defer tui_bell.stopFocusReports(&app);
    if (mirror.status.provider_missing) try tui_commands.showProviders(model);

    try app.run(tui_app.widget(model), .{});
    return .{
        .live = !mirror.ended,
        .handle = try init.arena.allocator().dupe(u8, mirror.status.handle),
        .spoken = mirror.spoken,
    };
}

/// The session to attach when none was named: the one live session, or the
/// one picked from a list. Null, having said why, when there is nothing to
/// pick or nobody to pick it.
fn choose(io: std.Io, host: []const u8, sessions: []const wire.Summary) !?[]const u8 {
    if (sessions.len == 0) {
        try complain(io, "nothing on {s} yet; start a session with: {s} remote new {s} <dir>", .{ host, pkg.name, host });
        return null;
    }
    var live: usize = 0;
    for (sessions) |session| live += @intFromBool(session.live);
    if (live == 1) return sessions[0].handle;

    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    const now = std.Io.Clock.now(.real, io).toMilliseconds();
    try out.interface.print("Sessions on {s}:\n", .{host});
    for (sessions, 1..) |session, number| {
        try out.interface.print("  {d}  ", .{number});
        try verbs.printSummary(&out.interface, session, now);
        try out.interface.writeByte('\n');
    }
    if (!try std.Io.File.stdin().isTty(io)) {
        try out.interface.print("name one: {s} remote connect {s} <session>\n", .{ pkg.name, host });
        try out.interface.flush();
        return null;
    }
    try out.interface.print("Attach which? [1] ", .{});
    try out.interface.flush();

    var line_buffer: [64]u8 = undefined;
    var in = std.Io.File.stdin().reader(io, &line_buffer);
    const read = in.interface.takeDelimiter('\n') catch return null;
    const line = read orelse return null;
    const answer = std.mem.trim(u8, line, " \t\r");
    if (answer.len == 0) return sessions[0].handle;
    const number = std.fmt.parseInt(usize, answer, 10) catch 0;
    if (number == 0 or number > sessions.len) {
        try complain(io, "no session {s}", .{answer});
        return null;
    }
    return sessions[number - 1].handle;
}

fn complain(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print(fmt ++ "\n", args);
    try out.interface.flush();
}
