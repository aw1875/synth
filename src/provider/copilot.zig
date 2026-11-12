const std = @import("std");
const auth = @import("copilot_auth.zig");
const OpenAI = @import("openai.zig");
const Provider = @import("provider.zig");
const Conversation = @import("../core/conversation.zig");

const Copilot = @This();

allocator: std.mem.Allocator,
io: std.Io,
host: []const u8 = auth.api_host,
label: []const u8 = "GitHub Copilot",
model: []const u8 = "",
api_key: ?[]const u8 = null,
debug_log: ?[]const u8 = null,
integration_id: []const u8 = auth.default_integration_id,
inner: OpenAI = undefined,
started: bool = false,
arena: ?std.heap.ArenaAllocator = null,
models: ?[]const Model = null,
listing: []const u8 = "",
headers: [5]std.http.Header = undefined,
connection_arena: ?std.heap.ArenaAllocator = null,
catalog_lock: std.Io.Mutex = .init,
interaction_id: [32]u8 = undefined,

pub const Model = struct {
    id: []const u8,
    model_picker_enabled: bool = true,
    supported_endpoints: ?[]const []const u8 = null,
    policy: ?struct { state: []const u8 = "enabled" } = null,
    capabilities: struct {
        type: []const u8 = "chat",
        limits: struct {
            max_context_window_tokens: u32 = 0,
            max_prompt_tokens: u32 = 0,
            max_output_tokens: u32 = 4096,
        } = .{},
        supports: struct {
            tool_calls: bool = true,
            vision: bool = false,
        } = .{},
    } = .{},

    fn usable(self: Model) bool {
        if (self.id.len == 0 or !self.capabilities.supports.tool_calls) return false;
        if (!std.mem.eql(u8, self.capabilities.type, "chat")) return false;
        if (self.policy) |policy| if (!std.mem.eql(u8, policy.state, "enabled")) return false;
        return true;
    }

    fn wire(self: Model) !OpenAI.Wire {
        if (self.supported_endpoints) |endpoints| {
            for (endpoints) |endpoint| if (std.mem.eql(u8, endpoint, "/v1/messages")) return .messages;
            for (endpoints) |endpoint| if (std.mem.eql(u8, endpoint, "/responses")) return .responses;
            for (endpoints) |endpoint| if (std.mem.eql(u8, endpoint, "/chat/completions")) return .chat;
            return error.UnsupportedCopilotEndpoint;
        }
        if ((std.mem.startsWith(u8, self.id, "gpt-5") and !std.mem.startsWith(u8, self.id, "gpt-5-mini")) or
            std.mem.startsWith(u8, self.id, "grok-") or std.mem.startsWith(u8, self.id, "mai-code-")) return .responses;
        return .chat;
    }
};

pub fn start(self: *Copilot) !void {
    if (self.started) return;
    self.headers = try auth.headers(self.integration_id);
    var bytes: [16]u8 = undefined;
    self.io.random(&bytes);
    self.interaction_id = std.fmt.bytesToHex(bytes, .lower);
    self.inner = .{
        .allocator = self.allocator,
        .io = self.io,
        .host = self.host,
        .label = self.label,
        .model = self.model,
        .api_key = self.api_key,
        .debug_log = self.debug_log,
        .extra_headers = &self.headers,
        .versioned_paths = false,
        .state_tag = "copilot",
    };
    try self.inner.startWithoutProbe();
    self.started = true;
}

pub fn startLike(self: *Copilot, other: *const Copilot) !void {
    try self.start();
    if (other.arena != null) {
        self.arena = .init(self.allocator);
        const arena = self.arena.?.allocator();
        self.inner.host = try arena.dupe(u8, other.inner.host);
        self.listing = try arena.dupe(u8, other.listing);
        self.models = try parseModels(arena, self.listing);
        try self.applyModel();
    }
}

pub fn deinit(self: *Copilot) void {
    if (self.started) self.inner.deinit();
    if (self.arena) |*arena| arena.deinit();
    if (self.connection_arena) |*arena| arena.deinit();
}

