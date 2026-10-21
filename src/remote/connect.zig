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
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const tui_app = @import("../tui/app.zig");
const tui_bell = @import("../tui/bell.zig");
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
    const listed = connection.call(arena, .{ .list = .{} }, &failure) catch |err| {
        connection.close();
        return err;
    };
    const live = try wire.parseResult([]const wire.Summary, arena, listed);
    const handle = requested orelse (onlyOne(io, host, live) catch {
        connection.close();
        return;
    });

    // Printed once the TUI has given the terminal back, or it would be drawn
    // on the screen it is about to leave.
    if (try drive(init, connection, host, handle, live)) {
        var farewell: [512]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &farewell);
        try out.interface.print(
            \\
            \\Session {1s} carries on on {0s}
            \\  {2s} remote connect {0s} {1s}   come back to it
            \\
        , .{ host, handle, pkg.name });
        try out.interface.flush();
    }
}

/// Run the TUI on `handle`, taking `connection` over. Whether the session is
/// still running on the host when the TUI closes.
fn drive(
    init: std.process.Init,
    connection: *client.Connection,
    host: []const u8,
    handle: []const u8,
    live: []const wire.Summary,
) !bool {
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
        .cwd_display = try describe(allocator, host, handle, live),
        .environ = init.environ_map,
        .bell = config.bell,
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
        return false;
    };
    attached = true;
    model.remote = mirror;
    model.provider = mirror.provider;

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, init.environ_map, &buffer);
    defer app.deinit();
    model.app = &app;

    try tui_app.wire(model);
    defer model.deinit();
    tui_bell.askForFocusReports(&app);
    defer tui_bell.stopFocusReports(&app);

    try app.run(tui_app.widget(model), .{});
    return !mirror.ended;
}

/// The session to attach when none was named: the only one there is. Says
/// what to do instead when there is not exactly one.
fn onlyOne(io: std.Io, host: []const u8, live: []const wire.Summary) ![]const u8 {
    if (live.len == 1) return live[0].handle;
    if (live.len == 0) {
        try complain(io, "no live sessions on {s}; start one with: {s} remote new {s} <dir>", .{ host, pkg.name, host });
        return error.NoSession;
    }
    try complain(io, "{d} live sessions on {s}; name one:", .{ live.len, host });
    for (live) |session| try complain(io, "  {s} remote connect {s} {s}   {s}", .{ pkg.name, host, session.handle, session.root });
    return error.NoSession;
}

/// Where the session runs, for the sidebar: the host, and the directory when
/// the session is live and so has said which.
fn describe(allocator: std.mem.Allocator, host: []const u8, handle: []const u8, live: []const wire.Summary) ![]const u8 {
    for (live) |session| {
        if (std.mem.eql(u8, session.handle, handle)) return std.fmt.allocPrint(allocator, "{s}:{s}", .{ host, session.root });
    }
    return allocator.dupe(u8, host);
}

fn complain(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print(fmt ++ "\n", args);
    try out.interface.flush();
}
