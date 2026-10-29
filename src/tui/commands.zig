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
const Backend = @import("../provider/backend.zig");
const Provider = @import("../provider/provider.zig");
const Connect = @import("connect.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const SignInTask = @import("chatgpt_sign_in.zig");
const SignOutTask = @import("chatgpt_sign_out.zig");
const keys = @import("keys.zig");
const Model = @import("model.zig");
const ModelListing = @import("model_listing.zig");
const ModelPicker = @import("model_picker.zig");
const Notification = @import("notification.zig");
const Slash = @import("slash.zig");

/// Most transcript hits `/search` will show at once.
const search_limit: usize = 20;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const humanize = @import("../core/humanize.zig");

pub const finish_turn_first = "Finish the turn first";

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
    if (isCommand(line, "/search")) {
        try searchTranscripts(self, ctx, commandArgument(line, "/search"));
        return true;
    }
    if (std.mem.eql(u8, line, "/prune")) {
        try pruneNow(self, ctx);
        return true;
    }
    if (std.mem.eql(u8, line, "/compact")) {
        if (try offerProvidersInstead(self)) return true;
        if (self.loop.isBusy()) return refuseCommand(self, ctx, line, finish_turn_first);
        try self.startCompaction(ctx);
        return true;
    }
    if (std.mem.eql(u8, line, "/clear")) {
        if (!self.clearSession()) return refuseCommand(self, ctx, line, finish_turn_first);
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
    if (isCommand(line, "/agent")) {
        const name = commandArgument(line, "/agent");
        if (name.len > 0) {
            try switchAgent(self, ctx, agents.findOrDefault(name).id);
        } else {
            try switchAgent(self, ctx, agents.next(self.loop.agent.id).id);
        }
        return true;
    }
    if (isCommand(line, "/theme")) {
        const name = commandArgument(line, "/theme");
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
    if (std.mem.eql(u8, line, "/logout")) {
        try signOutOfChatGPT(self, ctx);
        ctx.redraw = true;
        return true;
    }
    if (isCommand(line, "/effort")) {
        try chooseEffort(self, ctx, commandArgument(line, "/effort"));
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
    if (isCommand(line, "/model")) {
        if (try offerProvidersInstead(self)) return true;
        if (self.loop.isBusy()) return refuseCommand(self, ctx, line, finish_turn_first);
        const name = commandArgument(line, "/model");
        if (name.len > 0) {
            try switchModelNamed(self, ctx, name);
        } else {
            try showModels(self, ctx);
        }
        ctx.redraw = true;
        return true;
    }
    if (isCommand(line, "/rename")) {
        const name = commandArgument(line, "/rename");
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

/// Turn a command down and hand the draft back, so nothing typed is lost.
fn refuseCommand(self: *Model, ctx: *vxfw.EventContext, line: []const u8, said: []const u8) !bool {
    try self.input.insertText(line);
    try self.followDraft(ctx);
    try self.notification.show(ctx, .info, said);
    ctx.redraw = true;
    return true;
}

fn commandName(line: []const u8) []const u8 {
    return line[1..Slash.commandWordEnd(line)];
}

fn commandArgument(line: []const u8, command: []const u8) []const u8 {
    return std.mem.trim(u8, line[command.len..], " \t\r\n");
}

/// Invoke a skill by name: `/release 2.1`.
///
/// The instructions travel as an attachment rather than as the message text, so
/// the transcript shows what was typed and the model still receives the whole
/// skill. It is the same path an `@path` mention takes, which is what keeps a
/// two hundred line skill from being pasted into the conversation view.
fn runSkill(self: *Model, ctx: *vxfw.EventContext, line: []const u8) !bool {
    const found = skill.findIn(self.loop.skills, commandName(line)) orelse return false;

    if (self.loop.isBusy()) return refuseCommand(self, ctx, line, finish_turn_first);

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
            .connected = if (entry.key == .oauth) entry.ready(auth, self.chatgpt) else auth.key(entry.id) != null,
            .active = !self.provider_missing and std.mem.eql(u8, entry.id, active_id),
        };
    }

    try self.connect.show(&states);
}

/// Point the harness at a provider and say so. Returns false while a browser
/// sign-in it started is still waiting, so the dialog stays up for it.
pub fn connectProvider(self: *Model, result: Connect.Result) !bool {
    const auth = self.auth orelse return true;
    const entry = catalog.findOrDefault(result.id);
    const needs_sign_in = entry.key == .oauth and !entry.ready(auth, self.chatgpt);
    if (needs_sign_in) return !try beginSignIn(self);

    if (!try pointAt(self, result)) return true;
    try announceProvider(self, result, self.provider.model);
    return true;
}

/// Start a ChatGPT sign-in in the background. Returns whether one is running.
fn beginSignIn(self: *Model) !bool {
    if (self.chatgpt_sign_in) |running| {
        try self.connect.showSignIn(running.sign_in.url, running.sign_in.callbackPort(), isOverSsh(self));
        return true;
    }
    const store = self.chatgpt orelse {
        try note(self, "ChatGPT sign-in is unavailable: no credential file could be opened.", .{});
        return false;
    };

    const task = SignInTask.start(self.allocator, self.io, store) catch |err| {
        try note(self, "{s}", .{SignInTask.explain(err)});
        return false;
    };
    self.chatgpt_sign_in = task;
    try self.connect.showSignIn(task.sign_in.url, task.sign_in.callbackPort(), isOverSsh(self));
    keys.openUrl(self, task.sign_in.url);
    return true;
}

fn isOverSsh(self: *Model) bool {
    const environ = self.environ orelse return false;
    return environ.get("SSH_CONNECTION") != null or environ.get("SSH_TTY") != null;
}

pub fn cancelSignIn(self: *Model) void {
    if (self.chatgpt_sign_in) |task| task.cancel();
}

pub fn reopenSignIn(self: *Model) void {
    const task = self.chatgpt_sign_in orelse return;
    keys.openUrl(self, task.sign_in.url);
}

/// OSC 52, so the link reaches the clipboard of the machine the terminal is
/// on, which over SSH is the one with the browser.
pub fn copySignInLink(self: *Model, ctx: *vxfw.EventContext) !void {
    const task = self.chatgpt_sign_in orelse return;
    try ctx.copyToClipboard(task.sign_in.url);
    try self.notification.show(ctx, .info, "Sign-in link copied");
}

/// Called each tick: once the browser has come back, connect or say why not.
pub fn pollSignIn(self: *Model, ctx: *vxfw.EventContext) !void {
    const task = self.chatgpt_sign_in orelse return;
    if (!task.isFinished()) return self.scheduleTick(ctx);

    self.chatgpt_sign_in = null;
    self.connect.close();
    ctx.redraw = true;
    task.finish() catch |err| {
        try note(self, "{s}", .{SignInTask.explain(err)});
        return;
    };

    const entry = catalog.find(catalog.chatgpt_id).?;
    const result: Connect.Result = .{ .id = entry.id, .host = entry.host, .key = null };
    if (!try pointAt(self, result)) return;
    try announceProvider(self, result, self.provider.model);
    try welcomeToPlanUsage(self);
}

/// Said once, the first time this installation signs in.
fn welcomeToPlanUsage(self: *Model) !void {
    const welcomed_key = "chatgpt:welcomed";
    const db = self.loop.database() orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const welcomed = db.setting(arena_state.allocator(), welcomed_key) catch "";
    if (welcomed.len > 0) return;
    try note(self, "You're using your ChatGPT plan. Requests in synth count toward its usage. Manage usage with /usage or at {s}", .{chatgpt_auth.usage_url});
    db.setSetting(welcomed_key, "1") catch {};
}

/// Revoking is a network round trip, so it runs off this thread and the tick
/// loop reports how it went.
fn signOutOfChatGPT(self: *Model, ctx: *vxfw.EventContext) !void {
    const store = self.chatgpt orelse return;
    if (self.chatgpt_sign_out != null) return;
    if (!store.isSignedIn()) return note(self, "Not signed in to ChatGPT.", .{});
    self.chatgpt_sign_out = SignOutTask.start(self.allocator, self.io, store) catch |err| {
        return note(self, "Could not sign out of ChatGPT: {s}", .{@errorName(err)});
    };
    try self.scheduleTick(ctx);
}

pub fn pollSignOut(self: *Model, ctx: *vxfw.EventContext) !void {
    const task = self.chatgpt_sign_out orelse return;
    if (!task.isFinished()) return self.scheduleTick(ctx);

    self.chatgpt_sign_out = null;
    ctx.redraw = true;
    const confirmed = task.finish() catch |err| {
        return note(self, "Could not sign out of ChatGPT: {s}", .{@errorName(err)});
    };
    const said = if (confirmed)
        "Signed out of ChatGPT."
    else
        "Signed out of ChatGPT here, but OpenAI did not confirm it. You can disconnect synth in ChatGPT settings.";
    try note(self, "{s}", .{said});

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const active_id = try activeProviderId(self, arena_state.allocator());
    if (!std.mem.eql(u8, active_id, catalog.chatgpt_id)) return;
    self.provider_missing = true;
    const db = self.loop.database() orelse return;
    db.setActiveProvider("") catch |err| try note(self, "Could not clear the provider: {s}", .{@errorName(err)});
}

/// Open ChatGPT's usage page, where the plan's and synth's limits are set.
fn openUsage(self: *Model) !void {
    keys.openUrl(self, chatgpt_auth.usage_url);
    try note(self, "Manage your ChatGPT plan usage at {s}", .{chatgpt_auth.usage_url});
}

/// Say which provider is answering now, and with what.
///
/// The model is passed rather than read because the caller may not be finished:
/// a connect made to reach one particular model is announced after that model
/// is set, not while the backend is still on whatever it defaulted to.
fn announceProvider(self: *Model, result: Connect.Result, model: []const u8) !void {
    const entry = catalog.findOrDefault(result.id);
    if (entry.key == .oauth) return note(self, "Connected to your {s}, running {s}.", .{ entry.label, model });
    try note(self, "Connected {s} at {s}, running {s}.", .{ entry.label, result.host, model });
}

/// Point the harness at a provider: store what was given, re-point the backend,
/// and remember the choice. Returns whether it got there.
fn pointAt(self: *Model, result: Connect.Result) !bool {
    const auth = self.auth orelse return false;
    const entry = catalog.findOrDefault(result.id);

    if (result.key) |key| {
        auth.set(entry.id, key) catch {};
        auth.save(self.io, auth.path) catch |err| {
            try note(self, "Could not write {s}: {s}", .{ auth.path, @errorName(err) });
        };
    }

    const backend = self.backend orelse return false;
    const provider = backend.connect(entry, result.host, auth.key(entry.id)) catch |err| {
        try note(self, "Could not reach {s} at {s}: {s}", .{ entry.label, result.host, @errorName(err) });
        return false;
    };

    // Wholesale: another protocol is another client, and the old one is gone.
    self.provider = provider;
    self.provider_missing = false;
    self.loop.provider = provider;
    try self.loop.setModel(provider.model);

    if (self.loop.database()) |db| {
        db.setProviderHost(entry.id, result.host) catch |err| {
            try note(self, "Could not remember the host: {s}", .{@errorName(err)});
        };
        db.setActiveProvider(entry.id) catch |err| {
            try note(self, "Could not remember the provider: {s}", .{@errorName(err)});
        };
    }

    try restoreEffort(self);
    return true;
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
    const typed = line[0..Slash.commandWordEnd(line)];
    return std.mem.eql(u8, typed, command);
}

/// Nothing usable is selected: none was chosen, or the ChatGPT session in use
/// has ended. Marked, so the title and the next prompt say so too.
pub fn needsProvider(self: *Model) bool {
    if (self.provider_missing) return true;
    const store = self.chatgpt orelse return false;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const active_id = activeProviderId(self, arena_state.allocator()) catch return false;
    const is_chatgpt_active = std.mem.eql(u8, active_id, catalog.chatgpt_id);
    if (!is_chatgpt_active or store.isUsable()) return false;
    self.provider_missing = true;
    return true;
}

/// Open the providers dialog when there is nothing to act on. Returns whether
/// it did, so the caller stops.
pub fn offerProvidersInstead(self: *Model) !bool {
    if (!needsProvider(self)) return false;
    try showProviders(self);
    return true;
}

/// Open the model switcher at once on what each connected provider last
/// offered, and ask them all again in the background. Each answer replaces that
/// provider's models as it lands, so a slow or hung one never holds the picker
/// shut.
pub fn showModels(self: *Model, ctx: *vxfw.EventContext) !void {
    if (try offerProvidersInstead(self)) return;
    if (!self.provider.switchable()) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try self.models.show(try lastOffered(self, arena), try recentModels(self, arena), self.provider.model);
    try askProviders(self, ctx);
    self.models.asking = try countUnlisted(self, arena);
}

/// Ask every connected provider what it offers, unless it is being asked
/// already. Done once at launch too, so the first picker opens with rows.
pub fn askProviders(self: *Model, ctx: *vxfw.EventContext) !void {
    if (needsProvider(self)) return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const active_id = try activeProviderId(self, arena);
    for (catalog.all) |entry| {
        if (!isConnected(self, entry)) continue;
        if (isBeingAsked(self, entry.id)) continue;
        try startModelListing(self, arena, entry, active_id);
    }
    if (self.model_listings.items.len > 0) try self.scheduleTick(ctx);
}

/// Whether a provider has what it needs to be asked what it offers.
pub fn isConnected(self: *Model, entry: catalog.Entry) bool {
    const auth = self.auth orelse return std.mem.eql(u8, entry.id, catalog.default_id);
    return entry.ready(auth, self.chatgpt);
}

/// Each provider is asked through a client of its own, never the one a turn
/// uses. A provider that cannot be given a thread is left out.
fn startModelListing(self: *Model, arena: std.mem.Allocator, entry: catalog.Entry, active_id: []const u8) !void {
    const reach = try reachOf(self, arena, entry, active_id);
    const listing = ModelListing.start(self.allocator, self.io, entry, reach) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return,
        else => return err,
    };
    errdefer listing.abandon();
    try self.model_listings.append(self.allocator, listing);
}

fn isBeingAsked(self: *Model, provider_id: []const u8) bool {
    for (self.model_listings.items) |listing| {
        if (std.mem.eql(u8, listing.entry.id, provider_id)) return true;
    }
    return false;
}

/// The provider in use is reached where it is pointed now, which a runtime
/// connect may have moved; the rest where the database remembers, with the key
/// `auth.json` holds.
fn reachOf(self: *Model, arena: std.mem.Allocator, entry: catalog.Entry, active_id: []const u8) !ModelListing.Reach {
    const is_active = std.mem.eql(u8, entry.id, active_id);
    if (is_active) {
        if (self.backend) |backend| {
            return .{ .host = backend.currentHost(), .api_key = backend.currentKey(), .chatgpt = self.chatgpt };
        }
    }

    var host = entry.host;
    if (entry.host_editable) {
        if (self.loop.database()) |db| {
            const remembered = try db.providerHost(arena, entry.id);
            if (remembered.len > 0) host = remembered;
        }
    }
    const api_key = if (self.auth) |auth| auth.key(entry.id) else null;
    return .{ .host = host, .api_key = api_key, .chatgpt = self.chatgpt };
}

pub fn pollModelListings(self: *Model, ctx: *vxfw.EventContext) !void {
    const listings = &self.model_listings;
    var is_any_finished = false;
    var index: usize = 0;
    while (index < listings.items.len) {
        const listing = listings.items[index];
        if (!listing.isFinished()) {
            index += 1;
            continue;
        }
        _ = listings.orderedRemove(index);
        listing.join();
        try keepOffered(self, listing);
        is_any_finished = true;
    }
    if (is_any_finished and self.models.open) {
        try refillModels(self);
        ctx.redraw = true;
    }
    if (listings.items.len > 0) try self.scheduleTick(ctx);
}

/// A provider that could not be asked leaves what it offered last in place.
fn keepOffered(self: *Model, listing: *ModelListing) !void {
    if (listing.models == null) return listing.destroy();
    for (self.offered_models.items) |*kept| {
        if (!std.mem.eql(u8, kept.*.entry.id, listing.entry.id)) continue;
        kept.*.destroy();
        kept.* = listing;
        return;
    }
    errdefer listing.destroy();
    try self.offered_models.append(self.allocator, listing);
}

fn refillModels(self: *Model) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try self.models.refill(try lastOffered(self, arena), try recentModels(self, arena));
    self.models.asking = try countUnlisted(self, arena);
}

/// Every connected provider's models, in catalog order.
fn lastOffered(self: *Model, arena: std.mem.Allocator) ![]const ModelPicker.Entry {
    const active_id = try activeProviderId(self, arena);
    var entries: std.ArrayList(ModelPicker.Entry) = .empty;
    for (catalog.all) |entry| {
        if (!isConnected(self, entry)) continue;
        const models = try offeredBy(self, arena, entry, active_id) orelse continue;
        try entries.appendSlice(arena, try modelEntries(self, arena, entry, models));
    }
    return entries.items;
}

/// What a provider last offered from where it is reached now. A list from a
/// host it has since moved off is no answer: an OpenAI-compatible server takes
/// any name, so its rows would set a model the new host does not have.
fn offeredBy(self: *Model, arena: std.mem.Allocator, entry: catalog.Entry, active_id: []const u8) !?[]const ModelListing.Offered {
    const reach = try reachOf(self, arena, entry, active_id);
    for (self.offered_models.items) |kept| {
        if (!std.mem.eql(u8, kept.entry.id, entry.id)) continue;
        if (!std.mem.eql(u8, kept.reach.host, reach.host)) return null;
        return kept.models;
    }
    return null;
}

/// Providers still being asked that have no rows to show yet.
fn countUnlisted(self: *Model, arena: std.mem.Allocator) !usize {
    const active_id = try activeProviderId(self, arena);
    var count: usize = 0;
    for (self.model_listings.items) |listing| {
        const offered = try offeredBy(self, arena, listing.entry, active_id);
        if (offered == null) count += 1;
    }
    return count;
}

fn recentModels(self: *Model, arena: std.mem.Allocator) ![]const []const u8 {
    const db = self.loop.database() orelse return &.{};
    const project_id = self.loop.project_id orelse return &.{};
    return db.recentModels(arena, project_id, ModelPicker.max_recent) catch &.{};
}

/// Each model a provider offers, with the effort level last chosen for it.
/// Borrows from `offered`; the picker copies what it keeps.
fn modelEntries(
    self: *Model,
    arena: std.mem.Allocator,
    entry: catalog.Entry,
    offered: []const ModelListing.Offered,
) ![]const ModelPicker.Entry {
    const entries = try arena.alloc(ModelPicker.Entry, offered.len);
    for (offered, entries) |model, *picked| {
        const remembered = try rememberedEffort(self, arena, entry.id, model.name);
        const is_remembered_offered = for (model.efforts.levels) |level| {
            if (std.mem.eql(u8, level, remembered)) break true;
        } else false;
        picked.* = .{
            .name = model.name,
            .provider = entry.label,
            .provider_id = entry.id,
            .efforts = model.efforts.levels,
            .effort = if (is_remembered_offered) remembered else model.efforts.default,
        };
    }
    return entries;
}

fn effortKey(arena: std.mem.Allocator, provider_id: []const u8, model: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "effort:{s}:{s}", .{ provider_id, model });
}

