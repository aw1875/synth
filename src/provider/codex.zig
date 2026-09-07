//! Native client for the ChatGPT Codex subscription backend.

const std = @import("std");

const pkg = @import("pkg");

const Auth = @import("../core/auth.zig");
const Conversation = @import("../core/conversation.zig");
const Models = @import("models.zig");
const OpenAI = @import("openai.zig");
const Provider = @import("provider.zig");
const auth_flow = @import("codex_auth.zig");
const humanize = @import("../core/humanize.zig");
const retry = @import("retry.zig");
const window = @import("window.zig");

const CodexProvider = @This();

allocator: std.mem.Allocator,
io: std.Io,
auth: *Auth,
/// The backend is not user configurable; this exists so tests can serve the
/// wire contract from a loopback listener.
host: []const u8 = auth_flow.backend_url,
model: []const u8 = "",
models: ?*Models = null,
context_limit: u32 = 0,
supports_vision: bool = true,
owned_model: ?[]u8 = null,
debug_log: ?[]const u8 = null,
retries: retry.Policy = .{},
/// Null until the first request; the optional is what says "not started yet".
client: ?std.http.Client = null,
last_error: ?[]u8 = null,
session_id: ?[32]u8 = null,
last_message_count: u64 = 0,
/// The socket a turn is parked on, so a cancel can break it. A worker waiting
/// on a silent stream never notices a flag; shutting the socket down is what
/// makes the read return.
live_socket: std.posix.fd_t = no_socket,
socket_lock: std.Io.Mutex = .init,
aborted: bool = false,

// The backend gates its model list on the client version, and synth's own
// version returns an empty catalog, so this reports a Codex release instead.
// Raising it can change which models come back, which is why the catalog is
// keyed by it below.
const codex_client_version = "0.153.0";
/// Cache identity for the catalog. The version belongs in the key: a list
/// fetched under one is not an answer for another.
pub const codex_catalog_namespace = "codex/" ++ codex_client_version;
/// No request in flight.
const no_socket: std.posix.fd_t = -1;
const max_body_bytes: usize = 4 * 1024 * 1024;
const transfer_buffer_bytes: usize = 512 * 1024;

pub fn start(self: *CodexProvider) !void {
    if (self.client != null) return;
    self.client = .{ .allocator = self.allocator, .io = self.io };
    // The catalog decides the model, and it is reachable again on every later
    // call; a backend that is down at launch must not stop the app opening.
    self.ensureModel() catch {};
}

pub fn startLike(self: *CodexProvider, other: *const CodexProvider) !void {
    self.client = .{ .allocator = self.allocator, .io = self.io };
    self.context_limit = other.context_limit;
    self.supports_vision = other.supports_vision;
}

pub fn deinit(self: *CodexProvider) void {
    self.clearLastError();
    if (self.client) |*client| client.deinit();
    if (self.owned_model) |model| self.allocator.free(model);
}

pub fn provider(self: *CodexProvider) Provider {
    return .{
        .name = "Codex Subscription",
        .model = self.model,
        .context_limit = self.context_limit,
        .vision = self.supports_vision,
        .userdata = self,
        .respond = respond,
        .list_models = listModelsErased,
        .set_model = setModelErased,
        .refresh = currentErased,
        .describe_error = describeErrorErased,
        .abort = abortErased,
    };
}

fn listModelsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    return self.listModels(allocator);
}

fn setModelErased(ptr: *anyopaque, name: []const u8) anyerror!Provider.Current {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    try self.setModel(name);
    return self.current();
}

pub fn current(self: *CodexProvider) Provider.Current {
    return .{
        .model = self.model,
        .name = "Codex Subscription",
        .context_limit = self.context_limit,
        .vision = self.supports_vision,
    };
}

fn currentErased(ptr: *anyopaque) Provider.Current {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    return self.current();
}

/// Break off the request in flight. Safe to call when there is none.
pub fn abort(self: *CodexProvider) void {
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.aborted = true;
    self.shutdownLocked();
}

fn shutdownLocked(self: *CodexProvider) void {
    if (self.live_socket == no_socket) return;
    self.io.vtable.netShutdown(self.io.userdata, self.live_socket, .both) catch {};
    self.live_socket = no_socket;
}

/// Worker thread. What `abort` shuts down until `forgetSocket` takes it back.
fn watch(self: *CodexProvider, request: *std.http.Client.Request) void {
    const connection = request.connection orelse return;
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.live_socket = connection.stream_reader.stream.socket.handle;
    if (self.aborted) self.shutdownLocked();
}

/// Worker thread. A new turn is not the cancelled one.
fn armSocket(self: *CodexProvider) void {
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.aborted = false;
    self.live_socket = no_socket;
}

/// Worker thread. Must run before the request is torn down.
fn forgetSocket(self: *CodexProvider) void {
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.live_socket = no_socket;
}

fn abortErased(ptr: *anyopaque) void {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    self.abort();
}

fn describeErrorErased(ptr: *anyopaque, err: anyerror, allocator: std.mem.Allocator) anyerror![]const u8 {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    return self.describeError(err, allocator);
}

pub fn reconnect(self: *CodexProvider, _: Provider.Connection) !void {
    if (self.client == null) try self.start();
}

pub fn ensureModel(self: *CodexProvider) !void {
    if (self.model.len > 0) return self.setModel(self.model);
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const entries = try self.catalogModels(arena_state.allocator());
    for (entries) |entry| {
        if (!entry.visible) continue;
        return self.setModel(entry.id);
    }
    return error.NoModelsAvailable;
}

pub fn setModel(self: *CodexProvider, name: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const entries = try self.catalogModels(arena_state.allocator());
    const metadata = Models.findModel(entries, name) orelse return error.ModelNotAvailable;
    // UI snapshots borrow this name; revalidation must keep it alive.
    const model_changed = !std.mem.eql(u8, name, self.model);
    if (model_changed) {
        const owned_model = try self.allocator.dupe(u8, name);
        if (self.owned_model) |previous_model| self.allocator.free(previous_model);
        self.owned_model = owned_model;
        self.model = owned_model;
    }
    self.context_limit = metadata.context_limit;
    self.supports_vision = metadata.vision orelse true;
}

pub fn listModels(self: *CodexProvider, allocator: std.mem.Allocator) ![][]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    return Models.copyVisibleModelNames(allocator, try self.catalogModels(arena_state.allocator()));
}

fn catalogModels(self: *CodexProvider, arena: std.mem.Allocator) ![]const Models.Info {
    if (self.models) |models| {
        const tokens = try auth_flow.loadTokens(arena, self.auth);
        return models.getOrFetchCatalog(codex_catalog_namespace, self.host, tokens.account_id, self);
    }
    return self.fetchModels(arena);
}

pub fn fetchModels(self: *CodexProvider, arena: std.mem.Allocator) ![]const Models.Info {
    if (self.client == null) {
        const is_signed_in = self.auth.key(auth_flow.provider_id) != null;
        if (!is_signed_in) return error.NotSignedIn;
        self.client = .{ .allocator = self.allocator, .io = self.io };
    }
    const client = if (self.client) |*started_client| started_client else return error.NotSignedIn;
    const tokens = try auth_flow.ensureFreshTokens(arena, self.io, self.auth);
    const request_url = try std.fmt.allocPrint(arena, "{s}/models?client_version={s}", .{ self.host, codex_client_version });
    const uri = std.Uri.parse(request_url) catch return error.InvalidHost;
    const authorization_header = try std.fmt.allocPrint(arena, "Bearer {s}", .{tokens.access_token});
    const extra_headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Originator", .value = pkg.name },
    };
    const account_headers = [_]std.http.Header{
        .{ .name = "ChatGPT-Account-ID", .value = tokens.account_id },
    };
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{
            .authorization = .{ .override = authorization_header },
            .user_agent = .{ .override = auth_flow.userAgent() },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &extra_headers,
        .privileged_headers = &account_headers,
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const transfer_buffer = try arena.alloc(u8, 64 * 1024);
    const response_body = try response.reader(transfer_buffer).allocRemaining(arena, .limited(max_body_bytes));
    const request_succeeded = response.head.status.class() == .success;
    if (!request_succeeded) {
        self.rememberHttpError(response.head.status, response_body);
        return error.HttpError;
    }
    return parseModels(arena, response_body);
}

