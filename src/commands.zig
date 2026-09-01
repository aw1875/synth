//! The subcommands that print to a terminal and exit: `session ...` and
//! `models`. Everything here opens the same config and database the
//! TUI does, does one thing, and returns.

const std = @import("std");

const pkg = @import("pkg");

const cli = @import("cli.zig");
const Auth = @import("core/auth.zig");
const Config = @import("core/config.zig");
const Database = @import("core/database.zig");
const Project = @import("core/project.zig");
const skill = @import("core/skill.zig");
const mcp = @import("mcp");
const mcp_tools = @import("tools/mcp.zig");
const catalog = @import("provider/catalog.zig");
const Backend = @import("provider/backend.zig");

/// Sessions listed by `session list`.
const list_limit: usize = 50;

const dim = "\x1b[2m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

/// Config, project and database, which every command here needs.
const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    auth: Auth,
    project: Project,
    db: Database,
    project_id: i64,

    fn init(init_process: std.process.Init) !Context {
        const allocator = init_process.gpa;
        const io = init_process.io;

        var config = try Config.open(allocator, io, init_process.environ_map);
        errdefer config.deinit();

        var auth = try Auth.open(allocator, io, init_process.environ_map);
        errdefer auth.deinit();

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.process.currentPath(io, &path_buf);
        var project = try Project.detect(allocator, io, path_buf[0..n]);
        errdefer project.deinit(allocator);

        var db = try Database.init(allocator, io, config.database_path);
        errdefer db.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .auth = auth,
            .project = project,
            .db = db,
            .project_id = try db.resolveProject(project.root, "git", project.name()),
        };
    }

    fn deinit(self: *Context) void {
        self.db.deinit();
        self.project.deinit(self.allocator);
        self.auth.deinit();
        self.config.deinit();
    }
};

