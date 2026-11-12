const std = @import("std");
const Conversation = @import("../core/conversation.zig");
const Provider = @import("provider.zig");
const OpenAI = @import("openai.zig");
const window = @import("window.zig");

const aborted_call_output = "aborted";
pub const Options = struct {
    model: []const u8,
    max_output_tokens: u32 = 0,
    context_limit: u32 = 0,
    supports_vision: bool = true,
    supports_reasoning_summary: bool = false,
    effort: []const u8 = "",
    cache_key: []const u8 = "",
    provider_tag: []const u8 = "chatgpt",
};

/// The Responses item and content types this provider writes or reads.
const Item = struct {
    const message = "message";
    const function_call = "function_call";
    const function_call_output = "function_call_output";
    const input_text = "input_text";
    const output_text = "output_text";
};

pub fn buildRequest(options: Options, arena: std.mem.Allocator, convo: *Conversation, turn: Provider.Turn) ![]u8 {
    const budget = window.requestBudgetForOutput(options.context_limit, turn, options.max_output_tokens);
    const kept = try window.completeMessages(convo, arena, budget, options.supports_vision);
    const instructions = try window.systemText(arena, turn.system, kept, 0);

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"model\":");
    try writeString(w, options.model);
    try w.writeAll(",\"input\":[");
    var input: InputWriter = .{ .writer = w, .supports_vision = options.supports_vision, .provider_tag = options.provider_tag };
    try input.text("developer", Item.input_text, instructions);
    for (kept, 0..) |msg, i| {
        if (msg.role == .system or msg.role == .summary) continue;
        try input.message(arena, msg, kept[i + 1 ..]);
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
    if (options.supports_reasoning_summary) {
        try w.writeAll("\"summary\":\"detailed\"");
        reasoning_first = false;
    }
    const effort = options.effort;
    if (effort.len > 0) {
        if (!reasoning_first) try w.writeByte(',');
        try w.writeAll("\"effort\":");
        try writeString(w, effort);
    }
    try w.writeAll("},\"include\":[\"reasoning.encrypted_content\"],\"store\":false,\"stream\":true");
    if (options.cache_key.len > 0) {
        try w.writeAll(",\"prompt_cache_key\":");
        try writeString(w, options.cache_key);
    }
    if (options.max_output_tokens > 0) try w.print(",\"max_output_tokens\":{d}", .{options.max_output_tokens});
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// Writes the transcript as Responses input items, keeping each tool output
/// next to the call it answers.
const InputWriter = struct {
    writer: *std.Io.Writer,
    supports_vision: bool,
    provider_tag: []const u8,
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
                const w = self.writer;
                try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try writeString(w, msg.tool_call_id orelse "");
                try w.writeAll(",\"output\":");
                try writeString(w, content);
                try w.writeByte('}');
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
        if (!std.mem.eql(u8, record.provider, self.provider_tag) or record.items.len == 0) return null;

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
            if (window.toolResult(all, call.id) != null) continue;
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
pub const Refusal = struct {
    code: ?Code = null,
    param: []const u8 = "",
    message: []const u8 = "",

    pub fn parse(arena: std.mem.Allocator, body: []const u8) Refusal {
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
    pub fn describe(self: Refusal, arena: std.mem.Allocator, fallback: []const u8) ![]const u8 {
        const said = if (self.message.len > 0) self.message else fallback;
        if (self.param.len == 0) return said;
        return std.fmt.allocPrint(arena, "{s} (at {s})", .{ said, self.param });
    }

    pub fn isTemporary(self: Refusal) bool {
        const code = self.code orelse return true;
        return code == .subscription_sharing_usage_unavailable or code == .subscription_sharing_user_unavailable;
    }

    pub fn toError(self: Refusal, status: std.http.Status) anyerror {
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
pub const Failure = struct {
    refusal: Refusal = .{},
    incomplete_reason: []const u8 = "",

    pub fn toError(self: Failure) anyerror {
        if (self.incomplete_reason.len > 0) return error.ResponseIncomplete;
        if (self.refusal.code == null) return error.ResponseFailed;
        return self.refusal.toError(.ok);
    }
};

/// Everything one streamed response produces: the reply, plus each completed
/// output item kept verbatim for replay.
pub const ResponseStream = struct {
    allocator: std.mem.Allocator,
    provider_tag: []const u8 = "chatgpt",
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

    pub fn init(allocator: std.mem.Allocator, sink: ?Provider.Sink) ResponseStream {
        return .{ .allocator = allocator, .sink = sink, .items = .init(allocator), .failure_arena = .init(allocator) };
    }

    pub fn deinit(self: *ResponseStream) void {
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
    pub fn readEvents(self: *ResponseStream, arena: std.mem.Allocator, reader: *std.Io.Reader) !void {
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
        if (objectField(usage, "input_tokens_details")) |details| {
            self.usage.cached_tokens = unsignedField(details, "cached_tokens");
            self.usage.cache_write_tokens = unsignedField(details, "cache_write_tokens");
        }
        if (objectField(usage, "output_tokens_details")) |details| self.usage.reasoning_tokens = unsignedField(details, "reasoning_tokens");
    }

    /// A completed response with neither text nor a call is the model
    /// spending the plan on nothing; that is an error worth seeing, not a
    /// blank turn.
    pub fn intoReply(self: *ResponseStream) !Provider.Reply {
        if (self.text.items.len == 0 and self.calls.items.len == 0) return error.EmptyResponse;

        var record: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer record.deinit();
        try record.writer.writeAll("{\"provider\":");
        try writeString(&record.writer, self.provider_tag);
        try record.writer.writeAll(",\"items\":[");
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

test "Copilot Responses retains developer instructions and stable tool-result serialization" {
    const testing = std.testing;
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "read a file");
    var calls = [_]Conversation.ToolCall{.{ .id = "call_a", .name = "read", .arguments = "{}" }};
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    _ = try convo.addToolResult("read", "call_a", "line one\n\"quoted\"");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequest(.{ .model = "gpt-6.1-sol", .provider_tag = "copilot" }, arena.allocator(), &convo, .{ .system = "You are synth." });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    const root = parsed.object;
    try testing.expect(!root.contains("instructions"));
    try testing.expect(!root.contains("prompt_cache_key"));
    try testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
    const input = root.get("input").?.array.items;
    try testing.expectEqualStrings("developer", input[0].object.get("role").?.string);
    try testing.expectEqualStrings("You are synth.", input[0].object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_a\",\"output\":\"line one\\n\\\"quoted\\\"\"}") != null);
}

test "Responses closes an unanswered reused call id within its own exchange" {
    const testing = std.testing;
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    var calls = [_]Conversation.ToolCall{.{ .id = "0", .name = "read", .arguments = "{}" }};
    try convo.add(.user, "first");
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    _ = try convo.append(.{ .role = .tool, .text = "first result", .tool_call_id = "0" });
    try convo.add(.user, "second");
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequest(.{ .model = "gpt-6.1-sol", .provider_tag = "copilot" }, arena.allocator(), &convo, .{ .system = "s" });
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    var outputs: usize = 0;
    for (root.object.get("input").?.array.items) |item| {
        if (!std.mem.eql(u8, item.object.get("type").?.string, "function_call_output")) continue;
        try testing.expectEqualStrings(if (outputs == 0) "first result" else "aborted", item.object.get("output").?.string);
        outputs += 1;
    }
    try testing.expectEqual(@as(usize, 2), outputs);
}

test "Copilot Responses preserves cache and reasoning usage with its own replay tag" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stream: ResponseStream = .init(testing.allocator, null);
    defer stream.deinit();
    stream.provider_tag = "copilot";
    var reader: std.Io.Reader = .fixed(
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":80,\"cache_write_tokens\":5},\"output_tokens\":10,\"output_tokens_details\":{\"reasoning_tokens\":4}}}}\n\n",
    );
    try stream.readEvents(arena.allocator(), &reader);
    var reply = try stream.intoReply();
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 100), reply.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 80), reply.usage.cached_tokens);
    try testing.expectEqual(@as(u32, 5), reply.usage.cache_write_tokens);
    try testing.expectEqual(@as(u32, 10), reply.usage.completion_tokens);
    try testing.expectEqual(@as(u32, 4), reply.usage.reasoning_tokens);
    const record = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), reply.provider_state.?, .{});
    try testing.expectEqualStrings("copilot", record.object.get("provider").?.string);
}

fn stopped(sink: ?Provider.Sink) bool {
    const s = sink orelse return false;
    return s.stopped(s.userdata);
}