/// The effort last chosen for a model, or "" when none was.
fn rememberedEffort(self: *Model, arena: std.mem.Allocator, provider_id: []const u8, model: []const u8) ![]const u8 {
    const db = self.loop.database() orelse return "";
    return db.setting(arena, try effortKey(arena, provider_id, model)) catch "";
}

/// Run the current model at `level` from the next turn on, and remember it
/// for this model.
fn applyEffort(self: *Model, level: []const u8) !void {
    const set = self.provider.set_effort orelse return;
    set(self.provider.userdata, level);
    refreshEffort(self);

    const db = self.loop.database() orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_id = try activeProviderId(self, arena);
    db.setSetting(try effortKey(arena, provider_id, self.provider.model), level) catch |err| {
        try note(self, "Could not remember the effort: {s}", .{@errorName(err)});
    };
}

/// Put the current model back on the effort last chosen for it, or on its
/// default. For a launch, a resumed session, or a model switch.
pub fn restoreEffort(self: *Model) !void {
    const set = self.provider.set_effort orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_id = try activeProviderId(self, arena);
    set(self.provider.userdata, try rememberedEffort(self, arena, provider_id, self.provider.model));
    refreshEffort(self);
}

fn refreshEffort(self: *Model) void {
    const effort = self.provider.current().effort;
    self.provider.effort = effort;
    self.loop.provider.effort = effort;
}

