//! An Ollama-backed `Provider`.

const std = @import("std");

const Ollama = @import("ollama");
const pkg = @import("pkg");

const Conversation = @import("../core/conversation.zig");
const Provider = @import("provider.zig");
const retry = @import("retry.zig");
const window = @import("window.zig");

const OllamaProvider = @This();

allocator: std.mem.Allocator,
io: std.Io,
/// When a refused request is worth sending again.
retries: retry.Policy = .{},

/// Base URL of the server, e.g. `http://localhost:11434`. Borrowed.
host: []const u8,
/// Model tag, e.g. `qwen3`. Borrowed; also used as the provider's display name.
model: []const u8,
/// What this backend is called in the UI: the catalog provider's label, since
/// the same client talks to the local server and the hosted one. Borrowed until
/// a reconnect, which copies its own.
label: []const u8 = "Ollama",
/// Bearer token for ollama.com. Borrowed.
api_key: ?[]const u8 = null,
/// When set, every request and reply is appended here as JSON. The fastest way
/// to tell a model problem from a harness problem.
debug_log: ?[]const u8 = null,
/// Ask the model to reason before answering. Without this a thinking model has
/// no reason to emit `thinking` chunks, so the "Thought: ..." row never appears.
/// What the config asked for; `think` is this narrowed by what the model can
/// actually do.
want_think: bool = true,
/// Whether to send `think` on a request. Ollama rejects the field outright for
/// a model without the capability rather than ignoring it, so a switch to one
/// would otherwise fail every turn until the config was edited.
think: bool = true,
/// Whether to send tool definitions. Same reasoning: a model with no `tools`
/// capability is better off being asked in prose than erroring.
supports_tools: bool = true,
/// Whether to send image data. A model that cannot see does not quietly ignore
/// the field, and a transcript keeps its images forever - so switching to a
/// text-only model would break every remaining turn of the session, not just
/// the one that attached the picture.
supports_vision: bool = true,

/// Storage for the Authorization header. The client borrows this slice, so it
/// has to live in the struct rather than in `start`'s frame.
auth_header: [1]std.http.Header = undefined,
auth_value: []const u8 = "",

client: Ollama = undefined,
started: bool = false,
/// Set when the model was switched at runtime: `model` then points here rather
/// than at the config, and this is what has to be freed.
model_owned: ?[]u8 = null,
/// Same, for a host and key set by connecting a provider at runtime. The config
/// owns the ones this started with; these are ours.
host_owned: ?[]u8 = null,
key_owned: ?[]u8 = null,
label_owned: ?[]u8 = null,
/// Context window, read from the model's metadata at startup. The architecture
/// maximum: what the model could hold, not what the server gave it.
context_limit: u32 = 0,
/// Context window of the loaded runner, read from `/api/ps` once a turn has
/// landed. The server picks this - `OLLAMA_CONTEXT_LENGTH`, or its 4096
/// default - and it is usually far below what the metadata advertises. Zero
/// until a turn has run, or when the server is too old to report it.
runtime_limit: u32 = 0,
/// The window to ask the server to load the model with, sent as `num_ctx`.
///
/// Without it the server picks, and what it picks - `OLLAMA_CONTEXT_LENGTH`, or
/// its own default - is usually far below what the model can do. Null asks for
/// the model's advertised maximum; zero asks for nothing and leaves the choice
/// to the server.
num_ctx: ?u32 = null,
/// What ollama said when it last turned a request down, owned by this struct.
/// Written on the worker thread as a turn fails and read on the UI thread once
/// that turn has been joined, so no lock: the failure is the handoff.
rejection: ?[]u8 = null,

/// Build the HTTP client, then read what the model can do. Separate from field
/// initialization because the client borrows `auth_header`, which means this
/// must run once the struct is at its final address. With no model named there
/// is nothing to probe - a client built only to list what a server offers skips
/// the round trip.
pub fn start(self: *OllamaProvider) !void {
    var headers: []const std.http.Header = &.{};
    if (self.api_key) |key| {
        self.auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
        self.auth_header[0] = .{ .name = "Authorization", .value = self.auth_value };
        headers = self.auth_header[0..1];
    }

    self.client = Ollama.init(self.io, self.allocator, .{
        .host = self.host,
        .headers = headers,
    });
    self.started = true;
    if (self.model.len > 0) self.probe();
}

