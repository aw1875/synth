//! A `Provider` that runs on the user's ChatGPT plan through Sign in with
//! ChatGPT: the public Responses API with an OAuth token in place of a key.
//!
//! The contract: https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
//! and its preview limitations. `store` is always false, so the whole
//! conversation is sent every turn, with each turn's output items replayed
//! as the API returned them.

const std = @import("std");

const Conversation = @import("../core/conversation.zig");
const auth = @import("chatgpt_auth.zig");
const log_file = @import("log_file.zig");
const OpenAI = @import("openai.zig");
const Provider = @import("provider.zig");
const retry = @import("retry.zig");
const responses = @import("responses.zig");
const Refusal = responses.Refusal;
const Failure = responses.Failure;
const ResponseStream = responses.ResponseStream;

const ChatGPTProvider = @This();

allocator: std.mem.Allocator,
io: std.Io,
retries: retry.Policy = .{},
/// Borrowed; owned by whoever opened the credential file, and shared with
/// every client built from it. Null where there is no file to open.
store: ?*auth.Store,
host: []const u8 = auth.resource,
label: []const u8 = default_label,
model: []const u8 = "",
debug_log: ?[]const u8 = null,
context_limit: u32 = 0,
supports_vision: bool = true,

client: std.http.Client = undefined,
started: bool = false,
live_socket: std.posix.fd_t = no_socket,
socket_lock: std.Io.Mutex = .init,
aborted: bool = false,

/// The account's model list, fetched once per client and kept for picking,
/// windows and vision. Lives in `catalog_arena`.
catalog: []const Model = &.{},
catalog_arena: ?std.heap.ArenaAllocator = null,
catalog_lock: std.Io.Mutex = .init,
model_owned: ?[]u8 = null,
label_owned: ?[]u8 = null,
supports_reasoning_summary: bool = true,
/// What the server last said when it refused, owned here. Written on the
/// worker as a turn fails and read on the UI thread after it is joined.
rejection: ?[]u8 = null,
/// The prompt cache key: stable for a conversation so its prefix stays cached,
/// replaced only when the history starts over.
cache_key: ?[32]u8 = null,
last_message_count: u64 = 0,
/// The chosen reasoning effort; empty means the model's own default.
effort_buffer: [16]u8 = undefined,
effort_len: usize = 0,

/// What the sidebar calls this backend. The guidelines ask that using the
/// plan be visible beside the model.
pub const default_label = "ChatGPT plan";
const no_socket: std.posix.fd_t = -1;
const max_body_bytes: usize = 4 * 1024 * 1024;
const max_rejection_bytes: usize = 2 * 1024;
const transfer_buffer_bytes: usize = 64 * 1024;
const aborted_call_output = "aborted";
const models_url = auth.resource ++ "/models";
const responses_url = auth.resource ++ "/responses";

pub const Model = struct {
    slug: []const u8,
    context_window: u32 = 0,
    vision: bool = true,
    efforts: []const []const u8 = &.{},
    default_effort: []const u8 = "",
    accepts_summary: bool = true,
};

/// Catalog levels that are a mode of Codex's rather than a value the API
/// takes: `ultra` delegates to several agents. Codex never sends it either;
/// see `resolve_reasoning_effort` in openai/codex.
const codex_only_levels = [_][]const u8{"ultra"};

pub fn start(self: *ChatGPTProvider) !void {
    self.startClient();
    if (self.model.len > 0) self.loadCatalog(false) catch {};
}

fn startClient(self: *ChatGPTProvider) void {
    if (self.started) return;
    self.client = .{ .allocator = self.allocator, .io = self.io };
    self.started = true;
}

pub fn startLike(self: *ChatGPTProvider, other: *const ChatGPTProvider) !void {
    self.startClient();
    self.context_limit = other.context_limit;
    self.supports_vision = other.supports_vision;
    self.supports_reasoning_summary = other.supports_reasoning_summary;
    self.effort_buffer = other.effort_buffer;
    self.effort_len = other.effort_len;
}

pub fn deinit(self: *ChatGPTProvider) void {
    if (self.rejection) |rejection| self.allocator.free(rejection);
    if (self.started) self.client.deinit();
    if (self.catalog_arena) |*arena| arena.deinit();
    if (self.model_owned) |owned| self.allocator.free(owned);
    if (self.label_owned) |owned| self.allocator.free(owned);
}

