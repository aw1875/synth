//! A `Provider` for anything speaking the OpenAI chat API: OpenAI itself,
//! OpenRouter, Groq, Together, vLLM, llama.cpp's server, LM Studio.
//!
//! Only two endpoints are used, `/v1/chat/completions` and `/v1/models`, and
//! the request is kept to the fields every one of those implements. Where a
//! server offers more - a context window in its model listing, reasoning
//! deltas in its stream - it is read when present and never required.

const std = @import("std");

const Conversation = @import("../core/conversation.zig");
const Provider = @import("provider.zig");
const retry = @import("retry.zig");
const window = @import("window.zig");

const OpenAIProvider = @This();

allocator: std.mem.Allocator,
io: std.Io,
/// When a refused request is worth sending again.
retries: retry.Policy = .{},

/// Base URL, e.g. `https://api.openai.com/v1`. A `/v1` is appended when the
/// host does not already end in one, so `http://localhost:1234` works.
/// Borrowed until a reconnect, which copies its own.
host: []const u8,
/// Model id, e.g. `gpt-4o-mini`. Borrowed.
model: []const u8,
/// What this backend is called in the UI: the catalog provider's label, since
/// one client serves OpenAI and every server imitating it.
label: []const u8 = "OpenAI",
/// Bearer token. Borrowed. Optional: a local server usually wants none.
api_key: ?[]const u8 = null,
/// When set, every request and reply is appended here as JSON.
debug_log: ?[]const u8 = null,
/// Context window in tokens, from the model listing where the server reports
/// one and from `known_windows` otherwise. Zero when neither knows, which
/// leaves the transcript on `window.budget`'s fixed ceiling.
context_limit: u32 = 0,
/// Whether to send tool definitions. Off for a model that has answered that it
/// has no use for them, so the turn is retried as prose rather than failing.
supports_tools: bool = true,
/// Whether to send image parts. A text-only model is sent a note in place of
/// the picture, the same as on the ollama side.
supports_vision: bool = true,
/// Whether to ask a stream to report what the turn cost. Cleared for a server
/// that answered by rejecting the field; see `retryWithout`.
send_stream_options: bool = true,

/// Storage for the Authorization header value. The request borrows this slice,
/// so it has to outlive the call that builds it.
auth_value: []const u8 = "",

client: std.http.Client = undefined,
started: bool = false,
/// Set when the model, host, key or label was changed at runtime: the borrowed
/// field then points here rather than at the config, and this is what has to be
/// freed.
model_owned: ?[]u8 = null,
host_owned: ?[]u8 = null,
key_owned: ?[]u8 = null,
label_owned: ?[]u8 = null,
/// What the server said when it last turned a request down, owned by this
/// struct. Written on the worker thread as a turn fails and read on the UI
/// thread once that turn has been joined, so no lock: the failure is the
/// handoff.
rejection: ?[]u8 = null,

/// Cap on the complaint kept from a rejected request. An API error is a
/// sentence; anything longer is a page of HTML from something in between.
const max_rejection_bytes: usize = 2 * 1024;

/// Cap on a model listing, which for OpenAI runs to a few hundred entries.
const max_listing_bytes: usize = 4 * 1024 * 1024;

/// Buffer the response body is read through. Also the longest single SSE line
/// that can be handled: a server that answers a `stream` request with one
/// whole JSON body puts the entire turn on one line.
const transfer_buffer_bytes: usize = 512 * 1024;

/// Build the HTTP client and read what the model can hold. Separate from field
/// initialization because the request borrows `auth_value`, which means this
/// must run once the struct is at its final address.
pub fn start(self: *OpenAIProvider) !void {
    try self.startWithoutProbe();
    if (self.model.len > 0) self.probe();
}

/// Build the client without asking the server about the configured model. What
/// a listing needs: the context window does not matter, and a model the server
/// has never heard of should not fail the command.
fn startWithoutProbe(self: *OpenAIProvider) !void {
    if (self.api_key) |key| {
        if (key.len > 0) {
            self.auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
        }
    }
    self.client = .{ .allocator = self.allocator, .io = self.io };
    self.started = true;
}

/// Read the context window for the current model. Failures leave the table's
/// guess in place: a server that will not answer `/v1/models` is a problem the
/// first request reports better than startup can.
fn probe(self: *OpenAIProvider) void {
    self.context_limit = knownWindow(self.model);

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = self.get(arena, "/models") catch return;
    const reported = listedWindow(arena, body, self.model);
    if (reported > 0) self.context_limit = reported;
}

pub fn deinit(self: *OpenAIProvider) void {
    if (self.rejection) |rejection| self.allocator.free(rejection);
    if (self.started) self.client.deinit();
    if (self.auth_value.len > 0) self.allocator.free(self.auth_value);
    if (self.model_owned) |owned| self.allocator.free(owned);
    if (self.host_owned) |owned| self.allocator.free(owned);
    if (self.key_owned) |owned| self.allocator.free(owned);
    if (self.label_owned) |owned| self.allocator.free(owned);
}

pub fn provider(self: *OpenAIProvider) Provider {
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
    };
}

/// What this provider is pointed at, as the UI should show it.
pub fn current(self: *OpenAIProvider) Provider.Current {
    return .{
        .model = self.model,
        .name = self.label,
        .context_limit = self.context_limit,
        .vision = self.supports_vision,
    };
}

fn listModelsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
    const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
    return self.listModels(allocator);
}

fn setModelErased(ptr: *anyopaque, name: []const u8) anyerror!Provider.Current {
    const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
    try self.setModel(name);
    return self.current();
}

fn reconnectErased(ptr: *anyopaque, connection: Provider.Connection) anyerror!Provider.Current {
    const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
    try self.reconnect(connection);
    self.ensureModel() catch {};
    return self.current();
}

fn currentErased(ptr: *anyopaque) Provider.Current {
    const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
    return self.current();
}

fn describeErrorErased(ptr: *anyopaque, err: anyerror, allocator: std.mem.Allocator) anyerror![]const u8 {
    const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
    return self.describeError(err, allocator);
}