/// Start a second client on the same server, taking what `other` already
/// learned rather than asking again. What a nested run needs: same host, same
/// model, same answers, and no round trip to rediscover them.
pub fn startLike(self: *OllamaProvider, other: *const OllamaProvider) !void {
    try self.startWithoutProbe();
    self.context_limit = other.context_limit;
    self.runtime_limit = other.runtime_limit;
    self.think = other.think;
    self.supports_tools = other.supports_tools;
    self.supports_vision = other.supports_vision;
}

/// Read what this model can do and how much it can hold. Failures leave the
/// defaults in place: a server that will not answer `show` is a problem the
/// first request reports better than startup can.
fn probe(self: *OllamaProvider) void {
    self.context_limit = 0;
    self.runtime_limit = 0;
    self.think = self.want_think;
    self.supports_tools = true;
    self.supports_vision = true;

    var response = self.client.show(.{ .model = self.model }) catch return;
    defer response.deinit();
    const body = response.body() catch return;

    self.context_limit = contextLength(body.model_info);

    const capabilities = body.capabilities orelse return;
    self.think = self.want_think and has(capabilities, "thinking");
    self.supports_tools = has(capabilities, "tools");
    self.supports_vision = has(capabilities, "vision");
}

fn has(capabilities: []const []const u8, name: []const u8) bool {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability, name)) return true;
    }
    return false;
}

/// The model's context window. The key is architecture prefixed
/// (`qwen3.context_length`, `llama.context_length`, ...), so the first matching
/// suffix wins rather than guessing the architecture.
fn contextLength(model_info: ?std.json.Value) u32 {
    const info = model_info orelse return 0;
    const object = switch (info) {
        .object => |o| o,
        else => return 0,
    };

    var it = object.iterator();
    while (it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.key_ptr.*, ".context_length")) continue;
        return switch (entry.value_ptr.*) {
            .integer => |i| @intCast(@max(i, 0)),
            else => 0,
        };
    }
    return 0;
}

/// Model names the server has pulled, newest listing order. Caller owns the
/// result and each name.
pub fn listModels(self: *OllamaProvider, allocator: std.mem.Allocator) ![][]const u8 {
    if (!self.started) try self.startWithoutProbe();

    var response = try self.client.list();
    defer response.deinit();

    const body = try response.body();
    const names = try allocator.alloc([]const u8, body.models.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| allocator.free(name);
        allocator.free(names);
    }

    for (body.models, names) |model, *out| {
        const name = if (model.model.len > 0) model.model else model.name;
        out.* = try allocator.dupe(u8, name);
        filled += 1;
    }
    return names;
}

/// Build the client without asking the server about the configured model. The
/// listing does not need a context limit, and probing a model that is not
/// pulled yet would fail the command.
fn startWithoutProbe(self: *OllamaProvider) !void {
    var headers: []const std.http.Header = &.{};
    if (self.api_key) |key| {
        self.auth_value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
        self.auth_header[0] = .{ .name = "Authorization", .value = self.auth_value };
        headers = self.auth_header[0..1];
    }
    self.client = Ollama.init(self.io, self.allocator, .{ .host = self.host, .headers = headers });
    self.started = true;
}

/// Cap on the complaint kept from a rejected request. Ollama's errors are one
/// sentence; anything longer is a page of HTML from something in between.
const max_rejection_bytes: usize = 2 * 1024;

pub fn deinit(self: *OllamaProvider) void {
    if (self.rejection) |rejection| self.allocator.free(rejection);
    if (self.started) self.client.deinit();
    if (self.auth_value.len > 0) self.allocator.free(self.auth_value);
    if (self.model_owned) |owned| self.allocator.free(owned);
    if (self.host_owned) |owned| self.allocator.free(owned);
    if (self.key_owned) |owned| self.allocator.free(owned);
    if (self.label_owned) |owned| self.allocator.free(owned);
}