pub fn provider(self: *ChatGPTProvider) Provider {
    return .{
        .name = self.label,
        .model = self.model,
        .context_limit = self.context_limit,
        .vision = self.supports_vision,
        .userdata = self,
        .respond = respond,
        .list_models = listModelsErased,
        .set_model = setModelErased,
        .describe_error = describeErrorErased,
        .refresh = currentErased,
        .reconnect = reconnectErased,
        .abort = abortErased,
        .efforts = effortsErased,
        .set_effort = setEffortErased,
        .effort = self.effectiveEffort(),
    };
}

pub fn current(self: *ChatGPTProvider) Provider.Current {
    return .{
        .model = self.model,
        .name = self.label,
        .context_limit = self.context_limit,
        .vision = self.supports_vision,
        .effort = self.effectiveEffort(),
    };
}

fn effortsErased(ptr: *anyopaque, slug: []const u8) Provider.Efforts {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    return self.efforts(slug);
}

fn setEffortErased(ptr: *anyopaque, level: []const u8) void {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    self.setEffort(level);
}

pub fn abort(self: *ChatGPTProvider) void {
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.aborted = true;
    self.shutdownLocked();
}

fn shutdownLocked(self: *ChatGPTProvider) void {
    if (self.live_socket == no_socket) return;
    self.io.vtable.netShutdown(self.io.userdata, self.live_socket, .both) catch {};
    self.live_socket = no_socket;
}

fn watch(self: *ChatGPTProvider, request: *std.http.Client.Request) void {
    const connection = request.connection orelse return;
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.live_socket = connection.stream_reader.stream.socket.handle;
    if (self.aborted) self.shutdownLocked();
}

fn armSocket(self: *ChatGPTProvider) void {
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.aborted = false;
    self.live_socket = no_socket;
}

fn forgetSocket(self: *ChatGPTProvider) void {
    self.socket_lock.lockUncancelable(self.io);
    defer self.socket_lock.unlock(self.io);
    self.live_socket = no_socket;
}

fn abortErased(ptr: *anyopaque) void {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    self.abort();
}

fn listModelsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    return self.listModels(allocator);
}

fn setModelErased(ptr: *anyopaque, name: []const u8) anyerror!Provider.Current {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    try self.setModel(name);
    return self.current();
}

fn reconnectErased(ptr: *anyopaque, connection: Provider.Connection) anyerror!Provider.Current {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    try self.reconnect(connection);
    self.ensureModel() catch {};
    return self.current();
}

fn currentErased(ptr: *anyopaque) Provider.Current {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    return self.current();
}

fn describeErrorErased(ptr: *anyopaque, err: anyerror, allocator: std.mem.Allocator) anyerror![]const u8 {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    return self.describeError(err, allocator);
}

/// The host is fixed and the credential lives in the store, so a reconnect
/// only renames the backend and drops what it learned about the account.
pub fn reconnect(self: *ChatGPTProvider, connection: Provider.Connection) !void {
    const label_copy = try self.allocator.dupe(u8, if (connection.label.len > 0) connection.label else default_label);
    if (self.label_owned) |owned| self.allocator.free(owned);
    self.label_owned = label_copy;
    self.label = label_copy;

    if (self.catalog_arena) |*arena| arena.deinit();
    self.catalog_arena = null;
    self.catalog = &.{};
    self.clearRejection();
    try self.start();
}

/// Refused for a slug the catalog holds no entry for, as codex refuses one it
/// does not list. Judged against the catalog fetched at start, never a fetch of
/// its own: without one, the first turn reports a bad slug.
pub fn setModel(self: *ChatGPTProvider, name: []const u8) !void {
    if (std.mem.eql(u8, name, self.model)) return;
    const is_catalog_loaded = self.catalog.len > 0;
    if (is_catalog_loaded and self.catalogEntry(name) == null) return error.UnknownModel;
    const owned = try self.allocator.dupe(u8, name);
    if (self.model_owned) |previous| self.allocator.free(previous);
    self.model_owned = owned;
    self.model = owned;
    self.applyCatalogEntry();
}

/// The first model the account lists, in the server's own order, when none
/// was chosen or the one chosen is no longer listed.
pub fn ensureModel(self: *ChatGPTProvider) !void {
    try self.loadCatalog(false);
    const is_unlisted = self.catalog.len > 0 and self.catalogEntry(self.model) == null;
    if (is_unlisted) self.model = "";
    try self.chooseModel();
}

fn ensureModelForTurn(self: *ChatGPTProvider) !void {
    try self.loadCatalog(true);
    try self.chooseModel();
}

fn chooseModel(self: *ChatGPTProvider) !void {
    if (self.model.len > 0) return self.applyCatalogEntry();
    if (self.catalog.len == 0) return error.NoModels;
    try self.setModel(self.catalog[0].slug);
}

