//! The steps the model is working through.
//!
//! Like `ask_user`, the handler here is never reached: `Loop` intercepts the
//! call and applies it on the thread that draws. The list is UI state, and a
//! tool worker writing it while a frame reads it is a race for no gain - there
//! is nothing to do here that takes any time.

const std = @import("std");

const todo = @import("../core/todo.zig");
const tool = @import("tool.zig");

pub const name = "todo";

pub const all: []const tool.Tool = &.{
    .{
        .name = name,
        .description =
        \\Record the steps you are working through, as the whole list every
        \\time. Use it for work that takes several steps: write the list before
        \\starting, mark one step active as you begin it, and mark it done as
        \\soon as it is finished. Leave it alone for anything you can do in a
        \\single step.
        ,
        .schema =
        \\{"type":"object","properties":{"items":{"type":"array","description":"Every step, in order. This replaces the previous list.","items":{"type":"object","properties":{"text":{"type":"string","description":"What the step is, in a few words"},"status":{"type":"string","enum":["pending","active","done"],"description":"Only one step may be active"}},"required":["text"]}}},"required":["items"]}
        ,
        .handler = unreachableHandler,
        // Writing down a plan changes nothing on disk, so it never prompts.
        .read_only = true,
    },
};

fn unreachableHandler(ctx: tool.Context, _: tool.Input) !tool.Output {
    return tool.Output.err(try ctx.allocator.dupe(
        u8,
        "todo is applied by the harness, not run as a tool",
    ));
}

/// The steps a call is asking for. Borrowed from `arena`, and empty when the
/// arguments are not a list of steps - which reads back to the model as a list
/// it just emptied, and is a truthful answer to what it sent.
pub fn parse(arena: std.mem.Allocator, arguments: []const u8) []const todo.Item {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch
        return &.{};

    const fields = switch (parsed) {
        .object => |object| object,
        else => return &.{},
    };
    const value = fields.get("items") orelse return &.{};
    const entries = switch (value) {
        .array => |array| array.items,
        else => return &.{},
    };

    var out: std.ArrayList(todo.Item) = .empty;
    for (entries) |entry| {
        const item = switch (entry) {
            .object => |object| object,
            .string => |text| {
                out.append(arena, .{ .text = text }) catch return out.items;
                continue;
            },
            else => continue,
        };

        const text = switch (item.get("text") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const status = if (item.get("status")) |raw| switch (raw) {
            .string => |s| todo.Status.parse(s) orelse .pending,
            else => .pending,
        } else .pending;

        out.append(arena, .{ .text = text, .status = status }) catch return out.items;
    }
    return out.items;
}

/// What the model reads back. Short on purpose: it already knows what it sent,
/// and the useful part is the count it can check itself against.
pub fn summary(allocator: std.mem.Allocator, list: *const todo.List) ![]const u8 {
    if (!list.any()) return allocator.dupe(u8, "the list is empty");

    if (list.current()) |item| {
        return std.fmt.allocPrint(allocator, "{d}/{d} done, now: {s}", .{
            list.done(),
            list.items.items.len,
            item.text,
        });
    }
    return std.fmt.allocPrint(allocator, "all {d} done", .{list.items.items.len});
}

const testing = std.testing;

test "steps and their statuses are read out of the arguments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = parse(arena,
        \\{"items":[{"text":"read the code","status":"done"},{"text":"write the test","status":"active"},{"text":"run it"}]}
    );

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("read the code", items[0].text);
    try testing.expectEqual(todo.Status.done, items[0].status);
    try testing.expectEqual(todo.Status.active, items[1].status);
    try testing.expectEqual(todo.Status.pending, items[2].status);
}

test "a bare list of strings is still a list of steps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = parse(arena, "{\"items\":[\"one\",\"two\"]}");
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("one", items[0].text);
    try testing.expectEqual(todo.Status.pending, items[1].status);
}

test "arguments that are not steps read as an empty list" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(usize, 0), parse(arena, "not json").len);
    try testing.expectEqual(@as(usize, 0), parse(arena, "[]").len);
    try testing.expectEqual(@as(usize, 0), parse(arena, "{\"items\":7}").len);
    try testing.expectEqual(@as(usize, 0), parse(arena, "{\"items\":[{\"status\":\"done\"}]}").len);
    try testing.expectEqual(@as(usize, 0), parse(arena, "{}").len);
}

test "an unknown status is pending rather than a refusal" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = parse(arena, "{\"items\":[{\"text\":\"a\",\"status\":\"halfway\"}]}");
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(todo.Status.pending, items[0].status);
}

test "the summary names where the work stands" {
    var list: todo.List = .init(testing.allocator);
    defer list.deinit();

    const empty = try summary(testing.allocator, &list);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("the list is empty", empty);

    try list.replace(&.{
        .{ .text = "read", .status = .done },
        .{ .text = "write", .status = .active },
    });
    const midway = try summary(testing.allocator, &list);
    defer testing.allocator.free(midway);
    try testing.expectEqualStrings("1/2 done, now: write", midway);

    try list.replace(&.{.{ .text = "read", .status = .done }});
    const finished = try summary(testing.allocator, &list);
    defer testing.allocator.free(finished);
    try testing.expectEqualStrings("all 1 done", finished);
}