fn parseModels(arena: std.mem.Allocator, response_body: []const u8) ![]const Models.Info {
    const Entry = struct {
        slug: []const u8,
        visibility: []const u8 = "list",
        context_window: u32,
        effective_context_window_percent: u8 = 100,
        input_modalities: ?[]const []const u8 = null,
    };
    const catalog = std.json.parseFromSliceLeaky(struct { models: []const Entry }, arena, response_body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.UnexpectedResponse;
    const entries = try arena.alloc(Models.Info, catalog.models.len);
    for (catalog.models, entries) |entry, *out| {
        const invalid_limit = entry.context_window == 0 or entry.effective_context_window_percent == 0 or entry.effective_context_window_percent > 100;
        if (entry.slug.len == 0 or invalid_limit) return error.UnexpectedResponse;
        out.* = .{
            .id = entry.slug,
            .context_limit = @intCast(@as(u64, entry.context_window) * entry.effective_context_window_percent / 100),
            .visible = std.mem.eql(u8, entry.visibility, "list"),
            .vision = if (entry.input_modalities) |modalities| Models.containsString(modalities, "image") else null,
        };
    }
    return entries;
}

fn respond(
    ptr: *anyopaque,
    conversation: *Conversation,
    turn: Provider.Turn,
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
) !Provider.Reply {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    if (self.client == null) try self.start();
    const client = if (self.client) |*started_client| started_client else return error.NotSignedIn;
    self.clearLastError();
    const needs_model_metadata = self.model.len == 0 or self.context_limit == 0;
    if (needs_model_metadata) try self.ensureModel();

    self.armSocket();
    var attempt: usize = 1;
    var token_was_refreshed = false;
    var provider_state_was_reset = false;
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const tokens = try auth_flow.ensureFreshTokens(arena, self.io, self.auth);
        const request_body = try self.buildResponseRequestBody(arena, conversation, turn);
        const request_url = try std.fmt.allocPrint(arena, "{s}/responses", .{self.host});
        const uri = std.Uri.parse(request_url) catch return error.InvalidHost;
        const authorization_header = try std.fmt.allocPrint(arena, "Bearer {s}", .{tokens.access_token});
        const session_id = self.sessionIdForConversation(conversation);
        const extra_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "Originator", .value = pkg.name },
            .{ .name = "session-id", .value = session_id },
            .{ .name = "version", .value = codex_client_version },
        };
        const account_headers = [_]std.http.Header{
            .{ .name = "ChatGPT-Account-ID", .value = tokens.account_id },
        };
        var request = try client.request(.POST, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .headers = .{
                .authorization = .{ .override = authorization_header },
                .user_agent = .{ .override = auth_flow.userAgent() },
                .accept_encoding = .{ .override = "identity" },
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &extra_headers,
            .privileged_headers = &account_headers,
        });
        defer {
            self.forgetSocket();
            request.deinit();
        }
        try request.sendBodyComplete(request_body);
        self.watch(&request);

        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const retry_after_ms = retry.retryAfterMs(findHeaderValue(response.head, "retry-after"));
        const rate_limits = RateLimits.read(arena, response.head);
        const transfer_buffer = try arena.alloc(u8, transfer_buffer_bytes);
        const response_reader = response.reader(transfer_buffer);
        const request_succeeded = response.head.status.class() == .success;

        if (!request_succeeded) {
            const response_body = response_reader.allocRemaining(arena, .limited(max_body_bytes)) catch "";
            if (describeUsageLimit(arena, response_body, rate_limits)) |spent_allowance| {
                self.rememberResponseError(spent_allowance);
            } else {
                self.rememberHttpError(response.head.status, response_body);
            }

            const should_refresh_token = response.head.status == .unauthorized and !token_was_refreshed;
            if (should_refresh_token) {
                _ = try auth_flow.refreshTokens(arena, self.io, self.auth, tokens);
                token_was_refreshed = true;
                continue;
            }

            const stale_reasoning_state = response.head.status == .bad_request and reportsStaleReasoningItem(response_body);
            const should_reset_provider_state = stale_reasoning_state and !provider_state_was_reset;
            if (should_reset_provider_state) {
                discardProviderState(conversation);
                provider_state_was_reset = true;
                continue;
            }

            const will_retry = self.waitBeforeRetry(response.head.status, attempt, retry_after_ms, sink);
            if (will_retry) {
                attempt += 1;
                continue;
            }
            return error.HttpError;
        }

        var response_stream: ResponseStream = .init(allocator, sink, self.model);
        defer response_stream.deinit();
        response_stream.readEvents(arena, response_reader) catch |response_error| {
            const server_reported_error = response_stream.server_error.items.len > 0;
            if (server_reported_error) self.rememberResponseError(response_stream.server_error.items);
            return response_error;
        };
        const reply = try response_stream.intoReply();
        if (self.debug_log) |path| {
            appendDebugLog(self.io, path, "\n=== codex request ===\n{s}\n=== reply ===\ntext: {s}\ncalls: {d}\n", .{
                request_body,
                reply.text,
                reply.tool_calls.len,
            }) catch {}; // Diagnostics must never cost the user a completed turn.
        }
        return reply;
    }
}

/// One metered window. The backend meters two at once: a short rolling window
/// and a long one, and either can be the one that rejected the request.
const RateLimitWindow = struct {
    used_percent: f64,
    window_minutes: ?i64 = null,

    /// The window's own length is the only thing that says what to call it, so
    /// a client that guesses "weekly" is wrong most of the time.
    fn label(self: RateLimitWindow, is_secondary: bool) []const u8 {
        const minutes = self.window_minutes orelse return if (is_secondary) "secondary usage" else "usage";
        const known_windows = [_]struct { minutes: i64, name: []const u8 }{
            .{ .minutes = 5 * 60, .name = "5h" },
            .{ .minutes = 24 * 60, .name = "daily" },
            .{ .minutes = 7 * 24 * 60, .name = "weekly" },
            .{ .minutes = 30 * 24 * 60, .name = "monthly" },
            .{ .minutes = 365 * 24 * 60, .name = "annual" },
        };
        for (known_windows) |known| {
            if (isApproximateWindow(minutes, known.minutes)) return known.name;
        }
        return if (is_secondary) "secondary usage" else "usage";
    }
};

fn isApproximateWindow(minutes: i64, expected_minutes: i64) bool {
    const measured = @max(minutes, 0);
    const lower_bound = @divTrunc(expected_minutes * 95, 100);
    const upper_bound = @divTrunc(expected_minutes * 105, 100);
    return measured >= lower_bound and measured <= upper_bound;
}

/// What the backend says about the caller's allowance. Header strings die the
/// moment a body reader takes over the connection buffer, so this is read while
/// they are still valid.
const RateLimits = struct {
    primary: ?RateLimitWindow = null,
    secondary: ?RateLimitWindow = null,
    /// Owned by the caller's arena; null when the header is absent.
    reached_type: ?[]const u8 = null,

    fn read(arena: std.mem.Allocator, response_head: std.http.Client.Response.Head) RateLimits {
        const reached_type = findHeaderValue(response_head, "x-codex-rate-limit-reached-type");
        return .{
            .primary = readWindow(response_head, "x-codex-primary-used-percent", "x-codex-primary-window-minutes"),
            .secondary = readWindow(response_head, "x-codex-secondary-used-percent", "x-codex-secondary-window-minutes"),
            .reached_type = if (reached_type) |value| (arena.dupe(u8, value) catch null) else null,
        };
    }

    /// The window that rejected the turn is the fuller of the two.
    fn spentWindow(self: RateLimits) ?struct { window: RateLimitWindow, is_secondary: bool } {
        const primary = self.primary orelse {
            const secondary = self.secondary orelse return null;
            return .{ .window = secondary, .is_secondary = true };
        };
        const secondary = self.secondary orelse return .{ .window = primary, .is_secondary = false };
        const secondary_is_fuller = secondary.used_percent > primary.used_percent;
        if (secondary_is_fuller) return .{ .window = secondary, .is_secondary = true };
        return .{ .window = primary, .is_secondary = false };
    }
};

fn readWindow(response_head: std.http.Client.Response.Head, percent_header: []const u8, minutes_header: []const u8) ?RateLimitWindow {
    return parseWindow(findHeaderValue(response_head, percent_header), findHeaderValue(response_head, minutes_header));
}

/// The percent is what says a window exists at all; an unreadable length only
/// costs the window its name.
fn parseWindow(percent_text: ?[]const u8, minutes_text: ?[]const u8) ?RateLimitWindow {
    const percent = percent_text orelse return null;
    const used_percent = std.fmt.parseFloat(f64, percent) catch return null;
    if (!std.math.isFinite(used_percent)) return null;
    const window_minutes = if (minutes_text) |text| std.fmt.parseInt(i64, text, 10) catch null else null;
    return .{ .used_percent = used_percent, .window_minutes = window_minutes };
}

/// A spent allowance arrives as a JSON envelope carrying everything a person
/// needs, so the envelope itself never has to reach the transcript.
fn describeUsageLimit(arena: std.mem.Allocator, response_body: []const u8, limits: RateLimits) ?[]const u8 {
    const Envelope = struct {
        @"error": struct {
            type: []const u8 = "",
            resets_in_seconds: ?u64 = null,
        } = .{},
    };
    const envelope = std.json.parseFromSliceLeaky(Envelope, arena, response_body, .{ .ignore_unknown_fields = true }) catch return null;
    const allowance_is_spent = std.mem.eql(u8, envelope.@"error".type, "usage_limit_reached");
    if (!allowance_is_spent) return null;

    if (workspaceLimitMessage(limits.reached_type)) |message| return arena.dupe(u8, message) catch null;

    const spent = limits.spentWindow();
    const limit_label = if (spent) |spent_window| spent_window.window.label(spent_window.is_secondary) else "usage";
    const resets_in_seconds = envelope.@"error".resets_in_seconds orelse
        return std.fmt.allocPrint(arena, "your Codex {s} limit is used up.", .{limit_label}) catch null;
    var duration_buffer: [humanize.duration_bytes]u8 = undefined;
    const resets_in = humanize.duration(&duration_buffer, resets_in_seconds * std.time.ms_per_s);
    return std.fmt.allocPrint(arena, "your Codex {s} limit is used up. It resets in {s}.", .{ limit_label, resets_in }) catch null;
}

