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

/// What replaces a tool result that a later identical call has already
/// answered. Short on purpose: its whole reason for existing is the bytes it
/// gives back.
pub const superseded_note = "[superseded: an identical call later in this conversation returned the current result]";

/// Results shorter than this are left alone. Collapsing a one-line result costs
/// more in confusion than it saves in context.
pub const supersede_floor: usize = 256;

/// The most recent messages that fit within `budget` tokens, oldest dropped
/// first. The newest message is always kept even if it alone exceeds the
/// budget, so the model always sees the prompt it is answering.
///
/// A tool result that a later identical call has already answered is replaced
/// by a note as the window is chosen, not after: the room it gives back is what
/// lets an older message stay. Ten reads of one file otherwise cost ten copies
/// of it in every request from then on, which is context spent on nine answers
/// that are already known to be stale.
pub fn messages(
    convo: *Conversation,
    allocator: std.mem.Allocator,
    budget: usize,
    with_images: bool,
) ![]Conversation.Message {
    const all = convo.messages.items;
    if (all.len == 0) return &.{};

    const floor = summaryFloor(all);

    const stale = try supersededResults(allocator, all);
    defer allocator.free(stale);

    var used: usize = 0;
    var first: usize = all.len;
    while (first > floor) {
        const at = first - 1;
        // A summary is the harness talking to the person, never sent, so it
        // costs nothing and never crowds out a message that is sent.
        const cost = if (all[at].role == .summary)
            0
        else if (stale[at])
            superseded_note.len / 4
        else
            estimateTokens(all[at], with_images);
        if (first < all.len and used + cost > budget) break;
        used += cost;
        first -= 1;
    }

    const start = alignToExchange(all, first);
    const kept = try allocator.dupe(Conversation.Message, all[start..]);
    for (kept, start..) |*msg, at| {
        if (stale[at]) msg.text = superseded_note;
    }
    return kept;
}

/// Which messages hold a tool result that a later identical call has made
/// stale. Indexed alongside `all`; caller owns the result.
///
/// Identical means the same tool and byte-for-byte the same arguments, which
/// needs no knowledge of what any tool means. A `read` of the same file at a
/// different offset is a different call and is left alone.
fn supersededResults(
    allocator: std.mem.Allocator,
    all: []const Conversation.Message,
) ![]bool {
    const stale = try allocator.alloc(bool, all.len);
    errdefer allocator.free(stale);
    @memset(stale, false);

    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(allocator);

    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |key| allocator.free(key);
        owned.deinit(allocator);
    }

    var i = all.len;
    while (i > 0) {
        i -= 1;
        const msg = all[i];
        if (msg.role != .tool) continue;
        if (msg.text.len <= supersede_floor) continue;

        const id = msg.tool_call_id orelse continue;
        const call = callFor(all, id, i) orelse continue;

        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ call.name, call.arguments });
        const entry = try keys.getOrPut(allocator, key);
        if (entry.found_existing) {
            allocator.free(key);
            stale[i] = true;
        } else {
            try owned.append(allocator, key);
        }
    }

    return stale;
}