/// Point this provider at another server, with another credential.
pub fn reconnect(self: *OllamaProvider, connection: Provider.Connection) !void {
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

pub fn provider(self: *OllamaProvider) Provider {
    return .{
        .name = self.label,
        .model = self.model,
        .context_limit = self.effectiveLimit(),
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

fn listModelsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![][]const u8 {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.listModels(allocator);
}

fn setModelErased(ptr: *anyopaque, name: []const u8) anyerror!Provider.Current {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    try self.setModel(name);
    return self.current();
}

fn reconnectErased(ptr: *anyopaque, connection: Provider.Connection) anyerror!Provider.Current {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    try self.reconnect(connection);
    self.ensureModel() catch {};
    return self.current();
}

fn currentErased(ptr: *anyopaque) Provider.Current {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.current();
}

/// What this provider is pointed at, as the UI should show it.
pub fn current(self: *OllamaProvider) Provider.Current {
    return .{
        .model = self.model,
        .name = self.label,
        .context_limit = self.effectiveLimit(),
        .vision = self.supports_vision,
    };
}

fn describeErrorErased(ptr: *anyopaque, err: anyerror, allocator: std.mem.Allocator) anyerror![]const u8 {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));
    return self.describeError(err, allocator);
}

/// Ask the server to reject the request again, this time reading the body.
fn captureRejection(self: *OllamaProvider, request: Ollama.ChatRequest) void {
    self.clearRejection();
    self.rejection = self.readRejection(request) catch null;
}

/// Drop the last complaint, so a later failure of a different kind is never
/// explained with a stale one.
fn clearRejection(self: *OllamaProvider) void {
    if (self.rejection) |old| self.allocator.free(old);
    self.rejection = null;
}

fn readRejection(self: *OllamaProvider, request: Ollama.ChatRequest) !?[]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var payload: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{
        .writer = &payload.writer,
        .options = .{ .emit_null_optional_fields = false },
    };
    try json.write(request);

    const target = try std.fmt.allocPrint(arena, "{s}/api/chat", .{self.host});
    const uri = try std.Uri.parse(target);

    var client: std.http.Client = .{ .io = self.io, .allocator = arena };
    defer client.deinit();

    var req = try client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = if (self.auth_value.len > 0) self.auth_header[0..1] else &.{},
        .keep_alive = false,
    });
    defer req.deinit();

    try req.sendBodyComplete(payload.written());

    var redirect_buf: [0]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status == .ok) return null;

    var transfer: [1024]u8 = undefined;
    const body = try response.reader(&transfer).allocRemaining(
        arena,
        .limited(max_rejection_bytes),
    );

    const message = complaint(arena, body);
    if (message.len == 0) return null;
    return try self.allocator.dupe(u8, message);
}

/// The sentence out of an error body. Ollama answers `{"error": "..."}`; a proxy
/// in front of it might answer anything, so an unparseable body is handed back
/// as it came, trimmed.
fn complaint(allocator: std.mem.Allocator, body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    var parsed = std.json.parseFromSlice(
        struct { @"error": ?[]const u8 = null },
        allocator,
        trimmed,
        .{ .ignore_unknown_fields = true },
    ) catch return trimmed;
    defer parsed.deinit();

    const message = parsed.value.@"error" orelse return trimmed;
    if (std.mem.indexOf(u8, trimmed, message)) |at| return trimmed[at..][0..message.len];
    return trimmed;
}

/// Explain a failed turn in terms of what to do about it.
pub fn describeError(
    self: *OllamaProvider,
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
            "cannot reach ollama at {s}. Is it running? Start it with `ollama serve`.",
            .{self.host},
        ),
        error.HttpError => if (self.rejection) |why| return std.fmt.allocPrint(
            allocator,
            "ollama rejected the request for `{s}`: {s}. {s}",
            .{ self.model, std.mem.trimEnd(u8, why, ". \n"), advice(why) },
        ),
        else => return std.fmt.allocPrint(
            allocator,
            "{s} talking to ollama at {s}.",
            .{ @errorName(err), self.host },
        ),
    }

    const names = self.listModels(allocator) catch {
        return std.fmt.allocPrint(
            allocator,
            "ollama at {s} rejected the request, and is not answering `/api/tags` either.",
            .{self.host},
        );
    };
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    for (names) |name| {
        if (!sameModel(name, self.model)) continue;
        return std.fmt.allocPrint(
            allocator,
            "ollama rejected the request for `{s}`.{s} Try `/model` for another, " ++
                "or `/compact` if the conversation has outgrown the context window.",
            .{ self.model, self.optionalFields() },
        );
    }

    if (names.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "ollama at {s} has no models. Pull one with `ollama pull qwen3`.",
            .{self.host},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "ollama has no model called `{s}`. Pull it with `ollama pull {s}`, " ++
            "or pick one it does have with ctrl+o.",
        .{ self.model, self.model },
    );
}