pub fn session(init_process: std.process.Init, sub: cli.Command.Session) !void {
    var ctx = try Context.init(init_process);
    defer ctx.deinit();

    var buffer: [8192]u8 = undefined;
    var file = std.Io.File.stdout().writer(ctx.io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    switch (sub) {
        .list => try listSessions(&ctx, out),
        .show => |handle| try showSession(&ctx, out, handle),
        .remove => |handle| try removeSession(&ctx, out, handle),
    }
}

fn listSessions(ctx: *Context, out: *std.Io.Writer) !void {
    const sessions = try ctx.db.listSessions(ctx.allocator, ctx.project_id, list_limit);
    defer {
        for (sessions) |info| info.deinit(ctx.allocator);
        ctx.allocator.free(sessions);
    }

    if (sessions.len == 0) {
        try out.print("no sessions yet in {s}\n", .{ctx.project.name()});
        return;
    }

    try out.print("{s}sessions in {s}{s}\n\n", .{ dim, ctx.project.name(), reset });
    for (sessions) |info| {
        var stamp: [32]u8 = undefined;
        try out.print("  {s}{s}{s}  {s}{s}{s}  {s}{d} messages{s}\n", .{
            bold,
            info.public_id,
            reset,
            if (info.title.len > 0) "" else dim,
            if (info.title.len > 0) info.title else "untitled",
            reset,
            dim,
            info.messages,
            reset,
        });
        try out.print("    {s}{s}{s}\n", .{ dim, try ago(&stamp, ctx.io, info.updated_at), reset });
    }
}

fn showSession(ctx: *Context, out: *std.Io.Writer, handle: []const u8) !void {
    const id = try ctx.db.findSession(ctx.project_id, handle) orelse {
        try out.print("no session {s} in {s}\n", .{ handle, ctx.project.name() });
        return;
    };

    const messages = try ctx.db.loadMessages(ctx.allocator, id, std.math.maxInt(i64), 1000);
    defer {
        for (messages) |*msg| msg.deinit(ctx.allocator);
        ctx.allocator.free(messages);
    }
    std.mem.reverse(@TypeOf(messages[0]), messages);

    for (messages) |msg| {
        const label = switch (msg.role) {
            .user => "you",
            .assistant => pkg.name,
            .tool => "tool",
            .system => "system",
            .summary => "summary",
        };
        try out.print("{s}▸ {s}{s} {s}\n", .{ bold, label, reset, msg.text });
        for (msg.tool_calls) |call| {
            try out.print("  {s}{s}{s} {s}\n", .{ dim, call.name, reset, call.arguments });
        }
    }
}

fn removeSession(ctx: *Context, out: *std.Io.Writer, handle: []const u8) !void {
    const id = try ctx.db.findSession(ctx.project_id, handle) orelse {
        try out.print("no session {s} in {s}\n", .{ handle, ctx.project.name() });
        return;
    };
    try ctx.db.deleteSession(id);
    try out.print("deleted {s}\n", .{handle});
}

/// Models the configured provider offers.
/// `synth skills`: what this project offers, and every directory that was
/// searched. The paths matter more than the list: a skill that did not turn up
/// is the reason to run this at all.
pub fn skills(init_process: std.process.Init) !void {
    var ctx = try Context.init(init_process);
    defer ctx.deinit();

    var buffer: [8192]u8 = undefined;
    var file = std.Io.File.stdout().writer(ctx.io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    var found = try skill.load(
        ctx.allocator,
        ctx.io,
        ctx.project.root,
        ctx.config.skill_paths,
        init_process.environ_map.get("HOME"),
    );
    defer found.deinit();

    if (found.skills.len == 0) {
        try out.print("No skills found.\n\n", .{});
    } else {
        for (found.skills) |entry| {
            try out.print("{s}{s}{s}\n", .{ bold, entry.id, reset });
            if (entry.description.len > 0) {
                try out.print("  {s}\n", .{entry.description});
            }
            try out.print("  {s}{s}{s}\n", .{ dim, entry.dir, reset });
        }
        try out.print("\n", .{});
    }

    try out.print("{s}Looked in{s}\n", .{ dim, reset });
    for (found.paths) |path| try out.print("  {s}{s}{s}\n", .{ dim, path, reset });
}

pub fn models(init_process: std.process.Init) !void {
    var ctx = try Context.init(init_process);
    defer ctx.deinit();

    var buffer: [8192]u8 = undefined;
    var file = std.Io.File.stdout().writer(ctx.io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const active = try catalog.resolve(arena_state.allocator(), &ctx.db, &ctx.config, &ctx.auth);
    var backend: Backend = .init(active.entry.kind, .{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .host = active.host,
        .label = active.entry.label,
        .model = active.model,
        .api_key = active.api_key,
    });
    defer backend.deinit();

    const names = backend.listModels(ctx.allocator) catch |err| {
        const detail = try backend.describeError(err, ctx.allocator);
        defer ctx.allocator.free(detail);
        try out.print("{s}\n", .{detail});
        return;
    };
    defer {
        for (names) |name| ctx.allocator.free(name);
        ctx.allocator.free(names);
    }

    if (names.len == 0) {
        try out.print("no models reported by {s}\n", .{active.host});
        return;
    }

    const pinned = active.model.len > 0;
    for (names, 0..) |name, i| {
        const in_use = if (pinned)
            backend.sameModel(name, active.model)
        else
            i == 0;

        if (in_use) {
            const label = if (pinned) "(configured)" else "(default)";
            try out.print("  {s}{s}{s}  {s}{s}{s}\n", .{ bold, name, reset, dim, label, reset });
        } else {
            try out.print("  {s}\n", .{name});
        }
    }
}

/// How long ago a timestamp was, in the roughest useful unit.
fn ago(buffer: []u8, io: std.Io, millis: i64) ![]const u8 {
    const now = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const delta = @max(0, now - millis);

    const minutes = @divTrunc(delta, std.time.ms_per_min);
    if (minutes < 1) return std.fmt.bufPrint(buffer, "just now", .{});
    if (minutes < 60) return std.fmt.bufPrint(buffer, "{d}m ago", .{minutes});

    const hours = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.bufPrint(buffer, "{d}h ago", .{hours});
    return std.fmt.bufPrint(buffer, "{d}d ago", .{@divTrunc(hours, 24)});
}

test "elapsed time reads in the roughest useful unit" {
    var buffer: [32]u8 = undefined;
    const now = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();

    try std.testing.expectEqualStrings("just now", try ago(&buffer, std.testing.io, now));
    try std.testing.expectEqualStrings("5m ago", try ago(&buffer, std.testing.io, now - 5 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("3h ago", try ago(&buffer, std.testing.io, now - 3 * std.time.ms_per_hour));
    try std.testing.expectEqualStrings("2d ago", try ago(&buffer, std.testing.io, now - 2 * std.time.ms_per_day));
}

/// `mcp list`, `mcp auth`, `mcp logout`, `mcp enable`, `mcp disable`.
///
/// No database and no project: an MCP server is configured for the machine,
/// not for a directory, so none of this needs to know where it was run.
pub fn mcp_command(init_process: std.process.Init, sub: cli.Command.Mcp) !void {
    const allocator = init_process.gpa;
    const io = init_process.io;

    var config = try Config.open(allocator, io, init_process.environ_map);
    defer config.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    const servers: []const mcp_tools.Server = if (config.mcp) |block|
        try mcp_tools.serversFromJson(arena_state.allocator(), block)
    else
        &.{};

    const path = try Config.defaultMcpAuthPath(allocator, init_process.environ_map);
    defer allocator.free(path);

    var store = mcp.Auth.load(allocator, io, path) catch mcp.Auth.init(allocator);
    defer store.deinit();

    var buffer: [8192]u8 = undefined;
    var file = std.Io.File.stdout().writer(io, &buffer);
    const out = &file.interface;
    defer out.flush() catch {};

    switch (sub) {
        .list => try listServers(&store, servers, out),
        .auth => |name| try authServer(allocator, io, &store, servers, name, path, out),
        .debug => |name| try debugServer(allocator, io, &store, servers, name, out),
        .logout => |name| {
            store.forget(name);
            try store.save(io, path);
            try out.print("Forgot credentials for {s}.\n", .{name});
        },
        .enable => |name| try toggleServer(io, &store, name, true, path, out),
        .disable => |name| try toggleServer(io, &store, name, false, path, out),
    }
}

fn listServers(store: *mcp.Auth, servers: []const mcp_tools.Server, out: *std.Io.Writer) !void {
    if (servers.len == 0) {
        try out.print("No MCP servers configured. Add an \"mcp\" block to your config.\n", .{});
        return;
    }

    for (servers) |server| {
        const on = server.enabled and store.isEnabled(server.name);
        try out.print("{s}{s}{s}", .{ bold, server.name, reset });
        if (!on) try out.print("{s} (disabled){s}", .{ dim, reset });
        try out.print("\n", .{});

        switch (server.transport) {
            .stdio => |stdio| try out.print("  {s}local{s}   {s}\n", .{ dim, reset, stdio.command }),
            .http => |http| {
                try out.print("  {s}remote{s}  {s}\n", .{ dim, reset, http.url });

                const entry = store.getForUrl(server.name, http.url);
                const signed_in = if (entry) |e| e.tokens != null else false;
                try out.print("  {s}auth{s}    {s}\n", .{
                    dim,
                    reset,
                    if (signed_in) "signed in" else "not signed in",
                });
            },
        }
    }
}

fn toggleServer(
    io: std.Io,
    store: *mcp.Auth,
    name: []const u8,
    enabled: bool,
    path: []const u8,
    out: *std.Io.Writer,
) !void {
    try store.setEnabled(name, enabled);
    try store.save(io, path);
    try out.print("{s} is now {s}.\n", .{ name, if (enabled) "enabled" else "disabled" });
}

fn authServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *mcp.Auth,
    servers: []const mcp_tools.Server,
    name: []const u8,
    path: []const u8,
    out: *std.Io.Writer,
) !void {
    const found = for (servers) |server| {
        if (std.mem.eql(u8, server.name, name)) break server;
    } else {
        try out.print("No MCP server called {s} is configured.\n", .{name});
        return;
    };

    const http = switch (found.transport) {
        .http => |remote| remote,
        .stdio => {
            try out.print(
                "{s} runs as a local process, so there is nothing to sign in to.\n",
                .{name},
            );
            return;
        },
    };

    try out.print("Authorizing {s} at {s}\n", .{ name, http.url });
    try out.flush();

    _ = mcp.flow.authorize(allocator, io, store, .{
        .name = name,
        .server_url = http.url,
        .client_name = pkg.name,
        .scopes = http.scopes,
        .open = announce,
    }) catch |err| {
        try out.print("Authorization failed: {s}\n", .{@errorName(err)});
        return err;
    };

    try store.save(io, path);
    try out.print("Signed in to {s}.\n", .{name});
}

/// Print the URL before handing it to the browser. A terminal on the other end
/// of an SSH connection has no browser to open, and the URL is all someone
/// needs to finish the flow from wherever they are.
fn announce(io: std.Io, url: []const u8) mcp.Browser.Error!void {
    var buffer: [4096]u8 = undefined;
    var file = std.Io.File.stdout().writer(io, &buffer);
    file.interface.print("\nOpen this to continue:\n  {s}\n\n", .{url}) catch {};
    file.interface.flush() catch {};

    return mcp.Browser.defaultOpen(io, url);
}

/// Print everything the OAuth flow would work from, without running it.
///
/// The flow has three places to go wrong that all look the same from outside:
/// discovery finding the wrong authorization server, registration handing back
/// a client that will not accept our redirect URI, and the server wanting a
/// scope nobody asked for. This shows all three.
fn debugServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *mcp.Auth,
    servers: []const mcp_tools.Server,
    name: []const u8,
    out: *std.Io.Writer,
) !void {
    const found = for (servers) |server| {
        if (std.mem.eql(u8, server.name, name)) break server;
    } else {
        try out.print("No MCP server called {s} is configured.\n", .{name});
        return;
    };

    const http = switch (found.transport) {
        .http => |remote| remote,
        .stdio => {
            try out.print("{s} runs as a local process, so there is no OAuth to debug.\n", .{name});
            return;
        },
    };

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try out.print("{s}{s}{s}\n  {s}endpoint{s}   {s}\n", .{ bold, name, reset, dim, reset, http.url });
    try out.print("  {s}metadata{s}   {s}\n", .{
        dim,
        reset,
        try mcp.discovery.protectedResourceUrl(arena, http.url),
    });

    if (http.scopes.len == 0) {
        try out.print("  {s}scopes{s}     {s}none configured{s}\n", .{ dim, reset, dim, reset });
    } else {
        try out.print("  {s}scopes{s}     ", .{ dim, reset });
        for (http.scopes, 0..) |scope, i| {
            if (i > 0) try out.writeAll(" ");
            try out.writeAll(scope);
        }
        try out.writeAll("\n");
    }
    try out.flush();

    const discovered = mcp.discovery.discover(allocator, arena, io, http.url, "") catch |err| {
        try out.print("\n  discovery failed: {s}\n", .{@errorName(err)});
        return;
    };

    try out.print("\n  {s}resource{s}   {s}\n", .{ dim, reset, discovered.resource.resource });
    for (discovered.resource.authorization_servers) |issuer| {
        try out.print("  {s}issuer{s}     {s}\n", .{ dim, reset, issuer });
    }
    if (discovered.resource.scopes_supported.len > 0) {
        try out.print("  {s}offers{s}     ", .{ dim, reset });
        for (discovered.resource.scopes_supported, 0..) |scope, i| {
            if (i > 0) try out.writeAll(" ");
            try out.writeAll(scope);
        }
        try out.writeAll("\n");
    }

    try out.print("\n  {s}authorize{s}  {s}\n", .{ dim, reset, discovered.server.authorization_endpoint });
    try out.print("  {s}token{s}      {s}\n", .{ dim, reset, discovered.server.token_endpoint });
    try out.print("  {s}register{s}   {s}\n", .{
        dim,
        reset,
        discovered.server.registration_endpoint orelse "not supported",
    });
    try out.print("  {s}pkce{s}       {s}\n", .{
        dim,
        reset,
        if (discovered.server.supportsS256()) "S256" else "not advertised",
    });

    const entry = store.getForUrl(name, http.url);
    try out.print("\n  {s}client id{s}  {s}\n", .{
        dim,
        reset,
        if (entry) |e| if (e.client_info) |info| info.client_id else "none registered" else "none registered",
    });
    try out.print("  {s}redirect{s}   {s}\n", .{
        dim,
        reset,
        if (entry) |e| e.redirect_uri orelse "none stored" else "none stored",
    });
    try out.print("  {s}tokens{s}     {s}\n", .{
        dim,
        reset,
        if (entry) |e| if (e.tokens != null) "stored" else "none" else "none",
    });
    try out.flush();

    try probeInitialize(allocator, io, store, name, http.url, http.headers, arena, out);
}

/// Walk the real opening sequence and print what each step came back with.
///
/// The client reports a refusal as one word - `ServerClosed`, `RequestRejected` -
/// which is all a caller can act on but nowhere near enough to work out why.
/// `initialize`, the notification that follows it and the first `tools/list`
/// are three different requests, and knowing which one broke is most of the
/// answer.
fn probeInitialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *mcp.Auth,
    name: []const u8,
    url: []const u8,
    extra: []const std.http.Header,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
) !void {
    const token = mcp.flow.accessToken(allocator, io, store, .{
        .name = name,
        .server_url = url,
        .client_name = pkg.name,
    }) catch null;

    const authorization = if (token) |value|
        try std.fmt.allocPrint(arena, "Bearer {s}", .{value})
    else
        "";

    // Naming both: a configured header is the whole reason a server with no
    // registration endpoint can be reached at all, and a probe that quietly
    // left it out would report a refusal the real client never gets.
    try out.print("\n  {s}sent as{s}    {s}", .{
        dim,
        reset,
        if (authorization.len > 0) "bearer token" else "no token",
    });
    if (extra.len > 0) {
        try out.print("{s} + {d} configured header(s):{s}", .{ dim, extra.len, reset });
        for (extra) |header| try out.print(" {s}", .{header.name});
    }
    try out.writeAll("\n");

    var sid: ?[]const u8 = null;

    const initialize = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"2025-11-25","capabilities":{{}},"clientInfo":{{"name":"{s}","version":"{s}"}}}}}}
    , .{ pkg.name, pkg.version });

    if (!try probeStep(allocator, arena, io, out, "initialize", url, authorization, extra, &sid, initialize)) return;

    if (!try probeStep(allocator, arena, io, out, "initialized", url, authorization, extra, &sid,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) return;

    _ = try probeStep(allocator, arena, io, out, "tools/list", url, authorization, extra, &sid,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
    );
}

