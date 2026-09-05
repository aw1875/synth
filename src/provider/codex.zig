//! Native client for the ChatGPT Codex subscription backend.

const std = @import("std");

const pkg = @import("pkg");

const Auth = @import("../core/auth.zig");
const Conversation = @import("../core/conversation.zig");
const Models = @import("models.zig");
const OpenAI = @import("openai.zig");
const Provider = @import("provider.zig");
const auth_flow = @import("codex_auth.zig");
const retry = @import("retry.zig");
const window = @import("window.zig");

const CodexProvider = @This();

allocator: std.mem.Allocator,
io: std.Io,
auth: *Auth,
model: []const u8 = "",
models: ?*Models = null,
context_limit: u32 = 0,
supports_vision: bool = true,
owned_model: ?[]u8 = null,
debug_log: ?[]const u8 = null,
retries: retry.Policy = .{},
client: std.http.Client = undefined,
started: bool = false,
last_error: ?[]u8 = null,
session_id: [32]u8 = undefined,
has_session_id: bool = false,
last_conversation: ?*Conversation = null,
last_message_count: u64 = 0,

// Version Synth reports to the private Codex backend for compatibility checks.
const codex_client_version = "0.153.0";
const max_body_bytes: usize = 4 * 1024 * 1024;
const max_state_bytes: usize = 512 * 1024;
const transfer_buffer_bytes: usize = 512 * 1024;

pub fn start(self: *CodexProvider) !void {
    if (self.started) return;
    self.client = .{ .allocator = self.allocator, .io = self.io };
    self.started = true;
    self.ensureModel() catch {};
}

pub fn startLike(self: *CodexProvider, other: *const CodexProvider) !void {
    self.client = .{ .allocator = self.allocator, .io = self.io };
    self.started = true;
    self.context_limit = other.context_limit;
    self.supports_vision = other.supports_vision;
}

pub fn deinit(self: *CodexProvider) void {
    self.clearLastError();
    if (self.started) self.client.deinit();
    if (self.owned_model) |model| self.allocator.free(model);
}

pub fn provider(self: *CodexProvider) Provider {
    return .{
        .name = "Codex Subscription",
        .model = self.model,
        .context_limit = self.context_limit,
        .supports_vision = self.supports_vision,
        .userdata = self,
        .respond = respond,
        .list_models = listModelsErased,
        .set_model = setModelErased,
        .describe_current = currentErased,
        .describe_error = describeErrorErased,
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
        .supports_vision = self.supports_vision,
    };
}

fn currentErased(ptr: *anyopaque) Provider.Current {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    return self.current();
}

fn describeErrorErased(ptr: *anyopaque, err: anyerror, allocator: std.mem.Allocator) anyerror![]const u8 {
    const self: *CodexProvider = @ptrCast(@alignCast(ptr));
    return self.describeError(err, allocator);
}

pub fn reconnect(self: *CodexProvider, _: Provider.Connection) !void {
    if (!self.started) try self.start();
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
        return models.getOrFetchCatalog("codex", auth_flow.backend_url, tokens.account_id, self);
    }
    return self.fetchModels(arena);
}

pub fn fetchModels(self: *CodexProvider, arena: std.mem.Allocator) ![]const Models.Info {
    if (!self.started) {
        const is_signed_in = self.auth.key(auth_flow.provider_id) != null;
        if (!is_signed_in) return error.NotSignedIn;
        self.client = .{ .allocator = self.allocator, .io = self.io };
        self.started = true;
    }
    const tokens = try auth_flow.ensureFreshTokens(arena, self.io, self.auth);
    const request_url = try std.fmt.allocPrint(arena, "{s}/models?client_version={s}", .{ auth_flow.backend_url, codex_client_version });
    const uri = std.Uri.parse(request_url) catch return error.InvalidHost;
    const authorization_header = try std.fmt.allocPrint(arena, "Bearer {s}", .{tokens.access_token});
    const extra_headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Originator", .value = pkg.name },
    };
    const account_headers = [_]std.http.Header{
        .{ .name = "ChatGPT-Account-ID", .value = tokens.account_id },
    };
    var request = try self.client.request(.GET, uri, .{
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
    if (!self.started) try self.start();
    self.clearLastError();
    const needs_model_metadata = self.model.len == 0 or self.context_limit == 0;
    if (needs_model_metadata) try self.ensureModel();

    var attempt: usize = 1;
    var token_was_refreshed = false;
    var provider_state_was_reset = false;
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const tokens = try auth_flow.ensureFreshTokens(arena, self.io, self.auth);
        const request_body = try self.buildResponseRequestBody(arena, conversation, turn);
        const request_url = try std.fmt.allocPrint(arena, "{s}/responses", .{auth_flow.backend_url});
        const uri = std.Uri.parse(request_url) catch return error.InvalidHost;
        const authorization_header = try std.fmt.allocPrint(arena, "Bearer {s}", .{tokens.access_token});
        const session_id = self.sessionIdForConversation(conversation);
        const extra_headers = [_]std.http.Header{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "Originator", .value = pkg.name },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "session_id", .value = session_id },
            .{ .name = "version", .value = codex_client_version },
            .{ .name = "prompt_cache_key", .value = session_id },
        };
        const account_headers = [_]std.http.Header{
            .{ .name = "ChatGPT-Account-ID", .value = tokens.account_id },
        };
        var request = try self.client.request(.POST, uri, .{
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
        defer request.deinit();
        try request.sendBodyComplete(request_body);

        var redirect_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const retry_after_ms = retry.retryAfterMs(findHeaderValue(response.head, "retry-after"));
        const transfer_buffer = try arena.alloc(u8, transfer_buffer_bytes);
        const response_reader = response.reader(transfer_buffer);
        const request_succeeded = response.head.status.class() == .success;

        if (!request_succeeded) {
            const response_body = response_reader.allocRemaining(arena, .limited(max_body_bytes)) catch "";
            const error_detail = errorDetailForResponse(arena, response.head, response_body);
            self.rememberHttpError(response.head.status, error_detail);

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
            }) catch {};
        }
        return reply;
    }
}