/// A workspace rejection is not the caller's own allowance, and the action it
/// calls for is somebody else's, so it never reads as "your limit".
fn workspaceLimitMessage(reached_type: ?[]const u8) ?[]const u8 {
    const reached = reached_type orelse return null;
    const workspace_limits = [_]struct { reached_type: []const u8, message: []const u8 }{
        .{ .reached_type = "workspace_owner_credits_depleted", .message = "your workspace is out of credits. Add credits to continue." },
        .{ .reached_type = "workspace_member_credits_depleted", .message = "your workspace is out of credits. Ask the workspace owner to refill it." },
        .{ .reached_type = "workspace_owner_usage_limit_reached", .message = "you hit the spend cap set on your workspace. Raise it to continue." },
        .{ .reached_type = "workspace_member_usage_limit_reached", .message = "you hit the spend cap set by your workspace owner. Ask an owner to raise it." },
    };
    for (workspace_limits) |limit| {
        if (std.mem.eql(u8, reached, limit.reached_type)) return limit.message;
    }
    return null;
}

/// The key the backend caches a prompt prefix under, so it has to outlive
/// everything that keeps the prefix intact: model switches, subagents, and the
/// UI swapping which conversation it holds. Only starting the history over
/// earns a new one.
fn sessionIdForConversation(self: *CodexProvider, conversation: *Conversation) []const u8 {
    const message_count = conversation.totalCount();
    const history_restarted = message_count < self.last_message_count;
    const needs_new_session_id = self.session_id == null or history_restarted;
    if (needs_new_session_id) {
        var random_bytes: [16]u8 = undefined;
        self.io.random(&random_bytes);
        self.session_id = std.fmt.bytesToHex(random_bytes, .lower);
    }
    self.last_message_count = message_count;
    return &self.session_id.?;
}

fn buildResponseRequestBody(self: *CodexProvider, arena: std.mem.Allocator, conversation: *Conversation, turn: Provider.Turn) ![]u8 {
    const message_budget = window.requestBudget(self.context_limit, turn);
    const messages = try window.completeMessages(conversation, arena, message_budget, self.supports_vision);
    const instructions = try window.systemText(arena, turn.system, messages, 0);
    var request_body: std.Io.Writer.Allocating = .init(arena);
    const writer = &request_body.writer;
    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, self.model);
    try writer.writeAll(",\"instructions\":");
    try writeJsonString(writer, instructions);
    try writer.writeAll(",\"input\":[");
    var is_first_input = true;
    var can_replay_tool_results = false;
    for (messages) |message| {
        const is_instruction_message = message.role == .system or message.role == .summary;
        if (is_instruction_message) continue;
        try self.writeConversationMessage(arena, writer, message, messages, &is_first_input, &can_replay_tool_results);
    }
    const has_turn_instruction = turn.instruction.len > 0;
    if (has_turn_instruction) {
        try writeSeparator(writer, &is_first_input);
        try writeTextMessage(writer, "user", "input_text", turn.instruction);
    }
    try writer.writeByte(']');
    const has_tools = turn.tools_json.len > 2;
    if (has_tools) {
        try writer.writeAll(",\"tools\":");
        try writeToolDefinitions(arena, writer, turn.tools_json);
    }
    try writer.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true,\"reasoning\":{\"summary\":\"auto\"},\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]");
    // The backend reads the cache key from the body. Sent only as a header it
    // is ignored, and every turn is billed as an uncached prompt.
    try writer.writeAll(",\"prompt_cache_key\":");
    try writeJsonString(writer, self.sessionIdForConversation(conversation));
    try writer.writeByte('}');
    return request_body.toOwnedSlice();
}

fn writeConversationMessage(
    self: *CodexProvider,
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: Conversation.Message,
    all_messages: []const Conversation.Message,
    is_first_input: *bool,
    can_replay_tool_results: *bool,
) !void {
    const message_text = try OpenAI.messageContent(arena, message, self.supports_vision);
    switch (message.role) {
        .system, .summary => unreachable,
        .user => {
            can_replay_tool_results.* = false;
            try writeSeparator(writer, is_first_input);
            try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonString(writer, message_text);
            try writer.writeByte('}');
            for (message.images) |image| {
                if (!self.supports_vision) break;
                try writer.writeAll(",{\"type\":\"input_image\",\"image_url\":\"data:");
                try writer.writeAll(OpenAI.imageMime(image));
                try writer.writeAll(";base64,");
                try writer.writeAll(image);
                try writer.writeAll("\"}");
            }
            try writer.writeAll("]}");
        },
        .assistant => {
            can_replay_tool_results.* = false;
            if (message.provider_state) |provider_state| {
                const state_has_tool_calls = try writePreservedResponseItems(arena, writer, provider_state, is_first_input);
                if (state_has_tool_calls) |has_tool_calls| {
                    can_replay_tool_results.* = has_tool_calls;
                    try writeAbandonedCallOutputs(writer, message, all_messages, is_first_input);
                    return;
                }
            }
            const has_text = message_text.len > 0;
            if (has_text) {
                try writeSeparator(writer, is_first_input);
                try writeTextMessage(writer, "assistant", "output_text", message_text);
            }
            // Imported history and reasoning resets still have the canonical
            // calls. Rebuild them so their results remain part of the context.
            for (message.tool_calls) |call| {
                try writeSeparator(writer, is_first_input);
                try std.json.Stringify.value(.{
                    .type = "function_call",
                    .call_id = call.id,
                    .name = call.name,
                    .arguments = call.arguments,
                }, .{}, writer);
            }
            can_replay_tool_results.* = message.tool_calls.len > 0;
            try writeAbandonedCallOutputs(writer, message, all_messages, is_first_input);
        },
        .tool => {
            if (!can_replay_tool_results.*) return;
            const tool_call_id = message.tool_call_id orelse "";
            try writeSeparator(writer, is_first_input);
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try writeJsonString(writer, tool_call_id);
            try writer.writeAll(",\"output\":");
            try writeJsonString(writer, message_text);
            try writer.writeByte('}');
        },
    }
}

/// A call the turn never answered. The backend rejects a call with no output,
/// so an interrupted turn has to say so rather than leave the pair open.
fn writeAbandonedCallOutputs(
    writer: *std.Io.Writer,
    message: Conversation.Message,
    all_messages: []const Conversation.Message,
    is_first_input: *bool,
) !void {
    for (message.tool_calls) |call| {
        if (toolResultExists(all_messages, call.id)) continue;
        try writeSeparator(writer, is_first_input);
        try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
        try writeJsonString(writer, call.id);
        try writer.writeAll(",\"output\":\"aborted\"}");
    }
}

fn toolResultExists(all_messages: []const Conversation.Message, call_id: []const u8) bool {
    for (all_messages) |message| {
        if (message.role != .tool) continue;
        const result_call_id = message.tool_call_id orelse continue;
        if (std.mem.eql(u8, result_call_id, call_id)) return true;
    }
    return false;
}

fn writePreservedResponseItems(arena: std.mem.Allocator, writer: *std.Io.Writer, provider_state: []const u8, is_first_input: *bool) !?bool {
    const saved_state = std.json.parseFromSliceLeaky(struct {
        provider: []const u8 = "",
        items: []const std.json.Value = &.{},
    }, arena, provider_state, .{ .ignore_unknown_fields = true }) catch return null;
    // Reasoning belongs to the thread, not to the model that produced it, so a
    // model switch keeps it. Only another provider's state is unusable.
    const belongs_to_codex = std.mem.eql(u8, saved_state.provider, "codex");
    const has_items = saved_state.items.len > 0;
    const can_replay_state = belongs_to_codex and has_items;
    if (!can_replay_state) return null;

    var contains_tool_call = false;
    for (saved_state.items) |item| {
        const item_type = switch (item) {
            .object => |fields| stringValue(fields.get("type") orelse .null),
            else => null,
        };
        const is_tool_call = if (item_type) |value| std.mem.eql(u8, value, "function_call") else false;
        if (is_tool_call) contains_tool_call = true;
        try writeSeparator(writer, is_first_input);
        try std.json.Stringify.value(item, .{}, writer);
    }
    return contains_tool_call;
}

fn writeToolDefinitions(arena: std.mem.Allocator, writer: *std.Io.Writer, tools_json: []const u8) !void {
    const Definition = struct {
        function: struct { name: []const u8, description: []const u8, parameters: std.json.Value },
    };
    const tools = std.json.parseFromSliceLeaky([]const Definition, arena, tools_json, .{ .ignore_unknown_fields = true }) catch return error.InvalidToolSchema;
    try writer.writeByte('[');
    for (tools, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(.{
            .type = "function",
            .name = entry.function.name,
            .description = entry.function.description,
            .parameters = entry.function.parameters,
        }, .{}, writer);
    }
    try writer.writeByte(']');
}