/// How many times a rejected request is retried with half the history, and the
/// floor that stops at. Two halvings take a full window down to a quarter,
/// which is either enough or a sign the problem was never the size.
const max_shrink_attempts: u8 = 2;
const min_budget: usize = 2 * 1024;

/// Whether a complaint is about the size of the request, which is the one kind
/// the harness can do something about without being told.
/// Whether a refused request is worth sending again, waiting if so.
///
/// The ollama package hands back an error rather than a status, so the
/// rejection body is all there is to go on. It is only consulted for what a
/// rate limit or an outage actually says, so a refusal is never mistaken for
/// congestion.
fn waitAndRetry(
    self: *OllamaProvider,
    attempt: usize,
    why: []const u8,
    sink: ?Provider.Sink,
) bool {
    if (attempt >= self.retries.attempts) return false;
    if (!retry.transientText(why)) return false;

    if (sink) |s| {
        if (s.stopped(s.userdata)) return false;
    }

    const wait = retry.waitMs(self.retries, attempt, null);
    std.Io.sleep(self.io, .fromMilliseconds(@intCast(wait)), .awake) catch return false;

    if (sink) |s| {
        if (s.stopped(s.userdata)) return false;
    }
    return true;
}

fn isOverflow(why: []const u8) bool {
    const needles: []const []const u8 = &.{
        "context length",  "context window", "too long",     "too large",
        "too many token",  "exceeds",        "input length", "token limit",
        "maximum context",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(why, needle)) return true;
    }
    return false;
}