pub fn listModels(self: *ChatGPTProvider, allocator: std.mem.Allocator) ![][]const u8 {
    try self.loadCatalog(false);
    const names = try allocator.alloc([]const u8, self.catalog.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (self.catalog) |entry| {
        names[filled] = try allocator.dupe(u8, entry.slug);
        filled += 1;
    }
    return names;
}

fn applyCatalogEntry(self: *ChatGPTProvider) void {
    const entry = self.catalogEntry(self.model) orelse return;
    self.context_limit = entry.context_window;
    self.supports_vision = entry.vision;
    self.supports_reasoning_summary = entry.accepts_summary;
    if (!containsString(entry.efforts, self.chosenEffort())) self.effort_len = 0;
}

fn catalogEntry(self: *const ChatGPTProvider, slug: []const u8) ?Model {
    for (self.catalog) |entry| {
        if (std.mem.eql(u8, entry.slug, slug)) return entry;
    }
    return null;
}

pub fn efforts(self: *ChatGPTProvider, slug: []const u8) Provider.Efforts {
    self.loadCatalog(false) catch return .{};
    const entry = self.catalogEntry(slug) orelse return .{};
    return .{ .levels = entry.efforts, .default = entry.default_effort };
}

pub fn setEffort(self: *ChatGPTProvider, level: []const u8) void {
    const offered = if (self.catalogEntry(self.model)) |entry| containsString(entry.efforts, level) else false;
    if (!offered or level.len > self.effort_buffer.len) {
        self.effort_len = 0;
        return;
    }
    @memcpy(self.effort_buffer[0..level.len], level);
    self.effort_len = level.len;
}

fn chosenEffort(self: *const ChatGPTProvider) []const u8 {
    return self.effort_buffer[0..self.effort_len];
}

/// What the next request runs at, and what it says it runs at: the chosen
/// level, else the model's default.
fn effectiveEffort(self: *const ChatGPTProvider) []const u8 {
    if (self.effort_len > 0) return self.chosenEffort();
    const entry = self.catalogEntry(self.model) orelse return "";
    return entry.default_effort;
}

fn loadCatalog(self: *ChatGPTProvider, track_turn: bool) !void {
    self.catalog_lock.lockUncancelable(self.io);
    defer self.catalog_lock.unlock(self.io);
    if (self.catalog_arena != null) return;
    self.startClient();

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try self.get(arena, models_url, track_turn);
    self.catalog = try parseCatalog(arena, body);
    self.catalog_arena = arena_state;
    self.applyCatalogEntry();
}

/// The listing shape this route returns: `models`, each with a `slug` and a
/// `visibility` that says whether it belongs in a picker.
fn parseCatalog(arena: std.mem.Allocator, body: []const u8) ![]const Model {
    const Listing = struct {
        models: []const struct {
            slug: []const u8 = "",
            visibility: []const u8 = "",
            context_window: u32 = 0,
            input_modalities: []const []const u8 = &.{},
            supported_reasoning_levels: []const struct { effort: []const u8 = "" } = &.{},
            default_reasoning_level: []const u8 = "",
            supports_reasoning_summary_parameter: bool = true,
        } = &.{},
    };
    const parsed = std.json.parseFromSliceLeaky(Listing, arena, body, .{ .ignore_unknown_fields = true }) catch
        return error.UnexpectedResponse;

    var models: std.ArrayList(Model) = .empty;
    for (parsed.models) |entry| {
        const listed = std.mem.eql(u8, entry.visibility, "list");
        if (!listed or entry.slug.len == 0) continue;
        var levels: std.ArrayList([]const u8) = .empty;
        for (entry.supported_reasoning_levels) |level| {
            if (containsString(&codex_only_levels, level.effort)) continue;
            try levels.append(arena, level.effort);
        }
        const offered = try levels.toOwnedSlice(arena);
        const has_default = containsString(offered, entry.default_reasoning_level);
        try models.append(arena, .{
            .slug = entry.slug,
            .context_window = entry.context_window,
            .vision = containsString(entry.input_modalities, "image"),
            .efforts = offered,
            .default_effort = if (has_default) entry.default_reasoning_level else "",
            .accepts_summary = entry.supports_reasoning_summary_parameter,
        });
    }
    return models.toOwnedSlice(arena);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn get(self: *ChatGPTProvider, arena: std.mem.Allocator, url: []const u8, track_turn: bool) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidHost;

    const store = self.store orelse return error.NotSignedIn;
    var refreshed = false;
    while (true) {
        const token = try store.accessToken(arena);
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});

        var request = try self.client.request(.GET, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .headers = .{ .authorization = .{ .override = authorization }, .accept_encoding = .{ .override = "identity" } },
        });
        defer {
            if (track_turn) self.forgetSocket();
            request.deinit();
        }
        try request.sendBodiless();
        if (track_turn) self.watch(&request);

        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const transfer = try arena.alloc(u8, transfer_buffer_bytes);
        const body = try response.reader(transfer).allocRemaining(arena, .limited(max_body_bytes));

        if (response.head.status == .unauthorized and !refreshed) {
            try store.forceRefresh();
            refreshed = true;
            continue;
        }
        if (response.head.status.class() != .success) {
            self.captureRejection(response.head.status, body);
            return error.HttpError;
        }
        return body;
    }
}