const ResponseStream = struct {
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
    model: []const u8,
    response_text: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(Conversation.ToolCall) = .empty,
    preserved_items: std.Io.Writer.Allocating,
    usage: Provider.Usage = .{},
    server_error: std.ArrayList(u8) = .empty,
    response_completed: bool = false,
    received_text_delta: bool = false,
    thinking_finished: bool = false,
    /// A summary arrives in parts. Nothing separates them on the wire, so the
    /// first part of the next one has to carry the break itself.
    sent_summary_text: bool = false,

    fn init(allocator: std.mem.Allocator, sink: ?Provider.Sink, model: []const u8) ResponseStream {
        return .{ .allocator = allocator, .sink = sink, .model = model, .preserved_items = .init(allocator) };
    }

    fn deinit(self: *ResponseStream) void {
        self.response_text.deinit(self.allocator);
        for (self.tool_calls.items) |*tool_call| tool_call.deinit(self.allocator);
        self.tool_calls.deinit(self.allocator);
        self.preserved_items.deinit();
        self.server_error.deinit(self.allocator);
    }

    fn readEvents(self: *ResponseStream, arena: std.mem.Allocator, reader: *std.Io.Reader) !void {
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        while (true) {
            if (requestWasCanceled(self.sink)) return error.Canceled;
            const raw_line = reader.takeDelimiter('\n') catch |read_error| switch (read_error) {
                error.StreamTooLong => return error.ResponseTooLong,
                else => |other_error| return other_error,
            } orelse break;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            const is_data_event = std.mem.startsWith(u8, line, "data:");
            if (!is_data_event) continue;
            const event_json = std.mem.trimStart(u8, line[5..], " ");
            const event_is_empty = event_json.len == 0;
            const stream_is_done = std.mem.eql(u8, event_json, "[DONE]");
            const should_ignore_event = event_is_empty or stream_is_done;
            if (should_ignore_event) continue;
            _ = scratch.reset(.retain_capacity);
            const event = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), event_json, .{}) catch continue;
            try self.applyEvent(event);
        }
    }

    fn applyEvent(self: *ResponseStream, event: std.json.Value) !void {
        const event_fields = switch (event) {
            .object => |value| value,
            else => return,
        };
        const event_type = stringValue(event_fields.get("type") orelse return) orelse return;
        const is_text_delta = std.mem.eql(u8, event_type, "response.output_text.delta");
        if (is_text_delta) {
            const text_delta = stringValue(event_fields.get("delta") orelse return) orelse return;
            self.received_text_delta = true;
            return self.appendText(text_delta);
        }
        // A declined request is still the model answering, and it arrives on no
        // other event, so it is read as the reply rather than as a failure.
        const is_refusal_delta = std.mem.eql(u8, event_type, "response.refusal.delta");
        if (is_refusal_delta) {
            const refusal_delta = stringValue(event_fields.get("delta") orelse return) orelse return;
            self.received_text_delta = true;
            return self.appendText(refusal_delta);
        }
        const starts_summary_part = std.mem.eql(u8, event_type, "response.reasoning_summary_part.added");
        if (starts_summary_part) {
            // The first part opens the summary rather than breaking it.
            if (self.sent_summary_text) {
                if (self.sink) |sink| sink.onThinking(sink.userdata, "\n\n");
            }
            return;
        }
        const is_reasoning_summary = std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta");
        const is_reasoning_delta = std.mem.eql(u8, event_type, "response.reasoning_text.delta");
        const is_reasoning_event = is_reasoning_summary or is_reasoning_delta;
        if (is_reasoning_event) {
            const reasoning_delta = stringValue(event_fields.get("delta") orelse return) orelse return;
            if (is_reasoning_summary) self.sent_summary_text = true;
            if (self.sink) |sink| sink.onThinking(sink.userdata, reasoning_delta);
            return;
        }
        const output_item_completed = std.mem.eql(u8, event_type, "response.output_item.done");
        if (output_item_completed) {
            const completed_item = event_fields.get("item") orelse return;
            try self.processCompletedItem(completed_item);
            return;
        }
        const response_completed = std.mem.eql(u8, event_type, "response.completed");
        if (response_completed) {
            self.response_completed = true;
            const completed_response = event_fields.get("response") orelse return;
            self.readUsage(completed_response);
            return;
        }
        const response_failed = std.mem.eql(u8, event_type, "response.failed");
        const response_incomplete = std.mem.eql(u8, event_type, "response.incomplete");
        const response_ended_with_error = response_failed or response_incomplete;
        if (response_ended_with_error) {
            const failure_message = responseFailureMessage(event_fields, event_type);
            try self.server_error.appendSlice(self.allocator, failure_message);
            return if (response_failed) error.ResponseFailed else error.ResponseIncomplete;
        }
    }

    fn processCompletedItem(self: *ResponseStream, item: std.json.Value) !void {
        const has_preserved_items = self.preserved_items.written().len > 0;
        if (has_preserved_items) try self.preserved_items.writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, &self.preserved_items.writer);
        const item_fields = switch (item) {
            .object => |value| value,
            else => return,
        };
        const item_type = stringValue(item_fields.get("type") orelse return) orelse return;
        const is_function_call = std.mem.eql(u8, item_type, "function_call");
        if (is_function_call) {
            self.finishThinking();
            const call_id = stringValue(item_fields.get("call_id") orelse return) orelse return;
            const function_name = stringValue(item_fields.get("name") orelse return) orelse return;
            const arguments = stringValue(item_fields.get("arguments") orelse .{ .string = "{}" }) orelse "{}";
            const owned_id = try self.allocator.dupe(u8, call_id);
            errdefer self.allocator.free(owned_id);
            const owned_name = try self.allocator.dupe(u8, function_name);
            errdefer self.allocator.free(owned_name);
            const owned_arguments = try self.allocator.dupe(u8, arguments);
            errdefer self.allocator.free(owned_arguments);
            try self.tool_calls.append(self.allocator, .{
                .id = owned_id,
                .name = owned_name,
                .arguments = owned_arguments,
            });
            return;
        }
        const is_message = std.mem.eql(u8, item_type, "message");
        const should_read_completed_text = !self.received_text_delta and is_message;
        if (should_read_completed_text) {
            const content_parts = switch (item_fields.get("content") orelse return) {
                .array => |value| value.items,
                else => return,
            };
            for (content_parts) |part| {
                const part_fields = switch (part) {
                    .object => |value| value,
                    else => continue,
                };
                const part_type = stringValue(part_fields.get("type") orelse continue) orelse continue;
                const is_output_text = std.mem.eql(u8, part_type, "output_text");
                if (!is_output_text) continue;
                const text = stringValue(part_fields.get("text") orelse continue) orelse continue;
                try self.appendText(text);
            }
        }
    }

    fn appendText(self: *ResponseStream, text: []const u8) !void {
        const has_text = text.len > 0;
        if (!has_text) return;
        try self.response_text.appendSlice(self.allocator, text);
        if (self.sink) |sink| sink.onText(sink.userdata, text);
        self.finishThinking();
    }

    fn finishThinking(self: *ResponseStream) void {
        if (self.thinking_finished) return;
        self.thinking_finished = true;
        if (self.sink) |sink| sink.onThinkingDone(sink.userdata);
    }

    fn readUsage(self: *ResponseStream, response: std.json.Value) void {
        const response_fields = switch (response) {
            .object => |value| value,
            else => return,
        };
        const usage_fields = switch (response_fields.get("usage") orelse return) {
            .object => |value| value,
            else => return,
        };
        const input_tokens = usage_fields.get("input_tokens") orelse std.json.Value{ .integer = 0 };
        const output_tokens = usage_fields.get("output_tokens") orelse std.json.Value{ .integer = 0 };
        self.usage.prompt_tokens = unsignedIntegerValue(input_tokens);
        self.usage.completion_tokens = unsignedIntegerValue(output_tokens);
        // What the prompt cache actually saved, which is the only way to see
        // whether the cache key and the prefix are doing their job.
        if (usage_fields.get("input_tokens_details")) |details| {
            if (details == .object) {
                if (details.object.get("cached_tokens")) |cached| {
                    self.usage.cached_prompt_tokens = unsignedIntegerValue(cached);
                }
            }
        }
    }

    fn intoReply(self: *ResponseStream) !Provider.Reply {
        if (!self.response_completed) return error.IncompleteStream;
        const has_answer = self.response_text.items.len > 0 or self.tool_calls.items.len > 0;
        if (!has_answer) return error.ReasoningOnly;
        var provider_state: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer provider_state.deinit();
        try provider_state.writer.writeAll("{\"provider\":\"codex\",\"model\":");
        try writeJsonString(&provider_state.writer, self.model);
        try provider_state.writer.writeAll(",\"items\":[");
        try provider_state.writer.writeAll(self.preserved_items.written());
        try provider_state.writer.writeAll("]}");
        var reply: Provider.Reply = .{ .usage = self.usage };
        errdefer reply.deinit(self.allocator);
        reply.text = try self.response_text.toOwnedSlice(self.allocator);
        reply.tool_calls = try self.tool_calls.toOwnedSlice(self.allocator);
        reply.provider_state = try provider_state.toOwnedSlice();
        return reply;
    }
};

