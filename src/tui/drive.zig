//! The TUI, driving a session an ACP agent hosts.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Connection = @import("../acp/connection.zig");
const Mirror = @import("../acp/mirror.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const tui_app = @import("app.zig");
const tui_bell = @import("bell.zig");
const tui_commands = @import("commands.zig");
const Input = @import("input.zig");
const Model = @import("model.zig");
const themes = @import("themes.zig");

pub const Options = struct {
    /// Switch the session to this model once it is open.
    model: ?[]const u8 = null,
};

/// How a TUI left its session.
pub const Left = struct {
    /// Its handle, in the process arena: `/sessions` may have moved the TUI
    /// on from the one it started on.
    handle: []const u8,
    /// It has anything in it worth coming back to.
    spoken: bool,
};

/// Run the TUI on `target`, taking `connection` over. Null, having said why,
/// when the session could not be opened.
pub fn drive(
    init: std.process.Init,
    connection: *Connection,
    host: []const u8,
    target: Mirror.Target,
    options: Options,
) !?Left {
    const io = init.io;
    const allocator = init.gpa;
    var opened = false;
    defer if (!opened) connection.close();

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
        .input = Input.init(allocator),
        .cwd = try allocator.dupe(u8, ""),
        .cwd_display = try allocator.dupe(u8, host),
        .environ = init.environ_map,
        .bell = config.bell,
        .prune_policy = config.prune,
        .db = if (db) |*settings| settings else null,
    };

    var failure: Connection.Diagnostic = .{};
    const mirror = Mirror.open(allocator, io, connection, &model.conversation, host, target, &failure) catch |err| {
        model.conversation.deinit();
        model.input.deinit();
        allocator.free(model.cwd);
        allocator.free(model.cwd_display);
        if (err != error.Refused and err != error.ConnectionLost) return err;
        try complain(io, if (failure.message.len > 0) failure.message else "the agent did not answer");
        return null;
    };
    opened = true;
    model.mirror = mirror;
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
        .handle = try init.arena.allocator().dupe(u8, mirror.status.handle),
        .spoken = mirror.spoken,
    };
}

fn complain(io: std.Io, message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print("{s}\n", .{message});
    try out.interface.flush();
}