/// Runs on a worker thread; blocking here is expected.
fn respond(
    ptr: *anyopaque,
    convo: *Conversation,
    turn: Provider.Turn,
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
) !Provider.Reply {
    const self: *ChatGPTProvider = @ptrCast(@alignCast(ptr));
    const store = self.store orelse return error.NotSignedIn;
    self.startClient();
    self.clearRejection();
    self.armSocket();
    if (self.model.len == 0 or self.context_limit == 0) self.ensureModelForTurn() catch {};

    var attempt: usize = 1;
    var refreshed = false;
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const token = try store.accessToken(arena);
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
        const body = try self.buildRequest(arena, convo, turn);
        // `sendBodyComplete` uses the body as its write buffer, so it does not survive the send.
        const logged = if (self.debug_log != null) try arena.dupe(u8, body) else "";
        const uri = std.Uri.parse(responses_url) catch return error.InvalidHost;

        const extra_headers = self.requestHeaders();
        var request = try self.client.request(.POST, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .headers = .{
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &extra_headers,
        });
        defer {
            self.forgetSocket();
            request.deinit();
        }
        try request.sendBodyComplete(body);
        self.watch(&request);

        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const retry_after = retry.retryAfterMs(OpenAI.headerValue(response.head, "retry-after"));
        const transfer = try arena.alloc(u8, transfer_buffer_bytes);
        const reader = response.reader(transfer);

        if (response.head.status.class() != .success) {
            const why = reader.allocRemaining(arena, .limited(max_body_bytes)) catch "";
            self.captureRejection(response.head.status, why);
            const refusal = Refusal.parse(arena, why);

            if (response.head.status == .unauthorized and !refreshed) {
                try store.forceRefresh();
                refreshed = true;
                continue;
            }
            if (refusal.isTemporary() and self.waitAndRetry(response.head.status, attempt, retry_after, sink)) {
                attempt += 1;
                continue;
            }
            if (Provider.mentionsOverflow(why)) return error.ContextTooLarge;
            return refusal.toError(response.head.status);
        }

        var stream: ResponseStream = .init(allocator, sink);
        defer stream.deinit();
        stream.readEvents(arena, reader) catch |err| {
            if (stream.failure) |failure| {
                self.rememberFailure(failure);
                return failure.toError();
            }
            const nothing_shown = !stream.delivered_anything;
            if (nothing_shown and self.waitAndRetry(.service_unavailable, attempt, null, sink)) {
                attempt += 1;
                continue;
            }
            return err;
        };
        if (stream.failure) |failure| {
            self.rememberFailure(failure);
            return failure.toError();
        }

        const reply = try stream.intoReply();
        self.log(arena, logged, reply) catch {};
        return reply;
    }
}

fn waitAndRetry(
    self: *ChatGPTProvider,
    status: std.http.Status,
    attempt: usize,
    retry_after_ms: ?u64,
    sink: ?Provider.Sink,
) bool {
    if (attempt >= self.retries.attempts) return false;
    if (status == .too_many_requests) return false;
    if (!retry.transient(status)) return false;
    if (retry.tooLong(self.retries, retry_after_ms)) return false;
    if (stopped(sink)) return false;

    const wait = retry.waitMs(self.retries, attempt, retry_after_ms);
    std.Io.sleep(self.io, .fromMilliseconds(@intCast(wait)), .awake) catch return false;
    return !stopped(sink);
}

fn stopped(sink: ?Provider.Sink) bool {
    const s = sink orelse return false;
    return s.stopped(s.userdata);
}