/// POST one message and print the reply. Returns false when the exchange
/// failed badly enough that the next step would tell us nothing.
fn probeStep(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    label: []const u8,
    url: []const u8,
    authorization: []const u8,
    extra: []const std.http.Header,
    sid: *?[]const u8,
    body: []const u8,
) !bool {
    var built: [3]std.http.Header = undefined;
    var count: usize = 0;
    built[count] = .{ .name = "accept", .value = "application/json, text/event-stream" };
    count += 1;
    if (authorization.len > 0) {
        built[count] = .{ .name = "authorization", .value = authorization };
        count += 1;
    }
    if (sid.*) |value| {
        built[count] = .{ .name = "mcp-session-id", .value = value };
        count += 1;
    }

    // The same order the transport uses, so what this probe sends is what the
    // client sends.
    const headers = try arena.alloc(std.http.Header, count + extra.len);
    @memcpy(headers[0..count], built[0..count]);
    @memcpy(headers[count..], extra);

    var client: std.http.Client = .{ .io = io, .allocator = allocator };
    defer client.deinit();

    var request = client.request(.POST, try std.Uri.parse(url), .{
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers,
    }) catch |err| {
        try out.print("\n  {s}{s}{s} could not send ({s})\n", .{ bold, label, reset, @errorName(err) });
        return false;
    };
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    try request.sendBodyComplete(@constCast(body));

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch |err| {
        try out.print("\n  {s}{s}{s} no reply ({s})\n", .{ bold, label, reset, @errorName(err) });
        return false;
    };

    const status = response.head.status;
    const content_type = response.head.content_type orelse "none";

    var it = response.head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "mcp-session-id")) {
            sid.* = try arena.dupe(u8, header.value);
        }
    }

    try out.print("\n  {s}{s}{s} HTTP {d} {s}  {s}{s}{s}\n", .{
        bold,
        label,
        reset,
        @intFromEnum(status),
        status.phrase() orelse "",
        dim,
        content_type,
        reset,
    });
    if (sid.*) |value| try out.print("  {s}session{s}    {s}\n", .{ dim, reset, value });

    var transfer_buffer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const received = reader.allocRemaining(arena, .limited(512 * 1024)) catch |err| {
        try out.print("  {s}body{s}       unreadable ({s})\n", .{ dim, reset, @errorName(err) });
        return false;
    };

    if (received.len == 0) {
        try out.print("  {s}body{s}       empty\n", .{ dim, reset });
    } else {
        try out.print("  {s}body{s}       {d} bytes\n  {s}", .{
            dim,
            reset,
            received.len,
            received[0..@min(received.len, 700)],
        });
        if (received.len > 700) try out.print("{s}... truncated{s}", .{ dim, reset });
        try out.writeAll("\n");
    }
    try out.flush();

    return status.class() == .success;
}