/// Point this provider at another server, with another credential.
pub fn reconnect(self: *OpenAIProvider, connection: Provider.Connection) !void {
    const host_copy = try self.allocator.dupe(u8, connection.host);
    errdefer self.allocator.free(host_copy);

    const label_copy = try self.allocator.dupe(u8, connection.label);
    errdefer self.allocator.free(label_copy);

    const key_copy: ?[]u8 = if (connection.api_key) |key| blk: {
        if (key.len == 0) break :blk null;
        break :blk try self.allocator.dupe(u8, key);
    } else null;
    errdefer if (key_copy) |copy| self.allocator.free(copy);

    if (self.started) {
        self.client.deinit();
        self.started = false;
    }
    if (self.auth_value.len > 0) {
        self.allocator.free(self.auth_value);
        self.auth_value = "";
    }

    if (self.host_owned) |owned| self.allocator.free(owned);
    self.host_owned = host_copy;
    self.host = host_copy;

    if (self.label_owned) |owned| self.allocator.free(owned);
    self.label_owned = label_copy;
    self.label = label_copy;

    if (self.key_owned) |owned| self.allocator.free(owned);
    self.key_owned = key_copy;
    self.api_key = key_copy;

    self.clearRejection();
    try self.start();
}

/// Point this provider at another model, re-reading the context window since
/// that is per-model and the sidebar's "how full is the context" figure is
/// meaningless against the wrong number.
pub fn setModel(self: *OpenAIProvider, name: []const u8) !void {
    if (std.mem.eql(u8, name, self.model)) return;

    const owned = try self.allocator.dupe(u8, name);
    if (self.model_owned) |previous| self.allocator.free(previous);
    self.model_owned = owned;
    self.model = owned;
    self.supports_tools = true;
    self.supports_vision = true;
    self.send_stream_options = true;

    if (self.started) self.probe();
}

/// Settle on a model when the config named none. Unlike ollama, a named model
/// that the listing does not mention is left alone: a gateway is under no
/// obligation to list everything it will route, and silently answering as some
/// other model would be worse than the error the first turn returns.
pub fn ensureModel(self: *OpenAIProvider) !void {
    if (self.model.len > 0) return;

    const names = try self.listModels(self.allocator);
    defer {
        for (names) |name| self.allocator.free(name);
        self.allocator.free(names);
    }

    for (names) |name| {
        if (!isChatModel(name)) continue;
        try self.setModel(name);
        return;
    }
}

/// Model ids the server offers, sorted. Caller owns the result and each name.
pub fn listModels(self: *OpenAIProvider, allocator: std.mem.Allocator) ![][]const u8 {
    if (!self.started) try self.startWithoutProbe();

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try self.get(arena, "/models");

    const Listing = struct {
        data: []const struct { id: []const u8 = "" } = &.{},
    };
    const parsed = std.json.parseFromSlice(Listing, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnexpectedResponse;

    const names = try allocator.alloc([]const u8, parsed.value.data.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| allocator.free(name);
        allocator.free(names);
    }

    for (parsed.value.data) |entry| {
        if (entry.id.len == 0) continue;
        names[filled] = try allocator.dupe(u8, entry.id);
        filled += 1;
    }

    const listed = names[0..filled];
    std.mem.sort([]const u8, listed, {}, lessThan);
    return listed;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Whether a listed id is something that answers a chat request. A listing is
/// the whole catalogue - embeddings, speech, images - and picking the first
/// entry alphabetically would land on `dall-e-2` more often than not.
fn isChatModel(id: []const u8) bool {
    const excluded: []const []const u8 = &.{
        "embed",   "whisper",   "tts",     "dall-e",
        "moderat", "audio",     "image",   "realtime",
        "transcr", "rerank",    "guard",   "codex-mini",
        "search",  "similarit", "davinci", "babbage",
        "clip",    "stable-di", "flux",    "sora",
    };
    for (excluded) |needle| {
        if (containsIgnoreCase(id, needle)) return false;
    }
    return true;
}

/// The endpoint URL for a path under the API root. Trailing slashes and a
/// missing `/v1` are both common in a hand-typed host, and neither should be
/// the reason a request 404s.
fn endpoint(self: *const OpenAIProvider, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.mem.trimEnd(u8, self.host, "/");
    if (std.mem.endsWith(u8, base, "/v1")) {
        return std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });
    }
    return std.fmt.allocPrint(arena, "{s}/v1{s}", .{ base, path });
}

/// The headers every request carries. `authorization` is a standard header the
/// client knows how to place, so it goes through `Headers` rather than the
/// extra list; `identity` is asked for because an SSE stream read through a
/// decompressor would arrive a buffer at a time rather than a token at a time.
fn requestHeaders(self: *const OpenAIProvider, json_body: bool) std.http.Client.Request.Headers {
    return .{
        .authorization = if (self.auth_value.len > 0)
            .{ .override = self.auth_value }
        else
            .default,
        .accept_encoding = .{ .override = "identity" },
        .content_type = if (json_body) .{ .override = "application/json" } else .default,
    };
}

/// GET a path under the API root and return the whole body. Allocated in
/// `arena`, which is the caller's to discard.
fn get(self: *OpenAIProvider, arena: std.mem.Allocator, path: []const u8) ![]u8 {
    const url = try self.endpoint(arena, path);
    const uri = std.Uri.parse(url) catch return error.InvalidHost;

    var request = try self.client.request(.GET, uri, .{ .headers = self.requestHeaders(false) });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    const transfer = try arena.alloc(u8, 64 * 1024);
    const reader = response.reader(transfer);
    const body = try reader.allocRemaining(arena, .limited(max_listing_bytes));

    if (response.head.status.class() != .success) {
        self.captureRejection(response.head.status, body);
        return error.HttpError;
    }
    return body;
}