/// ChatGPT routes a request to the servers holding its cache by the
/// `session-id` header, not by `prompt_cache_key` alone, as Codex notes:
/// https://github.com/openai/codex/blob/main/codex-rs/core/src/client.rs
fn requestHeaders(self: *const ChatGPTProvider) [2]std.http.Header {
    return .{
        .{ .name = "Accept", .value = "text/event-stream" },
        .{ .name = "session-id", .value = &self.cache_key.? },
    };
}

/// Stable for as long as the history only grows, so the prompt prefix keeps
/// hitting the cache across turns, model switches and subagents.
fn cacheKey(self: *ChatGPTProvider, convo: *Conversation) []const u8 {
    const count = convo.totalCount();
    const restarted = count < self.last_message_count;
    if (self.cache_key == null or restarted) {
        var bytes: [16]u8 = undefined;
        self.io.random(&bytes);
        self.cache_key = std.fmt.bytesToHex(bytes, .lower);
    }
    self.last_message_count = count;
    return &self.cache_key.?;
}

fn buildRequest(self: *ChatGPTProvider, arena: std.mem.Allocator, convo: *Conversation, turn: Provider.Turn) ![]u8 {
    return responses.buildRequest(.{
        .model = self.model,
        .context_limit = self.context_limit,
        .supports_vision = self.supports_vision,
        .supports_reasoning_summary = self.supports_reasoning_summary,
        .effort = self.effectiveEffort(),
        .cache_key = self.cacheKey(convo),
    }, arena, convo, turn);
}

fn rememberFailure(self: *ChatGPTProvider, failure: Failure) void {
    self.clearRejection();
    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch.deinit();
    const detail = if (failure.incomplete_reason.len > 0)
        failure.incomplete_reason
    else
        failure.refusal.describe(scratch.allocator(), "") catch return;
    if (detail.len == 0) return;
    self.rejection = self.allocator.dupe(u8, detail[0..@min(detail.len, max_rejection_bytes)]) catch null;
}

fn log(self: *ChatGPTProvider, arena: std.mem.Allocator, body: []const u8, reply: Provider.Reply) !void {
    const path = self.debug_log orelse return;
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("\n=== request ===\n{s}\n=== reply ===\ntext: {s}\ncalls: {d}\n", .{ body, reply.text, reply.tool_calls.len });
    try log_file.writeUsage(&out.writer, reply.usage);
    try log_file.append(self.io, path, out.written());
}

fn captureRejection(self: *ChatGPTProvider, status: std.http.Status, body: []const u8) void {
    self.clearRejection();
    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch.deinit();
    const refusal = Refusal.parse(scratch.allocator(), body);
    const raw_body = std.mem.trim(u8, body, " \t\r\n");
    const said = refusal.describe(scratch.allocator(), raw_body) catch raw_body;
    const kept = said[0..@min(said.len, max_rejection_bytes)];
    self.rejection = std.fmt.allocPrint(self.allocator, "{d} {s}{s}{s}", .{
        @intFromEnum(status),
        status.phrase() orelse "",
        if (kept.len > 0) ": " else "",
        kept,
    }) catch null;
}

fn clearRejection(self: *ChatGPTProvider) void {
    if (self.rejection) |old| self.allocator.free(old);
    self.rejection = null;
}

pub fn describeError(self: *ChatGPTProvider, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    const said = self.rejection orelse "";
    return switch (err) {
        error.Canceled => allocator.dupe(u8, "canceled"),
        error.NotSignedIn, error.SessionExpired => allocator.dupe(u8, "your ChatGPT sign-in has ended. Sign in again from the providers dialog (ctrl+p)."),
        error.RefreshUnavailable => allocator.dupe(u8, "ChatGPT's sign-in service did not answer. Your sign-in is kept; try again in a moment."),
        error.UsageLimitReached => allocator.dupe(u8, "usage limit reached. The limit may be on your ChatGPT plan or on synth's share of it. Manage usage: " ++ auth.usage_url),
        error.UsageUnavailable => allocator.dupe(u8, "ChatGPT could not check your plan's usage right now. Try again in a moment."),
        error.PlanNotEligible => allocator.dupe(u8, "this ChatGPT account or workspace cannot use its plan in other apps. An OpenAI API key works instead: ctrl+p, then OpenAI."),
        error.NotAuthorizedForPlan => allocator.dupe(u8, "this sign-in is not allowed to use your ChatGPT plan. Run /logout, then sign in again and allow plan usage."),
        error.UnsupportedCapability => std.fmt.allocPrint(allocator, "your ChatGPT plan does not support part of this request{s}{s}.", .{
            if (said.len > 0) ": " else "",
            said,
        }),
        error.EmptyResponse => std.fmt.allocPrint(allocator, "`{s}` finished without writing anything.", .{self.model}),
        error.IncompleteStream => allocator.dupe(u8, "the response was cut off before it finished."),
        error.ResponseIncomplete => std.fmt.allocPrint(allocator, "the response stopped early: {s}", .{if (said.len > 0) said else "no reason given"}),
        error.ResponseFailed, error.HttpError => std.fmt.allocPrint(allocator, "{s} rejected the request{s}{s}", .{
            self.label,
            if (said.len > 0) ": " else ".",
            said,
        }),
        error.NoModels => allocator.dupe(u8, "your ChatGPT plan lists no models synth can use."),
        else => std.fmt.allocPrint(allocator, "{s} talking to {s}.", .{ @errorName(err), self.label }),
    };
}