/// The call a result belongs to: the nearest one before `before` that shares
/// its id.
///
/// Nearest rather than first, because an id is only unique within the reply it
/// arrived in. A provider that supplies none has one made up, and older
/// transcripts are full of calls numbered from zero every reply. Searching from
/// the start resolves every result in such a transcript to the same call, and
/// each one then looks like a repeat of the one before it.
fn callFor(all: []const Conversation.Message, id: []const u8, before: usize) ?Conversation.ToolCall {
    var i = @min(before, all.len);
    while (i > 0) {
        i -= 1;
        for (all[i].tool_calls) |call| {
            if (std.mem.eql(u8, call.id, id)) return call;
        }
    }
    return null;
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

/// A read of `path` and the result it came back with, as the transcript stores
/// them: the call on an assistant message, the result on a `tool` message that
/// shares its id.
fn addRead(convo: *Conversation, id: []const u8, path: []const u8, body: []const u8) !void {
    var arguments_buffer: [64]u8 = undefined;
    const arguments = try std.fmt.bufPrint(&arguments_buffer, "{{\"path\":\"{s}\"}}", .{path});

    var calls = [_]Conversation.ToolCall{.{ .id = id, .name = "read", .arguments = arguments }};
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    _ = try convo.append(.{ .role = .tool, .text = body, .tool_call_id = id });
}

test "an identical call later on makes the earlier result redundant" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const body = "x" ** (supersede_floor * 2);

    try convo.add(.user, "go");
    try addRead(&convo, "1", "a.zig", body);
    try addRead(&convo, "2", "b.zig", body);
    try addRead(&convo, "3", "a.zig", body);

    const kept = try messages(&convo, std.testing.allocator, 10_000, true);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqual(@as(usize, 7), kept.len);
    try std.testing.expectEqualStrings(superseded_note, kept[2].text);
    try std.testing.expectEqualStrings(body, kept[4].text);
    try std.testing.expectEqualStrings(body, kept[6].text);
}

test "a provider that reuses call ids does not collapse the whole transcript" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const body = "x" ** (supersede_floor * 2);

    try convo.add(.user, "go");
    try addRead(&convo, "call_0", "a.zig", body);
    try addRead(&convo, "call_0", "b.zig", body);
    try addRead(&convo, "call_0", "c.zig", body);

    const kept = try messages(&convo, std.testing.allocator, 10_000, true);
    defer std.testing.allocator.free(kept);

    for (kept) |msg| {
        try std.testing.expect(!std.mem.eql(u8, msg.text, superseded_note));
    }
}

test "the room a collapsed result gives back keeps an older message in" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const body = "x" ** (supersede_floor * 4);

    try convo.add(.user, "the first thing I asked");
    try addRead(&convo, "1", "a.zig", body);
    try addRead(&convo, "2", "a.zig", body);

    const budget = (body.len / 4) + 60;
    const kept = try messages(&convo, std.testing.allocator, budget, true);
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqualStrings("the first thing I asked", kept[0].text);
    try std.testing.expectEqualStrings(superseded_note, kept[2].text);
}

test "a different call, or a short result, is left alone" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const body = "x" ** (supersede_floor * 2);

    try convo.add(.user, "go");
    try addRead(&convo, "1", "a.zig", body);
    try addRead(&convo, "2", "other.zig", body);
    try addRead(&convo, "3", "a.zig", "short");
    try addRead(&convo, "4", "a.zig", "short");

    const kept = try messages(&convo, std.testing.allocator, 100_000, true);
    defer std.testing.allocator.free(kept);

    for (kept) |msg| {
        try std.testing.expect(!std.mem.eql(u8, msg.text, superseded_note));
    }
}

test "a result with no call to match is never collapsed" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const body = "x" ** (supersede_floor * 2);

    try convo.add(.user, "go");
    _ = try convo.append(.{ .role = .tool, .text = body, .tool_call_id = "missing" });
    _ = try convo.append(.{ .role = .tool, .text = body, .tool_call_id = "missing" });

    const kept = try messages(&convo, std.testing.allocator, 100_000, true);
    defer std.testing.allocator.free(kept);

    for (kept) |msg| {
        try std.testing.expect(!std.mem.eql(u8, msg.text, superseded_note));
    }
}

test "a summary is never sent to the model, and never costs budget" {
    const testing = std.testing;

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    _ = try convo.addUser("go", &.{}, &.{});
    _ = try convo.append(.{ .role = .assistant, .text = "did it" });
    _ = try convo.append(.{
        .role = .summary,
        .text = "done - 3 tools, 2 files changed\n  edited src/a.zig\n  wrote src/b.zig",
    });

    // A budget with no room for the summary still keeps both real messages.
    const kept = try messages(&convo, testing.allocator, 8, false);
    defer testing.allocator.free(kept);

    try testing.expectEqual(@as(usize, 3), kept.len);
    try testing.expectEqual(Conversation.Role.summary, kept[2].role);
}