/// `/effort` alone opens the picker; with a level, sets it. Answers in a
/// toast: a note would join the conversation the model is sent.
fn chooseEffort(self: *Model, ctx: *vxfw.EventContext, level: []const u8) !void {
    if (try offerProvidersInstead(self)) return;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const efforts = self.provider.effortsFor(self.provider.model);
    if (efforts.levels.len == 0) {
        return self.notification.show(ctx, .info, try std.fmt.allocPrint(arena, "{s} has no effort setting", .{self.provider.model}));
    }
    if (level.len == 0) return self.effort_picker.show(self.provider.model, efforts.levels, self.provider.current().effort);

    const is_offered = for (efforts.levels) |candidate| {
        if (std.mem.eql(u8, candidate, level)) break true;
    } else false;
    if (!is_offered) {
        const offered = try std.mem.join(arena, ", ", efforts.levels);
        return self.notification.show(ctx, .warn, try std.fmt.allocPrint(arena, "{s} offers: {s}", .{ self.provider.model, offered }));
    }
    try setEffort(self, ctx, level);
}

/// Refused mid-turn: the request in flight reads the level as it is built.
pub fn setEffort(self: *Model, ctx: *vxfw.EventContext, level: []const u8) !void {
    if (self.loop.isBusy()) return self.notification.show(ctx, .info, finish_turn_first);
    try applyEffort(self, level);

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const said = try std.fmt.allocPrint(arena_state.allocator(), "{s} now runs at {s} effort", .{ self.provider.model, self.provider.current().effort });
    try self.notification.show(ctx, .info, said);
}