fn loadModels(self: *Copilot) !void {
    self.catalog_lock.lockUncancelable(self.io);
    defer self.catalog_lock.unlock(self.io);
    if (self.models != null) return;
    const token = self.api_key orelse return error.NotSignedIn;
    if (token.len == 0) return error.NotSignedIn;
    try self.start();
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const endpoint = try auth.discover(a, self.io, token);
    const body = try auth.requestModels(a, self.io, endpoint, token, self.integration_id);
    const models = try parseModels(a, body);
    self.arena = arena;
    self.models = models;
    self.listing = body;
    self.inner.host = endpoint;
}

fn parseModels(arena: std.mem.Allocator, body: []const u8) ![]const Model {
    const Listing = struct { data: []const std.json.Value };
    const listing = try std.json.parseFromSliceLeaky(Listing, arena, body, .{ .ignore_unknown_fields = true });
    var models: std.ArrayList(Model) = .empty;
    for (listing.data) |value| {
        const model = std.json.parseFromValueLeaky(Model, arena, value, .{ .ignore_unknown_fields = true }) catch continue;
        if (!model.usable()) continue;
        try models.append(arena, model);
    }
    return models.toOwnedSlice(arena);
}

pub fn listModels(self: *Copilot, allocator: std.mem.Allocator) ![][]const u8 {
    try self.loadModels();
    const names = try allocator.alloc([]const u8, self.models.?.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (self.models.?, names) |entry, *name| {
        name.* = try allocator.dupe(u8, entry.id);
        filled += 1;
    }
    std.mem.sort([]const u8, names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return names;
}

pub fn ensureModel(self: *Copilot) !void {
    try self.loadModels();
    if (self.model.len == 0) {
        for (self.models.?) |entry| {
            _ = entry.wire() catch continue;
            return self.setModel(entry.id);
        }
        return error.NoCopilotModels;
    }
    try self.applyModel();
}

pub fn setModel(self: *Copilot, name: []const u8) !void {
    try self.loadModels();
    for (self.models.?) |entry| {
        if (!std.mem.eql(u8, entry.id, name)) continue;
        _ = try entry.wire();
        self.model = entry.id;
        try self.applyModel();
        return;
    }
    return error.UnknownCopilotModel;
}

fn applyModel(self: *Copilot) !void {
    for (self.models orelse return error.NoCopilotModels) |entry| {
        if (!std.mem.eql(u8, entry.id, self.model)) continue;
        self.inner.wire = try entry.wire();
        self.model = entry.id;
        self.inner.model = entry.id;
        self.inner.supports_tools = entry.capabilities.supports.tool_calls;
        self.inner.supports_vision = entry.capabilities.supports.vision;
        self.inner.context_limit = if (entry.capabilities.limits.max_context_window_tokens > 0)
            entry.capabilities.limits.max_context_window_tokens
        else
            entry.capabilities.limits.max_prompt_tokens;
        self.inner.max_output_tokens = entry.capabilities.limits.max_output_tokens;
        return;
    }
    return error.UnknownCopilotModel;
}

pub fn reconnect(self: *Copilot, connection: Provider.Connection) !void {
    var replacement: Copilot = blk: {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        break :blk .{
            .allocator = self.allocator,
            .io = self.io,
            .host = try a.dupe(u8, connection.host),
            .label = try a.dupe(u8, connection.label),
            .api_key = if (connection.api_key) |key| try a.dupe(u8, key) else null,
            .debug_log = self.debug_log,
            .integration_id = self.integration_id,
            .connection_arena = arena,
        };
    };
    errdefer replacement.deinit();
    try replacement.start();
    try replacement.ensureModel();
    self.deinit();
    self.* = replacement;
    self.relocate();
}

pub fn relocate(self: *Copilot) void {
    if (self.started) self.inner.extra_headers = &self.headers;
}

pub fn signOut(self: *Copilot) void {
    const allocator = self.allocator;
    const io = self.io;
    const debug_log = self.debug_log;
    const integration_id = self.integration_id;
    self.deinit();
    self.* = .{ .allocator = allocator, .io = io, .debug_log = debug_log, .integration_id = integration_id };
}

pub fn current(self: *Copilot) Provider.Current {
    if (!self.started) return .{ .name = self.label, .model = self.model, .context_limit = 0, .vision = false };
    return self.inner.current();
}

pub fn provider(self: *Copilot) Provider {
    const now = self.current();
    return .{ .name = now.name, .model = now.model, .context_limit = now.context_limit, .vision = now.vision, .userdata = self, .respond = respond, .list_models = listErased, .set_model = setErased, .refresh = refreshErased, .describe_error = describeErased, .abort = abortErased };
}

fn respond(ptr: *anyopaque, convo: *Conversation, turn: Provider.Turn, allocator: std.mem.Allocator, sink: ?Provider.Sink) !Provider.Reply {
    const self: *Copilot = @ptrCast(@alignCast(ptr));
    if (self.api_key == null) return error.NotSignedIn;
    if (self.models == null) return error.CopilotCatalogUnavailable;
    try self.applyModel();
    const agent_initiated = turn.instruction.len > 0 or if (convo.last()) |last| last.role != .user else false;
    var vision = false;
    if (self.inner.supports_vision) {
        for (convo.messages.items) |message| {
            if (message.images.len > 0) {
                vision = true;
                break;
            }
        }
    }
    var headers = self.headers ++ [_]std.http.Header{
        .{ .name = "X-Initiator", .value = if (agent_initiated) "agent" else "user" },
        .{ .name = "X-Interaction-Type", .value = if (turn.instruction.len > 0) "conversation-compaction" else "conversation-agent" },
        .{ .name = "X-Interaction-Id", .value = &self.interaction_id },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "Copilot-Vision-Request", .value = "true" },
    };
    self.inner.extra_headers = headers[0 .. headers.len - @as(usize, if (vision) 0 else 1)];
    defer self.relocate();
    const inner = self.inner.provider();
    return inner.respond(inner.userdata, convo, turn, allocator, sink);
}
fn listErased(ptr: *anyopaque, allocator: std.mem.Allocator) ![][]const u8 {
    const self: *Copilot = @ptrCast(@alignCast(ptr));
    return self.listModels(allocator);
}
fn setErased(ptr: *anyopaque, name: []const u8) !Provider.Current {
    const self: *Copilot = @ptrCast(@alignCast(ptr));
    try self.setModel(name);
    return self.current();
}
fn refreshErased(ptr: *anyopaque) Provider.Current {
    const self: *Copilot = @ptrCast(@alignCast(ptr));
    return self.current();
}
fn describeErased(ptr: *anyopaque, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    const self: *Copilot = @ptrCast(@alignCast(ptr));
    return self.describeError(err, allocator);
}

pub fn describeError(self: *Copilot, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    const explanation: ?[]const u8 = switch (err) {
        error.NotSignedIn, error.CopilotSessionExpired => "Sign in to GitHub Copilot with ctrl+p. Use /logout first to replace a rejected credential.",
        error.CopilotAccessDenied, error.CopilotNotEntitled => "GitHub denied Copilot access. Check your organization seat, model policy, and OAuth application policy.",
        error.CopilotCatalogUnavailable => "Copilot model discovery has not succeeded. Reconnect GitHub Copilot with ctrl+p to retry.",
        error.NoCopilotModels => "Copilot returned no enabled tool-capable chat models for this account.",
        error.UnknownCopilotModel => "This model is not in your account's enabled Copilot catalog. Choose a model with ctrl+o.",
        error.UnsupportedCopilotEndpoint => "This Copilot model advertises an API protocol synth does not support.",
        error.InvalidCopilotIntegrationId => "SYNTH_COPILOT_INTEGRATION_ID must contain only non-empty visible ASCII without spaces.",
        else => null,
    };
    if (explanation) |text| return allocator.dupe(u8, text);
    if (self.started) return self.inner.describeError(err, allocator);
    return allocator.dupe(u8, @errorName(err));
}
fn abortErased(ptr: *anyopaque) void {
    const self: *Copilot = @ptrCast(@alignCast(ptr));
    if (self.started) self.inner.abort();
}

test "failed Copilot reconnection preserves the old client and releases staged credentials" {
    const testing = std.testing;
    var copilot: Copilot = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .model = "original-model",
        .integration_id = "my-product-agent",
        .api_key = "example",
    };
    defer copilot.deinit();
    try copilot.start();
    try testing.expectError(error.NotSignedIn, copilot.reconnect(.{
        .host = auth.api_host,
        .label = "Replacement",
    }));
    try testing.expectEqualStrings("original-model", copilot.current().model);
    try testing.expectEqualStrings("my-product-agent", copilot.integration_id);
    try testing.expectEqualStrings("my-product-agent", copilot.inner.extra_headers[1].value);
    try testing.expectEqualStrings("Bearer example", copilot.inner.auth_value);
    copilot.signOut();
    try testing.expect(copilot.api_key == null);
    try testing.expect(!copilot.started);
    try testing.expectEqualStrings("my-product-agent", copilot.integration_id);
    try testing.expectError(error.NotSignedIn, copilot.ensureModel());
}