fn responseFailureMessage(event_fields: std.json.ObjectMap, fallback: []const u8) []const u8 {
    const response_fields = switch (event_fields.get("response") orelse return fallback) {
        .object => |value| value,
        else => return fallback,
    };
    // A truncated response carries its reason here rather than in an error.
    if (response_fields.get("incomplete_details")) |incomplete_details| {
        if (incomplete_details == .object) {
            if (incomplete_details.object.get("reason")) |reason| {
                if (stringValue(reason)) |truncation_reason| return truncationMessage(truncation_reason);
            }
        }
    }
    const error_fields = switch (response_fields.get("error") orelse return fallback) {
        .object => |value| value,
        else => return fallback,
    };
    const error_message = error_fields.get("message") orelse return fallback;
    return stringValue(error_message) orelse fallback;
}

/// The reason is an open string, so an unknown one is reported rather than
/// flattened into a guess.
fn truncationMessage(reason: []const u8) []const u8 {
    if (std.mem.eql(u8, reason, "content_filter")) return "the response was stopped by a content filter.";
    if (std.mem.eql(u8, reason, "max_output_tokens")) return "the reply hit the model's output limit and was cut off.";
    return reason;
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn unsignedIntegerValue(value: std.json.Value) u32 {
    return switch (value) {
        .integer => |number| @intCast(@max(0, @min(number, std.math.maxInt(u32)))),
        else => 0,
    };
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, writer);
}

fn writeSeparator(writer: *std.Io.Writer, is_first_value: *bool) !void {
    const needs_separator = !is_first_value.*;
    if (needs_separator) try writer.writeByte(',');
    is_first_value.* = false;
}

fn writeTextMessage(writer: *std.Io.Writer, role: []const u8, content_type: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"message\",\"role\":");
    try writeJsonString(writer, role);
    try writer.writeAll(",\"content\":[{\"type\":");
    try writeJsonString(writer, content_type);
    try writer.writeAll(",\"text\":");
    try writeJsonString(writer, text);
    try writer.writeAll("}]}");
}

fn findHeaderValue(response_head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var headers = response_head.iterateHeaders();
    while (headers.next()) |header| {
        const names_match = std.ascii.eqlIgnoreCase(header.name, name);
        if (names_match) return header.value;
    }
    return null;
}

/// Whether a rejection is about the reasoning we replayed.
///
/// Kept deliberately loose. The backend words this several ways and has changed
/// them before; a match that is too exact fails silently, and every later turn
/// then rebuilds the same rejected request, wedging the session for good. The
/// cost of being wrong the other way is one retry without reasoning.
fn reportsStaleReasoningItem(response_body: []const u8) bool {
    const names_a_reasoning_item = std.mem.indexOf(u8, response_body, "rs_") != null;
    if (!names_a_reasoning_item) return false;
    const complaints = [_][]const u8{ "reasoning", "not found", "expired", "required" };
    for (complaints) |complaint| {
        if (std.mem.indexOf(u8, response_body, complaint) != null) return true;
    }
    return false;
}

fn discardProviderState(conversation: *Conversation) void {
    for (conversation.messages.items) |*message| {
        if (message.provider_state) |provider_state| conversation.allocator.free(provider_state);
        message.provider_state = null;
    }
    conversation.reset_provider_state = true;
}

fn waitBeforeRetry(self: *CodexProvider, status: std.http.Status, attempt: usize, retry_after_ms: ?u64, sink: ?Provider.Sink) bool {
    const attempts_exhausted = attempt >= self.retries.attempts;
    // A 429 here is a spent allowance, not momentary congestion. Waiting eight
    // seconds cannot fix it, and retrying only delays telling the user.
    const allowance_is_spent = status == .too_many_requests;
    const status_is_transient = retry.transient(status) and !allowance_is_spent;
    const server_delay_is_too_long = retry.tooLong(self.retries, retry_after_ms);
    const request_can_retry = !attempts_exhausted and status_is_transient and !server_delay_is_too_long;
    const request_was_canceled = requestWasCanceled(sink);
    if (!request_can_retry or request_was_canceled) return false;

    const delay_ms = retry.waitMs(self.retries, attempt, retry_after_ms);
    std.Io.sleep(self.io, .fromMilliseconds(@intCast(delay_ms)), .awake) catch return false;
    if (requestWasCanceled(sink)) return false;
    return true;
}

fn requestWasCanceled(sink: ?Provider.Sink) bool {
    const response_sink = sink orelse return false;
    return response_sink.stopped(response_sink.userdata);
}

fn rememberHttpError(self: *CodexProvider, status: std.http.Status, response_body: []const u8) void {
    self.clearLastError();
    const trimmed_body = std.mem.trim(u8, response_body, " \t\r\n");
    const has_response_body = trimmed_body.len > 0;
    const detail_separator = if (has_response_body) ": " else "";
    const truncated_body = trimmed_body[0..@min(trimmed_body.len, 2048)];
    self.last_error = std.fmt.allocPrint(self.allocator, "{d} {s}{s}{s}", .{
        @intFromEnum(status),
        status.phrase() orelse "",
        detail_separator,
        truncated_body,
    }) catch null;
}

fn rememberResponseError(self: *CodexProvider, message: []const u8) void {
    self.clearLastError();
    const truncated_message = message[0..@min(message.len, 2048)];
    self.last_error = self.allocator.dupe(u8, truncated_message) catch null;
}

fn clearLastError(self: *CodexProvider) void {
    if (self.last_error) |previous_error| self.allocator.free(previous_error);
    self.last_error = null;
}

pub fn describeError(self: *CodexProvider, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    return switch (err) {
        error.NotSignedIn => allocator.dupe(u8, "not signed in. Open interactive synth and choose Codex Subscription in /providers."),
        error.ReasoningOnly => allocator.dupe(u8, "the model finished its turn without replying. Send the message again to continue."),
        error.SignedOut => allocator.dupe(u8, "the Codex sign-in expired. Choose Codex Subscription in /providers to sign in again."),
        error.TokenRefreshFailed => allocator.dupe(u8, "could not refresh the Codex sign-in just now. Your credentials are intact; try again."),
        error.ModelNotAvailable => allocator.dupe(u8, "this model is not in your Codex catalog. Choose an available model with /models."),
        error.NoModelsAvailable => allocator.dupe(u8, "Codex reported no available models. Reconnect with /providers."),
        error.HttpError, error.ResponseFailed, error.ResponseIncomplete => self.describeRejectedRequest(err, allocator),
        else => std.fmt.allocPrint(allocator, "Codex request failed: {s}", .{@errorName(err)}),
    };
}

fn describeRejectedRequest(self: *CodexProvider, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    if (self.last_error) |error_detail| {
        return std.fmt.allocPrint(allocator, "Codex rejected the request: {s}", .{error_detail});
    }
    return std.fmt.allocPrint(allocator, "Codex rejected the request ({s}).", .{@errorName(err)});
}

/// Append diagnostics without reading the existing log into memory. The lock
/// keeps concurrent parent and subagent entries from overwriting each other.
fn appendDebugLog(io: std.Io, path: []const u8, comptime format: []const u8, args: anytype) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.seekTo((try file.stat(io)).size);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

test "Codex debug logging appends without losing earlier entries in a large log" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const previous = try testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer testing.allocator.free(previous);
    @memset(previous, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "debug.log", .data = previous });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "debug.log" });
    defer testing.allocator.free(path);
    try appendDebugLog(testing.io, path, "\n{s}\n", .{"first"});
    try appendDebugLog(testing.io, path, "{s}\n", .{"second"});
    const contents = try tmp.dir.readFileAlloc(testing.io, "debug.log", testing.allocator, .limited(previous.len + 100));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(previous, contents[0..previous.len]);
    try testing.expectEqualStrings("\nfirst\nsecond\n", contents[previous.len..]);
}

