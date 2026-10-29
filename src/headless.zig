//! One headless turn, printing each step: `synth run`.

const std = @import("std");

const pkg = @import("pkg");

const Conversation = @import("core/conversation.zig");
const Stack = @import("agent/stack.zig");
const Auth = @import("core/auth.zig");
const chatgpt_auth = @import("provider/chatgpt_auth.zig");
const mcp = @import("mcp");

const Config = @import("core/config.zig");
const Database = @import("core/database.zig");
const humanize = @import("core/humanize.zig");
const catalog = @import("provider/catalog.zig");
const Backend = @import("provider/backend.zig");

const dim = "\x1b[2m";
const bold = "\x1b[1m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";
const reset = "\x1b[0m";

/// One headless turn: same loop and provider as the TUI, printing to stdout.
pub fn run(init: std.process.Init, prompt: []const u8, allow_mutating: bool) !void {
    const io = init.io;
    const allocator = init.gpa;

    var buffer: [4096]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout = stdout_file.writer(io, &buffer);
    const out = &stdout.interface;

    var config = try Config.open(allocator, io, init.environ_map);
    defer config.deinit();

    var auth = try Auth.open(allocator, io, init.environ_map);
    defer auth.deinit();
    const chatgpt = try chatgpt_auth.Store.openDefault(allocator, io, init.environ_map);
    defer chatgpt.destroy();

    var db = try Database.init(allocator, io, config.database_path);
    defer db.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const active = try catalog.resolve(arena_state.allocator(), &db, &config, &auth);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &path_buf);

    const mcp_auth_path = try Config.defaultMcpAuthPath(allocator, init.environ_map);
    defer allocator.free(mcp_auth_path);

    var mcp_auth = mcp.Auth.load(allocator, io, mcp_auth_path) catch mcp.Auth.init(allocator);
    defer mcp_auth.deinit();

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

    const stack = try Stack.create(allocator, io, .{
        .config = &config,
        .provider = backend.provider(),
        .backend = &backend,
        .cwd = path_buf[0..n],
        .home = init.environ_map.get("HOME"),
        .db = &db,
        .mcp_auth = &mcp_auth,
        .mcp_stderr = .inherit,
    });
    defer stack.destroy();
    const loop = &stack.loop;
    const convo = &stack.convo;
    const runner = &stack.runner;

    try out.print("{s}provider{s} {s}  {s}root{s} {s}\n", .{
        dim, reset, loop.provider.name, dim, reset, stack.project.root,
    });
    try out.print("{s}tools{s} {d} registered, mutating tools {s}\n", .{
        dim,                                                                  reset, stack.registry.tools.count(),
        if (allow_mutating) "ALLOWED" else "denied (pass --allow to enable)",
    });

    const mcp_report = try stack.mcp_host.report(allocator);
    defer allocator.free(mcp_report);
    if (mcp_report.len > 0) {
        try out.print("{s}mcp{s} {s}\n", .{ dim, reset, mcp_report });
    }
    try out.print("{s}safe commands{s} {s}\n\n", .{
        dim,
        reset,
        if (config.auto_approve_safe_commands) "run without asking" else "off",
    });
    try out.print("{s}▸ you{s} {s}\n", .{ bold, reset, prompt });
    try out.flush();

    try loop.submit(prompt, .{});

    var printed: usize = 0;
    while (loop.isBusy() or runner.busy()) {
        _ = try runner.poll();
        _ = try loop.poll();

        if (loop.state == .awaiting_approval) {
            const call = loop.pendingCall().?;
            try out.print("{s}  ? approve {s}{s}{s} {s}\n", .{
                yellow, bold, call.name, reset, call.arguments,
            });
            try out.flush();
            try loop.decide(if (allow_mutating) .once else .deny);
            continue;
        }

        printed = try report(out, convo, printed);
        std.Io.sleep(io, .fromMilliseconds(20), .real) catch {};
    }
    if (loop.takeHookNotice()) |notice| {
        defer allocator.free(notice);
        try out.print("{s}hook blocked prompt{s} {s}\n", .{ red, reset, notice });
        try out.flush();
        return;
    }
    _ = try report(out, convo, printed);

    try out.print("\n{s}{d} messages, {d} model calls{s}\n", .{ dim, convo.messages.items.len, loop.steps, reset });
    try out.flush();
}

/// Print any messages added since last time. Returns the new watermark.
fn report(out: *std.Io.Writer, convo: *Conversation, from: usize) !usize {
    const messages = convo.messages.items;
    for (messages[from..]) |msg| {
        switch (msg.role) {
            .user, .system => {},
            .summary => try out.print("{s}  {s}{s}\n", .{ dim, msg.text, reset }),
            .assistant => {
                if (msg.thinking_ms) |ms| {
                    var buffer: [humanize.duration_bytes]u8 = undefined;
                    try out.print("{s}  · thought {s}{s}\n", .{ dim, humanize.duration(&buffer, ms), reset });
                }
                if (msg.text.len > 0) {
                    try out.print("{s}▸ {s}{s} {s}\n", .{ bold, pkg.name, reset, msg.text });
                }
                for (msg.tool_calls) |call| {
                    const colour = switch (call.status) {
                        .ok => green,
                        .failed, .rejected => red,
                        else => yellow,
                    };
                    try out.print("{s}  ◐ {s}{s} {s}{s}\n", .{
                        colour, call.name, reset, dim, call.arguments,
                    });
                }
            },
            .tool => {
                const preview = firstLine(msg.text);
                try out.print("{s}    ↳ {s}{s}\n", .{ dim, preview, reset });
            },
        }
    }
    try out.flush();
    return messages.len;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..@min(end, 160)];
}