/// What to do about a complaint the server made. Only three answers are ever
/// useful - shorten the conversation, use a smaller model, or use a different
/// one - so this picks between them on the words ollama used.
fn advice(why: []const u8) []const u8 {
    if (isOverflow(why)) {
        return "Try `/compact` to shorten the conversation, or `/model` for one with more room.";
    }
    if (containsIgnoreCase(why, "memory")) {
        return "There is not enough memory for this model - try `/model` for a smaller one.";
    }
    return "Try `/model` for another model.";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The optional parts of a request, named because they are what a server
/// rejects when the model does not support them. Capabilities are meant to
/// have ruled this out, so a mention here is a hint that they lied.
fn optionalFields(self: *const OllamaProvider) []const u8 {
    if (self.think and self.supports_tools) return " It was sent thinking and tool definitions.";
    if (self.think) return " It was sent thinking.";
    if (self.supports_tools) return " It was sent tool definitions.";
    return "";
}

/// Point this provider at another model, re-reading the context window since
/// that is per-model and the sidebar's "how full is the context" figure is
/// meaningless against the wrong number.
pub fn setModel(self: *OllamaProvider, name: []const u8) !void {
    if (std.mem.eql(u8, name, self.model)) return;

    const owned = try self.allocator.dupe(u8, name);
    if (self.model_owned) |previous| self.allocator.free(previous);
    self.model_owned = owned;
    self.model = owned;
    self.runtime_limit = 0;

    if (self.started) self.probe();
}

/// Make sure the configured model is one the server actually has, and fall back
/// to the first it lists when it is not.
pub fn ensureModel(self: *OllamaProvider) !void {
    const names = try self.listModels(self.allocator);
    defer {
        for (names) |name| self.allocator.free(name);
        self.allocator.free(names);
    }
    if (names.len == 0) return;

    for (names) |name| {
        if (sameModel(name, self.model)) return;
    }
    try self.setModel(names[0]);
}

/// Whether a listed tag is the model that was asked for. Ollama lists
/// `qwen3:latest` for what a config calls `qwen3`, so the tag is optional on
/// the asking side.
pub fn sameModel(listed: []const u8, wanted: []const u8) bool {
    if (std.mem.eql(u8, listed, wanted)) return true;
    if (std.mem.indexOfScalar(u8, wanted, ':') != null) return false;
    const colon = std.mem.indexOfScalar(u8, listed, ':') orelse return false;
    return std.mem.eql(u8, listed[0..colon], wanted);
}

test "a listed tag matches the model it was configured as" {
    try std.testing.expect(sameModel("qwen3:latest", "qwen3"));
    try std.testing.expect(sameModel("qwen3:8b", "qwen3"));
    try std.testing.expect(sameModel("qwen3:8b", "qwen3:8b"));
    try std.testing.expect(!sameModel("qwen3:8b", "qwen3:70b"));
    try std.testing.expect(!sameModel("llama3:latest", "qwen3"));
}

/// Runs on a worker thread; blocking here is expected.
fn respond(
    ptr: *anyopaque,
    convo: *Conversation,
    turn: Provider.Turn,
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
) !Provider.Reply {
    const self: *OllamaProvider = @ptrCast(@alignCast(ptr));

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const system = turn.system;
    var budget = self.contextBudget() -| (system.len / 4);

    var tools_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (tools_parsed) |*parsed| parsed.deinit();

    const tools: ?[]const Ollama.Tool = blk: {
        if (!self.supports_tools) break :blk null;
        if (turn.tools_json.len == 0) break :blk null;
        const source = turn.tools_json;
        tools_parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch
            break :blk null;
        break :blk tools_parsed.?.value.array.items;
    };

    self.clearRejection();

    var messages: []Ollama.Message = undefined;
    var attempt: u8 = 0;
    var sends: usize = 1;
    var stream = while (true) {
        messages = try self.buildMessages(convo, arena, system, turn.instruction, budget);
        const request: Ollama.ChatRequest = .{
            .model = self.model,
            .messages = messages,
            .stream = true,
            .think = if (self.think) .{ .bool = true } else null,
            .tools = tools,
            .options = if (self.requestedContext()) |n| .{ .num_ctx = n } else null,
        };

        break self.client.chat(request) catch |err| {
            self.captureRejection(request);
            const why = self.rejection orelse "";

            if (attempt < max_shrink_attempts and budget > min_budget and isOverflow(why)) {
                attempt += 1;
                budget = @max(budget / 2, min_budget);
                continue;
            }

            if (self.waitAndRetry(sends, why, sink)) {
                sends += 1;
                continue;
            }
            return err;
        };
    };
    defer stream.deinit();

    self.clearRejection();

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);

    var usage: Provider.Usage = .{};

    var calls: std.ArrayList(Conversation.ToolCall) = .empty;
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    while (try stream.next()) |chunk| {
        if (sink) |s| {
            if (s.stopped(s.userdata)) break;
            if (chunk.message.thinking) |thinking| s.onThinking(s.userdata, thinking);
            if (chunk.message.content.len > 0) s.onText(s.userdata, chunk.message.content);

            if (chunk.message.content.len > 0 or chunk.message.tool_calls != null or chunk.done) {
                s.onThinkingDone(s.userdata);
            }
        }
        try text.appendSlice(allocator, chunk.message.content);

        if (chunk.message.tool_calls) |tool_calls| {
            for (tool_calls) |call| {
                try calls.append(allocator, try toolCall(allocator, call));
            }
        }

        if (chunk.done) {
            usage = .{
                .prompt_tokens = chunk.prompt_eval_count orelse 0,
                .completion_tokens = chunk.eval_count orelse 0,
                .eval_duration_ns = chunk.eval_duration orelse 0,
            };
            break;
        }
    }

    if (self.runtime_limit == 0) self.runtime_limit = self.readRuntimeLimit();

    const reply: Provider.Reply = .{
        .text = try text.toOwnedSlice(allocator),
        .tool_calls = try calls.toOwnedSlice(allocator),
        .usage = usage,
    };
    self.log(arena, messages, reply) catch {};
    return reply;
}

/// Append the exchange to the debug log, if one is configured. Failures are
/// swallowed: diagnostics must never break a turn.
fn log(
    self: *OllamaProvider,
    arena: std.mem.Allocator,
    messages: []const Ollama.Message,
    reply: Provider.Reply,
) !void {
    const path = self.debug_log orelse return;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("\n=== request ===\n");
    for (messages) |msg| {
        try out.writer.print("[{s}] {s}\n", .{ @tagName(msg.role), msg.content });
        if (msg.tool_calls) |tool_calls| {
            for (tool_calls) |call| {
                try out.writer.print("  -> call {s}\n", .{call.function.name});
            }
        }
    }
    try out.writer.print("=== reply ===\ntext: {s}\ncalls: {d}\n", .{
        reply.text,
        reply.tool_calls.len,
    });

    const existing = std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(1024 * 1024)) catch "";

    var combined: std.Io.Writer.Allocating = .init(arena);
    try combined.writer.writeAll(existing);
    try combined.writer.writeAll(out.written());

    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = combined.written() });
}