test "Codex stream and reply release partial allocations on failure" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            // Force ownership transfers to allocate instead of shrinking in place.
            var no_resize = std.testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
            exercise(no_resize.allocator()) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
        }

        fn exercise(allocator: std.mem.Allocator) !void {
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
                \\{"type":"function_call","call_id":"call-1","name":"read","arguments":"{}"}
            , .{});
            defer parsed.deinit();
            var stream = ResponseStream.init(allocator, null, "model");
            defer stream.deinit();
            try stream.response_text.appendSlice(allocator, "done");
            try stream.processCompletedItem(parsed.value);
            stream.response_completed = true;
            var reply = try stream.intoReply();
            defer reply.deinit(allocator);
            try std.testing.expectEqualStrings("done", reply.text);
            try std.testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
            try std.testing.expectEqualStrings("call-1", reply.tool_calls[0].id);
            try std.testing.expectEqualStrings("read", reply.tool_calls[0].name);
            try std.testing.expectEqualStrings("{}", reply.tool_calls[0].arguments);
            try std.testing.expect(reply.provider_state.?.len > 0);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "Codex replays server items before the matching tool output" {
    const default_model = "test-codex";
    const server_sent_events =
        \\data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1","encrypted_content":"one"}}
        \\data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_2","encrypted_content":"two"}}
        \\data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"read","arguments":"{}"}}
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":4,"output_tokens":3}}}
        \\
    ;
    var event_reader = std.Io.Reader.fixed(server_sent_events);
    var response_stream: ResponseStream = .init(std.testing.allocator, null, default_model);
    defer response_stream.deinit();
    try response_stream.readEvents(std.testing.allocator, &event_reader);
    var reply = try response_stream.intoReply();
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
    try std.testing.expectEqualStrings("read", reply.tool_calls[0].name);

    var auth = Auth.init(std.testing.allocator, std.testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = std.testing.allocator, .io = std.testing.io, .auth = &auth, .model = default_model };
    var conversation = Conversation.init(std.testing.allocator);
    defer conversation.deinit();
    _ = try conversation.append(.{ .role = .assistant, .text = reply.text, .tool_calls = reply.tool_calls, .provider_state = reply.provider_state });
    _ = try conversation.addToolResult("read", "call_1", "ok");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = try @import("../tools/registry.zig").init(std.testing.allocator);
    defer registry.deinit();
    const tools_json = try registry.schemaJson(arena_state.allocator(), &.{"read"});
    const request_body = try codex.buildResponseRequestBody(arena_state.allocator(), &conversation, .{ .system = "brief", .tools_json = tools_json });
    const parsed_request = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), request_body, .{});
    const definitions = parsed_request.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), definitions.len);
    const definition = definitions[0].object;
    try std.testing.expectEqualStrings("function", definition.get("type").?.string);
    try std.testing.expectEqualStrings("read", definition.get("name").?.string);
    try std.testing.expectEqualStrings(registry.get("read").?.description, definition.get("description").?.string);
    try std.testing.expect(definition.get("parameters").?.object.get("properties").?.object.contains("path"));
    const request_items = parsed_request.object.get("input").?.array.items;
    const expected_item_types = [_][]const u8{ "reasoning", "reasoning", "function_call", "function_call_output" };
    try std.testing.expectEqual(expected_item_types.len, request_items.len);
    for (request_items, expected_item_types) |item, expected_type| {
        const item_type = stringValue(item.object.get("type").?) orelse "";
        try std.testing.expectEqualStrings(expected_type, item_type);
    }
    const first_reasoning_id = stringValue(request_items[0].object.get("id").?) orelse "";
    const second_reasoning_id = stringValue(request_items[1].object.get("id").?) orelse "";
    const tool_call_id = stringValue(request_items[3].object.get("call_id").?) orelse "";
    const tool_output = stringValue(request_items[3].object.get("output").?) orelse "";
    try std.testing.expectEqualStrings("rs_1", first_reasoning_id);
    try std.testing.expectEqualStrings("rs_2", second_reasoning_id);
    try std.testing.expectEqualStrings("call_1", tool_call_id);
    try std.testing.expectEqualStrings("ok", tool_output);
}

test "Codex does not accept a reply when the stream closes before completion" {
    var reader = std.Io.Reader.fixed(
        \\data: {"type":"response.output_text.delta","delta":"partial answer"}
        \\
    );
    var stream = ResponseStream.init(std.testing.allocator, null, "model");
    defer stream.deinit();
    try stream.readEvents(std.testing.allocator, &reader);
    try std.testing.expectError(error.IncompleteStream, stream.intoReply());
}

test "Codex keeps tool history after a model switch, import, or reasoning reset" {
    const testing = std.testing;
    const histories = [_]struct { state: ?[]const u8, reset: bool = false }{
        .{ .state = null },
        .{ .state = "{\"provider\":\"other\",\"model\":\"current\",\"items\":[{\"type\":\"reasoning\"}]}" },
        .{ .state = "{\"provider\":\"codex\",\"model\":\"current\",\"items\":[{\"type\":\"reasoning\"}]}", .reset = true },
    };
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = testing.allocator, .io = testing.io, .auth = &auth, .model = "current" };
    var calls = [_]Conversation.ToolCall{
        .{ .id = "read-1", .name = "read", .arguments = "{\"path\":\"first.zig\"}" },
        .{ .id = "read-2", .name = "read", .arguments = "{\"path\":\"second.zig\"}" },
    };
    const outputs = [_][]const u8{ "first file contents", "second file contents" };
    for (histories) |history| {
        var conversation = Conversation.init(testing.allocator);
        defer conversation.deinit();
        _ = try conversation.append(.{ .role = .assistant, .text = "Checking both files.", .tool_calls = &calls, .provider_state = history.state });
        for (calls, outputs) |call, output| _ = try conversation.addToolResult(call.name, call.id, output);
        try conversation.add(.user, "What did those files say?");
        if (history.reset) discardProviderState(&conversation);

        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system = "brief" });
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        const items = parsed.object.get("input").?.array.items;
        try testing.expectEqual(@as(usize, 6), items.len);
        try testing.expectEqualStrings("Checking both files.", items[0].object.get("content").?.array.items[0].object.get("text").?.string);
        for (calls, outputs, 0..) |call, output, index| {
            const sent_call = items[index + 1].object;
            const sent_output = items[index + 3].object;
            try testing.expectEqualStrings("function_call", sent_call.get("type").?.string);
            try testing.expectEqualStrings(call.id, sent_call.get("call_id").?.string);
            try testing.expectEqualStrings(call.name, sent_call.get("name").?.string);
            try testing.expectEqualStrings(call.arguments, sent_call.get("arguments").?.string);
            try testing.expectEqualStrings("function_call_output", sent_output.get("type").?.string);
            try testing.expectEqualStrings(call.id, sent_output.get("call_id").?.string);
            try testing.expectEqualStrings(output, sent_output.get("output").?.string);
        }
    }
}

test "Codex discovers limits for new models and lists only visible models in server order" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = try parseModels(arena_state.allocator(),
        \\{"models":[{"slug":"gpt-new","context_window":272000,"max_context_window":1000000,"effective_context_window_percent":95},{"slug":"gpt-hidden","visibility":"hide","context_window":123000},{"slug":"gpt-old","context_window":128000}]}
    );
    try std.testing.expectEqual(@as(u32, 258400), Models.findModel(entries, "gpt-new").?.context_limit);
    try std.testing.expectEqual(@as(u32, 123000), Models.findModel(entries, "gpt-hidden").?.context_limit);
    try std.testing.expectError(error.UnexpectedResponse, parseModels(arena_state.allocator(), "{\"models\":[{\"slug\":\"new\"}]}"));
    const model_names = try Models.copyVisibleModelNames(std.testing.allocator, entries);
    defer {
        for (model_names) |model_name| std.testing.allocator.free(model_name);
        std.testing.allocator.free(model_names);
    }
    try std.testing.expectEqual(@as(usize, 2), model_names.len);
    try std.testing.expectEqualStrings("gpt-new", model_names[0]);
    try std.testing.expectEqualStrings("gpt-old", model_names[1]);
}

test "starting Codex does not require prior sign-in" {
    var auth = Auth.init(std.testing.allocator, std.testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = std.testing.allocator, .io = std.testing.io, .auth = &auth };
    defer codex.deinit();
    try codex.start();
}

test "a spent allowance reads as a sentence, not as the wire body" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spent =
        \\{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"pro_lite","resets_at":1788749039,"eligible_promo":null,"resets_in_seconds":37086}}
    ;
    const five_hour_window: RateLimits = .{ .primary = .{ .used_percent = 100, .window_minutes = 300 } };
    try std.testing.expectEqualStrings(
        "your Codex 5h limit is used up. It resets in 10h 18m.",
        describeUsageLimit(arena, spent, five_hour_window).?,
    );

    // The fuller window is the one that rejected the turn, and names itself.
    const weekly_is_spent: RateLimits = .{
        .primary = .{ .used_percent = 40, .window_minutes = 300 },
        .secondary = .{ .used_percent = 100, .window_minutes = 10080 },
    };
    try std.testing.expectEqualStrings(
        "your Codex weekly limit is used up. It resets in 10h 18m.",
        describeUsageLimit(arena, spent, weekly_is_spent).?,
    );

    // An unrecognised window length must not be guessed at.
    const odd_window: RateLimits = .{ .primary = .{ .used_percent = 100, .window_minutes = 42 } };
    try std.testing.expectEqualStrings(
        "your Codex usage limit is used up. It resets in 10h 18m.",
        describeUsageLimit(arena, spent, odd_window).?,
    );

    // A workspace rejection is somebody else's to act on.
    const workspace: RateLimits = .{
        .primary = .{ .used_percent = 100, .window_minutes = 300 },
        .reached_type = "workspace_member_usage_limit_reached",
    };
    try std.testing.expectEqualStrings(
        "you hit the spend cap set by your workspace owner. Ask an owner to raise it.",
        describeUsageLimit(arena, spent, workspace).?,
    );

    // Without a reset time the sentence still stands on its own.
    const undated = "{\"error\":{\"type\":\"usage_limit_reached\"}}";
    try std.testing.expectEqualStrings(
        "your Codex 5h limit is used up.",
        describeUsageLimit(arena, undated, five_hour_window).?,
    );

    // Anything else keeps the existing rejection path.
    const nothing_known: RateLimits = .{};
    try std.testing.expect(describeUsageLimit(arena, "{\"error\":{\"type\":\"invalid_request_error\"}}", nothing_known) == null);
    try std.testing.expect(describeUsageLimit(arena, "upstream timeout", nothing_known) == null);
    try std.testing.expect(describeUsageLimit(arena, "", nothing_known) == null);
}