/// Runs on a worker thread; blocking here is expected.
fn respond(
    ptr: *anyopaque,
    convo: *Conversation,
    turn: Provider.Turn,
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
) !Provider.Reply {
    const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
    if (!self.started) try self.startWithoutProbe();

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    self.clearRejection();

    const url = try self.endpoint(arena, "/chat/completions");
    const uri = std.Uri.parse(url) catch return error.InvalidHost;

    var attempt: usize = 1;
    while (true) {
        const body = try self.buildRequest(arena, convo, turn);

        var request = try self.client.request(.POST, uri, .{ .headers = self.requestHeaders(true) });
        defer request.deinit();
        try request.sendBodyComplete(body);

        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);

        // Read before the body reader is built: taking one invalidates every
        // string in the head, `content_type` among them.
        const sse = streamed(response.head.content_type);
        const asked_for = retry.retryAfterMs(headerValue(response.head, "retry-after"));

        const transfer = try arena.alloc(u8, transfer_buffer_bytes);
        const reader = response.reader(transfer);

        if (response.head.status.class() != .success) {
            const why = reader.allocRemaining(arena, .limited(max_listing_bytes)) catch "";
            self.captureRejection(response.head.status, why);
            if (self.retryWithout(why)) continue;

            if (self.waitAndRetry(response.head.status, attempt, asked_for, sink)) {
                attempt += 1;
                continue;
            }
            return error.HttpError;
        }

        var collector: Collector = .init(allocator, sink);
        errdefer collector.deinit();

        if (sse) {
            try collector.readEvents(arena, reader);
        } else {
            const whole = try reader.allocRemaining(arena, .limited(max_listing_bytes));
            try collector.readWhole(arena, whole);
        }

        const reply = try collector.finish();
        self.log(arena, body, reply) catch {};
        return reply;
    }
}

/// Whether a rejection is one an identical-but-smaller request can get past.
/// `stream_options` is the field that draws this: it is how a stream reports
/// what it cost, several compatible servers have never heard of it, and some of
/// those reject a body carrying it rather than ignoring it. Dropping it loses
/// the token counts for the session, which is better than losing every turn.
fn retryWithout(self: *OpenAIProvider, why: []const u8) bool {
    if (!self.send_stream_options) return false;
    if (!containsIgnoreCase(why, "stream_options")) return false;
    self.send_stream_options = false;
    self.clearRejection();
    return true;
}

/// Whether the server is answering with an event stream. Some compatible
/// servers ignore `stream` and reply with one JSON body, which is worth
/// handling: the alternative is a turn that reads as empty.
/// Whether to wait and send this request again, waiting if so.
///
/// Only ever reached before anything has been streamed: a retry once the
/// reader has produced tokens would repeat them.
fn waitAndRetry(
    self: *OpenAIProvider,
    status: std.http.Status,
    attempt: usize,
    retry_after_ms: ?u64,
    sink: ?Provider.Sink,
) bool {
    if (attempt >= self.retries.attempts) return false;
    if (!retry.transient(status)) return false;
    if (retry.tooLong(self.retries, retry_after_ms)) return false;

    if (sink) |s| {
        if (s.stopped(s.userdata)) return false;
    }

    const wait = retry.waitMs(self.retries, attempt, retry_after_ms);
    std.Io.sleep(self.io, .fromMilliseconds(@intCast(wait)), .awake) catch return false;

    if (sink) |s| {
        if (s.stopped(s.userdata)) return false;
    }
    return true;
}