/// The text a message is sent as: its own, plus inlined `@mention` files, plus
/// a note standing in for images this model cannot be shown.
fn messageContent(
    allocator: std.mem.Allocator,
    msg: Conversation.Message,
    supports_vision: bool,
) ![]const u8 {
    const text = if (msg.attachments.len > 0)
        try inlineAttachments(allocator, msg)
    else
        msg.text;

    if (supports_vision or msg.images.len == 0) return text;

    return std.fmt.allocPrint(
        allocator,
        "{s}{s}<note>{d} image(s) omitted: the current model cannot see images.</note>",
        .{ text, if (text.len > 0) "\n\n" else "", msg.images.len },
    );
}

/// Rebuild the tool calls we parsed out of a previous turn, so the assistant
/// message we send back matches what the model originally produced.
fn outboundToolCalls(
    arena: std.mem.Allocator,
    calls: []const Conversation.ToolCall,
) ![]Ollama.ToolCall {
    const out = try arena.alloc(Ollama.ToolCall, calls.len);
    for (calls, out) |call, *dst| {
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            if (call.arguments.len == 0) "{}" else call.arguments,
            .{},
        ) catch std.json.Value{ .null = {} };

        dst.* = .{ .function = .{ .name = call.name, .arguments = parsed } };
    }
    return out;
}

/// Ollama does not assign call ids, so one is synthesised from the position in
/// the turn. It only has to be unique within the message.
fn toolCall(
    allocator: std.mem.Allocator,
    call: Ollama.ToolCall,
) !Conversation.ToolCall {
    var arguments: std.Io.Writer.Allocating = .init(allocator);
    errdefer arguments.deinit();
    try std.json.Stringify.value(call.function.arguments, .{}, &arguments.writer);

    return .{
        .id = try Conversation.ToolCall.synthesizeId(allocator),
        .name = try allocator.dupe(u8, call.function.name),
        .arguments = try arguments.toOwnedSlice(),
    };
}

/// Map the transcript onto Ollama's message list, with the system prompt first.
/// Message contents borrow from the conversation, which is safe because the UI
/// thread does not mutate it while a request is in flight.
/// The message text followed by each mentioned file, tagged with its path.
fn inlineAttachments(allocator: std.mem.Allocator, msg: Conversation.Message) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(msg.text);
    for (msg.attachments) |attachment| {
        try out.writer.print(
            "\n\n<file path=\"{s}\"{s}>\n{s}\n</file>",
            .{ attachment.path, if (attachment.shortened()) " truncated=\"true\"" else "", attachment.content },
        );
    }

    return out.toOwnedSlice();
}

fn buildMessages(
    self: *OllamaProvider,
    convo: *Conversation,
    allocator: std.mem.Allocator,
    system: []const u8,
    instruction: []const u8,
    budget: usize,
) ![]Ollama.Message {
    const kept = try window.messages(convo, allocator, budget, self.supports_vision);

    const extra: usize = if (instruction.len > 0) 1 else 0;
    const messages = try allocator.alloc(Ollama.Message, kept.len + 1 + extra);
    errdefer allocator.free(messages);

    const dropped = convo.messages.items.len - kept.len;
    messages[0] = .{
        .role = .system,
        .content = try window.systemText(allocator, system, kept, dropped),
    };
    if (instruction.len > 0) {
        messages[messages.len - 1] = .{ .role = .user, .content = instruction };
    }

    var next: usize = 1;
    for (kept) |msg| {
        if (msg.role == .system or msg.role == .summary) continue;
        const out = &messages[next];
        next += 1;
        out.* = .{
            .role = switch (msg.role) {
                .system, .summary => unreachable,
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
            },
            .content = try messageContent(allocator, msg, self.supports_vision),
            .images = if (self.supports_vision and msg.images.len > 0) msg.images else null,
            .tool_name = msg.tool_name,
            .tool_calls = if (msg.tool_calls.len > 0)
                try outboundToolCalls(allocator, msg.tool_calls)
            else
                null,
        };
    }

    if (instruction.len > 0) {
        messages[next] = messages[messages.len - 1];
        next += 1;
    }
    return messages[0..next];
}