fn errorDetailForResponse(arena: std.mem.Allocator, response_head: std.http.Client.Response.Head, response_body: []const u8) []const u8 {
    const is_rate_limited = response_head.status == .too_many_requests;
    if (!is_rate_limited) return response_body;
    const quota_used = findHeaderValue(response_head, "x-codex-primary-used-percent") orelse return response_body;
    return std.fmt.allocPrint(arena, "weekly quota {s}% used. {s}", .{ quota_used, response_body }) catch response_body;
}

fn sessionIdForConversation(self: *CodexProvider, conversation: *Conversation) []const u8 {
    const message_count = conversation.totalCount();
    const conversation_changed = self.last_conversation != conversation;
    const conversation_was_cleared = message_count < self.last_message_count;
    const needs_new_session_id = !self.has_session_id or conversation_changed or conversation_was_cleared;
    if (needs_new_session_id) {
        var random_bytes: [16]u8 = undefined;
        self.io.random(&random_bytes);
        self.session_id = std.fmt.bytesToHex(random_bytes, .lower);
        self.has_session_id = true;
    }
    self.last_conversation = conversation;
    self.last_message_count = message_count;
    return &self.session_id;
}

fn buildResponseRequestBody(self: *CodexProvider, arena: std.mem.Allocator, conversation: *Conversation, turn: Provider.Turn) ![]u8 {
    const message_budget = window.requestBudget(self.context_limit, turn);
    const messages = try window.completeMessages(conversation, arena, message_budget, self.supports_vision);
    const instructions = try window.systemText(arena, turn.system_prompt, messages, 0);
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
        try self.writeConversationMessage(arena, writer, message, &is_first_input, &can_replay_tool_results);
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
    try writer.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true,\"reasoning\":{\"summary\":\"auto\"},\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]}");
    return request_body.toOwnedSlice();
}

fn writeConversationMessage(
    self: *CodexProvider,
    arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: Conversation.Message,
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
                const state_has_tool_calls = try self.writePreservedResponseItems(arena, writer, provider_state, is_first_input);
                if (state_has_tool_calls) |has_tool_calls| {
                    can_replay_tool_results.* = has_tool_calls;
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

fn writePreservedResponseItems(self: *CodexProvider, arena: std.mem.Allocator, writer: *std.Io.Writer, provider_state: []const u8, is_first_input: *bool) !?bool {
    const saved_state = std.json.parseFromSliceLeaky(struct {
        provider: []const u8 = "",
        model: []const u8 = "",
        items: []const std.json.Value = &.{},
    }, arena, provider_state, .{ .ignore_unknown_fields = true }) catch return null;
    const belongs_to_codex = std.mem.eql(u8, saved_state.provider, "codex");
    const matches_model = std.mem.eql(u8, saved_state.model, self.model);
    const has_items = saved_state.items.len > 0;
    const can_replay_state = belongs_to_codex and matches_model and has_items;
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
        const is_reasoning_summary = std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta");
        const is_reasoning_delta = std.mem.eql(u8, event_type, "response.reasoning_text.delta");
        const is_reasoning_event = is_reasoning_summary or is_reasoning_delta;
        if (is_reasoning_event) {
            const reasoning_delta = stringValue(event_fields.get("delta") orelse return) orelse return;
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
        const provider_state_is_too_large = self.preserved_items.written().len > max_state_bytes;
        if (provider_state_is_too_large) return error.ResponseTooLong;

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
    const error_fields = switch (response_fields.get("error") orelse return fallback) {
        .object => |value| value,
        else => return fallback,
    };
    const error_message = error_fields.get("message") orelse return fallback;
    return stringValue(error_message) orelse fallback;
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

fn reportsStaleReasoningItem(response_body: []const u8) bool {
    return std.mem.indexOf(u8, response_body, "rs_") != null;
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
    const status_is_transient = retry.transient(status);
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
    return response_sink.isStopped(response_sink.userdata);
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
        error.ReasoningOnly => allocator.dupe(u8, "Codex spent reasoning tokens but returned no answer. The synth instructions may not be supported by this model."),
        error.TokenRefreshFailed => allocator.dupe(u8, "the Codex sign-in expired. Choose Codex Subscription in /providers to sign in again."),
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
    const request_body = try codex.buildResponseRequestBody(arena_state.allocator(), &conversation, .{ .system_prompt = "brief", .tools_json = tools_json });
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
        .{ .state = "{\"provider\":\"codex\",\"model\":\"previous\",\"items\":[{\"type\":\"reasoning\"}]}" },
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
        const body = try codex.buildResponseRequestBody(arena, &conversation, .{ .system_prompt = "brief" });
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