test "a metered window names itself from its own length" {
    // Codex's own tolerance is plus or minus five percent of the nominal window.
    const five_hours: RateLimitWindow = .{ .used_percent = 0, .window_minutes = 300 };
    const nearly_five_hours: RateLimitWindow = .{ .used_percent = 0, .window_minutes = 290 };
    const weekly: RateLimitWindow = .{ .used_percent = 0, .window_minutes = 10080 };
    const unknown_length: RateLimitWindow = .{ .used_percent = 0, .window_minutes = 60 };
    const unreported: RateLimitWindow = .{ .used_percent = 0 };

    try std.testing.expectEqualStrings("5h", five_hours.label(false));
    try std.testing.expectEqualStrings("5h", nearly_five_hours.label(false));
    try std.testing.expectEqualStrings("weekly", weekly.label(false));
    try std.testing.expectEqualStrings("usage", unknown_length.label(false));
    try std.testing.expectEqualStrings("secondary usage", unreported.label(true));
}

test "a declined request reads as the model's answer, not as a failure" {
    var reader = std.Io.Reader.fixed(
        \\data: {"type":"response.refusal.delta","delta":"I can't help with that."}
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":9,"output_tokens":5}}}
        \\
    );
    var stream = ResponseStream.init(std.testing.allocator, null, "model");
    defer stream.deinit();
    try stream.readEvents(std.testing.allocator, &reader);
    var reply = try stream.intoReply();
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("I can't help with that.", reply.text);
}

test "a summary that arrives in parts keeps the parts apart" {
    const Collected = struct {
        thinking: std.ArrayList(u8) = .empty,
        fn onThinking(ptr: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.thinking.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
        fn onText(_: *anyopaque, _: []const u8) void {}
        fn isRunning(_: *anyopaque) bool {
            return false;
        }
    };
    var collected: Collected = .{};
    defer collected.thinking.deinit(std.testing.allocator);
    const sink: Provider.Sink = .{
        .userdata = &collected,
        .onThinking = Collected.onThinking,
        .onText = Collected.onText,
        .stopped = Collected.isRunning,
    };

    // The first part opens the summary; only the second one breaks it.
    var reader = std.Io.Reader.fixed(
        \\data: {"type":"response.reasoning_summary_part.added","item_id":"rs_1","summary_index":0}
        \\data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"Read the config"}
        \\data: {"type":"response.reasoning_summary_part.added","item_id":"rs_1","summary_index":1}
        \\data: {"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":1,"delta":"Patch it"}
        \\data: {"type":"response.output_text.delta","delta":"done"}
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}
        \\
    );
    var stream = ResponseStream.init(std.testing.allocator, sink, "model");
    defer stream.deinit();
    try stream.readEvents(std.testing.allocator, &reader);
    var reply = try stream.intoReply();
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Read the config\n\nPatch it", collected.thinking.items);
}

test "a truncated response says why it stopped" {
    var reader = std.Io.Reader.fixed(
        \\data: {"type":"response.incomplete","response":{"status":"incomplete","error":null,"incomplete_details":{"reason":"content_filter"}}}
        \\
    );
    var stream = ResponseStream.init(std.testing.allocator, null, "model");
    defer stream.deinit();
    try std.testing.expectError(error.ResponseIncomplete, stream.readEvents(std.testing.allocator, &reader));
    try std.testing.expectEqualStrings("the response was stopped by a content filter.", stream.server_error.items);
}

test "a window is read from the header values the backend really sends" {
    // Values lifted from codex's own fixtures for these headers.
    const twelve_and_a_half = parseWindow("12.5", "10").?;
    try std.testing.expectEqual(@as(f64, 12.5), twelve_and_a_half.used_percent);
    try std.testing.expectEqual(@as(i64, 10), twelve_and_a_half.window_minutes.?);
    try std.testing.expectEqualStrings("usage", twelve_and_a_half.label(false));

    const spent = parseWindow("100.0", "10080").?;
    try std.testing.expectEqual(@as(f64, 100), spent.used_percent);
    try std.testing.expectEqualStrings("weekly", spent.label(false));

    // No percent means no window, whatever else the response carries.
    try std.testing.expect(parseWindow(null, "300") == null);
    try std.testing.expect(parseWindow("", "300") == null);
    try std.testing.expect(parseWindow("not-a-number", "300") == null);
    try std.testing.expect(parseWindow("nan", "300") == null);
    try std.testing.expect(parseWindow("inf", "300") == null);

    // An unreadable or absent length leaves a usable window with no name.
    const unnamed = parseWindow("40.0", null).?;
    try std.testing.expectEqual(@as(f64, 40), unnamed.used_percent);
    try std.testing.expect(unnamed.window_minutes == null);
    try std.testing.expectEqualStrings("secondary usage", unnamed.label(true));
    try std.testing.expect(parseWindow("40.0", "later").?.window_minutes == null);
}

test "a rejected turn is read off the wire, headers and all" {
    const testing = std.testing;
    // The header names, and the rule that they must be read before the body
    // reader invalidates them, are only exercised over a real connection.
    const Endpoint = struct {
        server: std.Io.net.Server,

        fn serve(self: *@This()) !void {
            const stream = try self.server.accept(testing.io);
            defer stream.close(testing.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var reader = stream.reader(testing.io, &read_buffer);
            var writer = stream.writer(testing.io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try http.receiveHead();
            try testing.expectEqualStrings("/responses", request.head.target);
            try request.respond(
                \\{"error":{"type":"usage_limit_reached","message":"limit reached","resets_in_seconds":37086}}
            , .{
                .status = .too_many_requests,
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "x-codex-primary-used-percent", .value = "40.0" },
                    .{ .name = "x-codex-primary-window-minutes", .value = "300" },
                    .{ .name = "x-codex-secondary-used-percent", .value = "100.0" },
                    .{ .name = "x-codex-secondary-window-minutes", .value = "10080" },
                },
            });
        }
    };

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var endpoint: Endpoint = .{ .server = try address.listen(testing.io, .{ .mode = .stream }) };
    defer endpoint.server.deinit(testing.io);
    var server_task = try testing.io.concurrent(Endpoint.serve, .{&endpoint});
    defer server_task.cancel(testing.io) catch {};

    const host = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{endpoint.server.socket.address.getPort()});
    defer testing.allocator.free(host);

    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    try auth.set(auth_flow.provider_id, "{\"access_token\":\"t\",\"refresh_token\":\"r\",\"account_id\":\"a\"}");

    var codex: CodexProvider = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .auth = &auth,
        .host = host,
        .model = "gpt-test",
        .context_limit = 128000,
        .retries = .{ .attempts = 1 },
    };
    // Not `start`: resolving the model would spend the listener on a catalog
    // request, and this is about the response path.
    codex.client = .{ .allocator = testing.allocator, .io = testing.io };
    defer codex.deinit();

    var conversation = Conversation.init(testing.allocator);
    defer conversation.deinit();
    _ = try conversation.append(.{ .role = .user, .text = "hello" });

    const provider_value = codex.provider();
    try testing.expectError(error.HttpError, provider_value.respond(
        provider_value.userdata,
        &conversation,
        .{ .system = "brief" },
        testing.allocator,
        null,
    ));

    // The weekly window is the spent one, and it must name itself as weekly.
    const detail = try codex.describeError(error.HttpError, testing.allocator);
    defer testing.allocator.free(detail);
    try testing.expectEqualStrings(
        "Codex rejected the request: your Codex weekly limit is used up. It resets in 10h 18m.",
        detail,
    );
}

test "the prompt cache key rides in the body and survives a model switch" {
    const testing = std.testing;
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = testing.allocator, .io = testing.io, .auth = &auth, .model = "current", .context_limit = 100000 };

    var conversation = Conversation.init(testing.allocator);
    defer conversation.deinit();
    _ = try conversation.append(.{ .role = .user, .text = "first" });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first_body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system = "brief" });
    const first = try std.json.parseFromSliceLeaky(std.json.Value, arena, first_body, .{});
    const first_key = first.object.get("prompt_cache_key").?.string;
    try testing.expect(first_key.len > 0);

    // A model switch must not invalidate the cached prefix.
    codex.model = "other";
    _ = try conversation.append(.{ .role = .user, .text = "second" });
    const second_body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system = "brief" });
    const second = try std.json.parseFromSliceLeaky(std.json.Value, arena, second_body, .{});
    try testing.expectEqualStrings(first_key, second.object.get("prompt_cache_key").?.string);

    // Starting the history over does earn a new key.
    conversation.clear();
    _ = try conversation.append(.{ .role = .user, .text = "fresh" });
    const third_body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system = "brief" });
    const third = try std.json.parseFromSliceLeaky(std.json.Value, arena, third_body, .{});
    try testing.expect(!std.mem.eql(u8, first_key, third.object.get("prompt_cache_key").?.string));
}

