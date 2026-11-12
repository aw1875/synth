const std = @import("std");
const Conversation = @import("../core/conversation.zig");
const Provider = @import("provider.zig");
const OpenAI = @import("openai.zig");
const window = @import("window.zig");

pub const Options = struct {
    model: []const u8,
    context_limit: u32 = 0,
    max_output_tokens: u32 = 4096,
    vision: bool = false,
};

fn object(arena: std.mem.Allocator, value: anytype) !std.json.Value {
    const encoded = try std.json.Stringify.valueAlloc(arena, value, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{});
}

const Message = struct {
    role: []const u8,
    content: std.ArrayList(std.json.Value) = .empty,
};

fn append(arena: std.mem.Allocator, messages: *std.ArrayList(Message), role: []const u8, block: std.json.Value) !void {
    if (messages.items.len == 0 or !std.mem.eql(u8, messages.items[messages.items.len - 1].role, role)) {
        try messages.append(arena, .{ .role = role });
    }
    try messages.items[messages.items.len - 1].content.append(arena, block);
}

pub fn buildRequest(options: Options, arena: std.mem.Allocator, convo: *Conversation, turn: Provider.Turn) ![]u8 {
    const kept = try window.completeMessages(convo, arena, window.requestBudgetForOutput(options.context_limit, turn, @max(@as(u32, 1), options.max_output_tokens)), options.vision);
    var messages: std.ArrayList(Message) = .empty;
    for (kept) |msg| {
        if (msg.role == .system or msg.role == .summary or msg.role == .tool) continue;
        const role = if (msg.role == .assistant) "assistant" else "user";
        const text = try OpenAI.messageContent(arena, msg, options.vision);
        if (text.len > 0) try append(arena, &messages, role, try object(arena, .{ .type = "text", .text = text }));
        if (options.vision and msg.role == .user) {
            for (msg.images) |image| try append(arena, &messages, role, try object(arena, .{
                .type = "image",
                .source = .{ .type = "base64", .media_type = OpenAI.imageMime(image), .data = image },
            }));
        }
        if (msg.role != .assistant) continue;
        for (msg.tool_calls) |call| {
            const input = std.json.parseFromSliceLeaky(std.json.Value, arena, if (call.arguments.len > 0) call.arguments else "{}", .{}) catch return error.InvalidToolArguments;
            try append(arena, &messages, "assistant", try object(arena, .{ .type = "tool_use", .id = call.id, .name = call.name, .input = input }));
        }
        for (msg.tool_calls) |call| {
            var result: []const u8 = call.result orelse "aborted";
            for (kept) |candidate| {
                if (candidate.role == .tool and std.mem.eql(u8, candidate.tool_call_id orelse "", call.id)) {
                    result = try OpenAI.messageContent(arena, candidate, false);
                    break;
                }
            }
            try append(arena, &messages, "user", try object(arena, .{ .type = "tool_result", .tool_use_id = call.id, .content = result }));
        }
    }
    if (turn.instruction.len > 0) try append(arena, &messages, "user", try object(arena, .{ .type = "text", .text = turn.instruction }));

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(options.model, .{}, w);
    try w.print(",\"stream\":true,\"max_tokens\":{d},\"system\":", .{@max(@as(u32, 1), options.max_output_tokens)});
    try std.json.Stringify.value(try window.systemText(arena, turn.system, kept, 0), .{}, w);
    try w.writeAll(",\"messages\":[");
    for (messages.items, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.value(.{ .role = msg.role, .content = msg.content.items }, .{}, w);
    }
    try w.writeByte(']');
    if (turn.tools_json.len > 2) {
        const Tool = struct { function: struct { name: []const u8, description: []const u8 = "", parameters: std.json.Value } };
        const tools = try std.json.parseFromSliceLeaky([]const Tool, arena, turn.tools_json, .{ .ignore_unknown_fields = true });
        try w.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, i| {
            if (i > 0) try w.writeByte(',');
            try std.json.Stringify.value(.{ .name = tool.function.name, .description = tool.function.description, .input_schema = tool.function.parameters }, .{}, w);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

const Pending = struct {
    id: []const u8,
    name: []const u8,
    initial: []const u8,
    arguments: std.ArrayList(u8) = .empty,
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    sink: ?Provider.Sink,
    arena: std.heap.ArenaAllocator,
    text: std.ArrayList(u8) = .empty,
    calls: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
    usage: Provider.Usage = .{},
    uncached_input_tokens: u32 = 0,
    completed: bool = false,
    thinking_closed: bool = false,
    rejection: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, sink: ?Provider.Sink) Stream {
        return .{ .allocator = allocator, .sink = sink, .arena = .init(allocator) };
    }

    pub fn deinit(self: *Stream) void {
        self.text.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn readEvents(self: *Stream, arena: std.mem.Allocator, reader: *std.Io.Reader) !void {
        var scratch: std.heap.ArenaAllocator = .init(arena);
        defer scratch.deinit();
        while (true) {
            if (self.sink) |sink| if (sink.stopped(sink.userdata)) return error.Canceled;
            _ = scratch.reset(.retain_capacity);
            var line: std.Io.Writer.Allocating = .init(scratch.allocator());
            const ended = blk: {
                _ = reader.streamDelimiter(&line.writer, '\n') catch |err| switch (err) {
                    error.EndOfStream => break :blk true,
                    error.WriteFailed => return error.OutOfMemory,
                    else => return err,
                };
                reader.toss(1);
                break :blk false;
            };
            const value = std.mem.trim(u8, line.written(), "\r ");
            if (std.mem.startsWith(u8, value, "data:")) {
                const event = try std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), std.mem.trimStart(u8, value[5..], " "), .{});
                try self.apply(event);
            }
            if (self.completed) return;
            if (ended) break;
        }
        return error.IncompleteStream;
    }

    pub fn readWhole(self: *Stream, arena: std.mem.Allocator, body: []const u8) !void {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        const fields = fieldsOf(value) orelse return error.UnexpectedResponse;
        if (fields.get("error")) |err| {
            self.rejection = try self.arena.allocator().dupe(u8, string(fieldsOf(err) orelse fields, "message") orelse "Messages API error");
            return error.ResponseFailed;
        }
        if (std.mem.eql(u8, string(fields, "stop_reason") orelse "", "max_tokens")) return error.ResponseIncomplete;
        if (fieldsOf(fields.get("usage") orelse .null)) |usage| self.readUsage(usage);
        const content = fields.get("content") orelse return error.UnexpectedResponse;
        if (content != .array) return error.UnexpectedResponse;
        for (content.array.items, 0..) |block, i| try self.startBlock(@intCast(i), block);
        self.completed = true;
    }

    fn apply(self: *Stream, event: std.json.Value) !void {
        const fields = fieldsOf(event) orelse return error.UnexpectedResponse;
        const kind = string(fields, "type") orelse return error.UnexpectedResponse;
        const a = self.arena.allocator();
        if (std.mem.eql(u8, kind, "error")) {
            self.rejection = try a.dupe(u8, string(fieldsOf(fields.get("error") orelse .null) orelse fields, "message") orelse "Messages API error");
            return error.ResponseFailed;
        }
        if (std.mem.eql(u8, kind, "message_start")) {
            const msg = fieldsOf(fields.get("message") orelse .null) orelse return;
            if (fieldsOf(msg.get("usage") orelse .null)) |usage| self.readUsage(usage);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            try self.startBlock(number(fields, "index"), fields.get("content_block") orelse return);
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            const delta = fieldsOf(fields.get("delta") orelse .null) orelse return;
            const delta_type = string(delta, "type") orelse return;
            if (std.mem.eql(u8, delta_type, "text_delta")) {
                try self.appendText(string(delta, "text") orelse "");
            } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                if (self.sink) |sink| sink.onThinking(sink.userdata, string(delta, "thinking") orelse "");
            } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                const call = self.calls.getPtr(number(fields, "index")) orelse return error.UnexpectedResponse;
                try call.arguments.appendSlice(a, string(delta, "partial_json") orelse "");
            }
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            if (fieldsOf(fields.get("usage") orelse .null)) |usage| self.readUsage(usage);
            if (fieldsOf(fields.get("delta") orelse .null)) |delta| {
                if (std.mem.eql(u8, string(delta, "stop_reason") orelse "", "max_tokens")) return error.ResponseIncomplete;
            }
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            self.completed = true;
            self.closeThinking();
        }
    }

    fn startBlock(self: *Stream, index: u32, value: std.json.Value) !void {
        const fields = fieldsOf(value) orelse return error.UnexpectedResponse;
        const kind = string(fields, "type") orelse return error.UnexpectedResponse;
        if (std.mem.eql(u8, kind, "text")) {
            try self.appendText(string(fields, "text") orelse "");
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            const a = self.arena.allocator();
            try self.calls.put(a, index, .{
                .id = try a.dupe(u8, string(fields, "id") orelse return error.UnexpectedResponse),
                .name = try a.dupe(u8, string(fields, "name") orelse return error.UnexpectedResponse),
                .initial = try std.json.Stringify.valueAlloc(a, fields.get("input") orelse std.json.Value{ .object = .empty }, .{}),
            });
            self.closeThinking();
        }
    }

    fn readUsage(self: *Stream, usage: std.json.ObjectMap) void {
        if (usage.contains("input_tokens")) self.uncached_input_tokens = number(usage, "input_tokens");
        if (usage.contains("cache_read_input_tokens")) self.usage.cached_tokens = number(usage, "cache_read_input_tokens");
        if (usage.contains("cache_creation_input_tokens")) self.usage.cache_write_tokens = number(usage, "cache_creation_input_tokens");
        self.usage.prompt_tokens = self.uncached_input_tokens +| self.usage.cached_tokens +| self.usage.cache_write_tokens;
        if (usage.contains("output_tokens")) self.usage.completion_tokens = number(usage, "output_tokens");
    }

    fn appendText(self: *Stream, text: []const u8) !void {
        if (text.len == 0) return;
        try self.text.appendSlice(self.allocator, text);
        self.closeThinking();
        if (self.sink) |sink| sink.onText(sink.userdata, text);
    }

    fn closeThinking(self: *Stream) void {
        if (self.thinking_closed) return;
        self.thinking_closed = true;
        if (self.sink) |sink| sink.onThinkingDone(sink.userdata);
    }

    pub fn intoReply(self: *Stream) !Provider.Reply {
        if (!self.completed) return error.IncompleteStream;
        if (self.text.items.len == 0 and self.calls.count() == 0) return error.EmptyResponse;
        var reply: Provider.Reply = .{ .usage = self.usage };
        errdefer reply.deinit(self.allocator);
        var calls: std.ArrayList(Conversation.ToolCall) = .empty;
        errdefer {
            for (calls.items) |*call| call.deinit(self.allocator);
            calls.deinit(self.allocator);
        }
        var keys = try self.arena.allocator().alloc(u32, self.calls.count());
        var iter = self.calls.keyIterator();
        var i: usize = 0;
        while (iter.next()) |key| : (i += 1) keys[i] = key.*;
        std.mem.sort(u32, keys, {}, std.sort.asc(u32));
        for (keys) |key| {
            const pending = self.calls.get(key).?;
            const id = try self.allocator.dupe(u8, pending.id);
            errdefer self.allocator.free(id);
            const name = try self.allocator.dupe(u8, pending.name);
            errdefer self.allocator.free(name);
            const arguments = try self.allocator.dupe(u8, if (pending.arguments.items.len > 0) pending.arguments.items else pending.initial);
            errdefer self.allocator.free(arguments);
            try calls.append(self.allocator, .{ .id = id, .name = name, .arguments = arguments });
        }
        reply.tool_calls = try calls.toOwnedSlice(self.allocator);
        reply.text = try self.text.toOwnedSlice(self.allocator);
        return reply;
    }
};