const testing = std.testing;

fn testStore(dir: *std.testing.TmpDir) !*auth.Store {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try dir.dir.realPath(testing.io, &buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "chatgpt.json" });
    defer testing.allocator.free(path);
    return auth.Store.open(testing.allocator, testing.io, path);
}

fn testProvider(store: *auth.Store) ChatGPTProvider {
    return .{ .allocator = testing.allocator, .io = testing.io, .store = store, .model = "gpt-test", .context_limit = 100_000 };
}

test "the catalog keeps what a picker should show, in the server's order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const models = try parseCatalog(arena_state.allocator(),
        \\{"models":[
        \\ {"slug":"gpt-b","visibility":"list","context_window":500000,"input_modalities":["text","image"]},
        \\ {"slug":"gpt-hidden","visibility":"hide","context_window":1},
        \\ {"slug":"gpt-a","visibility":"list","context_window":272000,"input_modalities":["text"]}
        \\]}
    );
    try testing.expectEqual(@as(usize, 2), models.len);
    try testing.expectEqualStrings("gpt-b", models[0].slug);
    try testing.expectEqual(@as(u32, 500000), models[0].context_window);
    try testing.expect(models[0].vision);
    try testing.expect(!models[1].vision);
}

test "instructions go first as a cached developer message, never a system one, and nothing is kept server-side" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hello");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body = try chat.buildRequest(arena_state.allocator(), &convo, .{
        .system = "You are synth.",
        .tools_json =
        \\[{"type":"function","function":{"name":"read","description":"Read a file","parameters":{"type":"object"}}}]
        ,
    });

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    const root = parsed.object;
    try testing.expect(root.get("instructions") == null);
    try testing.expectEqual(false, root.get("store").?.bool);
    try testing.expectEqual(true, root.get("stream").?.bool);
    try testing.expect(root.get("temperature") == null);
    try testing.expect(root.get("max_output_tokens") == null);
    try testing.expect(root.get("previous_response_id") == null);

    const input = root.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 2), input.len);
    try testing.expectEqualStrings("developer", input[0].object.get("role").?.string);
    const brief = input[0].object.get("content").?.array.items[0].object;
    try testing.expectEqualStrings("You are synth.", brief.get("text").?.string);
    try testing.expectEqualStrings("user", input[1].object.get("role").?.string);

    const tool = root.get("tools").?.array.items[0].object;
    try testing.expectEqualStrings("function", tool.get("type").?.string);
    try testing.expectEqualStrings("read", tool.get("name").?.string);
}

test "a request names its cache key as its session, so it is routed to its cache" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hi");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body = try chat.buildRequest(arena_state.allocator(), &convo, .{ .system = "s" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});

    const headers = chat.requestHeaders();
    try testing.expectEqualStrings("session-id", headers[1].name);
    try testing.expectEqualStrings(parsed.object.get("prompt_cache_key").?.string, headers[1].value);
}

