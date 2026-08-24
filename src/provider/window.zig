//! Choosing which of a transcript's messages fit in a request.
//!
//! Shared by every backend: what fits in a context window is a property of the
//! conversation and the window, not of the wire format it is about to be
//! written into.

const std = @import("std");

const Conversation = @import("../core/conversation.zig");

/// The token budget for the transcript, derived from the model's context
/// window. When the window is unknown, fall back to a fixed ceiling so a long
/// session still cannot grow the request without bound.
pub fn budgetFor(limit: u32) usize {
    if (limit > 0) {
        return @intCast(@max(@as(i64, 0), @divTrunc(@as(i64, limit) * 3, 4)));
    }
    return 32 * 1024;
}

/// Rough token cost of a message, at the usual four-bytes-a-token rule.
/// Exactness does not matter, only that the request stops growing.
pub fn estimateTokens(msg: Conversation.Message, with_images: bool) usize {
    var bytes: usize = msg.text.len;
    for (msg.tool_calls) |call| {
        bytes += call.name.len + call.arguments.len;
        if (call.result) |result| bytes += result.len;
    }
    for (msg.attachments) |attachment| {
        bytes += attachment.path.len + attachment.content.len;
    }
    if (with_images) {
        for (msg.images) |image| bytes += image.len;
    }
    return bytes / 4;
}

/// The most recent messages that fit within `budget` tokens, oldest dropped
/// first. The newest message is always kept even if it alone exceeds the
/// budget, so the model always sees the prompt it is answering.
/// The newest messages that fit in `budget`, oldest dropped first.
pub fn messages(
    convo: *Conversation,
    allocator: std.mem.Allocator,
    budget: usize,
    with_images: bool,
) ![]Conversation.Message {
    const all = convo.messages.items;
    if (all.len == 0) return &.{};

    const floor = summaryFloor(all);

    var used: usize = 0;
    var first: usize = all.len;
    while (first > floor) {
        const cost = estimateTokens(all[first - 1], with_images);
        if (first < all.len and used + cost > budget) break;
        used += cost;
        first -= 1;
    }

    return allocator.dupe(Conversation.Message, all[alignToExchange(all, first)..]);
}

/// Index of the newest compaction summary, which is as far back as the window
/// ever needs to reach.
fn summaryFloor(all: []const Conversation.Message) usize {
    var i = all.len;
    while (i > 0) {
        i -= 1;
        if (all[i].role == .system) return i;
    }
    return 0;
}

/// Move a window boundary forward until it no longer splits a tool exchange.
fn alignToExchange(all: []const Conversation.Message, first: usize) usize {
    var at = first;
    while (at < all.len and all[at].role == .tool) at += 1;
    return at;
}

test "the window keeps the newest messages within budget" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    try convo.add(.user, "a" ** 100);
    try convo.add(.assistant, "b" ** 100);
    try convo.add(.user, "c" ** 100);
    try convo.add(.assistant, "d" ** 100);

    const kept = try messages(&convo, std.testing.allocator, 60, true);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("c" ** 100, kept[0].text);
    try std.testing.expectEqualStrings("d" ** 100, kept[1].text);
}

test "the window always keeps the newest message" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    try convo.add(.user, "old");
    try convo.add(.assistant, "n" ** 100);

    const kept = try messages(&convo, std.testing.allocator, 1, true);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("n" ** 100, kept[0].text);
}

test "the window never orphans a tool result from its call" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    try convo.add(.user, "a" ** 100);
    var calls = [_]Conversation.ToolCall{.{ .id = "1", .name = "list", .arguments = "{}" }};
    _ = try convo.append(.{
        .role = .assistant,
        .text = "b" ** 100,
        .tool_calls = &calls,
    });
    _ = try convo.append(.{ .role = .tool, .text = "c" ** 100, .tool_call_id = "1" });
    try convo.add(.user, "d" ** 100);

    const kept = try messages(&convo, std.testing.allocator, 60, true);
    defer std.testing.allocator.free(kept);

    try std.testing.expect(kept.len > 0);
    try std.testing.expect(kept[0].role != .tool);
}

test "an image counts against the budget" {
    const plain: Conversation.Message = .{ .role = .user, .text = "a" ** 400 };
    try std.testing.expectEqual(@as(usize, 100), estimateTokens(plain, true));

    var images = [_][]const u8{"i" ** 4000};
    const with_image: Conversation.Message = .{
        .role = .user,
        .text = "a" ** 400,
        .images = &images,
    };
    try std.testing.expectEqual(@as(usize, 1100), estimateTokens(with_image, true));

    try std.testing.expectEqual(@as(usize, 100), estimateTokens(with_image, false));
}

test "a compaction summary is the floor of the window" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    try convo.add(.user, "a" ** 100);
    try convo.add(.assistant, "b" ** 100);
    _ = try convo.append(.{ .role = .system, .text = "summary of the above" });
    try convo.add(.user, "c" ** 100);

    const kept = try messages(&convo, std.testing.allocator, 10_000, true);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("summary of the above", kept[0].text);
}

/// The system text to send: the brief, plus any compaction summaries still in
/// the window.
///
/// A summary is stored as a `system` message in the transcript, which is what
/// it is - but a chat template is entitled to insist that the only system
/// message is the first one, and several do, refusing the whole request
/// otherwise. Folding the summaries into the brief keeps the content and drops
/// the second role. Ordering survives: `messages` floors the window at the
/// newest summary, so nothing it summarises is still in the list.
pub fn systemText(
    allocator: std.mem.Allocator,
    system: []const u8,
    kept: []const Conversation.Message,
    dropped: usize,
) ![]const u8 {
    var summaries: usize = 0;
    for (kept) |msg| {
        if (msg.role == .system) summaries += 1;
    }
    if (summaries == 0 and dropped == 0) return system;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(system);
    for (kept) |msg| {
        if (msg.role != .system) continue;
        try out.writer.print("\n\n<summary>\n{s}\n</summary>", .{msg.text});
    }
    if (dropped > 0) {
        try out.writer.print(
            "\n\n<note>{d} earlier message(s) in this session were dropped to fit the context window. Ask if you need something from them.</note>",
            .{dropped},
        );
    }

    return out.toOwnedSlice();
}

test "the brief is returned untouched when there is nothing to fold in" {
    const system = "brief";
    try std.testing.expectEqualStrings(
        system,
        try systemText(std.testing.allocator, system, &.{}, 0),
    );
}

test "a summary is folded into the brief rather than sent as its own message" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const kept: []const Conversation.Message = &.{
        .{ .role = .system, .text = "what happened earlier" },
        .{ .role = .user, .text = "and then" },
    };

    const text = try systemText(arena_state.allocator(), "brief", kept, 0);
    try std.testing.expect(std.mem.startsWith(u8, text, "brief"));
    try std.testing.expect(std.mem.indexOf(u8, text, "<summary>\nwhat happened earlier\n</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "and then") == null);
}

test "the dropped-messages note still gets through" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const text = try systemText(arena_state.allocator(), "brief", &.{}, 3);
    try std.testing.expect(std.mem.indexOf(u8, text, "3 earlier message(s)") != null);
}