fn fieldsOf(value: std.json.Value) ?std.json.ObjectMap {
    return if (value == .object) value.object else null;
}
fn string(fields: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = fields.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
fn number(fields: std.json.ObjectMap, name: []const u8) u32 {
    const value = fields.get(name) orelse return 0;
    return if (value == .integer) @intCast(std.math.clamp(value.integer, 0, std.math.maxInt(u32))) else 0;
}

test "Messages requests pair tool batches with their results and translate schemas" {
    const testing = std.testing;
    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    try convo.add(.user, "read two files");
    var calls = [_]Conversation.ToolCall{
        .{ .id = "a", .name = "read", .arguments = "{\"path\":\"a\"}" },
        .{ .id = "b", .name = "read", .arguments = "{\"path\":\"b\"}" },
    };
    _ = try convo.append(.{ .role = .assistant, .text = "Checking.", .tool_calls = &calls });
    _ = try convo.addToolResult("read", "a", "contents of a");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const body = try buildRequest(.{ .model = "claude-org" }, arena.allocator(), &convo, .{
        .system = "s",
        .tools_json = "[{\"type\":\"function\",\"function\":{\"name\":\"read\",\"parameters\":{\"type\":\"object\"}}}]",
    });
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    const messages = value.object.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 3), messages.len);
    const assistant = messages[1].object;
    try testing.expectEqualStrings("assistant", assistant.get("role").?.string);
    try testing.expectEqual(@as(usize, 3), assistant.get("content").?.array.items.len);
    const results = messages[2].object.get("content").?.array.items;
    try testing.expectEqualStrings("contents of a", results[0].object.get("content").?.string);
    try testing.expectEqualStrings("aborted", results[1].object.get("content").?.string);
    try testing.expect(value.object.get("tools").?.array.items[0].object.contains("input_schema"));
}