/// The provider in use, by catalog id. Caller owns the result.
pub fn activeProviderId(self: *Model, arena: std.mem.Allocator) ![]const u8 {
    const db = self.loop.database() orelse return catalog.default_id;
    const chosen = try db.activeProvider(arena);
    return catalog.findOrDefault(chosen).id;
}

/// Copy what the loop is pointed at into the copy of `Provider` the sidebar
/// reads. Both are values, and the loop's is the one that changes: resuming a
/// session switches models, and a turn re-reads the context window.
pub fn syncProvider(self: *Model) void {
    self.provider.model = self.loop.provider.model;
    self.provider.name = self.loop.provider.name;
    self.provider.context_limit = self.loop.provider.context_limit;
    self.provider.vision = self.loop.provider.vision;
    self.provider.effort = self.loop.provider.effort;
}

/// Switch to a model, connecting its provider first when it belongs to another
/// one. Picking `gpt-oss` from a list that also holds local models should just
/// work, which means the switch is a reconnect and a model change together.
pub fn switchTo(self: *Model, entry: ModelPicker.Entry) !void {
    if (entry.provider_id.len > 0) {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const active_id = try activeProviderId(self, arena);
        if (self.provider_missing or !std.mem.eql(u8, entry.provider_id, active_id)) {
            const provider = catalog.findOrDefault(entry.provider_id);
            var host = provider.host;
            if (provider.host_editable) {
                if (self.loop.database()) |db| {
                    const remembered = try db.providerHost(arena, provider.id);
                    if (remembered.len > 0) host = remembered;
                }
            }

            const connection: Connect.Result = .{ .id = provider.id, .host = host, .key = null };

            // A provider we never reached is still on the old model.
            if (!try pointAt(self, connection)) return;

            const running = switchModel(self, entry.name) catch |err| {
                try announceProvider(self, connection, self.provider.model);
                return err;
            };
            if (entry.effort_changed) try applyEffort(self, entry.effort);
            try announceProvider(self, connection, running);
            return;
        }
    }

    _ = try switchModel(self, entry.name);
    if (entry.effort_changed) try applyEffort(self, entry.effort);
}