/// The window to ask for, or null to let the server decide.
///
/// A runner already loaded with a different window is reloaded to match, so
/// asking for more than the machine has costs a load that fails or spills to
/// the CPU. `/api/ps` is what says which one actually happened.
pub fn requestedContext(self: *const OllamaProvider) ?u32 {
    if (self.num_ctx) |asked| return if (asked == 0) null else asked;
    return if (self.context_limit > 0) self.context_limit else null;
}

/// The context window to plan against: what the loaded runner actually has,
/// falling back to what the model says it could have.
pub fn effectiveLimit(self: *const OllamaProvider) u32 {
    if (self.runtime_limit > 0) return self.runtime_limit;
    return self.context_limit;
}

/// Ask the server what window the loaded model is running with. Called once a
/// turn has landed, since nothing is loaded before that. Zero on any failure,
/// which leaves the metadata figure in place.
fn readRuntimeLimit(self: *OllamaProvider) u32 {
    var response = self.client.ps() catch return 0;
    defer response.deinit();
    return runnerContextLength(self.allocator, response.raw, self.model);
}

/// The `context_length` `/api/ps` reports for `model`, or 0 if it says nothing
/// useful. Older servers omit the field entirely.
fn runnerContextLength(allocator: std.mem.Allocator, raw: []const u8, model: []const u8) u32 {
    const Running = struct {
        models: []const struct {
            name: []const u8 = "",
            model: []const u8 = "",
            context_length: u32 = 0,
        } = &.{},
    };

    var parsed = std.json.parseFromSlice(Running, allocator, raw, .{
        .ignore_unknown_fields = true,
    }) catch return 0;
    defer parsed.deinit();

    for (parsed.value.models) |running| {
        if (sameModel(running.model, model) or sameModel(running.name, model)) {
            return running.context_length;
        }
    }
    return 0;
}

fn contextBudget(self: *OllamaProvider) usize {
    return window.budgetFor(self.effectiveLimit());
}

test "the window asked for is the model's own unless configured otherwise" {
    var self: OllamaProvider = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .host = "",
        .model = "",
    };

    try std.testing.expect(self.requestedContext() == null);

    self.context_limit = 500_000;
    try std.testing.expectEqual(@as(u32, 500_000), self.requestedContext().?);

    self.num_ctx = 32_768;
    try std.testing.expectEqual(@as(u32, 32_768), self.requestedContext().?);

    self.num_ctx = 0;
    try std.testing.expect(self.requestedContext() == null);
}

test "the runner's window wins over what the model advertises" {
    var self: OllamaProvider = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .host = "",
        .model = "",
    };

    self.context_limit = 262_144;
    try std.testing.expectEqual(@as(u32, 262_144), self.effectiveLimit());

    self.runtime_limit = 32_768;
    try std.testing.expectEqual(@as(u32, 32_768), self.effectiveLimit());
}

test "a text-only model gets a note where the image was" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var images = [_][]const u8{ "aGk=", "aGk=" };
    const msg: Conversation.Message = .{
        .role = .user,
        .text = "what is in this screenshot?",
        .images = &images,
    };

    try std.testing.expectEqualStrings(
        "what is in this screenshot?",
        try messageContent(arena, msg, true),
    );

    const blind = try messageContent(arena, msg, false);
    try std.testing.expect(std.mem.startsWith(u8, blind, "what is in this screenshot?"));
    try std.testing.expect(std.mem.indexOf(u8, blind, "2 image(s) omitted") != null);

    const plain: Conversation.Message = .{ .role = .user, .text = "hello" };
    try std.testing.expectEqualStrings("hello", try messageContent(arena, plain, false));
}

test "capabilities narrow what a request asks for" {
    try std.testing.expect(has(&.{ "completion", "tools", "thinking" }, "thinking"));
    try std.testing.expect(!has(&.{ "completion", "tools" }, "thinking"));
    try std.testing.expect(!has(&.{}, "tools"));
}

test "the context window is read whatever the architecture calls it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        \\{"general.architecture":"qwen3","qwen3.context_length":40960}
    ,
        .{},
    );
    try std.testing.expectEqual(@as(u32, 40960), contextLength(parsed));

    try std.testing.expectEqual(@as(u32, 0), contextLength(null));
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    try std.testing.expectEqual(@as(u32, 0), contextLength(empty));
}

