const std = @import("std");

const pkg = @import("pkg");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
pub const panic = vaxis.panic_handler;

const Conversation = @import("core/conversation.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const Auth = @import("core/auth.zig");
const agents = @import("agent/agent.zig");
const subagent = @import("agent/subagent.zig");
const mcp = @import("mcp");

const Config = @import("core/config.zig");
const Database = @import("core/database.zig");
const Timing = @import("core/timing.zig");
const Project = @import("core/project.zig");
const skill = @import("core/skill.zig");
const headless = @import("headless.zig");
const prompt_dump = @import("prompt_dump.zig");
const catalog = @import("provider/catalog.zig");
const Backend = @import("provider/backend.zig");
const Provider = @import("provider/provider.zig");
const mcp_tools = @import("tools/mcp.zig");
const skill_tool = @import("tools/skill.zig");
const tui_app = @import("tui/app.zig");
const Model = @import("tui/model.zig");
const tui_commands = @import("tui/commands.zig");
const Input = @import("tui/input.zig");
const themes = @import("tui/themes.zig");

pub fn main(init: std.process.Init) !void {
    const command = try cli.parse(init, init.arena.allocator());
    switch (command) {
        .help => try writeLine(init.io, cli.usage),
        .version => try writeLine(init.io, pkg.name ++ " " ++ pkg.version ++ "\n"),
        .tui => |options| {
            if (try runTui(init, options)) |handle| {
                var farewell: [256]u8 = undefined;
                var out = std.Io.File.stdout().writer(init.io, &farewell);
                try out.interface.print(
                    \\
                    \\Session {1s}
                    \\  {0s} --continue               resume it here
                    \\  {0s} --session {1s}   resume it from anywhere
                    \\
                , .{ pkg.name, handle });
                try out.interface.flush();
            }
        },
        .run => |options| try headless.run(init, options.message, options.allow),
        .prompt => try prompt_dump.dump(init),
        .models => try commands.models(init),
        .session => |sub| try commands.session(init, sub),
        .mcp => |sub| try commands.mcp_command(init, sub),
    }
}

fn writeLine(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

/// Run the TUI, returning the session's handle when there is one worth
/// resuming. Allocated in the process arena, so it outlives everything this
/// function tears down on the way out.
fn runTui(init: std.process.Init, options: cli.Command.Tui) !?[]const u8 {
    const io = init.io;
    const allocator = init.gpa;

    var timing: Timing = .start(io, init.environ_map);

    var config = try Config.open(allocator, io, init.environ_map);
    defer config.deinit();
    timing.mark("config");

    var auth = try Auth.open(allocator, io, init.environ_map);
    defer auth.deinit();
    timing.mark("auth");

    var db = try Database.init(allocator, io, config.database_path);
    defer db.deinit();
    timing.mark("database");

    {
        var theme_arena: std.heap.ArenaAllocator = .init(allocator);
        defer theme_arena.deinit();
        const stored = db.setting(theme_arena.allocator(), "theme") catch "";
        _ = themes.apply(stored);
    }

    var active = try catalog.resolve(init.arena.allocator(), &db, &config, &auth);
    if (options.model) |model_override| active.model = model_override;
    timing.mark("resolve provider");

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, allocator, init.environ_map, &buffer);
    defer app.deinit();
    timing.mark("terminal");

    const model = try allocator.create(Model);
    defer allocator.destroy(model);

    const path = std.process.currentPathAlloc(io, allocator) catch try allocator.dupeZ(u8, "");
    defer allocator.free(path);

    const cwd = try allocator.dupe(u8, path);
    errdefer allocator.free(cwd);

    var project = try Project.detect(allocator, io, cwd);
    defer project.deinit(allocator);

    var skills = try skill.load(allocator, io, project.root, config.skill_paths, init.environ_map.get("HOME"));
    defer skills.deinit();
    timing.mark("skills");

    const home = init.environ_map.get("HOME") orelse "";
    const cwd_display = if (home.len > 0 and std.mem.startsWith(u8, path, home))
        try std.fmt.allocPrint(allocator, "~{s}", .{path[home.len..]})
    else
        try allocator.dupe(u8, path);

    // Declared before the model so it is torn down after it: the registry holds
    // pointers into this host, and the model owns the registry.
    var mcp_host: mcp_tools.Host = .init(allocator, io);
    defer mcp_host.deinit();

    const mcp_auth_path = try Config.defaultMcpAuthPath(allocator, init.environ_map);
    defer allocator.free(mcp_auth_path);

    var mcp_auth = mcp.Auth.load(allocator, io, mcp_auth_path) catch mcp.Auth.init(allocator);
    defer mcp_auth.deinit();
    mcp_host.auth = &mcp_auth;

    var backend: Backend = .init(active.entry.kind, .{
        .allocator = allocator,
        .io = io,
        .host = active.host,
        .label = active.entry.label,
        .model = active.model,
        .api_key = active.api_key,
        .want_think = config.think,
        .debug_log = config.debug_log,
    });
    defer backend.deinit();

    try backend.start();
    timing.mark("provider probe");

    const provider = backend.provider();

    model.* = Model{
        .io = io,
        .allocator = allocator,
        .conversation = Conversation.init(allocator),
        .provider = provider,
        .input = Input.init(allocator),
        .cwd = cwd,
        .cwd_display = cwd_display,
        .project = &project,
        .app = &app,
        .auth = &auth,
        .backend = &backend,
    };
    defer model.deinit();
    try tui_app.wire(model);

    // Installed from here rather than inside the loop: running a subagent needs
    // a loop, and the loop must not need the thing that runs one.
    var runner: subagent.Runner = .{ .parent = &model.loop };
    model.loop.delegate = runner.delegate();
    model.mcp = &mcp_host;

    // Into the model's registry, which is the one the loop was built with, and
    // before `useAgent` builds the tool schema from it - a tool registered after
    // that is one the model is never told about.
    if (config.mcp) |block| {
        const servers = try mcp_tools.serversFromJson(init.arena.allocator(), block);
        try mcp_host.beginConnectAll(servers, .{
            .name = pkg.name,
            .version = pkg.version,
        });
    }

    try skill_tool.install(&model.registry, &skills);

    model.pending_model_check = options.model == null;
    timing.mark("mcp start");

    model.loop.auto_approve_safe = config.auto_approve_safe_commands;
    if (config.system_prompt) |text| model.loop.system_prompt = text;
    model.loop.project = &project;
    model.loop.skills = skills.skills;
    model.slash.skills = skills.skills;
    model.skills = &skills;
    try model.loop.useAgent(agents.default_id);
    try model.loop.attachDatabase(&db, project.name(), cwd, backend.model());
    timing.mark("agent and session");

    if (!active.entry.ready(&auth)) try tui_commands.showProviders(model);

    if (try resumeTarget(&db, model.loop.project_id, options)) |session_id| {
        try model.loop.resumeSession(session_id, Model.resume_messages);
        tui_commands.syncProvider(model);
        try model.seedHistory();
    }

    timing.total("startup");

    try app.run(tui_app.widget(model), .{});

    if (model.conversation.totalCount() == 0) return null;
    const handle = try model.loop.sessionHandle(init.arena.allocator());
    return if (handle.len > 0) handle else null;
}

/// Which session `--continue` or `--session` names, if either was given.
fn resumeTarget(db: *Database, project_id: ?i64, options: cli.Command.Tui) !?i64 {
    const id = project_id orelse return null;
    if (options.session) |handle| {
        return try db.findSession(id, handle) orelse error.UnknownSession;
    }
    if (options.continue_last) return db.latestSession(id);
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