/// One header off a reply, before a body reader invalidates it.
fn headerValue(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn streamed(content_type: ?[]const u8) bool {
    const value = content_type orelse return false;
    return std.mem.indexOf(u8, value, "event-stream") != null;
}

/// Everything a turn accumulates as it arrives, and the rules for folding a
/// stream of deltas back into one reply.
const Collector = struct {
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
    text: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Pending) = .empty,
    usage: Provider.Usage = .{},
    /// Whether `onThinkingDone` has been sent, so the row is closed once rather
    /// than on every chunk that follows the first token of the answer.
    answered: bool = false,

    /// One tool call being assembled. Arguments arrive a fragment at a time and
    /// are only valid JSON once the stream ends.
    const Pending = struct {
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,
    };

    fn init(allocator: std.mem.Allocator, sink: ?Provider.Sink) Collector {
        return .{ .allocator = allocator, .sink = sink };
    }

    fn deinit(self: *Collector) void {
        self.text.deinit(self.allocator);
        for (self.calls.items) |*call| {
            call.id.deinit(self.allocator);
            call.name.deinit(self.allocator);
            call.arguments.deinit(self.allocator);
        }
        self.calls.deinit(self.allocator);
    }

    /// Read `data:` events until the stream ends or the caller gives up.
    fn readEvents(self: *Collector, arena: std.mem.Allocator, reader: *std.Io.Reader) !void {
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();

        while (true) {
            if (self.stopped()) return;

            const raw = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.ResponseTooLong,
                else => |e| return e,
            } orelse return;

            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            if (!std.mem.startsWith(u8, line, "data:")) continue;

            const payload = std.mem.trimStart(u8, line["data:".len..], " ");
            if (std.mem.eql(u8, payload, "[DONE]")) return;

            _ = scratch.reset(.retain_capacity);
            const chunk = std.json.parseFromSliceLeaky(Chunk, scratch.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch continue;

            try self.apply(chunk);
        }
    }

    /// Fold a whole non-streamed body in, which carries `message` where a
    /// stream carries `delta`.
    fn readWhole(self: *Collector, arena: std.mem.Allocator, body: []const u8) !void {
        const parsed = std.json.parseFromSliceLeaky(Chunk, arena, body, .{
            .ignore_unknown_fields = true,
        }) catch return error.UnexpectedResponse;

        try self.apply(parsed);
    }

    fn apply(self: *Collector, chunk: Chunk) !void {
        if (chunk.usage) |usage| {
            self.usage = .{
                .prompt_tokens = usage.prompt_tokens,
                .completion_tokens = usage.completion_tokens,
            };
        }

        for (chunk.choices) |choice| {
            const delta = choice.message orelse choice.delta orelse continue;

            if (delta.reasoning_content orelse delta.reasoning) |thinking| {
                if (self.sink) |s| s.onThinking(s.userdata, thinking);
            }

            if (delta.content) |content| {
                if (content.len > 0) {
                    try self.text.appendSlice(self.allocator, content);
                    if (self.sink) |s| s.onText(s.userdata, content);
                    self.closeThinking();
                }
            }

            for (delta.tool_calls orelse &.{}) |call| {
                self.closeThinking();
                try self.accumulate(call);
            }

            if (choice.finish_reason != null) self.closeThinking();
        }
    }

    /// Merge one tool-call delta into the call it belongs to. The index is what
    /// ties fragments together; a server that omits it is assumed to be sending
    /// whole calls, so a fragment carrying a name starts a new one.
    fn accumulate(self: *Collector, delta: Chunk.ToolCall) !void {
        const at = delta.index orelse blk: {
            const named = if (delta.function) |f| f.name != null else false;
            if (named or self.calls.items.len == 0) break :blk self.calls.items.len;
            break :blk self.calls.items.len - 1;
        };

        while (self.calls.items.len <= at) try self.calls.append(self.allocator, .{});
        const call = &self.calls.items[at];

        if (delta.id) |id| try call.id.appendSlice(self.allocator, id);
        const function = delta.function orelse return;
        if (function.name) |name| try call.name.appendSlice(self.allocator, name);
        if (function.arguments) |arguments| {
            try call.arguments.appendSlice(self.allocator, arguments);
        }
    }

    /// Tell the sink the model has stopped reasoning, once.
    fn closeThinking(self: *Collector) void {
        if (self.answered) return;
        self.answered = true;
        if (self.sink) |s| s.onThinkingDone(s.userdata);
    }

    fn stopped(self: *Collector) bool {
        const s = self.sink orelse return false;
        return s.stopped(s.userdata);
    }

    /// Hand everything collected to the caller, which owns it from here.
    fn finish(self: *Collector) !Provider.Reply {
        var calls: std.ArrayList(Conversation.ToolCall) = .empty;
        errdefer {
            for (calls.items) |*call| call.deinit(self.allocator);
            calls.deinit(self.allocator);
        }

        for (self.calls.items) |*pending| {
            if (pending.name.items.len == 0) continue;

            const id = if (pending.id.items.len > 0)
                try self.allocator.dupe(u8, pending.id.items)
            else
                try Conversation.ToolCall.synthesizeId(self.allocator);
            errdefer self.allocator.free(id);

            const name = try self.allocator.dupe(u8, pending.name.items);
            errdefer self.allocator.free(name);

            const arguments = try self.allocator.dupe(
                u8,
                if (pending.arguments.items.len > 0) pending.arguments.items else "{}",
            );

            try calls.append(self.allocator, .{ .id = id, .name = name, .arguments = arguments });
        }

        const reply: Provider.Reply = .{
            .text = try self.text.toOwnedSlice(self.allocator),
            .tool_calls = try calls.toOwnedSlice(self.allocator),
            .usage = self.usage,
        };

        for (self.calls.items) |*pending| {
            pending.id.deinit(self.allocator);
            pending.name.deinit(self.allocator);
            pending.arguments.deinit(self.allocator);
        }
        self.calls.deinit(self.allocator);
        return reply;
    }
};

/// One `data:` event, and equally one whole completion body: the two differ
/// only in whether the content sits under `delta` or `message`.
const Chunk = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,

    const Choice = struct {
        delta: ?Delta = null,
        message: ?Delta = null,
        finish_reason: ?[]const u8 = null,
    };

    const Delta = struct {
        content: ?[]const u8 = null,
        /// What most servers call the reasoning trace. OpenRouter uses
        /// `reasoning`; neither is in the OpenAI spec, and a server sending
        /// neither simply never shows a thought row.
        reasoning_content: ?[]const u8 = null,
        reasoning: ?[]const u8 = null,
        tool_calls: ?[]const ToolCall = null,
    };

    const ToolCall = struct {
        index: ?usize = null,
        id: ?[]const u8 = null,
        function: ?Function = null,

        const Function = struct {
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
        };
    };

    const Usage = struct {
        prompt_tokens: u32 = 0,
        completion_tokens: u32 = 0,
    };
};

/// Write the chat request body. Written by hand rather than through a struct
/// because `tools` is already JSON from the registry and reparsing it only to
/// print it again would be work for nothing.
fn buildRequest(
    self: *OpenAIProvider,
    arena: std.mem.Allocator,
    convo: *Conversation,
    turn: Provider.Turn,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try std.json.Stringify.encodeJsonString(self.model, .{}, w);
    try w.writeAll(",\"stream\":true");
    if (self.send_stream_options) {
        try w.writeAll(",\"stream_options\":{\"include_usage\":true}");
    }

    if (self.supports_tools and turn.tools_json.len > 2) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(turn.tools_json);
    }

    try w.writeAll(",\"messages\":[");
    try self.writeMessages(arena, w, convo, turn);
    try w.writeAll("]}");

    return out.toOwnedSlice();
}

fn writeMessages(
    self: *OpenAIProvider,
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    convo: *Conversation,
    turn: Provider.Turn,
) !void {
    const budget = window.budgetFor(self.context_limit) -| (turn.system.len / 4);
    const kept = try window.messages(convo, arena, budget, self.supports_vision);
    const dropped = convo.messages.items.len - kept.len;

    try w.writeAll("{\"role\":\"system\",\"content\":");
    try std.json.Stringify.encodeJsonString(
        try window.systemText(arena, turn.system, kept, dropped),
        .{},
        w,
    );
    try w.writeAll("}");

    for (kept) |msg| {
        if (msg.role == .system or msg.role == .summary) continue;
        try w.writeByte(',');
        try self.writeMessage(arena, w, msg);
    }

    if (turn.instruction.len > 0) {
        try w.writeAll(",{\"role\":\"user\",\"content\":");
        try std.json.Stringify.encodeJsonString(turn.instruction, .{}, w);
        try w.writeByte('}');
    }
}

