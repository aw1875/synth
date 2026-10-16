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
const OpenAI = @import("openai.zig");
const Provider = @import("provider.zig");
const retry = @import("retry.zig");
const window = @import("window.zig");

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
const provider_tag = "chatgpt";
const no_socket: std.posix.fd_t = -1;
const max_body_bytes: usize = 4 * 1024 * 1024;
const max_rejection_bytes: usize = 2 * 1024;
const transfer_buffer_bytes: usize = 64 * 1024;
const aborted_call_output = "aborted";
const models_url = auth.resource ++ "/models";
const responses_url = auth.resource ++ "/responses";

/// The Responses item and content types this provider writes or reads.
const Item = struct {
    const message = "message";
    const function_call = "function_call";
    const function_call_output = "function_call_output";
    const input_text = "input_text";
    const output_text = "output_text";
};

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

pub fn setModel(self: *ChatGPTProvider, name: []const u8) !void {
    if (std.mem.eql(u8, name, self.model)) return;
    const owned = try self.allocator.dupe(u8, name);
    if (self.model_owned) |previous| self.allocator.free(previous);
    self.model_owned = owned;
    self.model = owned;
    self.applyCatalogEntry();
}

/// The first model the account lists, in the server's own order, when none
/// was chosen.
pub fn ensureModel(self: *ChatGPTProvider) !void {
    try self.loadCatalog(false);
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
        const uri = std.Uri.parse(responses_url) catch return error.InvalidHost;

        const extra_headers = [_]std.http.Header{.{ .name = "Accept", .value = "text/event-stream" }};
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
        self.log(arena, body, reply) catch {};
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
    const budget = window.requestBudget(self.context_limit, turn);
    const kept = try window.completeMessages(convo, arena, budget, self.supports_vision);
    const instructions = try window.systemText(arena, turn.system, kept, 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"model\":");
    try writeString(w, self.model);
    try w.writeAll(",\"instructions\":");
    try writeString(w, instructions);
    try w.writeAll(",\"input\":[");
    var input: InputWriter = .{ .writer = w, .supports_vision = self.supports_vision };
    for (kept) |msg| {
        if (msg.role == .system or msg.role == .summary) continue;
        try input.message(arena, msg, kept);
    }
    if (turn.instruction.len > 0) try input.text("user", Item.input_text, turn.instruction);
    try w.writeByte(']');

    if (turn.tools_json.len > 2) {
        try w.writeAll(",\"tools\":");
        try writeTools(arena, w, turn.tools_json);
        try w.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true");
    }
    try w.writeAll(",\"reasoning\":{");
    var reasoning_first = true;
    if (self.supports_reasoning_summary) {
        try w.writeAll("\"summary\":\"detailed\"");
        reasoning_first = false;
    }
    const effort = self.effectiveEffort();
    if (effort.len > 0) {
        if (!reasoning_first) try w.writeByte(',');
        try w.writeAll("\"effort\":");
        try writeString(w, effort);
    }
    try w.writeAll("},\"include\":[\"reasoning.encrypted_content\"],\"store\":false,\"stream\":true,\"prompt_cache_key\":");
    try writeString(w, self.cacheKey(convo));
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// Writes the transcript as Responses input items, keeping each tool output
/// next to the call it answers.
const InputWriter = struct {
    writer: *std.Io.Writer,
    supports_vision: bool,
    first: bool = true,
    /// Whether an assistant turn since the last user message made calls for
    /// tool messages to answer. An output with no call before it is refused.
    /// A message without calls in between, such as a note posted mid-turn,
    /// leaves them open.
    open_calls: bool = false,

    fn separator(self: *InputWriter) !void {
        if (!self.first) try self.writer.writeByte(',');
        self.first = false;
    }

    fn message(self: *InputWriter, arena: std.mem.Allocator, msg: Conversation.Message, all: []const Conversation.Message) !void {
        const content = try OpenAI.messageContent(arena, msg, self.supports_vision);
        switch (msg.role) {
            .system, .summary => unreachable,
            .user => {
                self.open_calls = false;
                try self.user(content, msg.images);
            },
            .assistant => {
                const made_calls = try self.assistant(arena, msg, content);
                self.open_calls = self.open_calls or made_calls;
                try self.closeUnansweredCalls(msg, all);
            },
            .tool => {
                if (!self.open_calls) return;
                try self.separator();
                try std.json.Stringify.value(.{
                    .type = Item.function_call_output,
                    .call_id = msg.tool_call_id orelse "",
                    .output = content,
                }, .{}, self.writer);
            },
        }
    }

    fn user(self: *InputWriter, content: []const u8, images: []const []const u8) !void {
        try self.separator();
        const w = self.writer;
        try w.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
        try writeString(w, content);
        try w.writeByte('}');
        if (self.supports_vision) {
            for (images) |image| {
                try w.writeAll(",{\"type\":\"input_image\",\"image_url\":\"data:");
                try w.writeAll(OpenAI.imageMime(image));
                try w.writeAll(";base64,");
                try w.writeAll(image);
                try w.writeAll("\"}");
            }
        }
        try w.writeAll("]}");
    }

    /// The turn's own output items when this provider recorded them, and a
    /// reconstruction from the transcript otherwise: a turn another provider
    /// answered, or one from before this provider existed. Returns whether
    /// the turn made tool calls.
    fn assistant(self: *InputWriter, arena: std.mem.Allocator, msg: Conversation.Message, content: []const u8) !bool {
        if (msg.provider_state) |state| {
            if (try self.recorded(arena, state)) |made_calls| return made_calls;
        }
        if (content.len > 0) try self.text("assistant", Item.output_text, content);
        for (msg.tool_calls) |call| {
            try self.separator();
            try std.json.Stringify.value(.{
                .type = Item.function_call,
                .call_id = call.id,
                .name = call.name,
                .arguments = if (call.arguments.len > 0) call.arguments else "{}",
            }, .{}, self.writer);
        }
        return msg.tool_calls.len > 0;
    }

    fn recorded(self: *InputWriter, arena: std.mem.Allocator, state: []const u8) !?bool {
        const Record = struct { provider: []const u8 = "", items: []const std.json.Value = &.{} };
        const record = std.json.parseFromSliceLeaky(Record, arena, state, .{ .ignore_unknown_fields = true }) catch return null;
        if (!std.mem.eql(u8, record.provider, provider_tag) or record.items.len == 0) return null;

        var made_calls = false;
        for (record.items) |item| {
            if (itemType(item)) |kind| {
                if (std.mem.eql(u8, kind, Item.function_call)) made_calls = true;
            }
            try self.separator();
            try std.json.Stringify.value(item, .{}, self.writer);
        }
        return made_calls;
    }

    /// A call the turn never answered - interrupted, or rejected before it
    /// ran - still needs an output, or the next request is refused.
    fn closeUnansweredCalls(self: *InputWriter, msg: Conversation.Message, all: []const Conversation.Message) !void {
        for (msg.tool_calls) |call| {
            if (hasResult(all, call.id)) continue;
            try self.separator();
            try std.json.Stringify.value(.{
                .type = Item.function_call_output,
                .call_id = call.id,
                .output = aborted_call_output,
            }, .{}, self.writer);
        }
    }

    fn text(self: *InputWriter, role: []const u8, content_type: []const u8, value: []const u8) !void {
        try self.separator();
        const w = self.writer;
        try w.writeAll("{\"type\":\"message\",\"role\":");
        try writeString(w, role);
        try w.writeAll(",\"content\":[{\"type\":");
        try writeString(w, content_type);
        try w.writeAll(",\"text\":");
        try writeString(w, value);
        try w.writeAll("}]}");
    }
};

fn hasResult(all: []const Conversation.Message, call_id: []const u8) bool {
    for (all) |msg| {
        if (msg.role != .tool) continue;
        const answered = msg.tool_call_id orelse continue;
        if (std.mem.eql(u8, answered, call_id)) return true;
    }
    return false;
}

/// The registry's definitions are chat-completions shaped; Responses wants
/// the function's fields at the top level.
fn writeTools(arena: std.mem.Allocator, w: *std.Io.Writer, tools_json: []const u8) !void {
    const Definition = struct {
        function: struct { name: []const u8, description: []const u8 = "", parameters: std.json.Value = .null },
    };
    const tools = std.json.parseFromSliceLeaky([]const Definition, arena, tools_json, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidToolSchema;
    try w.writeByte('[');
    for (tools, 0..) |tool, index| {
        if (index > 0) try w.writeByte(',');
        try std.json.Stringify.value(.{
            .type = "function",
            .name = tool.function.name,
            .description = tool.function.description,
            .parameters = tool.function.parameters,
        }, .{}, w);
    }
    try w.writeByte(']');
}

fn itemType(item: std.json.Value) ?[]const u8 {
    const fields = switch (item) {
        .object => |object| object,
        else => return null,
    };
    return stringField(fields, "type");
}

fn stringField(fields: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (fields.get(name) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn objectField(fields: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    return switch (fields.get(name) orelse return null) {
        .object => |value| value,
        else => null,
    };
}

fn unsignedField(fields: std.json.ObjectMap, name: []const u8) u32 {
    return switch (fields.get(name) orelse return 0) {
        .integer => |number| @intCast(std.math.clamp(number, 0, std.math.maxInt(u32))),
        else => 0,
    };
}

/// Codes the plan-usage route answers with, each with its own recovery.
/// https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
const Code = enum {
    subscription_sharing_user_not_eligible,
    subscription_sharing_usage_limit_exceeded,
    subscription_sharing_usage_unavailable,
    subscription_sharing_unsupported_capability,
    subscription_sharing_route_not_supported,
    subscription_sharing_invalid_user,
    subscription_sharing_user_unavailable,
    chatpass_v2_scope_not_authorized,
    chatpass_v2_invalid_authorization_context,
};

/// What a refused request or a failed stream said, read from either the
/// standard `error` object or the bare `detail` some admission failures use.
const Refusal = struct {
    code: ?Code = null,
    param: []const u8 = "",
    message: []const u8 = "",

    fn parse(arena: std.mem.Allocator, body: []const u8) Refusal {
        const Body = struct {
            @"error": ?struct { code: ?[]const u8 = null, param: ?[]const u8 = null, message: ?[]const u8 = null } = null,
            detail: ?[]const u8 = null,
        };
        const parsed = std.json.parseFromSliceLeaky(Body, arena, body, .{ .ignore_unknown_fields = true }) catch return .{};
        if (parsed.@"error") |err| return .{
            .code = if (err.code) |code| std.meta.stringToEnum(Code, code) else null,
            .param = err.param orelse "",
            .message = err.message orelse "",
        };
        return .{ .message = parsed.detail orelse "" };
    }

    fn fromFields(fields: std.json.ObjectMap) Refusal {
        return .{
            .code = if (stringField(fields, "code")) |code| std.meta.stringToEnum(Code, code) else null,
            .param = stringField(fields, "param") orelse "",
            .message = stringField(fields, "message") orelse "",
        };
    }

    /// The server's words, naming the offending field when it said which.
    fn describe(self: Refusal, arena: std.mem.Allocator, fallback: []const u8) ![]const u8 {
        const said = if (self.message.len > 0) self.message else fallback;
        if (self.param.len == 0) return said;
        return std.fmt.allocPrint(arena, "{s} (at {s})", .{ said, self.param });
    }

    fn isTemporary(self: Refusal) bool {
        const code = self.code orelse return true;
        return code == .subscription_sharing_usage_unavailable or code == .subscription_sharing_user_unavailable;
    }

    fn toError(self: Refusal, status: std.http.Status) anyerror {
        const code = self.code orelse return if (status == .unauthorized) error.SessionExpired else error.HttpError;
        return switch (code) {
            .subscription_sharing_usage_limit_exceeded => error.UsageLimitReached,
            .subscription_sharing_user_not_eligible => error.PlanNotEligible,
            .subscription_sharing_invalid_user => error.SessionExpired,
            .subscription_sharing_usage_unavailable, .subscription_sharing_user_unavailable => error.UsageUnavailable,
            .subscription_sharing_unsupported_capability => error.UnsupportedCapability,
            .subscription_sharing_route_not_supported,
            .chatpass_v2_scope_not_authorized,
            .chatpass_v2_invalid_authorization_context,
            => error.NotAuthorizedForPlan,
        };
    }
};

/// A stream that ended in `response.failed` or `response.incomplete`.
const Failure = struct {
    refusal: Refusal = .{},
    incomplete_reason: []const u8 = "",

    fn toError(self: Failure) anyerror {
        if (self.incomplete_reason.len > 0) return error.ResponseIncomplete;
        if (self.refusal.code == null) return error.ResponseFailed;
        return self.refusal.toError(.ok);
    }
};

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

/// Everything one streamed response produces: the reply, plus each completed
/// output item kept verbatim for replay.
const ResponseStream = struct {
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
    text: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Conversation.ToolCall) = .empty,
    items: std.Io.Writer.Allocating,
    usage: Provider.Usage = .{},
    failure: ?Failure = null,
    /// Backs the strings in `failure`, which outlive the line they came from.
    failure_arena: std.heap.ArenaAllocator,
    completed: bool = false,
    streamed_text: bool = false,
    /// Once anything has reached the screen, a re-send would repeat it.
    delivered_anything: bool = false,
    thinking_closed: bool = false,
    summary_started: bool = false,

    fn init(allocator: std.mem.Allocator, sink: ?Provider.Sink) ResponseStream {
        return .{ .allocator = allocator, .sink = sink, .items = .init(allocator), .failure_arena = .init(allocator) };
    }

    fn deinit(self: *ResponseStream) void {
        self.text.deinit(self.allocator);
        for (self.calls.items) |*call| call.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.items.deinit();
        self.failure_arena.deinit();
    }

    fn fail(self: *ResponseStream, failure: Failure) !void {
        const arena = self.failure_arena.allocator();
        self.failure = .{
            .refusal = .{
                .code = failure.refusal.code,
                .param = try arena.dupe(u8, failure.refusal.param),
                .message = try arena.dupe(u8, failure.refusal.message),
            },
            .incomplete_reason = try arena.dupe(u8, failure.incomplete_reason),
        };
    }

    /// One event per `data:` line. A line can be larger than any fixed
    /// buffer - encrypted reasoning has no bound - so it is grown to fit.
    fn readEvents(self: *ResponseStream, arena: std.mem.Allocator, reader: *std.Io.Reader) !void {
        var line_arena: std.heap.ArenaAllocator = .init(arena);
        defer line_arena.deinit();
        while (true) {
            if (stopped(self.sink)) return error.Canceled;
            _ = line_arena.reset(.retain_capacity);
            const scratch = line_arena.allocator();

            var line: std.Io.Writer.Allocating = .init(scratch);
            const ended = blk: {
                _ = reader.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
                    error.EndOfStream => break :blk true,
                    error.WriteFailed => return error.OutOfMemory,
                    else => |other| return other,
                };
                reader.toss(1);
                break :blk false;
            };

            const trimmed = std.mem.trimEnd(u8, line.written(), "\r");
            if (std.mem.startsWith(u8, trimmed, "data:")) {
                const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
                const is_event = payload.len > 0 and !std.mem.eql(u8, payload, "[DONE]");
                if (is_event) {
                    const event = std.json.parseFromSliceLeaky(std.json.Value, scratch, payload, .{}) catch null;
                    if (event) |parsed| try self.apply(parsed);
                }
            }
            if (self.failure != null) return;
            if (ended) break;
        }
        if (!self.completed) return error.IncompleteStream;
    }

    fn apply(self: *ResponseStream, event: std.json.Value) !void {
        const fields = switch (event) {
            .object => |object| object,
            else => return,
        };
        const kind = stringField(fields, "type") orelse return;

        if (std.mem.eql(u8, kind, "response.output_text.delta") or std.mem.eql(u8, kind, "response.refusal.delta")) {
            const delta = stringField(fields, "delta") orelse return;
            self.streamed_text = true;
            return self.appendText(delta);
        }
        if (std.mem.eql(u8, kind, "response.reasoning_summary_part.added")) {
            if (self.summary_started) self.think("\n\n");
            return;
        }
        if (std.mem.eql(u8, kind, "response.reasoning_summary_text.delta") or std.mem.eql(u8, kind, "response.reasoning_text.delta")) {
            const delta = stringField(fields, "delta") orelse return;
            self.summary_started = true;
            return self.think(delta);
        }
        if (std.mem.eql(u8, kind, "response.output_item.done")) {
            return self.keepItem(fields.get("item") orelse return);
        }
        if (std.mem.eql(u8, kind, "response.completed")) {
            self.completed = true;
            if (objectField(fields, "response")) |response| self.readUsage(response);
            return;
        }
        if (std.mem.eql(u8, kind, "response.failed") or std.mem.eql(u8, kind, "response.incomplete")) {
            return self.fail(readFailure(fields));
        }
        if (std.mem.eql(u8, kind, "error")) {
            return self.fail(.{ .refusal = Refusal.fromFields(objectField(fields, "error") orelse fields) });
        }
    }

    fn keepItem(self: *ResponseStream, item: std.json.Value) !void {
        if (self.items.written().len > 0) try self.items.writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, &self.items.writer);

        const fields = switch (item) {
            .object => |object| object,
            else => return,
        };
        const kind = stringField(fields, "type") orelse return;

        if (std.mem.eql(u8, kind, Item.function_call)) {
            self.closeThinking();
            self.delivered_anything = true;
            const call_id = stringField(fields, "call_id") orelse return;
            const name = stringField(fields, "name") orelse return;
            const arguments = stringField(fields, "arguments") orelse "{}";

            const owned_id = try self.allocator.dupe(u8, call_id);
            errdefer self.allocator.free(owned_id);
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_arguments = try self.allocator.dupe(u8, arguments);
            errdefer self.allocator.free(owned_arguments);
            try self.calls.append(self.allocator, .{ .id = owned_id, .name = owned_name, .arguments = owned_arguments });
            return;
        }

        // A message whose text never streamed as deltas still has it here.
        const unstreamed_message = std.mem.eql(u8, kind, Item.message) and !self.streamed_text;
        if (!unstreamed_message) return;
        const parts = switch (fields.get("content") orelse return) {
            .array => |array| array.items,
            else => return,
        };
        for (parts) |part| {
            const part_fields = switch (part) {
                .object => |object| object,
                else => continue,
            };
            const part_type = stringField(part_fields, "type") orelse continue;
            if (!std.mem.eql(u8, part_type, Item.output_text)) continue;
            try self.appendText(stringField(part_fields, "text") orelse continue);
        }
    }

    fn appendText(self: *ResponseStream, value: []const u8) !void {
        if (value.len == 0) return;
        try self.text.appendSlice(self.allocator, value);
        self.delivered_anything = true;
        if (self.sink) |sink| sink.onText(sink.userdata, value);
        self.closeThinking();
    }

    fn think(self: *ResponseStream, value: []const u8) void {
        self.delivered_anything = true;
        if (self.sink) |sink| sink.onThinking(sink.userdata, value);
    }

    fn closeThinking(self: *ResponseStream) void {
        if (self.thinking_closed) return;
        self.thinking_closed = true;
        if (self.sink) |sink| sink.onThinkingDone(sink.userdata);
    }

    fn readUsage(self: *ResponseStream, response: std.json.ObjectMap) void {
        const usage = objectField(response, "usage") orelse return;
        self.usage.prompt_tokens = unsignedField(usage, "input_tokens");
        self.usage.completion_tokens = unsignedField(usage, "output_tokens");
    }

    /// A completed response with neither text nor a call is the model
    /// spending the plan on nothing; that is an error worth seeing, not a
    /// blank turn.
    fn intoReply(self: *ResponseStream) !Provider.Reply {
        if (self.text.items.len == 0 and self.calls.items.len == 0) return error.EmptyResponse;

        var record: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer record.deinit();
        try record.writer.writeAll("{\"provider\":\"" ++ provider_tag ++ "\",\"items\":[");
        try record.writer.writeAll(self.items.written());
        try record.writer.writeAll("]}");

        var reply: Provider.Reply = .{ .usage = self.usage };
        errdefer reply.deinit(self.allocator);
        reply.text = try self.text.toOwnedSlice(self.allocator);
        reply.tool_calls = try self.calls.toOwnedSlice(self.allocator);
        reply.provider_state = try record.toOwnedSlice();
        return reply;
    }
};

fn readFailure(fields: std.json.ObjectMap) Failure {
    const response = objectField(fields, "response") orelse return .{};
    if (objectField(response, "incomplete_details")) |details| {
        if (stringField(details, "reason")) |reason| return .{ .incomplete_reason = reason };
    }
    const err = objectField(response, "error") orelse return .{};
    return .{ .refusal = Refusal.fromFields(err) };
}

fn writeString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.encodeJsonString(value, .{}, w);
}

