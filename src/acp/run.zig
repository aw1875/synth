//! `synth acp`: the agent on stdio, until the client closes it.

const std = @import("std");

const Agent = @import("agent.zig");
const Providers = @import("providers.zig");
const sockets = @import("sockets.zig");
const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var config = try Config.open(allocator, io, init.environ_map);
    defer config.deinit();
    var auth = try Auth.open(allocator, io, init.environ_map);
    defer auth.deinit();
    const chatgpt = try chatgpt_auth.Store.openDefault(allocator, io, init.environ_map);
    defer chatgpt.destroy();

    var db = try Database.init(allocator, io, config.database_path);
    defer db.deinit();
    const active = try catalog.resolve(init.arena.allocator(), &db, &config, &auth);

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
    var providers: Providers = .init(io, &config, &auth, chatgpt, &backend, active);

    const mcp_auth_path = try Config.defaultMcpAuthPath(allocator, init.environ_map);
    defer allocator.free(mcp_auth_path);
    const socket_dir = try sockets.dir(allocator, init.environ_map);
    defer allocator.free(socket_dir);

    var agent: Agent = .init(allocator, io, .{
        .config = &config,
        .db = &db,
        .source = .{ .providers = &providers },
        .home = init.environ_map.get("HOME"),
        .mcp_auth_path = mcp_auth_path,
        .socket_dir = socket_dir,
    });
    defer agent.deinit();
    try agent.connect(.stdin(), .stdout());
    agent.serve();
}
