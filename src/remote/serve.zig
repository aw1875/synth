//! `synth remote serve`: host sessions for remote clients on this machine,
//! until SIGINT or SIGTERM. The bridge starts it when none is running; run it
//! by hand, or under a service manager, to keep one up.

const std = @import("std");
const posix = std.posix;

const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const Providers = @import("providers.zig");
const Server = @import("server.zig");

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var config = try Config.open(allocator, io, init.environ_map);
    defer config.deinit();
    var auth = try Auth.open(allocator, io, init.environ_map);
    defer auth.deinit();
    const chatgpt = try chatgpt_auth.Store.openDefault(allocator, io, init.environ_map);
    defer chatgpt.destroy();

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    var db = try Database.init(allocator, io, config.database_path);
    defer db.deinit();
    if (db.prune(config.prune, db.nowMs())) |dropped| {
        if (dropped.any()) db.vacuum() catch {};
    } else |_| {}
    const active = try catalog.resolve(arena_state.allocator(), &db, &config, &auth);

    var backend: Backend = .init(active.entry.kind, .{
        .allocator = allocator,
        .io = io,
        .host = active.host,
        .label = active.entry.label,
        .model = active.model,
        .api_key = active.api_key,
        .want_think = config.think,
        .num_ctx = config.num_ctx,
        .debug_log = config.debug_log,
        .chatgpt = chatgpt,
    });
    defer backend.deinit();
    try backend.start();
    backend.ensureModel() catch {};
    const missing = !try Providers.usable(arena_state.allocator(), &db, &config, active, &auth, chatgpt, &backend);
    var providers: Providers = .init(io, &auth, chatgpt, &backend, active.entry.id, missing);

    const mcp_auth_path = try Config.defaultMcpAuthPath(allocator, init.environ_map);
    defer allocator.free(mcp_auth_path);

    const socket_path = try Server.socketPath(allocator, init.environ_map);
    defer allocator.free(socket_path);
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);

    try Signals.install();

    const server = Server.start(allocator, io, .{
        .config = &config,
        .environ_map = init.environ_map,
        .socket_path = socket_path,
        .database_path = config.database_path,
        .source = .{ .providers = &providers },
        .executable = executable,
        .on_shutdown = Signals.raise,
        .home = init.environ_map.get("HOME"),
        .mcp_auth_path = mcp_auth_path,
    }) catch |err| switch (err) {
        error.AlreadyRunning => {
            try say(io, "a server is already listening on {s}\n", .{socket_path});
            return err;
        },
        else => return err,
    };
    defer server.stop();

    try say(io, "serving sessions on {s}\n", .{socket_path});
    Signals.wait();
}

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.print(fmt, args);
    try out.interface.flush();
}

/// SIGINT and SIGTERM, waited on with the self-pipe trick: the handler's only
/// job is a `write`, which is safe in a handler, and the main thread blocks
/// reading the other end.
const Signals = struct {
    var pipe: [2]posix.fd_t = undefined;

    fn install() !void {
        if (posix.errno(posix.system.pipe(&pipe)) != .SUCCESS) return error.SignalPipe;
        const action: posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &action, null);
        posix.sigaction(posix.SIG.TERM, &action, null);
    }

    fn onSignal(_: posix.SIG) callconv(.c) void {
        raise();
    }

    /// Let `wait` return, as a signal would.
    fn raise() void {
        _ = posix.system.write(pipe[1], "x", 1);
    }

    fn wait() void {
        var byte: [1]u8 = undefined;
        _ = posix.read(pipe[0], &byte) catch {};
    }
};
