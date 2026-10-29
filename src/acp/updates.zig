//! A session as a client without synth's extension sees it: the transcript
//! and the loop, told as `session/update`s.

const std = @import("std");
const testing = std.testing;

const protocol = @import("protocol.zig");
const Conversation = @import("../core/conversation.zig");
const todo = @import("../core/todo.zig");

/// How ACP names a tool call: its message, then its place in that message.
/// A provider's own call ids repeat from turn to turn.
pub fn toolCallId(arena: std.mem.Allocator, seq: u64, call: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}.{d}", .{ seq, call });
}

/// A call as ACP describes it, with its result once there is one. Paths in
/// its arguments are relative to `root`.
pub fn toolCall(arena: std.mem.Allocator, root: []const u8, seq: u64, index: usize, call: *const Conversation.ToolCall) !protocol.ToolCall {
    const arguments = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments, .{}) catch null;
    const content: ?[]const protocol.ToolContent = if (call.result) |result| blk: {
        const out = try arena.alloc(protocol.ToolContent, 1);
        out[0] = .{ .content = .{ .text = result } };
        break :blk out;
    } else null;
    const locations: ?[]const protocol.Location = if (argument(arguments, "path")) |path| blk: {
        const out = try arena.alloc(protocol.Location, 1);
        out[0] = .{ .path = try std.fs.path.resolve(arena, &.{ root, path }) };
        break :blk out;
    } else null;
    return .{
        .toolCallId = try toolCallId(arena, seq, index),
        .title = try title(arena, call.name, arguments),
        .kind = kinds.get(call.name) orelse .other,
        .status = status(call.status),
        .content = content,
        .locations = locations,
        .rawInput = arguments,
    };
}

/// The tool, and what it acts on.
fn title(arena: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) ![]const u8 {
    for ([_][]const u8{ "path", "command", "pattern", "url", "query", "prompt" }) |key| {
        const subject = argument(arguments, key) orelse continue;
        const line = std.mem.sliceTo(subject, '\n');
        return std.fmt.allocPrint(arena, "{s} {s}", .{ name, line[0..@min(line.len, 120)] });
    }
    return name;
}

fn argument(arguments: ?std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (arguments orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return switch (object.get(key) orelse return null) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

const kinds: std.StaticStringMap(protocol.ToolKind) = .initComptime(.{
    .{ "read", .read },
    .{ "list", .read },
    .{ "glob", .search },
    .{ "grep", .search },
    .{ "write", .edit },
    .{ "edit", .edit },
    .{ "bash", .execute },
    .{ "web_fetch", .fetch },
    .{ "web_search", .fetch },
    .{ "todo", .think },
});

pub fn status(of: Conversation.ToolCall.Status) protocol.ToolStatus {
    return switch (of) {
        .pending => .pending,
        .running => .in_progress,
        .ok => .completed,
        .failed, .rejected => .failed,
    };
}

pub fn plan(arena: std.mem.Allocator, items: []const todo.Item) ![]const protocol.PlanEntry {
    const out = try arena.alloc(protocol.PlanEntry, items.len);
    for (items, out) |item, *entry| entry.* = .{
        .content = item.text,
        .status = switch (item.status) {
            .pending => "pending",
            .active => "in_progress",
            .done => "completed",
        },
    };
    return out;
}

/// The transcript, told from the start, for `session/load`. What the harness
/// wrote for itself - summaries, tool results fed back, the system's own -
/// is left out: a call's result is told with the call.
pub fn replay(arena: std.mem.Allocator, root: []const u8, messages: []const Conversation.Message) ![]const protocol.Update {
    var out: std.ArrayList(protocol.Update) = .empty;
    for (messages) |*msg| switch (msg.role) {
        .user => if (msg.text.len > 0) try out.append(arena, .{ .user_message_chunk = .{ .content = .{ .text = msg.text } } }),
        .assistant => {
            if (msg.thinking) |thinking| try out.append(arena, .{ .agent_thought_chunk = .{ .content = .{ .text = thinking } } });
            if (msg.text.len > 0) try out.append(arena, .{ .agent_message_chunk = .{ .content = .{ .text = msg.text } } });
            for (msg.tool_calls, 0..) |*call, index| try out.append(arena, .{ .tool_call = try toolCall(arena, root, msg.seq, index, call) });
        },
        .system, .tool, .summary => {},
    };
    return out.items;
}

test "a call reads as what it acts on, where, and how it went" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const call: Conversation.ToolCall = .{ .id = "", .name = "read", .arguments = "{\"path\":\"src/a.zig\"}", .status = .ok, .result = "const a = 1;" };
    const told = try toolCall(arena, "/project", 7, 1, &call);
    try testing.expectEqualStrings("7.1", told.toolCallId);
    try testing.expectEqualStrings("read src/a.zig", told.title.?);
    try testing.expectEqual(protocol.ToolKind.read, told.kind.?);
    try testing.expectEqual(protocol.ToolStatus.completed, told.status.?);
    try testing.expectEqualStrings("/project/src/a.zig", told.locations.?[0].path);
    try testing.expectEqualStrings("const a = 1;", told.content.?[0].content.text);

    const command: Conversation.ToolCall = .{ .id = "", .name = "bash", .arguments = "{\"command\":\"zig build\\nzig build test\"}", .status = .rejected };
    const refused = try toolCall(arena, "/project", 7, 2, &command);
    try testing.expectEqualStrings("bash zig build", refused.title.?);
    try testing.expectEqual(protocol.ToolStatus.failed, refused.status.?);
    try testing.expectEqual(null, refused.locations);
    try testing.expectEqual(null, refused.content);
}

test "a replay tells the conversation and leaves out what the harness wrote" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls = [_]Conversation.ToolCall{.{ .id = "c", .name = "write", .arguments = "{\"path\":\"note.txt\"}", .status = .ok, .result = "wrote it" }};
    const messages = [_]Conversation.Message{
        .{ .seq = 1, .role = .system, .text = "Summary of the work so far." },
        .{ .seq = 2, .role = .user, .text = "make a note" },
        .{ .seq = 3, .role = .assistant, .text = "", .thinking = "a note, then", .tool_calls = &calls },
        .{ .seq = 4, .role = .tool, .text = "wrote it", .tool_call_id = "c" },
        .{ .seq = 5, .role = .assistant, .text = "done" },
        .{ .seq = 6, .role = .summary, .text = "1 file changed" },
    };
    const told = try replay(arena, "/project", &messages);
    try testing.expectEqual(4, told.len);
    try testing.expectEqualStrings("make a note", told[0].user_message_chunk.content.text);
    try testing.expectEqualStrings("a note, then", told[1].agent_thought_chunk.content.text);
    try testing.expectEqualStrings("3.0", told[2].tool_call.toolCallId);
    try testing.expectEqualStrings("done", told[3].agent_message_chunk.content.text);
}