fn writeMessage(
    self: *OpenAIProvider,
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    msg: Conversation.Message,
) !void {
    const content = try messageContent(arena, msg, self.supports_vision);

    switch (msg.role) {
        // Filtered out before this, along with the system prompt.
        .summary => unreachable,
        .system => {
            try w.writeAll("{\"role\":\"system\",\"content\":");
            try std.json.Stringify.encodeJsonString(content, .{}, w);
            try w.writeByte('}');
        },
        .user => {
            try w.writeAll("{\"role\":\"user\",\"content\":");
            if (self.supports_vision and msg.images.len > 0) {
                try writeParts(w, content, msg.images);
            } else {
                try std.json.Stringify.encodeJsonString(content, .{}, w);
            }
            try w.writeByte('}');
        },
        .assistant => {
            try w.writeAll("{\"role\":\"assistant\",\"content\":");
            try std.json.Stringify.encodeJsonString(content, .{}, w);
            if (msg.tool_calls.len > 0) {
                try w.writeAll(",\"tool_calls\":[");
                for (msg.tool_calls, 0..) |call, index| {
                    if (index > 0) try w.writeByte(',');
                    try writeToolCall(arena, w, call, index);
                }
                try w.writeByte(']');
            }
            try w.writeByte('}');
        },
        .tool => {
            try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
            try std.json.Stringify.encodeJsonString(msg.tool_call_id orelse "", .{}, w);
            try w.writeAll(",\"content\":");
            try std.json.Stringify.encodeJsonString(content, .{}, w);
            try w.writeByte('}');
        },
    }
}

fn writeToolCall(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    call: Conversation.ToolCall,
    index: usize,
) !void {
    const id = if (call.id.len > 0)
        call.id
    else
        try std.fmt.allocPrint(arena, "call_{d}", .{index});

    try w.writeAll("{\"type\":\"function\",\"id\":");
    try std.json.Stringify.encodeJsonString(id, .{}, w);
    try w.writeAll(",\"function\":{\"name\":");
    try std.json.Stringify.encodeJsonString(call.name, .{}, w);
    try w.writeAll(",\"arguments\":");
    try std.json.Stringify.encodeJsonString(
        if (call.arguments.len > 0) call.arguments else "{}",
        .{},
        w,
    );
    try w.writeAll("}}");
}

/// A user message as a content array, which is the only shape that can carry an
/// image alongside the text.
fn writeParts(w: *std.Io.Writer, text: []const u8, images: []const []const u8) !void {
    try w.writeByte('[');
    if (text.len > 0) {
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.encodeJsonString(text, .{}, w);
        try w.writeAll("},");
    }
    for (images, 0..) |image, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
        try w.writeAll(imageMime(image));
        try w.writeAll(";base64,");
        try w.writeAll(image);
        try w.writeAll("\"}}");
    }
    try w.writeByte(']');
}

/// The media type of a base64 image, read from what the encoding of its magic
/// bytes always begins with. A data URL has to name one, and guessing wrong
/// makes a model refuse to look.
fn imageMime(base64: []const u8) []const u8 {
    if (std.mem.startsWith(u8, base64, "iVBORw0KGgo")) return "image/png";
    if (std.mem.startsWith(u8, base64, "/9j/")) return "image/jpeg";
    if (std.mem.startsWith(u8, base64, "R0lGOD")) return "image/gif";
    if (std.mem.startsWith(u8, base64, "UklGR")) return "image/webp";
    return "image/png";
}

/// The text a message is sent as: its own, plus inlined `@mention` files, plus
/// a note standing in for images this model cannot be shown.
fn messageContent(
    arena: std.mem.Allocator,
    msg: Conversation.Message,
    supports_vision: bool,
) ![]const u8 {
    const text = if (msg.attachments.len > 0)
        try inlineAttachments(arena, msg)
    else
        msg.text;

    if (supports_vision or msg.images.len == 0) return text;

    return std.fmt.allocPrint(
        arena,
        "{s}{s}<note>{d} image(s) omitted: the current model cannot see images.</note>",
        .{ text, if (text.len > 0) "\n\n" else "", msg.images.len },
    );
}

/// The message text followed by each mentioned file, tagged with its path.
fn inlineAttachments(arena: std.mem.Allocator, msg: Conversation.Message) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(msg.text);
    for (msg.attachments) |attachment| {
        try out.writer.print(
            "\n\n<file path=\"{s}\"{s}>\n{s}\n</file>",
            .{ attachment.path, if (attachment.shortened()) " truncated=\"true\"" else "", attachment.content },
        );
    }
    return out.toOwnedSlice();
}

/// Append the exchange to the debug log, if one is configured. Failures are
/// swallowed: diagnostics must never break a turn.
fn log(self: *OpenAIProvider, arena: std.mem.Allocator, body: []const u8, reply: Provider.Reply) !void {
    const path = self.debug_log orelse return;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("\n=== request ===\n{s}\n=== reply ===\ntext: {s}\ncalls: {d}\n", .{
        body,
        reply.text,
        reply.tool_calls.len,
    });

    const existing = std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(1024 * 1024)) catch "";

    var combined: std.Io.Writer.Allocating = .init(arena);
    try combined.writer.writeAll(existing);
    try combined.writer.writeAll(out.written());

    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = combined.written() });
}

/// Keep what the server said about a rejected request, reduced to the sentence
/// it wrote rather than the envelope it wrote it in.
fn captureRejection(self: *OpenAIProvider, status: std.http.Status, body: []const u8) void {
    self.clearRejection();

    const message = complaint(self.allocator, body);
    const kept = message[0..@min(message.len, max_rejection_bytes)];

    self.rejection = std.fmt.allocPrint(self.allocator, "{d} {s}{s}{s}", .{
        @intFromEnum(status),
        status.phrase() orelse "",
        if (kept.len > 0) ": " else "",
        kept,
    }) catch null;
}

/// Drop the last complaint, so a later failure of a different kind is never
/// explained with a stale one.
fn clearRejection(self: *OpenAIProvider) void {
    if (self.rejection) |old| self.allocator.free(old);
    self.rejection = null;
}