test "a recorded turn is replayed verbatim, in order, ahead of its outputs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "read two files");
    var calls = [_]Conversation.ToolCall{
        .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"a\"}" },
        .{ .id = "call_2", .name = "read", .arguments = "{\"path\":\"b\"}" },
    };
    _ = try convo.append(.{
        .role = .assistant,
        .text = "Reading both.",
        .tool_calls = &calls,
        .provider_state =
        \\{"provider":"chatgpt","model":"gpt-test","items":[
        \\{"id":"rs_1","type":"reasoning","summary":[],"encrypted_content":"opaque"},
        \\{"id":"msg_1","type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Reading both."}]},
        \\{"id":"fc_1","type":"function_call","call_id":"call_1","name":"read","arguments":"{\"path\":\"a\"}"},
        \\{"id":"fc_2","type":"function_call","call_id":"call_2","name":"read","arguments":"{\"path\":\"b\"}"}]}
        ,
    });
    _ = try convo.addToolResult("read", "call_1", "contents of a");
    _ = try convo.addToolResult("read", "call_2", "contents of b");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body = try chat.buildRequest(arena_state.allocator(), &convo, .{ .system = "s" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    const input = parsed.object.get("input").?.array.items;

    const expected = [_][]const u8{ "message", "message", "reasoning", "message", "function_call", "function_call", "function_call_output", "function_call_output" };
    try testing.expectEqual(expected.len, input.len);
    for (expected, input) |kind, item| try testing.expectEqualStrings(kind, item.object.get("type").?.string);
    try testing.expectEqualStrings("opaque", input[2].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("commentary", input[3].object.get("phase").?.string);
    try testing.expectEqualStrings("call_2", input[7].object.get("call_id").?.string);
    try testing.expectEqualStrings("contents of a", input[6].object.get("output").?.string);
    try testing.expectEqualStrings("contents of b", input[7].object.get("output").?.string);
}

test "a turn another provider answered is rebuilt, and an unanswered call is closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "list it");
    var calls = [_]Conversation.ToolCall{.{ .id = "call_9", .name = "list", .arguments = "" }};
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    try convo.add(.user, "never mind");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body = try chat.buildRequest(arena_state.allocator(), &convo, .{ .system = "s" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    const input = parsed.object.get("input").?.array.items;

    try testing.expectEqual(@as(usize, 5), input.len);
    try testing.expectEqualStrings("function_call", input[2].object.get("type").?.string);
    try testing.expectEqualStrings("{}", input[2].object.get("arguments").?.string);
    try testing.expectEqualStrings("function_call_output", input[3].object.get("type").?.string);
    try testing.expectEqualStrings(aborted_call_output, input[3].object.get("output").?.string);
}

fn feed(stream: *ResponseStream, events: []const u8) !void {
    var reader: std.Io.Reader = .fixed(events);
    try stream.readEvents(testing.allocator, &reader);
}

test "a stream folds into text, calls, and a replay record" {
    var stream: ResponseStream = .init(testing.allocator, null);
    defer stream.deinit();
    try feed(&stream,
        \\data: {"type":"response.output_text.delta","delta":"Hel"}
        \\
        \\data: {"type":"response.output_text.delta","delta":"lo"}
        \\
        \\data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","content":[{"type":"output_text","text":"Hello"}]}}
        \\
        \\data: {"type":"response.output_item.done","item":{"id":"fc_1","type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}}
        \\
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"input_tokens_details":{"cached_tokens":10},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":2}}}}
        \\
    );
    var reply = try stream.intoReply();
    defer reply.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello", reply.text);
    try testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
    try testing.expectEqualStrings("call_1", reply.tool_calls[0].id);
    try testing.expectEqual(@as(u32, 12), reply.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 10), reply.usage.cached_tokens);
    try testing.expectEqual(@as(u32, 2), reply.usage.reasoning_tokens);
    try testing.expect(std.mem.indexOf(u8, reply.provider_state.?, "\"fc_1\"") != null);
}

test "a stream that never completes is not a reply" {
    var stream: ResponseStream = .init(testing.allocator, null);
    defer stream.deinit();
    try testing.expectError(error.IncompleteStream, feed(&stream,
        \\data: {"type":"response.output_text.delta","delta":"half"}
        \\
    ));
}

test "a completed response with nothing in it is an error, not a blank turn" {
    var stream: ResponseStream = .init(testing.allocator, null);
    defer stream.deinit();
    try feed(&stream,
        \\data: {"type":"response.output_item.done","item":{"id":"rs_1","type":"reasoning","summary":[]}}
        \\
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":5,"output_tokens":9}}}
        \\
    );
    try testing.expectError(error.EmptyResponse, stream.intoReply());
}

test "a usage limit mid-stream reads as the limit, not a broken stream" {
    var stream: ResponseStream = .init(testing.allocator, null);
    defer stream.deinit();
    try feed(&stream,
        \\data: {"type":"response.output_text.delta","delta":"Start"}
        \\
        \\data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}
        \\
    );
    try testing.expectEqual(@as(anyerror, error.UsageLimitReached), stream.failure.?.toError());
}

test "each documented refusal maps to its own recovery" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const limit = Refusal.parse(arena,
        \\{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"m"}}
    );
    try testing.expect(!limit.isTemporary());
    try testing.expectEqual(@as(anyerror, error.UsageLimitReached), limit.toError(.too_many_requests));

    const unavailable = Refusal.parse(arena,
        \\{"error":{"code":"subscription_sharing_usage_unavailable"}}
    );
    try testing.expect(unavailable.isTemporary());

    const unsupported = Refusal.parse(arena,
        \\{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools[0]"}}
    );
    try testing.expectEqualStrings("tools[0]", unsupported.param);
    try testing.expectEqual(@as(anyerror, error.UnsupportedCapability), unsupported.toError(.bad_request));

    const admission = Refusal.parse(arena,
        \\{"detail":"Direct routing is not enabled"}
    );
    try testing.expect(admission.code == null);
    try testing.expectEqualStrings("Direct routing is not enabled", admission.message);
    try testing.expectEqual(@as(anyerror, error.SessionExpired), admission.toError(.unauthorized));
}

fn catalogFixture(chat: *ChatGPTProvider) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena_state.deinit();
    chat.catalog = try parseCatalog(arena_state.allocator(),
        \\{"models":[
        \\ {"slug":"gpt-test","visibility":"list","default_reasoning_level":"medium",
        \\  "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"ultra"}]},
        \\ {"slug":"gpt-small","visibility":"list","default_reasoning_level":"low","supports_reasoning_summary_parameter":false,
        \\  "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]}
        \\]}
    );
    chat.catalog_arena = arena_state;
}

fn requestReasoning(chat: *ChatGPTProvider, arena: std.mem.Allocator, convo: *Conversation) !std.json.ObjectMap {
    const body = try chat.buildRequest(arena, convo, .{ .system = "s" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return parsed.object.get("reasoning").?.object;
}

test "effort is one of the model's API levels, always sent, and dropped where unsupported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();
    try catalogFixture(&chat);

    const offered = chat.efforts("gpt-test");
    try testing.expectEqual(@as(usize, 3), offered.levels.len);
    try testing.expectEqualStrings("medium", offered.default);
    try testing.expectEqualStrings("medium", chat.current().effort);

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hello");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("medium", (try requestReasoning(&chat, arena, &convo)).get("effort").?.string);

    chat.setEffort("ultra");
    try testing.expectEqualStrings("medium", chat.current().effort);

    chat.setEffort("high");
    try testing.expectEqualStrings("high", (try requestReasoning(&chat, arena, &convo)).get("effort").?.string);

    try chat.setModel("gpt-small");
    try testing.expectEqualStrings("low", chat.current().effort);
}

test "a slug the catalog does not hold is refused, and the model stays put" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();
    try catalogFixture(&chat);
    try chat.setModel("gpt-test");

    try testing.expectError(error.UnknownModel, chat.setModel("gpt-nope"));
    try testing.expectEqualStrings("gpt-test", chat.model);
}

test "a remembered slug the catalog no longer holds gives way to the first one listed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();
    try catalogFixture(&chat);
    chat.model = "s";

    try chat.ensureModel();
    try testing.expectEqualStrings("gpt-test", chat.model);
}

test "a summary is asked for only from a model that takes the parameter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();
    try catalogFixture(&chat);

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hello");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("detailed", (try requestReasoning(&chat, arena, &convo)).get("summary").?.string);
    try chat.setModel("gpt-small");
    try testing.expect((try requestReasoning(&chat, arena, &convo)).get("summary") == null);
}

test "a nested client keeps the model's summary support" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();

    var parent = testProvider(store);
    defer parent.deinit();
    try catalogFixture(&parent);
    try parent.setModel("gpt-small");

    var child = testProvider(store);
    defer child.deinit();
    child.model = "gpt-small";
    try child.startLike(&parent);

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hello");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expect((try requestReasoning(&child, arena_state.allocator(), &convo)).get("summary") == null);
}

test "a note posted mid-turn does not cut a tool call off from its result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try testStore(&tmp);
    defer store.destroy();
    var chat = testProvider(store);
    defer chat.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "list it");
    var calls = [_]Conversation.ToolCall{.{ .id = "call_9", .name = "list", .arguments = "{}" }};
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    try convo.add(.assistant, "`gpt-test` now runs at high effort.");
    _ = try convo.addToolResult("list", "call_9", "a b c");

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const body = try chat.buildRequest(arena_state.allocator(), &convo, .{ .system = "s" });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    const input = parsed.object.get("input").?.array.items;
    const last = input[input.len - 1].object;
    try testing.expectEqualStrings("function_call_output", last.get("type").?.string);
    try testing.expectEqualStrings("a b c", last.get("output").?.string);
}