test "the cached prefix holds steady across turns and a model switch" {
    const testing = std.testing;
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = testing.allocator, .io = testing.io, .auth = &auth, .model = "current", .context_limit = 100000 };

    var conversation = Conversation.init(testing.allocator);
    defer conversation.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Caching keys off the prompt prefix, so `instructions` has to be byte
    // identical turn over turn or every request pays full price.
    const turn: Provider.Turn = .{ .system = "you are synth" };
    _ = try conversation.append(.{ .role = .user, .text = "first" });
    const first = try std.json.parseFromSliceLeaky(std.json.Value, arena, try codex.buildResponseRequestBody(arena, &conversation, turn), .{});
    const first_instructions = first.object.get("instructions").?.string;

    _ = try conversation.append(.{ .role = .assistant, .text = "answered" });
    _ = try conversation.append(.{ .role = .user, .text = "second" });
    const second = try std.json.parseFromSliceLeaky(std.json.Value, arena, try codex.buildResponseRequestBody(arena, &conversation, turn), .{});
    try testing.expectEqualStrings(first_instructions, second.object.get("instructions").?.string);

    // A model switch keeps the prefix and the key, so the cache survives it.
    codex.model = "other";
    const switched = try std.json.parseFromSliceLeaky(std.json.Value, arena, try codex.buildResponseRequestBody(arena, &conversation, turn), .{});
    try testing.expectEqualStrings(first_instructions, switched.object.get("instructions").?.string);
    try testing.expectEqualStrings(
        first.object.get("prompt_cache_key").?.string,
        switched.object.get("prompt_cache_key").?.string,
    );

    // The first user message stays first, so the prefix after `instructions`
    // is stable too.
    const first_input = second.object.get("input").?.array.items[0].object;
    try testing.expectEqualStrings("user", first_input.get("role").?.string);
    try testing.expectEqualStrings("first", first_input.get("content").?.array.items[0].object.get("text").?.string);
}

test "reasoning recorded under one model is replayed under the next" {
    const testing = std.testing;
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = testing.allocator, .io = testing.io, .auth = &auth, .model = "current" };

    // What a real turn stores: the reasoning and the call it belongs to.
    const recorded_under_previous_model =
        \\{"provider":"codex","model":"previous","items":[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque"},{"type":"function_call","call_id":"read-1","name":"read","arguments":"{}"}]}
    ;
    var calls = [_]Conversation.ToolCall{.{ .id = "read-1", .name = "read", .arguments = "{}" }};

    var conversation = Conversation.init(testing.allocator);
    defer conversation.deinit();
    _ = try conversation.append(.{ .role = .assistant, .text = "checking", .tool_calls = &calls, .provider_state = recorded_under_previous_model });
    _ = try conversation.addToolResult("read", "read-1", "contents");
    try conversation.add(.user, "and?");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system = "brief" });
    const items = (try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{})).object.get("input").?.array.items;

    // Verbatim, in order, and the tool result still lands behind its call.
    const expected_types = [_][]const u8{ "reasoning", "function_call", "function_call_output", "message" };
    try testing.expectEqual(expected_types.len, items.len);
    for (items, expected_types) |item, expected| {
        try testing.expectEqualStrings(expected, item.object.get("type").?.string);
    }
    try testing.expectEqualStrings("rs_1", items[0].object.get("id").?.string);
    try testing.expectEqualStrings("opaque", items[0].object.get("encrypted_content").?.string);
}

test "a call the turn never answered is closed rather than left open" {
    const testing = std.testing;
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = testing.allocator, .io = testing.io, .auth = &auth, .model = "current" };

    // Two calls, one interrupted before its result was recorded.
    var calls = [_]Conversation.ToolCall{
        .{ .id = "read-1", .name = "read", .arguments = "{}" },
        .{ .id = "read-2", .name = "read", .arguments = "{}" },
    };
    var conversation = Conversation.init(testing.allocator);
    defer conversation.deinit();
    _ = try conversation.append(.{ .role = .assistant, .text = "checking", .tool_calls = &calls });
    _ = try conversation.addToolResult("read", "read-1", "contents");
    try conversation.add(.user, "carry on");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system = "brief" });
    const items = (try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{})).object.get("input").?.array.items;

    // Every call is answered, and all calls precede all outputs.
    var last_call_index: usize = 0;
    var first_output_index: usize = items.len;
    var answered_calls: usize = 0;
    for (items, 0..) |item, index| {
        const item_type = item.object.get("type").?.string;
        if (std.mem.eql(u8, item_type, "function_call")) last_call_index = index;
        if (std.mem.eql(u8, item_type, "function_call_output")) {
            if (index < first_output_index) first_output_index = index;
            answered_calls += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), answered_calls);
    try testing.expect(last_call_index < first_output_index);

    for (calls) |call| {
        const expected_output = if (std.mem.eql(u8, call.id, "read-1")) "contents" else "aborted";
        var found = false;
        for (items) |item| {
            const item_type = item.object.get("type").?.string;
            if (!std.mem.eql(u8, item_type, "function_call_output")) continue;
            if (!std.mem.eql(u8, item.object.get("call_id").?.string, call.id)) continue;
            try testing.expectEqualStrings(expected_output, item.object.get("output").?.string);
            found = true;
        }
        try testing.expect(found);
    }
}

test "the cache saving is read back off a completed response" {
    // Shape taken from a real Codex response.
    var reader = std.Io.Reader.fixed(
        \\data: {"type":"response.output_text.delta","delta":"hi"}
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":3038,"input_tokens_details":{"cache_write_tokens":0,"cached_tokens":2560},"output_tokens":6,"total_tokens":3044}}}
        \\
    );
    var stream = ResponseStream.init(std.testing.allocator, null, "model");
    defer stream.deinit();
    try stream.readEvents(std.testing.allocator, &reader);
    var reply = try stream.intoReply();
    defer reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3038), reply.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 2560), reply.usage.cached_prompt_tokens);
    try std.testing.expectEqual(@as(u32, 6), reply.usage.completion_tokens);

    // A provider that reports no details simply saves nothing.
    var bare = std.Io.Reader.fixed(
        \\data: {"type":"response.output_text.delta","delta":"hi"}
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":2}}}
        \\
    );
    var plain = ResponseStream.init(std.testing.allocator, null, "model");
    defer plain.deinit();
    try plain.readEvents(std.testing.allocator, &bare);
    var plain_reply = try plain.intoReply();
    defer plain_reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), plain_reply.usage.cached_prompt_tokens);
}

test "a cancel breaks the socket a silent stream is parked on" {
    const testing = std.testing;
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var codex: CodexProvider = .{ .allocator = testing.allocator, .io = testing.io, .auth = &auth, .model = "current" };
    defer codex.deinit();

    // Nothing in flight: a no-op rather than a shutdown of whatever -1 is.
    codex.abort();
    try testing.expectEqual(no_socket, codex.live_socket);

    // A cancel arriving before the socket exists still takes, on the next watch.
    try testing.expect(codex.aborted);
    codex.armSocket();
    try testing.expect(!codex.aborted);

    // The loop can reach it: the provider seam exposes the abort.
    const provider_value = codex.provider();
    try testing.expect(provider_value.abort != null);
    provider_value.abort.?(provider_value.userdata);
    try testing.expect(codex.aborted);

    codex.forgetSocket();
    try testing.expectEqual(no_socket, codex.live_socket);
}

test "a stale reasoning rejection is recognised however it is worded" {
    // The wordings the backend is known to use.
    try std.testing.expect(reportsStaleReasoningItem(
        \\{"error":{"message":"Item 'fc_1' of type 'function_call' was provided without its required 'reasoning' item: 'rs_1'."}}
    ));
    try std.testing.expect(reportsStaleReasoningItem(
        \\{"error":{"message":"Item with id 'rs_1' not found"}}
    ));
    try std.testing.expect(reportsStaleReasoningItem(
        \\{"error":{"message":"Referenced reasoning item 'rs_1' was not found or has expired"}}
    ));
    try std.testing.expect(reportsStaleReasoningItem(
        \\{"error":{"message":"Item 'rs_1' of type 'reasoning' was provided without its required following item"}}
    ));

    // A rejection that merely echoes an id is not about the reasoning.
    try std.testing.expect(!reportsStaleReasoningItem(
        \\{"error":{"message":"Unsupported parameter 'foo' near item rs_1"}}
    ));
    try std.testing.expect(!reportsStaleReasoningItem(
        \\{"error":{"message":"System messages are not allowed"}}
    ));
    try std.testing.expect(!reportsStaleReasoningItem(""));
}