/// The human-readable part of an error body. Every one of these servers wraps
/// it differently; the OpenAI shape is `{"error":{"message":...}}`, and a
/// proxy that returns plain text is passed through as it is. The result points
/// into `body`, which the caller still owns.
fn complaint(allocator: std.mem.Allocator, body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return "";

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return trimmed;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return trimmed,
    };

    if (root.get("error")) |wrapped| switch (wrapped) {
        .string => |text| if (locate(trimmed, text)) |found| return found,
        .object => |object| if (object.get("message")) |message| switch (message) {
            .string => |text| if (locate(trimmed, text)) |found| return found,
            else => {},
        },
        else => {},
    };

    for ([_][]const u8{ "message", "detail" }) |key| {
        const value = root.get(key) orelse continue;
        switch (value) {
            .string => |text| if (locate(trimmed, text)) |found| return found,
            else => {},
        }
    }
    return trimmed;
}

/// Where a parsed string sits in the body it came from. The parse owns its own
/// copy, which is freed with it, so the slice handed back has to point into the
/// caller's bytes instead. Null when the two differ - a message carrying an
/// escape is not worth unescaping to find.
fn locate(body: []const u8, needle: []const u8) ?[]const u8 {
    if (needle.len == 0) return null;
    const at = std.mem.indexOf(u8, body, needle) orelse return null;
    return body[at..][0..needle.len];
}

/// What went wrong, in terms of what to do about it.
pub fn describeError(
    self: *OpenAIProvider,
    err: anyerror,
    allocator: std.mem.Allocator,
) ![]const u8 {
    switch (err) {
        error.Canceled => return allocator.dupe(u8, "cancelled"),
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostLacksNetworkAddresses,
        error.TemporaryNameServerFailure,
        error.UnknownHostName,
        => return std.fmt.allocPrint(
            allocator,
            "cannot reach {s} at {s}. Check the host, or that the server is running.",
            .{ self.label, self.host },
        ),
        error.HttpError => {
            const why = self.rejection orelse return std.fmt.allocPrint(
                allocator,
                "{s} rejected the request for `{s}`.",
                .{ self.label, self.model },
            );
            return std.fmt.allocPrint(allocator, "{s} rejected the request: {s}{s}", .{
                self.label,
                std.mem.trimEnd(u8, why, ". \n"),
                advice(why),
            });
        },
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => return std.fmt.allocPrint(
            allocator,
            "TLS to {s} failed. If this is a local server, use `http://` rather than `https://`.",
            .{self.host},
        ),
        error.InvalidHost, error.UnsupportedUriScheme, error.UriMissingHost => return std.fmt.allocPrint(
            allocator,
            "`{s}` is not a URL this can connect to. It should look like `https://api.openai.com/v1`.",
            .{self.host},
        ),
        else => return std.fmt.allocPrint(
            allocator,
            "{s} talking to {s} at {s}.",
            .{ @errorName(err), self.label, self.host },
        ),
    }
}

/// The next thing to try, chosen from what the server complained about.
fn advice(why: []const u8) []const u8 {
    if (containsIgnoreCase(why, "context length") or
        containsIgnoreCase(why, "too many tokens") or
        containsIgnoreCase(why, "reduce the length"))
    {
        return " Try `/compact`.";
    }
    if (containsIgnoreCase(why, "401") or
        containsIgnoreCase(why, "invalid api key") or
        containsIgnoreCase(why, "incorrect api key"))
    {
        return " Set a key with `/connect`.";
    }
    if (containsIgnoreCase(why, "429") or containsIgnoreCase(why, "rate limit")) {
        return " Wait a moment and send it again.";
    }
    if (containsIgnoreCase(why, "does not exist") or containsIgnoreCase(why, "model not found")) {
        return " Pick another with ctrl+o.";
    }
    return "";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The context window a listing reports for `model`. Not part of the OpenAI
/// API, but every self-hosted server has a field for it, and each picked a
/// different name.
fn listedWindow(arena: std.mem.Allocator, body: []const u8, model: []const u8) u32 {
    const Listing = struct {
        data: []const struct {
            id: []const u8 = "",
            context_length: u32 = 0,
            max_model_len: u32 = 0,
            max_context_length: u32 = 0,
            context_window: u32 = 0,
        } = &.{},
    };

    const parsed = std.json.parseFromSliceLeaky(Listing, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return 0;

    for (parsed.data) |entry| {
        if (!std.mem.eql(u8, entry.id, model)) continue;
        return @max(
            @max(entry.context_length, entry.max_model_len),
            @max(entry.max_context_length, entry.context_window),
        );
    }
    return 0;
}

/// Context windows for models that will never report one, matched on the
/// longest prefix so a dated id like `gpt-4o-2024-08-06` lands on its family.
/// Only a starting figure: a listing that reports a window overrides it, and an
/// unrecognised model falls back to the fixed budget.
const known_windows: []const struct { prefix: []const u8, tokens: u32 } = &.{
    .{ .prefix = "gpt-3.5", .tokens = 16_385 },
    .{ .prefix = "gpt-4-turbo", .tokens = 128_000 },
    .{ .prefix = "gpt-4o", .tokens = 128_000 },
    .{ .prefix = "gpt-4.1", .tokens = 1_047_576 },
    .{ .prefix = "gpt-4", .tokens = 8_192 },
    .{ .prefix = "gpt-5", .tokens = 400_000 },
    .{ .prefix = "o1", .tokens = 200_000 },
    .{ .prefix = "o3", .tokens = 200_000 },
    .{ .prefix = "o4", .tokens = 200_000 },
};

fn knownWindow(model: []const u8) u32 {
    var best: u32 = 0;
    var longest: usize = 0;
    for (known_windows) |entry| {
        if (!std.mem.startsWith(u8, model, entry.prefix)) continue;
        if (entry.prefix.len < longest) continue;
        longest = entry.prefix.len;
        best = entry.tokens;
    }
    return best;
}

const testing = std.testing;

test "a host is completed to an API root however it was written" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases: []const struct { host: []const u8, want: []const u8 } = &.{
        .{ .host = "https://api.openai.com/v1", .want = "https://api.openai.com/v1/models" },
        .{ .host = "https://api.openai.com/v1/", .want = "https://api.openai.com/v1/models" },
        .{ .host = "http://localhost:1234", .want = "http://localhost:1234/v1/models" },
        .{ .host = "http://localhost:1234/", .want = "http://localhost:1234/v1/models" },
    };

    for (cases) |case| {
        const backend: OpenAIProvider = .{
            .allocator = arena,
            .io = testing.io,
            .host = case.host,
            .model = "gpt-4o",
        };
        try testing.expectEqualStrings(case.want, try backend.endpoint(arena, "/models"));
    }
}

test "a request carries the transcript in the shape the API expects" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    try convo.add(.user, "list the files");
    var calls = [_]Conversation.ToolCall{.{ .id = "call_abc", .name = "list", .arguments = "{\"path\":\".\"}" }};
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    _ = try convo.append(.{ .role = .tool, .text = "build.zig", .tool_call_id = "call_abc" });

    var backend: OpenAIProvider = .{
        .allocator = arena,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
    };

    const body = try backend.buildRequest(arena, &convo, .{
        .system = "you are a harness",
        .tools_json = "[{\"type\":\"function\",\"function\":{\"name\":\"list\"}}]",
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqualStrings("local-model", root.get("model").?.string);
    try testing.expect(root.get("stream").?.bool);
    try testing.expectEqual(@as(usize, 1), root.get("tools").?.array.items.len);

    const messages = root.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 4), messages.len);
    try testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
    try testing.expectEqualStrings("you are a harness", messages[0].object.get("content").?.string);
    try testing.expectEqualStrings("list the files", messages[1].object.get("content").?.string);

    const assistant = messages[2].object;
    try testing.expectEqualStrings("assistant", assistant.get("role").?.string);
    const call = assistant.get("tool_calls").?.array.items[0].object;
    try testing.expectEqualStrings("call_abc", call.get("id").?.string);
    try testing.expectEqualStrings("function", call.get("type").?.string);
    try testing.expectEqualStrings("list", call.get("function").?.object.get("name").?.string);
    try testing.expectEqualStrings(
        "{\"path\":\".\"}",
        call.get("function").?.object.get("arguments").?.string,
    );

    const result = messages[3].object;
    try testing.expectEqualStrings("tool", result.get("role").?.string);
    try testing.expectEqualStrings("call_abc", result.get("tool_call_id").?.string);
    try testing.expectEqualStrings("build.zig", result.get("content").?.string);
}