test "Copilot rejects an unsafe integration profile before starting a client" {
    var copilot: Copilot = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .integration_id = "bad\r\nInjected:yes",
    };
    defer copilot.deinit();
    try std.testing.expectError(error.InvalidCopilotIntegrationId, copilot.start());
    try std.testing.expect(!copilot.started);
}

test "Copilot catalog applies protocol, vision and limits without another request" {
    const testing = std.testing;
    var copilot: Copilot = .{ .allocator = testing.allocator, .io = testing.io };
    defer copilot.deinit();
    try copilot.start();
    const entries = [_]Model{
        .{ .id = "org-claude", .supported_endpoints = &.{"/v1/messages"}, .capabilities = .{
            .limits = .{ .max_context_window_tokens = 200000, .max_output_tokens = 16000 },
            .supports = .{ .vision = true },
        } },
        .{ .id = "org-gpt", .supported_endpoints = &.{"/responses"} },
    };
    copilot.models = &entries;
    try copilot.setModel("org-claude");
    try testing.expectEqual(OpenAI.Wire.messages, copilot.inner.wire);
    try testing.expect(copilot.current().vision);
    try testing.expectEqual(@as(u32, 200000), copilot.current().context_limit);
    try testing.expectEqual(@as(u32, 16000), copilot.inner.max_output_tokens);
    try copilot.setModel("org-gpt");
    try testing.expectEqual(OpenAI.Wire.responses, copilot.inner.wire);
    try testing.expect(!copilot.current().vision);
    try testing.expectError(error.UnknownCopilotModel, copilot.setModel("not-offered"));
    try testing.expectEqualStrings("org-gpt", copilot.current().model);
    const unsupported: Model = .{ .id = "future", .supported_endpoints = &.{"/unknown"} };
    try testing.expectError(error.UnsupportedCopilotEndpoint, unsupported.wire());
}