/// Point the provider at another of its models. Returns the model now in use,
/// which is what a caller announcing the change has to wait for: until this
/// returns, the backend is still on whatever it was.
pub fn switchModel(self: *Model, name: []const u8) ![]const u8 {
    const set = self.provider.set_model orelse return self.provider.model;
    const current = try set(self.provider.userdata, name);

    self.provider.model = current.model;
    self.provider.context_limit = current.context_limit;
    self.provider.vision = current.vision;
    self.loop.provider.model = current.model;
    self.loop.provider.context_limit = current.context_limit;
    self.loop.provider.vision = current.vision;
    try self.loop.setModel(current.model);
    try rememberModelChoice(self, current.model);
    try restoreEffort(self);
    return self.provider.model;
}

fn switchModelNamed(self: *Model, ctx: *vxfw.EventContext, name: []const u8) !void {
    _ = switchModel(self, name) catch |err| return reportSwitchFailure(self, ctx, name, err);
}

/// In the backend's words where it has some. A switch that went through before
/// a later step failed, such as remembering the choice, is said to have.
pub fn reportSwitchFailure(self: *Model, ctx: *vxfw.EventContext, name: []const u8, err: anyerror) !void {
    if (err == error.UnknownModel) {
        return self.notification.showFmt(ctx, .warn, "{s} has no model called {s}. Ctrl+o lists what it has", .{ self.provider.name, name });
    }
    const is_switched = std.mem.eql(u8, self.provider.model, name);
    if (is_switched) {
        return self.notification.showFmt(ctx, .warn, "Switched to {s}, but could not save it: {s}", .{ name, @errorName(err) });
    }
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    try self.notification.show(ctx, .err, try self.provider.explain(err, arena_state.allocator()));
}