test "an instruction rides along without joining the transcript" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hello");

    var backend: OpenAIProvider = .{
        .allocator = arena,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
    };

    const body = try backend.buildRequest(arena, &convo, .{
        .system = "brief",
        .instruction = "summarise the session",
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();

    const messages = parsed.value.object.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 3), messages.len);
    try testing.expectEqualStrings("user", messages[2].object.get("role").?.string);
    try testing.expectEqualStrings("summarise the session", messages[2].object.get("content").?.string);
    try testing.expectEqual(@as(usize, 1), convo.messages.items.len);
}

test "an image is sent as a data URL, and a blind model gets a note instead" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    var images = [_][]const u8{"iVBORw0KGgoAAAA"};
    _ = try convo.append(.{ .role = .user, .text = "what is this?", .images = &images });

    var backend: OpenAIProvider = .{
        .allocator = arena,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
    };

    {
        const body = try backend.buildRequest(arena, &convo, .{ .system = "brief" });
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const parts = parsed.value.object.get("messages").?.array.items[1].object.get("content").?.array.items;
        try testing.expectEqual(@as(usize, 2), parts.len);
        try testing.expectEqualStrings("what is this?", parts[0].object.get("text").?.string);
        try testing.expectEqualStrings(
            "data:image/png;base64,iVBORw0KGgoAAAA",
            parts[1].object.get("image_url").?.object.get("url").?.string,
        );
    }

    backend.supports_vision = false;
    const body = try backend.buildRequest(arena, &convo, .{ .system = "brief" });
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();

    const content = parsed.value.object.get("messages").?.array.items[1].object.get("content").?.string;
    try testing.expect(std.mem.indexOf(u8, content, "1 image(s) omitted") != null);
}

test "a stream of deltas folds back into one reply" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stream =
        \\data: {"choices":[{"delta":{"reasoning_content":"weighing it up"}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"Reading "}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"the file."}}]}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read","arguments":"{\"path\""}}]}}]}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"build.zig\"}"}}]}}]}
        \\
        \\data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        \\
        \\data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":8}}
        \\
        \\data: [DONE]
        \\
    ;

    var reader: std.Io.Reader = .fixed(stream);
    var collector: Collector = .init(testing.allocator, null);
    errdefer collector.deinit();
    try collector.readEvents(arena, &reader);

    var reply = try collector.finish();
    defer reply.deinit(testing.allocator);

    try testing.expectEqualStrings("Reading the file.", reply.text);
    try testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
    try testing.expectEqualStrings("call_1", reply.tool_calls[0].id);
    try testing.expectEqualStrings("read", reply.tool_calls[0].name);
    try testing.expectEqualStrings("{\"path\":\"build.zig\"}", reply.tool_calls[0].arguments);
    try testing.expectEqual(@as(u32, 120), reply.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 8), reply.usage.completion_tokens);
}