test "Copilot picker visibility does not determine model access" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const models = try parseModels(arena.allocator(),
        \\{"data":[
        \\ {"id":"gpt-4o","model_picker_enabled":false,"supported_endpoints":null,"policy":null,"capabilities":{"type":"chat","limits":{"max_context_window_tokens":128000,"max_output_tokens":4096,"max_prompt_tokens":64000},"supports":{"tool_calls":true,"vision":true}}},
        \\ {"id":"gpt-41-copilot","model_picker_enabled":false,"capabilities":{"type":"completion","limits":null,"supports":{"streaming":true}}},
        \\ {"id":"denied","model_picker_enabled":false,"policy":{"state":"disabled"}}
        \\]}
    );
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("gpt-4o", models[0].id);
    try std.testing.expectEqual(OpenAI.Wire.chat, try models[0].wire());
}

test "Copilot discovers new organization model IDs and their advertised protocols" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const models = try parseModels(arena.allocator(),
        \\{"data":[
        \\ {"id":"claude-new-org","supported_endpoints":["/v1/messages"],"capabilities":{"supports":{"tool_calls":true,"vision":true},"limits":{"max_context_window_tokens":200000}}},
        \\ {"id":"gpt-new-org","supported_endpoints":["/responses"]},
        \\ {"id":"gemini-new-org","supported_endpoints":["/chat/completions"]},
        \\ {"id":"disabled","policy":{"state":"disabled"}},
        \\ {"id":"hidden","model_picker_enabled":false},
        \\ {"id":"embedding","capabilities":{"type":"embeddings"}},
        \\ {"id":"no-tools","capabilities":{"supports":{"tool_calls":false}}},
        \\ {"id":12}
        \\]}
    );
    try std.testing.expectEqual(@as(usize, 4), models.len);
    try std.testing.expectEqualStrings("hidden", models[3].id);
    try std.testing.expectEqual(OpenAI.Wire.messages, try models[0].wire());
    try std.testing.expectEqual(OpenAI.Wire.responses, try models[1].wire());
    try std.testing.expectEqual(OpenAI.Wire.chat, try models[2].wire());
    try std.testing.expectEqual(@as(u32, 200000), models[0].capabilities.limits.max_context_window_tokens);
}
