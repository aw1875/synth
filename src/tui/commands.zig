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
const catalog = @import("../provider/catalog.zig");
const Connect = @import("connect.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const keys = @import("keys.zig");
const Database = @import("../core/database.zig");
const Mirror = @import("../acp/mirror.zig");
const client = @import("../acp/connection.zig");
const Model = @import("model.zig");
const ModelPicker = @import("model_picker.zig");
const Notification = @import("notification.zig");
const SessionPicker = @import("session_picker.zig");
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
        const text = try Slash.helpText(arena_state.allocator(), self.skillsOffered());
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
        if (try offerProvidersInstead(self)) return true;
        try self.startCompaction(ctx);
        return true;
    }
    if (std.mem.eql(u8, line, "/clear")) {
        if (!try self.clearSession()) {
            try self.notification.show(ctx, .info, "Finish the turn first");
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/sessions")) {
        try showSessions(self);
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/agent")) {
        const name = std.mem.trim(u8, line["/agent".len..], " ");
        if (name.len > 0) {
            try switchAgent(self, ctx, agents.findOrDefault(name).id);
        } else {
            try switchAgent(self, ctx, agents.next(self.mirror.agentId()).id);
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
        if (self.mirror.status.mcp.len > 0) {
            try self.mcp_picker.show(self.mirror.status.mcp);
        } else {
            try self.notification.show(ctx, .info, "No MCP servers configured");
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/skills")) {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();

        const text = try skill.describe(arena_state.allocator(), self.mirror.skills, self.mirror.skill_paths);
        _ = try self.conversation.append(.{ .role = .assistant, .text = text });
        self.scroll = 0;
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/logout")) {
        try signOutOfChatGPT(self);
        ctx.redraw = true;
        return true;
    }
    if (isCommand(line, "/effort")) {
        try chooseEffort(self, ctx, std.mem.trim(u8, line["/effort".len..], " "));
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/usage")) {
        try openUsage(self);
        ctx.redraw = true;
        return true;
    }
    if (std.mem.eql(u8, line, "/providers")) {
        try showProviders(self);
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/model")) {
        if (try offerProvidersInstead(self)) return true;
        const name = std.mem.trim(u8, line["/model".len..], " ");
        if (name.len > 0) {
            switchModel(self, name) catch {};
        } else {
            try showModels(self);
        }
        ctx.redraw = true;
        return true;
    }
    if (std.mem.startsWith(u8, line, "/rename")) {
        const name = std.mem.trim(u8, line["/rename".len..], " ");
        if (name.len > 0) {
            self.mirror.rename(name) catch {};
        } else {
            try self.rename.show(self.mirror.title());
        }
        ctx.redraw = true;
        return true;
    }
    return runSkill(self, ctx, line);
}

/// Invoke one of the server's skills by name: `/release 2.1`.
///
/// The server sends the instructions as an attachment rather than as the
/// message text, so the transcript shows what was typed and the model still
/// receives the whole skill: the same path an `@path` mention takes, which is
/// what keeps a two hundred line skill out of the conversation view.
fn runSkill(self: *Model, ctx: *vxfw.EventContext, line: []const u8) !bool {
    if (skill.findIn(self.skillsOffered(), skill.idOf(line)) == null) return false;

    if (self.mirror.isBusy()) {
        try self.notification.show(ctx, .info, "Finish the turn first");
        ctx.redraw = true;
        return true;
    }
    if (try offerProvidersInstead(self)) return true;
    try self.remember(line);
    try self.mirror.runSkill(line);
    try self.followTurn(ctx);
    return true;
}

/// Ask for this project's stored sessions. They arrive on a later tick, and
/// open the switcher then.
pub fn showSessions(self: *Model) !void {
    try self.mirror.listSessions(SessionPicker.fetch_limit);
}

/// Show what the session's server answered.
pub fn showAnswer(self: *Model, ctx: *vxfw.EventContext, answer: Mirror.Answer) !void {
    switch (answer) {
        .sessions => |listed| {
            try self.sessions.show(listed, self.mirror.status.handle);
        },
        .search => |found| {
            defer answer.deinit(self.allocator);
            try showHits(self, ctx, found.query, found.hits);
        },
        .files => |paths| {
            self.mentions.supply(self.io, paths);
            try self.refreshMentions();
            ctx.redraw = true;
        },
        .models => |offer| {
            defer answer.deinit(self.allocator);
            var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena_state.deinit();
            const entries = try arena_state.allocator().alloc(ModelPicker.Entry, offer.models.offered.len);
            for (offer.models.offered, entries) |offered, *entry| entry.* = .{
                .name = offered.name,
                .provider = if (offered.provider.len > 0) offered.provider else self.mirror.status.provider,
                .provider_id = offered.provider_id,
                .efforts = offered.efforts,
                .effort = offered.effort,
            };
            try self.models.show(entries, offer.models.recent, self.mirror.status.model);
        },
        .subagent => |transcript| try self.receiveSubagent(transcript.seq, transcript.call, transcript.live, transcript.messages),
        .providers => |known| {
            defer answer.deinit(self.allocator);
            var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena_state.deinit();
            const states = try arena_state.allocator().alloc(Connect.State, known.states.len);
            for (known.states, states) |state, *out| out.* = .{
                .id = state.id,
                .host = state.host,
                .connected = state.connected,
                .active = state.active,
            };
            try self.connect.show(states);
        },
    }
}

/// The theme in use, by id. Read from the database, since that is where it is
/// kept; the default when there is none.
pub fn themeId(self: *Model) []const u8 {
    const db = self.db orelse return themes.default_id;
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const stored = db.setting(fixed.allocator(), "theme") catch return themes.default_id;
    return themes.findOrDefault(stored).id;
}

/// Paint in a theme and remember it. A theme outlives the session, so it is
/// stored the way the provider is.
pub fn keepTheme(self: *Model, id: []const u8) void {
    const chosen = themes.apply(id);
    if (self.db) |db| db.setSetting("theme", chosen.id) catch {};
}

/// Search this project's transcripts. The hits arrive on a later tick, and
/// are written into the view then.
fn searchTranscripts(self: *Model, ctx: *vxfw.EventContext, query: []const u8) !void {
    if (query.len == 0) {
        try self.notification.show(ctx, .info, "Give /search something to look for");
        return;
    }
    try self.mirror.search(query, search_limit);
}

/// Write search hits into the view.
fn showHits(self: *Model, ctx: *vxfw.EventContext, query: []const u8, hits: []const Database.Hit) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
    const db = self.db orelse {
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
    try self.mirror.useAgent(id);
    ctx.redraw = true;
}

/// Ask for the providers the server knows. They arrive on a later tick, and
/// open the dialog then.
pub fn showProviders(self: *Model) !void {
    try self.mirror.listProviders();
}

/// Point the session at a provider. Returns false while a ChatGPT sign-in it
/// starts will be waiting, so the dialog stays up for it.
pub fn connectProvider(self: *Model, result: Connect.Result) !bool {
    try self.mirror.connectProvider(result.id, result.host, result.key);
    return catalog.findOrDefault(result.id).key != .oauth or self.connect.isConnected(result.id);
}

fn isOverSsh(self: *Model) bool {
    const environ = self.environ orelse return false;
    return environ.get("SSH_CONNECTION") != null or environ.get("SSH_TTY") != null;
}

pub fn cancelSignIn(self: *Model) !void {
    try self.mirror.cancelSignIn();
}

pub fn reopenSignIn(self: *Model) void {
    keys.openUrl(self, signInUrl(self) orelse return);
}

/// OSC 52, so the link reaches the clipboard of the machine the terminal is
/// on, which over SSH is the one with the browser.
pub fn copySignInLink(self: *Model, ctx: *vxfw.EventContext) !void {
    try ctx.copyToClipboard(signInUrl(self) orelse return);
    try self.notification.show(ctx, .info, "Sign-in link copied");
}

fn signInUrl(self: *Model) ?[]const u8 {
    const sign_in = self.mirror.status.sign_in orelse return null;
    return sign_in.url;
}

/// Called each tick: show the server's sign-in while one waits on a browser,
/// and put the dialog away once it settles. The callback listens on the
/// server's machine, so from anywhere else it takes a forward.
pub fn followSignIn(self: *Model) !void {
    const sign_in = self.mirror.status.sign_in orelse {
        if (self.connect.isSigningIn()) self.connect.close();
        return;
    };
    if (self.connect.isSigningIn() and std.mem.eql(u8, self.connect.sign_in_url, sign_in.url)) return;
    const elsewhere = !std.mem.eql(u8, self.mirror.host, client.here) or isOverSsh(self);
    try self.connect.showSignIn(sign_in.url, sign_in.port, elsewhere);
    keys.openUrl(self, sign_in.url);
}

/// Revoking is a network round trip, so the server does it off the session's
/// thread and says how it went.
fn signOutOfChatGPT(self: *Model) !void {
    try self.mirror.signOut();
}

/// Open ChatGPT's usage page, where the plan's and synth's limits are set.
fn openUsage(self: *Model) !void {
    keys.openUrl(self, chatgpt_auth.usage_url);
    try note(self, "Manage your ChatGPT plan usage at {s}", .{chatgpt_auth.usage_url});
}

/// Say something in the transcript, in the harness's own voice.
pub fn note(self: *Model, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(text);
    _ = try self.conversation.append(.{ .role = .assistant, .text = text });
    self.scroll = 0;
}

/// Whether `line` is `command` alone or followed by an argument, so `/effortx`
/// is not read as `/effort x`.
fn isCommand(line: []const u8, command: []const u8) bool {
    if (!std.mem.startsWith(u8, line, command)) return false;
    return line.len == command.len or line[command.len] == ' ';
}

/// Nothing usable answers the session: none was chosen, or the ChatGPT
/// sign-in in use has ended.
pub fn needsProvider(self: *Model) bool {
    return self.mirror.status.provider_missing;
}

/// Open the providers dialog when there is nothing to act on. Returns whether
/// it did, so the caller stops.
pub fn offerProvidersInstead(self: *Model) !bool {
    if (!needsProvider(self)) return false;
    try showProviders(self);
    return true;
}

/// Ask for the models the server's providers offer. They arrive on a later
/// tick, and open the switcher then.
pub fn showModels(self: *Model) !void {
    if (try offerProvidersInstead(self)) return;
    if (!self.mirror.status.switchable) return;
    try self.mirror.listModels(ModelPicker.max_recent);
}

/// `/effort` alone opens the picker; with a level, sets it. Answers in a
/// toast: a note would join the conversation the model is sent.
fn chooseEffort(self: *Model, ctx: *vxfw.EventContext, level: []const u8) !void {
    if (try offerProvidersInstead(self)) return;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = self.mirror.provider;
    const efforts = provider.effortsFor(provider.model);
    if (efforts.levels.len == 0) {
        return self.notification.show(ctx, .info, try std.fmt.allocPrint(arena, "{s} has no effort setting", .{provider.model}));
    }
    if (level.len == 0) return self.effort_picker.show(provider.model, efforts.levels, provider.effort);

    const is_offered = for (efforts.levels) |candidate| {
        if (std.mem.eql(u8, candidate, level)) break true;
    } else false;
    if (!is_offered) {
        const offered = try std.mem.join(arena, ", ", efforts.levels);
        return self.notification.show(ctx, .warn, try std.fmt.allocPrint(arena, "{s} offers: {s}", .{ provider.model, offered }));
    }
    try setEffort(self, ctx, level);
}

/// Refused mid-turn: the request in flight reads the level as it is built.
pub fn setEffort(self: *Model, ctx: *vxfw.EventContext, level: []const u8) !void {
    if (self.mirror.isBusy()) return self.notification.show(ctx, .info, "Finish the turn first");
    try self.mirror.setEffort(level);

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const said = try std.fmt.allocPrint(arena_state.allocator(), "{s} now runs at {s} effort", .{ self.mirror.provider.model, level });
    try self.notification.show(ctx, .info, said);
}

/// Switch to a model picked from the list, connecting its provider first when
/// it belongs to another one.
pub fn switchTo(self: *Model, entry: ModelPicker.Entry) !void {
    const provider_id = if (entry.provider_id.len > 0) entry.provider_id else null;
    try self.mirror.switchModel(entry.name, if (entry.effort_changed) entry.effort else null, provider_id);
}

/// Point the session at another of its provider's models. The status says
/// what it landed on.
pub fn switchModel(self: *Model, name: []const u8) !void {
    try self.mirror.switchModel(name, null, null);
}

pub fn toggleMcpServer(self: *Model, ctx: *vxfw.EventContext) !void {
    const chosen = self.mcp_picker.selected() orelse return;
    try self.mirror.toggleMcp(chosen.name);
    if (chosen.state != .off) {
        try self.notification.showFmt(ctx, .info, "{s} off", .{chosen.name});
    } else {
        try self.notification.showFmt(ctx, .info, "Connecting to {s}", .{chosen.name});
    }
    ctx.redraw = true;
}

/// Show the MCP servers as they stand now, if the picker is open.
pub fn refreshMcpPicker(self: *Model) !void {
    if (!self.mcp_picker.isOpen()) return;
    try self.mcp_picker.refresh(self.mirror.status.mcp);
}