test "a server that ignores `stream` is understood anyway" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"choices":[{"message":{"content":"done","tool_calls":[
        \\{"id":"call_9","type":"function","function":{"name":"list","arguments":"{}"}}]},
        \\"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}
    ;

    var collector: Collector = .init(testing.allocator, null);
    errdefer collector.deinit();
    try collector.readWhole(arena, body);

    var reply = try collector.finish();
    defer reply.deinit(testing.allocator);

    try testing.expectEqualStrings("done", reply.text);
    try testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
    try testing.expectEqualStrings("call_9", reply.tool_calls[0].id);
    try testing.expectEqual(@as(u32, 4), reply.usage.prompt_tokens);

    try testing.expect(!streamed("application/json"));
    try testing.expect(streamed("text/event-stream; charset=utf-8"));
    try testing.expect(!streamed(null));
}

test "an error body is reduced to the sentence the server wrote" {
    const allocator = testing.allocator;

    try testing.expectEqualStrings(
        "Incorrect API key provided.",
        complaint(allocator,
            \\{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}
        ),
    );
    try testing.expectEqualStrings(
        "no model loaded",
        complaint(allocator, "{\"error\":\"no model loaded\"}"),
    );
    try testing.expectEqualStrings(
        "Not Found",
        complaint(allocator, "{\"detail\":\"Not Found\"}"),
    );
    try testing.expectEqualStrings("<html>502</html>", complaint(allocator, "  <html>502</html>\n"));
    try testing.expectEqualStrings("", complaint(allocator, "   "));
}

test "advice follows the complaint" {
    try testing.expect(std.mem.indexOf(
        u8,
        advice("This model's maximum context length is 128000 tokens"),
        "/compact",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, advice("401: Invalid API key"), "/connect") != null);
    try testing.expect(std.mem.indexOf(u8, advice("429 rate limit reached"), "again") != null);
    try testing.expect(std.mem.indexOf(u8, advice("The model `gpt-9` does not exist"), "ctrl+o") != null);
    try testing.expectEqualStrings("", advice("upstream connect error"));
}

test "a context window is taken from the listing, then the table" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const listing =
        \\{"data":[
        \\{"id":"qwen2.5-coder","max_model_len":32768},
        \\{"id":"anthropic/claude","context_length":200000},
        \\{"id":"gpt-4o","object":"model"}
        \\]}
    ;

    try testing.expectEqual(@as(u32, 32_768), listedWindow(arena, listing, "qwen2.5-coder"));
    try testing.expectEqual(@as(u32, 200_000), listedWindow(arena, listing, "anthropic/claude"));
    try testing.expectEqual(@as(u32, 0), listedWindow(arena, listing, "gpt-4o"));
    try testing.expectEqual(@as(u32, 0), listedWindow(arena, listing, "absent"));
    try testing.expectEqual(@as(u32, 0), listedWindow(arena, "<html>502</html>", "gpt-4o"));

    try testing.expectEqual(@as(u32, 128_000), knownWindow("gpt-4o-2024-08-06"));
    try testing.expectEqual(@as(u32, 128_000), knownWindow("gpt-4-turbo-preview"));
    try testing.expectEqual(@as(u32, 8_192), knownWindow("gpt-4"));
    try testing.expectEqual(@as(u32, 200_000), knownWindow("o3-mini"));
    try testing.expectEqual(@as(u32, 0), knownWindow("qwen2.5-coder"));
}

test "the model chosen by default is one that answers a chat request" {
    try testing.expect(isChatModel("gpt-4o-mini"));
    try testing.expect(isChatModel("qwen2.5-coder:7b"));
    try testing.expect(!isChatModel("text-embedding-3-small"));
    try testing.expect(!isChatModel("dall-e-3"));
    try testing.expect(!isChatModel("whisper-1"));
    try testing.expect(!isChatModel("gpt-4o-realtime-preview"));
    try testing.expect(!isChatModel("omni-moderation-latest"));
}

test "a server that rejects `stream_options` gets the same request without it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "hello");

    var backend: OpenAIProvider = .{
        .allocator = arena,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
    };

    const asking = try backend.buildRequest(arena, &convo, .{ .system = "brief" });
    try testing.expect(std.mem.indexOf(u8, asking, "stream_options") != null);

    try testing.expect(backend.retryWithout("400: unknown field \"stream_options\""));
    try testing.expect(!backend.retryWithout("400: unknown field \"stream_options\""));
    try testing.expect(!backend.retryWithout("429: rate limit reached"));

    const quiet = try backend.buildRequest(arena, &convo, .{ .system = "brief" });
    try testing.expect(std.mem.indexOf(u8, quiet, "stream_options") == null);
    try testing.expect(std.mem.indexOf(u8, quiet, "\"stream\":true") != null);
}

/// A sink that reports the turn as given up on, for the retry tests.
fn stoppedSink() Provider.Sink {
    const Always = struct {
        fn stopped(_: *anyopaque) bool {
            return true;
        }
        fn onThinking(_: *anyopaque, _: []const u8) void {}
        fn onText(_: *anyopaque, _: []const u8) void {}
    };
    const nothing = struct {
        var slot: u8 = 0;
    };
    return .{
        .userdata = &nothing.slot,
        .stopped = Always.stopped,
        .onThinking = Always.onThinking,
        .onText = Always.onText,
    };
}

test "a refusal is not sent again, however many attempts are left" {
    var backend: OpenAIProvider = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
        .retries = .{ .base_ms = 1 },
    };

    try testing.expect(!backend.waitAndRetry(.bad_request, 1, null, null));
    try testing.expect(!backend.waitAndRetry(.unauthorized, 1, null, null));
    try testing.expect(!backend.waitAndRetry(.not_found, 1, null, null));
}

test "congestion is sent again until the attempts run out" {
    var backend: OpenAIProvider = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
        .retries = .{ .attempts = 3, .base_ms = 1 },
    };

    try testing.expect(backend.waitAndRetry(.too_many_requests, 1, null, null));
    try testing.expect(backend.waitAndRetry(.service_unavailable, 2, null, null));
    try testing.expect(!backend.waitAndRetry(.too_many_requests, 3, null, null));
}

test "a delay longer than a turn is worth is not waited out" {
    var backend: OpenAIProvider = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
        .retries = .{ .base_ms = 1, .max_retry_after_ms = 1_000 },
    };

    try testing.expect(backend.waitAndRetry(.too_many_requests, 1, 500, null));
    try testing.expect(!backend.waitAndRetry(.too_many_requests, 1, 60_000, null));
}

test "a turn the user gave up on is not retried" {
    var backend: OpenAIProvider = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:1234",
        .model = "local-model",
        .retries = .{ .base_ms = 1 },
    };

    try testing.expect(!backend.waitAndRetry(.too_many_requests, 1, null, stoppedSink()));
}