fn log(self: *ChatGPTProvider, arena: std.mem.Allocator, body: []const u8, reply: Provider.Reply) !void {
    const path = self.debug_log orelse return;
    var out: std.Io.Writer.Allocating = .init(arena);
    const existing = std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(1024 * 1024)) catch "";
    try out.writer.writeAll(existing);
    try out.writer.print("\n=== request ===\n{s}\n=== reply ===\ntext: {s}\ncalls: {d}\n", .{ body, reply.text, reply.tool_calls.len });
    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.written() });
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

test "a request carries instructions, never a system message, and keeps nothing server-side" {
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
    try testing.expectEqualStrings("You are synth.", root.get("instructions").?.string);
    try testing.expectEqual(false, root.get("store").?.bool);
    try testing.expectEqual(true, root.get("stream").?.bool);
    try testing.expect(root.get("temperature") == null);
    try testing.expect(root.get("max_output_tokens") == null);
    try testing.expect(root.get("previous_response_id") == null);

    const input = root.get("input").?.array.items;
    try testing.expectEqual(@as(usize, 1), input.len);
    try testing.expectEqualStrings("user", input[0].object.get("role").?.string);

    const tool = root.get("tools").?.array.items[0].object;
    try testing.expectEqualStrings("function", tool.get("type").?.string);
    try testing.expectEqualStrings("read", tool.get("name").?.string);
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

    const expected = [_][]const u8{ "message", "reasoning", "message", "function_call", "function_call", "function_call_output", "function_call_output" };
    try testing.expectEqual(expected.len, input.len);
    for (expected, input) |kind, item| try testing.expectEqualStrings(kind, item.object.get("type").?.string);
    try testing.expectEqualStrings("opaque", input[1].object.get("encrypted_content").?.string);
    try testing.expectEqualStrings("commentary", input[2].object.get("phase").?.string);
    try testing.expectEqualStrings("call_2", input[6].object.get("call_id").?.string);
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

    try testing.expectEqual(@as(usize, 4), input.len);
    try testing.expectEqualStrings("function_call", input[1].object.get("type").?.string);
    try testing.expectEqualStrings("{}", input[1].object.get("arguments").?.string);
    try testing.expectEqualStrings("function_call_output", input[2].object.get("type").?.string);
    try testing.expectEqualStrings(aborted_call_output, input[2].object.get("output").?.string);
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
        \\data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":3}}}
        \\
    );
    var reply = try stream.intoReply();
    defer reply.deinit(testing.allocator);
    try testing.expectEqualStrings("Hello", reply.text);
    try testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
    try testing.expectEqualStrings("call_1", reply.tool_calls[0].id);
    try testing.expectEqual(@as(u32, 12), reply.usage.prompt_tokens);
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