/// Remember the model per provider so the next launch reopens on it.
fn rememberModelChoice(self: *Model, model: []const u8) !void {
    if (model.len == 0) return;
    const db = self.loop.database() orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider_id = try activeProviderId(self, arena);
    const key = try std.fmt.allocPrint(arena, "model:{s}", .{provider_id});
    db.setSetting(key, model) catch |err| {
        try note(self, "Could not remember the model: {s}", .{@errorName(err)});
    };
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
pub fn checkModel(self: *Model, ctx: *vxfw.EventContext) void {
    if (!self.pending_model_check) return;
    self.pending_model_check = false;

    const backend = self.backend orelse return;
    backend.ensureModel() catch {};
    syncProvider(self);
    ctx.redraw = true;
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

const testing = std.testing;

/// Stands in for a backend that can be pointed at another of its models.
fn fakeSetModel(_: *anyopaque, name: []const u8) anyerror!Provider.Current {
    if (std.mem.eql(u8, name, unserved_model)) return error.UnknownModel;
    return .{ .model = name };
}

const unserved_model = "asdf";

/// A model in a test needs only enough to hold a provider and a transcript.
fn switchFixture(allocator: std.mem.Allocator, userdata: *u8, model_name: []const u8) !Model {
    var self: Model = .{
        .allocator = allocator,
        .io = testing.io,
        .conversation = .init(allocator),
        .provider = .{
            .userdata = userdata,
            .respond = undefined,
            .name = "Ollama",
            .model = model_name,
            .set_model = fakeSetModel,
        },
        .input = .init(allocator),
    };
    try self.wire();
    return self;
}

test "a model the provider does not serve is refused, and the one in use stays" {
    var userdata: u8 = 0;
    var model = try switchFixture(testing.allocator, &userdata, "qwen3-coder:30b");
    defer model.deinit();
    var ctx = testContext();
    defer ctx.cmds.deinit(testing.allocator);

    try testing.expect(try runCommand(&model, &ctx, "/model " ++ unserved_model));
    try testing.expectEqualStrings("qwen3-coder:30b", model.provider.model);

    try testing.expect(try runCommand(&model, &ctx, "/model glm-5.3-flash"));
    try testing.expectEqualStrings("glm-5.3-flash", model.provider.model);
}

test "the model is not switched under a running turn" {
    var userdata: u8 = 0;
    var model = try switchFixture(testing.allocator, &userdata, "qwen3-coder:30b");
    defer model.deinit();
    var ctx = testContext();
    defer ctx.cmds.deinit(testing.allocator);

    model.loop.state = .awaiting_approval;
    defer model.loop.state = .idle;

    try testing.expect(try runCommand(&model, &ctx, "/model glm-5.3-flash"));
    try testing.expectEqualStrings("qwen3-coder:30b", model.provider.model);
    try testing.expectEqualStrings("/model glm-5.3-flash", model.input.text.items);
}

test "clearing the draft closes the slash menu over it" {
    var userdata: u8 = 0;
    var model = try switchFixture(testing.allocator, &userdata, "qwen3-coder:30b");
    defer model.deinit();
    var ctx = testContext();
    defer ctx.cmds.deinit(testing.allocator);

    try model.input.insertText("/mo");
    try model.followDraft(&ctx);
    try testing.expect(model.slash.isOpen());

    try model.handleInterrupt(&ctx);
    try testing.expect(!model.slash.isOpen());
}

test "a tab separates a command from its argument" {
    var userdata: u8 = 0;
    var model = try switchFixture(testing.allocator, &userdata, "qwen3-coder:30b");
    defer model.deinit();
    var ctx = testContext();
    defer ctx.cmds.deinit(testing.allocator);

    try testing.expect(try runCommand(&model, &ctx, "/model\tglm-5.3-flash"));
    try testing.expectEqualStrings("glm-5.3-flash", model.provider.model);
}

test "a command is matched by its whole name, not as a prefix" {
    try testing.expect(isCommand("/model", "/model"));
    try testing.expect(isCommand("/model glm-5.3-flash", "/model"));
    try testing.expect(!isCommand("/models", "/model"));
}

fn testContext() vxfw.EventContext {
    return .{
        .phase = .at_target,
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
    };
}

test "the provider is announced with the model that was actually picked" {
    var userdata: u8 = 0;
    var model = try switchFixture(testing.allocator, &userdata, "deepseek-v4-pro:0813");
    defer model.deinit();

    // What the connect settled on, which is not what the backend defaulted to.
    model.provider.model = "glm-5.3-flash";
    try announceProvider(&model, .{ .id = "ollama-cloud", .host = "https://ollama.com", .key = null }, model.provider.model);

    const said = model.conversation.messages.items[0].text;
    try testing.expect(std.mem.indexOf(u8, said, "glm-5.3-flash") != null);
    try testing.expect(std.mem.indexOf(u8, said, "deepseek-v4-pro:0813") == null);
    try testing.expect(std.mem.indexOf(u8, said, "https://ollama.com") != null);
}

test "a model whose provider could not be reached is not set on the one in use" {
    var userdata: u8 = 0;
    var model = try switchFixture(testing.allocator, &userdata, "qwen3-coder:30b");
    defer model.deinit();

    // No backend to connect with, so the switch cannot go through.
    try switchTo(&model, .{
        .name = "glm-5.3-flash",
        .provider = "Ollama Cloud",
        .provider_id = "ollama-cloud",
    });

    try testing.expectEqualStrings("qwen3-coder:30b", model.provider.model);
}

test "connecting to reach a model announces that model, not what the backend defaulted to" {
    const Auth = @import("../core/auth.zig");

    // Unreachable on purpose: the lookup that picks a default model is ignored.
    var backend: Backend = .init(.ollama, .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://127.0.0.1:1",
        .label = "Ollama",
    });
    defer backend.deinit();

    var auth: Auth = .{ .arena = .init(testing.allocator) };
    defer auth.deinit();

    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = backend.provider(),
        .input = .init(testing.allocator),
        .backend = &backend,
        .auth = &auth,
    };
    try model.wire();
    defer model.deinit();

    try switchTo(&model, .{
        .name = "glm-5.3-flash",
        .provider = "Ollama Cloud",
        .provider_id = "ollama-cloud",
    });

    try testing.expectEqualStrings("glm-5.3-flash", model.provider.model);

    const said = model.conversation.messages.items[0].text;
    try testing.expect(std.mem.indexOf(u8, said, "glm-5.3-flash") != null);
    try testing.expect(std.mem.indexOf(u8, said, "Ollama Cloud") != null);
}