test "a failed turn is explained in terms of what to do about it" {
    const allocator = std.testing.allocator;

    var backend: OllamaProvider = .{
        .allocator = allocator,
        .io = std.testing.io,
        .host = "http://127.0.0.1:1",
        .model = "qwen3",
    };
    defer backend.deinit();

    const cancelled = try backend.describeError(error.Canceled, allocator);
    defer allocator.free(cancelled);
    try std.testing.expectEqualStrings("cancelled", cancelled);

    const refused = try backend.describeError(error.ConnectionRefused, allocator);
    defer allocator.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "127.0.0.1:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "ollama serve") != null);

    const odd = try backend.describeError(error.OutOfMemory, allocator);
    defer allocator.free(odd);
    try std.testing.expect(std.mem.indexOf(u8, odd, "OutOfMemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, odd, "127.0.0.1:1") != null);
}

test "the optional parts of a request are named when one is refused" {
    var backend: OllamaProvider = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .host = "http://127.0.0.1:1",
        .model = "qwen3",
        .think = true,
        .supports_tools = true,
    };
    try std.testing.expect(std.mem.indexOf(u8, backend.optionalFields(), "thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend.optionalFields(), "tool") != null);

    backend.think = false;
    try std.testing.expect(std.mem.indexOf(u8, backend.optionalFields(), "thinking") == null);

    backend.supports_tools = false;
    try std.testing.expectEqualStrings("", backend.optionalFields());
}

test "an error body is reduced to the sentence the server wrote" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "model requires more system memory (21.5 GiB) than is available (12.3 GiB)",
        complaint(testing.allocator,
            \\{"error":"model requires more system memory (21.5 GiB) than is available (12.3 GiB)"}
        ),
    );

    try testing.expectEqualStrings("502 Bad Gateway", complaint(testing.allocator, "  502 Bad Gateway\n"));
    try testing.expectEqualStrings("{\"detail\":\"nope\"}", complaint(testing.allocator, "{\"detail\":\"nope\"}"));
    try testing.expectEqualStrings("", complaint(testing.allocator, "   \n"));
}

test "advice follows the complaint" {
    const testing = std.testing;

    for ([_][]const u8{
        "input length 41234 exceeds context length 32768",
        "Request too long for this model",
        "this model's maximum context length is 32768 tokens",
    }) |why| {
        try testing.expect(isOverflow(why));
        try testing.expect(std.mem.indexOf(u8, advice(why), "/compact") != null);
    }

    const memory = "model requires more system memory (21.5 GiB) than is available";
    try testing.expect(!isOverflow(memory));
    try testing.expect(std.mem.indexOf(u8, advice(memory), "smaller") != null);

    const other = advice("registry.ollama.ai: no such host");
    try testing.expect(std.mem.indexOf(u8, other, "/compact") == null);
    try testing.expect(std.mem.indexOf(u8, other, "/model") != null);
}

test "the loaded runner's window is read from /api/ps" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const raw =
        \\{"models":[
        \\{"name":"llama3:latest","model":"llama3:latest","size":1,"context_length":8192},
        \\{"name":"qwen3:35b","model":"qwen3:35b","size":2,"context_length":4096}
        \\]}
    ;

    try testing.expectEqual(@as(u32, 4096), runnerContextLength(allocator, raw, "qwen3:35b"));
    try testing.expectEqual(@as(u32, 8192), runnerContextLength(allocator, raw, "llama3"));
    try testing.expectEqual(@as(u32, 0), runnerContextLength(allocator, raw, "mistral"));

    try testing.expectEqual(@as(u32, 0), runnerContextLength(
        allocator,
        \\{"models":[{"name":"qwen3:35b","model":"qwen3:35b","size":2}]}
    ,
        "qwen3",
    ));
    try testing.expectEqual(@as(u32, 0), runnerContextLength(allocator, "", "qwen3"));
    try testing.expectEqual(@as(u32, 0), runnerContextLength(allocator, "<html>502</html>", "qwen3"));
}

test "the window planned against is the runner's, not the metadata's" {
    const testing = std.testing;

    var backend: OllamaProvider = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:11434",
        .model = "qwen3",
        .context_limit = 262_144,
    };

    try testing.expectEqual(@as(u32, 262_144), backend.effectiveLimit());

    backend.runtime_limit = 4096;
    try testing.expectEqual(@as(u32, 4096), backend.effectiveLimit());
    try testing.expectEqual(@as(u32, 4096), backend.current().context_limit);
    try testing.expect(backend.contextBudget() < 4096);
}