test "Messages streams collect fragmented tool calls, text and cached token usage" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var stream: Stream = .init(a, null);
    defer stream.deinit();
    var reader: std.Io.Reader = .fixed(
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":3}}}
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_a","name":"read","input":{}}}
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"README.md\"}"}}
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}
        \\data: {"type":"message_stop"}
        \\
    );
    try stream.readEvents(arena.allocator(), &reader);
    var reply = try stream.intoReply();
    defer reply.deinit(a);
    try std.testing.expectEqualStrings("Checking.", reply.text);
    try std.testing.expectEqual(@as(usize, 1), reply.tool_calls.len);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", reply.tool_calls[0].arguments);
    try std.testing.expectEqual(@as(u32, 33), reply.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 20), reply.usage.cached_tokens);
    try std.testing.expectEqual(@as(u32, 3), reply.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(u32, 5), reply.usage.completion_tokens);
}

test "Messages whole replies preserve cache usage across partial usage updates" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stream: Stream = .init(testing.allocator, null);
    defer stream.deinit();
    try stream.readWhole(arena.allocator(),
        \\{"content":[{"type":"text","text":"OK"}],"usage":{"input_tokens":10,"cache_read_input_tokens":30,"cache_creation_input_tokens":7,"output_tokens":3}}
    );
    const update = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"cache_creation_input_tokens\":11,\"output_tokens\":9}", .{});
    stream.readUsage(update.object);
    var reply = try stream.intoReply();
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 51), reply.usage.prompt_tokens);
    try testing.expectEqual(@as(u32, 30), reply.usage.cached_tokens);
    try testing.expectEqual(@as(u32, 11), reply.usage.cache_write_tokens);
    try testing.expectEqual(@as(u32, 9), reply.usage.completion_tokens);
}

test "Messages whole replies reject truncated text and tool calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}",
        "{\"stop_reason\":\"max_tokens\",\"content\":[{\"type\":\"tool_use\",\"id\":\"a\",\"name\":\"read\",\"input\":{}}]}",
    }) |body| {
        var stream: Stream = .init(std.testing.allocator, null);
        defer stream.deinit();
        try std.testing.expectError(error.ResponseIncomplete, stream.readWhole(arena.allocator(), body));
        try std.testing.expect(!stream.completed);
    }
}

test "Messages refuses truncated streams and in-stream errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var stream: Stream = .init(std.testing.allocator, null);
    defer stream.deinit();
    var truncated: std.Io.Reader = .fixed("data: {\"type\":\"ping\"}\n");
    try std.testing.expectError(error.IncompleteStream, stream.readEvents(arena.allocator(), &truncated));
    var denied: std.Io.Reader = .fixed("data: {\"type\":\"error\",\"error\":{\"message\":\"policy denied\"}}\n");
    try std.testing.expectError(error.ResponseFailed, stream.readEvents(arena.allocator(), &denied));
    try std.testing.expectEqualStrings("policy denied", stream.rejection);
}
