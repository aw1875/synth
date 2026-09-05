//! What a slash command does, and the provider and model switching behind it.
//!
//! Split from the Model because these are the app's verbs: each one takes the
//! Model, changes something, and returns. The event router picks which; nothing
//! here knows about keys.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const agents = @import("../agent/agent.zig");
const mention = @import("../core/mention.zig");
const skill = @import("../core/skill.zig");
const skill_tool = @import("../tools/skill.zig");
const catalog = @import("../provider/catalog.zig");
const codex_auth = @import("../provider/codex_auth.zig");
const Backend = @import("../provider/backend.zig");
const Provider = @import("../provider/provider.zig");
const Connect = @import("connect.zig");
const Model = @import("model.zig");
const ModelPicker = @import("model_picker.zig");
const Notification = @import("notification.zig");
const Slash = @import("slash.zig");

/// Most transcript hits `/search` will show at once.
const search_limit: usize = 20;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const humanize = @import("../core/humanize.zig");

pub fn runCommand(self: *Model, ctx: *vxfw.EventContext, value: []const u8) !bool {
    const line = std.mem.trim(u8, value, " \t\r\n");
    if (line.len == 0 or line[0] != '/') return false;
    self.slash.close();

    if (std.mem.eql(u8, line, "/help")) {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const text = try Slash.helpText(arena_state.allocator(), self.loop.skills);
        _ = try self.conversation.append(.{ .role = .assistant, .text = text });
        self.scroll = 0;
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/search")) {
        try searchTranscripts(self, ctx, std.mem.trim(u8, line["/search".len..], " "));
        return true;
    }
    if (std.mem.eql(u8, line, "/prune")) {
        try pruneNow(self, ctx);
        return true;
    }
    if (std.mem.eql(u8, line, "/compact")) {
        try self.startCompaction(ctx);
        return true;
    }
    if (std.mem.eql(u8, line, "/clear")) {
        if (!self.clearSession()) {
            try self.notification.show(ctx, .info, "Finish the turn first");
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/sessions")) {
        if (self.loop.database()) |db| {
            if (self.loop.project_id) |project_id| {
                try self.sessions.show(db, project_id, self.loop.session_id);
            }
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/agent")) {
        const name = std.mem.trim(u8, line["/agent".len..], " ");
        if (name.len > 0) {
            try switchAgent(self, ctx, agents.findOrDefault(name).id);
        } else {
            try switchAgent(self, ctx, agents.next(self.loop.agent.id).id);
        }
        return true;
    }
    if (std.mem.startsWith(u8, line, "/theme")) {
        const name = std.mem.trim(u8, line["/theme".len..], " ");
        if (name.len > 0) {
            keepTheme(self, themes.findOrDefault(name).id);
        } else {
            try self.theme_picker.show(themeId(self));
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/mcp")) {
        if (self.mcp) |host| {
            try self.mcp_picker.show(host);
        } else {
            try self.notification.show(ctx, .info, "No MCP servers configured");
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/skills")) {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();

        const text = if (self.skills) |set|
            try set.listText(arena_state.allocator())
        else
            "No skills found.";
        _ = try self.conversation.append(.{ .role = .assistant, .text = text });
        self.scroll = 0;
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/providers")) {
        try showProviders(self);
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/model")) {
        const name = std.mem.trim(u8, line["/model".len..], " ");
        if (name.len > 0) {
            switchModel(self, ctx, name) catch {};
        } else {
            try showModels(self, ctx);
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/rename")) {
        const name = std.mem.trim(u8, line["/rename".len..], " ");
        if (name.len > 0) {
            self.loop.rename(name) catch {};
        } else {
            try self.rename.show(self.loop.title());
        }
        ctx.redraw = true;
        return true;
    }
    return runSkill(self, ctx, line);
}

/// Invoke a skill by name: `/release 2.1`.
///
/// The instructions travel as an attachment rather than as the message text, so
/// the transcript shows what was typed and the model still receives the whole
/// skill. It is the same path an `@path` mention takes, which is what keeps a
/// two hundred line skill from being pasted into the conversation view.
fn runSkill(self: *Model, ctx: *vxfw.EventContext, line: []const u8) !bool {
    const word_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const id = line[1..word_end];
    const found = skill.findIn(self.loop.skills, id) orelse return false;

    if (self.loop.isBusy()) {
        try self.notification.show(ctx, .info, "Finish the turn first");
        ctx.redraw = true;
        return true;
    }

    const path = try std.fs.path.join(self.allocator, &.{ found.dir, skill.file_name });
    defer self.allocator.free(path);

    const content = try skill_tool.render(self.allocator, found);
    defer self.allocator.free(content);

    const attachment: mention.Attachment = .{ .path = path, .content = content };
    try self.beginTurn(ctx, line, .{ .attachments = &.{attachment} });
    return true;
}

/// Open the provider connect flow.
/// The theme in use, by id. Read from the database, since that is where it is
/// kept; the default when there is none.
pub fn themeId(self: *Model) []const u8 {
    const db = self.loop.database() orelse return themes.default_id;
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const stored = db.setting(fixed.allocator(), "theme") catch return themes.default_id;
    return themes.findOrDefault(stored).id;
}

/// Paint in a theme and remember it. A theme outlives the session, so it is
/// stored the way the provider is.
pub fn keepTheme(self: *Model, id: []const u8) void {
    const chosen = themes.apply(id);
    if (self.loop.database()) |db| db.setSetting("theme", chosen.id) catch {};
}

/// Find text in this project's transcripts, and write the hits into the view.
fn searchTranscripts(self: *Model, ctx: *vxfw.EventContext, query: []const u8) !void {
    if (query.len == 0) {
        try self.notification.show(ctx, .info, "Give /search something to look for");
        return;
    }

    const db = self.loop.database() orelse return;
    const project_id = self.loop.project_id orelse return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hits = db.search(arena, project_id, query, search_limit) catch {
        try self.notification.show(ctx, .warn, "Could not search the transcripts");
        return;
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    if (hits.len == 0) {
        try out.writer.print("Nothing matching `{s}`.", .{query});
    } else {
        try out.writer.print("{d} message(s) matching `{s}`:\n", .{ hits.len, query });
        for (hits) |hit| {
            const named = if (hit.title.len > 0) hit.title else hit.public_id;
            try out.writer.print("\n**{s}** ({s})\n{s}: {s}\n", .{
                named,
                hit.public_id,
                hit.role,
                hit.excerpt,
            });
        }
    }

    _ = try self.conversation.append(.{ .role = .assistant, .text = out.written() });
    self.scroll = 0;
    ctx.redraw = true;
}

/// Apply the configured policy now, and say what it took out.
fn pruneNow(self: *Model, ctx: *vxfw.EventContext) !void {
    const db = self.loop.database() orelse {
        try self.notification.show(ctx, .info, "No database to prune");
        return;
    };

    const policy = self.prune_policy;
    if (!policy.any()) {
        try self.notification.show(ctx, .info, "Pruning is switched off in config.json");
        return;
    }

    const dropped = db.prune(policy, db.nowMs()) catch {
        try self.notification.show(ctx, .warn, "Could not prune the database");
        return;
    };
    if (dropped.any()) db.vacuum() catch {};

    var buffer: [128]u8 = undefined;
    var size: [humanize.bytes_len]u8 = undefined;
    const text = if (dropped.any())
        try std.fmt.bufPrint(&buffer, "Freed {s}: {d} session(s), {d} stored result(s)", .{
            humanize.bytes(&size, dropped.bytes_freed),
            dropped.sessions_deleted,
            dropped.blobs_dropped,
        })
    else
        try std.fmt.bufPrint(&buffer, "Nothing old enough to prune", .{});

    try self.notification.show(ctx, .info, text);
    ctx.redraw = true;
}

/// Change mode and say so. The change is silent otherwise: the tool schema and
/// the prompt both move, and neither is visible from the transcript.
pub fn switchAgent(self: *Model, ctx: *vxfw.EventContext, id: []const u8) !void {
    try self.loop.useAgent(id);
    ctx.redraw = true;
}

pub fn showProviders(self: *Model) !void {
    const auth = self.auth orelse return;
    const db = self.loop.database() orelse return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chosen = try db.activeProvider(arena);
    const active_id = catalog.findOrDefault(chosen).id;

    var states: [catalog.all.len]Connect.State = undefined;
    for (catalog.all, &states) |entry, *state| {
        const remembered = try db.providerHost(arena, entry.id);
        state.* = .{
            .id = entry.id,
            .host = if (entry.host_editable and remembered.len > 0) remembered else entry.host,
            .connected = entry.ready(auth),
            .active = std.mem.eql(u8, entry.id, active_id),
        };
    }

    try self.connect.show(&states);
}

/// Point the harness at a provider: store what was given, re-point the backend,
/// and remember the choice.
pub fn connectProvider(self: *Model, ctx: *vxfw.EventContext, connection: Connect.Result) !void {
    if (!try canSwitchProvider(self, ctx)) return;
    const auth = self.auth orelse return;
    const entry = catalog.findOrDefault(connection.id);

    const uses_browser_sign_in = entry.key == .oauth;
    const needs_browser_sign_in = uses_browser_sign_in and !entry.ready(auth);
    if (needs_browser_sign_in) {
        try self.codex_login.start();
        return;
    }

    const accepts_api_key = !uses_browser_sign_in;
    if (accepts_api_key) {
        if (connection.key) |api_key| {
            auth.set(entry.id, api_key) catch {};
            auth.save(self.io, auth.path) catch |err| {
                try note(self, "Could not write {s}: {s}", .{ auth.path, @errorName(err) });
            };
        }
    }

    const backend = self.backend orelse return;
    const provider = backend.connect(entry, connection.host, auth.key(entry.id)) catch |err| {
        try note(self, "Could not reach {s} at {s}: {s}", .{ entry.label, connection.host, @errorName(err) });
        return;
    };

    // Wholesale, not field by field: a provider of another protocol is a
    // different client behind a different vtable, and the old one is gone.
    self.provider = provider;
    self.loop.provider = provider;
    try self.loop.setModel(provider.model);

    if (self.loop.database()) |db| {
        db.setProviderHost(entry.id, connection.host) catch |err| {
            try note(self, "Could not remember the host: {s}", .{@errorName(err)});
        };
        db.setActiveProvider(entry.id) catch |err| {
            try note(self, "Could not remember the provider: {s}", .{@errorName(err)});
        };
        backend.warmModels(db) catch {};
    }
    if (backend.modelsWarming()) try self.scheduleTick(ctx);

    try note(self, "Connected {s} at {s}, running {s}.", .{ entry.label, connection.host, provider.model });
}

pub fn disconnectProvider(self: *Model, ctx: *vxfw.EventContext, provider_id: []const u8) !void {
    const auth = self.auth orelse return;
    const entry = catalog.find(provider_id) orelse return;
    const uses_browser_sign_in = entry.key == .oauth;
    const is_connected = entry.ready(auth);
    const can_disconnect = uses_browser_sign_in and is_connected;
    if (!can_disconnect) return;
    if (self.loop.isBusy()) {
        try self.notification.show(ctx, .info, "Finish the turn first");
        return;
    }

    codex_auth.removeStoredTokens(self.allocator, self.io, auth) catch |err| {
        try self.notification.showFmt(ctx, .err, "Could not disconnect {s}: {s}", .{ entry.label, @errorName(err) });
        return;
    };
    try self.notification.showFmt(ctx, .info, "Disconnected {s}", .{entry.label});
}

pub fn pollCodexLogin(self: *Model, ctx: *vxfw.EventContext) !void {
    if (self.loop.isBusy()) return;
    const should_announce_code = self.codex_login.shouldAnnounceCode();
    if (should_announce_code) {
        try note(self, "Codex login pending — see the statusline for the one-time code.", .{});
    }
    const login_result = self.codex_login.takeResult() orelse return;
    ctx.redraw = true;
    switch (login_result) {
        .success => {
            const codex_entry = catalog.find(codex_auth.provider_id).?;
            try connectProvider(self, ctx, .{ .id = codex_entry.id, .host = codex_entry.host, .key = null });
        },
        .canceled => try self.notification.show(ctx, .info, "Codex login canceled"),
        .failed => |err| try self.notification.showFmt(ctx, .err, "Codex sign-in failed: {s}", .{@errorName(err)}),
    }
}

/// Say something in the transcript, in the harness's own voice.
pub fn note(self: *Model, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(text);
    _ = try self.conversation.append(.{ .role = .assistant, .text = text });
    self.scroll = 0;
}

/// Open the model switcher, asking each provider what it offers.
pub fn showModels(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!try canSwitchProvider(self, ctx)) return;
    if (!self.provider.hasModelChoice()) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayList(ModelPicker.Entry) = .empty;
    const active_id = try activeProviderId(self, arena);

    for (catalog.all) |entry| {
        if (!isConnected(self, entry)) continue;

        const names = try listModels(self, arena, entry, active_id);
        for (names) |name| {
            try entries.append(arena, .{
                .name = name,
                .provider = entry.label,
                .provider_id = entry.id,
            });
        }
    }

    var recent: []const []const u8 = &.{};
    if (self.loop.database()) |db| {
        if (self.loop.project_id) |project_id| {
            recent = db.recentModels(arena, project_id, ModelPicker.max_recent) catch &.{};
        }
    }

    try self.models.show(entries.items, recent, self.provider.model);
}

/// Whether a provider has what it needs to be asked what it offers.
pub fn isConnected(self: *Model, entry: catalog.Entry) bool {
    const auth = self.auth orelse return std.mem.eql(u8, entry.id, catalog.default_id);
    return entry.ready(auth);
}

/// The models one provider offers.
///
/// The one in use answers through the live backend; the rest get a client of
/// their own, built from the host the database remembers and the key
/// `auth.json` holds. Nothing is reconnected to list a model - that only
/// happens when one is picked.
pub fn listModels(
    self: *Model,
    arena: std.mem.Allocator,
    entry: catalog.Entry,
    active_id: []const u8,
) ![]const []const u8 {
    const is_active_provider = std.mem.eql(u8, entry.id, active_id);
    if (is_active_provider) return self.provider.listModelNames(arena) catch &.{};

    var host = entry.host;
    if (entry.host_editable) {
        if (self.loop.database()) |db| {
            const remembered_host = try db.providerHost(arena, entry.id);
            const has_remembered_host = remembered_host.len > 0;
            if (has_remembered_host) host = remembered_host;
        }
    }

    const api_key = if (self.auth) |auth| auth.key(entry.id) else null;

    var backend: Backend = .init(entry.kind, .{
        .allocator = arena,
        .io = self.io,
        .host = host,
        .label = entry.label,
        .api_key = api_key,
        .auth = self.auth,
        .models = if (self.backend) |backend| backend.options.models else null,
    });
    defer backend.deinit();
    backend.start() catch return &.{};

    return backend.listModels(arena) catch &.{};
}

/// The provider in use, by catalog id. Caller owns the result.
pub fn activeProviderId(self: *Model, arena: std.mem.Allocator) ![]const u8 {
    const db = self.loop.database() orelse return catalog.default_id;
    const remembered_provider_id = try db.activeProvider(arena);
    return catalog.findOrDefault(remembered_provider_id).id;
}

/// Copy what the loop is pointed at into the copy of `Provider` the sidebar
/// reads. Both are values, and the loop's is the one that changes: resuming a
/// session switches models, and a turn re-reads the context window.
pub fn syncProvider(self: *Model) void {
    self.provider.model = self.loop.provider.model;
    self.provider.name = self.loop.provider.name;
    self.provider.context_limit = self.loop.provider.context_limit;
    self.provider.supports_vision = self.loop.provider.supports_vision;
}

/// Switch to a model, connecting its provider first when it belongs to another
/// one. Picking `gpt-oss` from a list that also holds local models should just
/// work, which means the switch is a reconnect and a model change together.
pub fn switchTo(self: *Model, ctx: *vxfw.EventContext, entry: ModelPicker.Entry) !void {
    if (!try canSwitchProvider(self, ctx)) return;
    if (entry.provider_id.len > 0) {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const active_id = try activeProviderId(self, arena);
        if (!std.mem.eql(u8, entry.provider_id, active_id)) {
            const provider = catalog.findOrDefault(entry.provider_id);
            var host = provider.host;
            if (provider.host_editable) {
                if (self.loop.database()) |db| {
                    const remembered = try db.providerHost(arena, provider.id);
                    if (remembered.len > 0) host = remembered;
                }
            }
            try connectProvider(self, ctx, .{ .id = provider.id, .host = host, .key = null });
        }
    }

    try switchModel(self, ctx, entry.name);
}

pub fn switchModel(self: *Model, ctx: *vxfw.EventContext, name: []const u8) !void {
    if (!try canSwitchProvider(self, ctx)) return;
    const set = self.provider.set_model orelse return;
    const current = try set(self.provider.userdata, name);

    self.provider.model = current.model;
    self.provider.context_limit = current.context_limit;
    self.provider.supports_vision = current.supports_vision;
    self.loop.provider.model = current.model;
    self.loop.provider.context_limit = current.context_limit;
    self.loop.provider.supports_vision = current.supports_vision;
    try self.loop.setModel(current.model);
}

fn canSwitchProvider(self: *Model, ctx: *vxfw.EventContext) !bool {
    if (!self.loop.isBusy()) return true;
    try self.notification.show(ctx, .info, "Finish the turn before changing providers or models");
    return false;
}

/// Turn the highlighted MCP server on or off.
///
/// Turning one off closes it and takes its tools back out of the registry;
/// turning one on hands the whole list back to `beginConnectAll`, which skips
/// what is already up and reaches only the one that changed. Either way the
/// model has to be told again, because the tool schema was built once.
pub fn toggleMcpServer(self: *Model, ctx: *vxfw.EventContext) !void {
    const host = self.mcp orelse return;
    const server = self.mcp_picker.selected() orelse return;

    if (host.connecting()) {
        try self.notification.show(ctx, .info, "Still connecting - try again in a moment");
        return;
    }

    const store = host.auth orelse {
        try self.notification.show(ctx, .warn, "No MCP state file, so this cannot be remembered");
        return;
    };

    const wanted = server.enabled and store.isEnabled(server.name);
    try store.setEnabled(server.name, !wanted);
    store.save(self.io, null) catch {};

    if (wanted) {
        if (host.disconnect(&self.registry, server.name)) {
            try self.loop.useAgent(self.loop.agent.id);
        }
        try self.notification.showFmt(ctx, .info, "{s} off", .{server.name});
    } else {
        try host.beginConnectAll(host.servers, host.client);
        try self.scheduleTick(ctx);
        try self.notification.showFmt(ctx, .info, "Connecting to {s}", .{server.name});
    }

    try self.mcp_picker.filter();
    ctx.redraw = true;
}

/// Check the configured model against what the provider has, once.
///
/// On the drawing thread rather than a worker because the provider's HTTP
/// client is the same one a turn uses, and two threads in it is a race. After
/// the first frame, so the cost lands on a window that is already up.
pub fn checkModel(self: *Model, ctx: *vxfw.EventContext) !void {
    if (!self.pending_model_check) return;
    if (self.loop.isBusy()) return;
    self.pending_model_check = false;

    const backend = self.backend orelse return;
    backend.ensureModel() catch {};
    self.loop.syncProvider();
    syncProvider(self);
    try self.loop.setModel(self.provider.model);
    ctx.redraw = true;
}

test "pending login waits for the worker before announcing once in the transcript" {
    const testing = std.testing;
    const Auth = @import("../core/auth.zig");
    const Gate = struct {
        started: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        fn respond(ptr: *anyopaque, _: *@import("../core/conversation.zig"), _: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const gate: *@This() = @ptrCast(@alignCast(ptr));
            gate.started.set(testing.io);
            try gate.released.wait(testing.io);
            return .{ .text = try allocator.dupe(u8, "done") };
        }
    };
    var gate: Gate = .{};
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = .{ .userdata = &gate, .name = "test", .respond = Gate.respond },
        .input = .init(testing.allocator),
        .auth = &auth,
    };
    try model.wire();
    defer model.deinit();
    defer gate.released.set(testing.io);
    try model.loop.submit("hello", .{});
    try gate.started.wait(testing.io);
    model.codex_login.code_received.store(true, .release);
    var ctx: vxfw.EventContext = .{ .phase = .at_target, .io = testing.io, .alloc = testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(testing.allocator);
    const count = model.conversation.messages.items.len;
    try pollCodexLogin(&model, &ctx);
    try testing.expectEqual(count, model.conversation.messages.items.len);
    gate.released.set(testing.io);
    while (model.loop.isBusy()) {
        _ = try model.loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    const completed_count = model.conversation.messages.items.len;
    try pollCodexLogin(&model, &ctx);
    try pollCodexLogin(&model, &ctx);
    try testing.expectEqual(completed_count + 1, model.conversation.messages.items.len);
    try testing.expectEqualStrings("Codex login pending — see the statusline for the one-time code.", model.conversation.messages.items[completed_count].text);
}

test "provider and model actions leave a running turn and its credentials alone" {
    const testing = std.testing;
    const Auth = @import("../core/auth.zig");
    const Fake = struct {
        started: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        changes: usize = 0,
        listings: usize = 0,
        fn respond(ptr: *anyopaque, _: *@import("../core/conversation.zig"), _: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.started.set(testing.io);
            try self.released.wait(testing.io);
            return .{ .text = try allocator.dupe(u8, "done") };
        }
        fn setModel(ptr: *anyopaque, _: []const u8) !Provider.Current {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.changes += 1;
            return .{ .model = "next", .context_limit = 123000, .supports_vision = true };
        }
        fn listModels(ptr: *anyopaque, allocator: std.mem.Allocator) ![][]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.listings += 1;
            return allocator.alloc([]const u8, 0);
        }
    };
    var fake: Fake = .{};
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var backend = Backend.init(.ollama, .{ .allocator = testing.allocator, .io = testing.io, .host = "http://127.0.0.1:1", .label = "Ollama", .auth = &auth });
    defer backend.deinit();
    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = .{ .userdata = &fake, .name = "Ollama", .model = "first", .respond = Fake.respond, .set_model = Fake.setModel, .list_models = Fake.listModels },
        .input = .init(testing.allocator),
        .auth = &auth,
        .backend = &backend,
    };
    try model.wire();
    defer model.deinit();
    defer fake.released.set(testing.io);
    var ctx: vxfw.EventContext = .{ .phase = .at_target, .io = testing.io, .alloc = testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(testing.allocator);
    try model.loop.submit("hello", .{});
    try fake.started.wait(testing.io);
    const count = model.conversation.messages.items.len;
    try switchModel(&model, &ctx, "next");
    try testing.expect(try runCommand(&model, &ctx, "/model next"));
    try switchTo(&model, &ctx, .{ .name = "next", .provider = "Ollama", .provider_id = "ollama" });
    try connectProvider(&model, &ctx, .{ .id = "openai-compat", .host = "http://127.0.0.1:1", .key = "must not be saved" });
    try showModels(&model, &ctx);
    try testing.expectEqual(@as(usize, 0), fake.changes);
    try testing.expectEqual(@as(usize, 0), fake.listings);
    try testing.expectEqualStrings("first", model.provider.model);
    try testing.expectEqual(count, model.conversation.messages.items.len);
    try testing.expectEqual(catalog.Kind.ollama, std.meta.activeTag(backend.client));
    try testing.expect(auth.key("openai-compat") == null);
    try testing.expect(!model.models.open);

    fake.released.set(testing.io);
    while (model.loop.isBusy()) {
        _ = try model.loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    try switchModel(&model, &ctx, "next");
    try testing.expectEqual(@as(usize, 1), fake.changes);
    try testing.expectEqualStrings("next", model.provider.model);
}

test "startup selection is displayed and saved before the first request for every backend" {
    const testing = std.testing;
    const Auth = @import("../core/auth.zig");
    const Database = @import("../core/database.zig");
    const Models = @import("../provider/models.zig");
    const Source = struct {
        pub fn fetchModels(_: *@This(), arena: std.mem.Allocator) ![]const Models.Info {
            return arena.dupe(Models.Info, &.{
                .{ .id = "available-model", .context_limit = 123000, .vision = false },
            });
        }
    };

    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    try auth.set("codex", "{\"access_token\":\"test\",\"refresh_token\":\"test\",\"account_id\":\"test-account\"}");
    var models = try Models.init(testing.allocator, testing.io, "");
    defer models.deinit();
    var source: Source = .{};
    // Keep the optional metadata fallback offline as well.
    _ = try models.getOrFetchCatalog("models.dev", "https://models.dev/api.json", "", &source);

    for ([_]catalog.Kind{ .ollama, .openai, .codex }) |kind| {
        const host = if (kind == .codex) codex_auth.backend_url else "http://127.0.0.1:1/v1";
        const identity = if (kind == .codex) "test-account" else "";
        _ = try models.getOrFetchCatalog(@tagName(kind), host, identity, &source);
        if (kind == .ollama) _ = try models.getOrFetchCatalog("ollama/show/available-model", host, identity, &source);
        var backend = Backend.init(kind, .{
            .allocator = testing.allocator,
            .io = testing.io,
            .host = host,
            .label = "test",
            .auth = &auth,
            .models = &models,
        });
        defer backend.deinit();
        try backend.start();

        var db = try Database.init(testing.allocator, testing.io, ":memory:");
        defer db.deinit();
        var model: Model = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .conversation = .init(testing.allocator),
            .provider = backend.provider(),
            .input = .init(testing.allocator),
            .backend = &backend,
            .auth = &auth,
            .pending_model_check = true,
        };
        try model.wire();
        defer model.deinit();
        try model.loop.attachDatabase(&db, "project", "/repo", backend.model());
        var ctx: vxfw.EventContext = .{
            .phase = .at_target,
            .io = testing.io,
            .alloc = testing.allocator,
            .cmds = .empty,
        };
        defer ctx.cmds.deinit(testing.allocator);

        try checkModel(&model, &ctx);

        try testing.expectEqualStrings("available-model", model.provider.model);
        try testing.expectEqualStrings("available-model", model.loop.provider.model);
        try testing.expectEqual(@as(u32, 123000), model.provider.context_limit);
        try testing.expect(!model.provider.supports_vision);
        try testing.expectEqual(@as(u64, 0), model.loop.usage.calls);
        try model.loop.rename("Before the first prompt");
        const saved_model = try db.sessionModel(model.loop.session_id.?, testing.allocator);
        defer testing.allocator.free(saved_model);
        try testing.expectEqualStrings("available-model", saved_model);
    }
}

/// Take delivery of servers connected on a worker.
///
/// Registering happens here rather than on the worker because the registry
/// belongs to this thread, and the model has to be told again afterwards: the
/// tool schema is built once by `useAgent`, so a tool registered after that is
/// one it never hears about.
pub fn applyMcp(self: *Model, ctx: *vxfw.EventContext) !void {
    const host = self.mcp orelse return;
    if (!host.settled()) return;

    const added = host.install(&self.registry) catch 0;
    if (added > 0) try self.loop.useAgent(self.loop.agent.id);

    try reportMcpFailures(self, ctx);
    ctx.redraw = true;
}

/// Say which MCP servers did not come up, once there is a screen to say it on.
///
/// Connecting happens before the event loop starts, so a failure has nowhere
/// to go at the time. It waits in the host until the first frame, which is
/// what this reads. Silence would otherwise be indistinguishable from a server
/// that started fine and offered nothing.
pub fn reportMcpFailures(self: *Model, ctx: *vxfw.EventContext) !void {
    const host = self.mcp orelse return;
    const failures = host.failures.items;
    if (failures.len == 0) return;

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    try out.writer.print("{d} MCP server{s} failed: ", .{
        failures.len,
        if (failures.len == 1) "" else "s",
    });
    for (failures, 0..) |failure, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.print("{s} ({s})", .{ failure.server, failure.reason });
    }

    try self.notification.show(ctx, .err, out.written());
}
