//! Asking the user a question mid-turn.
//!
//! The handler here is never reached. `Loop` intercepts the call, stops on
//! `awaiting_answer`, and writes the answer in as the result - the same shape
//! as the approval gate, which also stops a turn on a person and resumes it.
//! Running it on a tool worker would mean blocking that worker on a keystroke.
//!
//! The tool exists so the model is told it can ask, and so the call appears in
//! the transcript like any other.

const std = @import("std");

const tool = @import("tool.zig");

pub const name = "ask_user";

pub const all: []const tool.Tool = &.{
    .{
        .name = name,
        .description =
        \\Ask the user a question and wait for their answer. For a decision only
        \\they can make - which of two approaches, which file they meant, a
        \\value you cannot infer. Do not use it for anything you can find out by
        \\reading the project.
        ,
        .schema =
        \\{"type":"object","properties":{"question":{"type":"string","description":"What to ask. One question, phrased so a short answer settles it."},"options":{"type":"array","description":"Answers to offer, if the choice is between a few known ones","items":{"type":"string"}}},"required":["question"]}
        ,
        .handler = unreachableHandler,
        // Asking is harmless, so it never stops for approval. It stops for an
        // answer instead, which is the whole point of it.
        .read_only = true,
    },
};

fn unreachableHandler(ctx: tool.Context, _: tool.Input) !tool.Output {
    return tool.Output.err(try ctx.allocator.dupe(
        u8,
        "ask_user is answered by the user, not run as a tool",
    ));
}

/// The question a call is asking, for the UI to render. Borrowed from the
/// call's arguments.
pub fn question(arena: std.mem.Allocator, arguments: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch
        return "";
    const fields = switch (parsed) {
        .object => |object| object,
        else => return "",
    };
    const value = fields.get("question") orelse return "";
    return switch (value) {
        .string => |text| text,
        else => "",
    };
}

/// The offered answers, or empty when the question is open-ended.
pub fn options(arena: std.mem.Allocator, arguments: []const u8) []const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch
        return &.{};
    const fields = switch (parsed) {
        .object => |object| object,
        else => return &.{},
    };
    const value = fields.get("options") orelse return &.{};
    const items = switch (value) {
        .array => |array| array.items,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item != .string) continue;
        out.append(arena, item.string) catch return out.items;
    }
    return out.items;
}

const testing = std.testing;

test "the question and its options are read back out of the arguments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arguments =
        \\{"question":"Which one?","options":["left","right"]}
    ;

    try testing.expectEqualStrings("Which one?", question(arena, arguments));

    const offered = options(arena, arguments);
    try testing.expectEqual(@as(usize, 2), offered.len);
    try testing.expectEqualStrings("left", offered[0]);
    try testing.expectEqualStrings("right", offered[1]);
}

test "a question with no options is open-ended, not broken" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arguments =
        \\{"question":"What should it be called?"}
    ;
    try testing.expectEqualStrings("What should it be called?", question(arena, arguments));
    try testing.expectEqual(@as(usize, 0), options(arena, arguments).len);
}

test "arguments that are not a question read as empty rather than failing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("", question(arena, "not json"));
    try testing.expectEqualStrings("", question(arena, "[]"));
    try testing.expectEqualStrings("", question(arena, "{\"question\":7}"));
    try testing.expectEqual(@as(usize, 0), options(arena, "{\"options\":\"nope\"}").len);
}
