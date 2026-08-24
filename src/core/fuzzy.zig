//! Fuzzy matching, shared by everything the harness lets you search.

const std = @import("std");
const testing = std.testing;

/// Scoring weights. Tuned against the shapes these queries actually take: a
/// file name, a directory and a file name run together, a model tag, a command.
const score_match: i32 = 16;
/// A character immediately after the previous match. What makes a contiguous
/// substring beat the same letters scattered about.
const score_consecutive: i32 = 12;
/// A character starting a word or a path segment. What makes `mp` land on
/// `mention_popup.zig` rather than on the first file containing an m and a p.
const score_boundary: i32 = 14;
/// Every character skipped inside the matched span.
const penalty_gap: i32 = -2;
/// Matching inside the last path segment rather than only in the directories
/// leading to it. A weak preference: a query is allowed to cross a separator.
const score_tail: i32 = 20;
/// Longer candidates lose, gently, so a short match is not buried under a long
/// one that scores the same.
const penalty_length: i32 = -1;

pub const Options = struct {
    /// Treat the candidate as a path: characters in the last segment are worth
    /// more, and separators start a word. Off for a model tag or a command,
    /// where there is no such thing as a directory prefix.
    path: bool = false,
};

/// Whether the query asks to be matched case-sensitively, by having any capital
/// in it. Smartcase, as `zf` and every editor's search box do it: a query typed
/// in lower case matches anything, and reaching for shift is taken as meaning
/// it.
fn caseSensitive(query: []const u8) bool {
    for (query) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

/// How well `text` answers `query`, or null when it does not.
pub fn score(text: []const u8, query: []const u8, options: Options) ?i32 {
    const trimmed = std.mem.trim(u8, query, " ");
    if (trimmed.len == 0) return 0;

    const sensitive = caseSensitive(trimmed);
    var total: i32 = 0;
    var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (tokens.next()) |token| {
        total += scoreToken(text, token, options, sensitive) orelse return null;
    }
    return total;
}

/// One space-free part of a query. A higher score is a better match; scores are
/// only comparable between candidates scored against the same query.
fn scoreToken(text: []const u8, query: []const u8, options: Options, sensitive: bool) ?i32 {
    if (query.len == 0) return 0;
    if (query.len > text.len) return null;

    var end: usize = 0;
    var ahead: usize = 0;
    while (end < text.len) : (end += 1) {
        if (same(text[end], query[ahead], sensitive)) {
            ahead += 1;
            if (ahead == query.len) break;
        }
    }
    if (ahead < query.len) return null;

    var start = end;
    var back = query.len - 1;
    while (true) {
        if (same(text[start], query[back], sensitive)) {
            if (back == 0) break;
            back -= 1;
        }
        if (start == 0) break;
        start -= 1;
    }

    const tail_at = if (options.path) tailStart(text) else 0;
    var total: i32 = 0;
    var previous: ?usize = null;
    var next: usize = 0;
    var at = start;
    while (at <= end and next < query.len) : (at += 1) {
        if (!same(text[at], query[next], sensitive)) continue;
        next += 1;

        total += score_match;
        if (previous) |last| {
            if (at == last + 1) total += score_consecutive;
        }
        if (isBoundary(text, at)) total += score_boundary;
        if (options.path and at >= tail_at) total += score_tail;
        previous = at;
    }

    const span: i32 = @intCast(end + 1 - start);
    total += penalty_gap * (span - @as(i32, @intCast(query.len)));
    total += penalty_length * @as(i32, @intCast(text.len / 8));

    return total;
}

/// Whether `text` matches at all, for a caller that only needs a yes or no.
pub fn matches(text: []const u8, query: []const u8, options: Options) bool {
    return score(text, query, options) != null;
}

/// Where the last path segment starts, which is one past the last separator.
/// Directory entries carry a trailing separator, so that one does not count.
fn tailStart(path: []const u8) usize {
    var end = path.len;
    if (end > 0 and path[end - 1] == std.fs.path.sep) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, path[0..end], std.fs.path.sep)) |at| return at + 1;
    return 0;
}

/// Whether `at` starts a word: the first character, anything after a separator
/// or punctuation, and the capital in `camelCase`.
fn isBoundary(text: []const u8, at: usize) bool {
    if (at == 0) return true;
    const previous = text[at - 1];
    if (previous == '/' or previous == std.fs.path.sep) return true;
    return switch (previous) {
        '_', '-', '.', ' ', ':' => true,
        else => std.ascii.isLower(previous) and std.ascii.isUpper(text[at]),
    };
}

fn same(a: u8, b: u8, sensitive: bool) bool {
    if (sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// The best `capacity` candidates seen so far, by score.
pub fn Top(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { score: i32, index: usize };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        pub fn offer(self: *Self, index: usize, value: i32) void {
            var at = self.len;
            while (at > 0 and self.entries[at - 1].score < value) : (at -= 1) {
                if (at < capacity) self.entries[at] = self.entries[at - 1];
            }
            if (at < capacity) self.entries[at] = .{ .score = value, .index = index };
            if (self.len < capacity) self.len += 1;
        }

        /// Consider one candidate, keeping it if it matches and ranks.
        pub fn consider(self: *Self, index: usize, text: []const u8, query: []const u8, options: Options) void {
            const value = score(text, query, options) orelse return;
            self.offer(index, value);
        }

        pub fn ranked(self: *const Self) []const Entry {
            return self.entries[0..self.len];
        }
    };
}

/// Rank `candidates` against `query`, best first, for a test to read.
fn order(candidates: []const []const u8, query: []const u8, options: Options) [8]usize {
    var top: Top(8) = .{};
    for (candidates, 0..) |text, i| top.consider(i, text, query, options);

    var result: [8]usize = @splat(std.math.maxInt(usize));
    for (top.ranked(), 0..) |entry, i| result[i] = entry.index;
    return result;
}

test "a query may run two path segments together" {
    const files: []const []const u8 = &.{
        "src/tui/app.zig",
        "src/provider/ollama.zig",
        "src/core/config.zig",
    };

    try testing.expectEqual(@as(usize, 1), order(files, "srcollama", .{ .path = true })[0]);
    try testing.expect(score(files[0], "srcollama", .{ .path = true }) == null);

    try testing.expectEqual(@as(usize, 1), order(files, "ollama", .{ .path = true })[0]);
}

test "contiguous beats scattered" {
    const together = score("abc.zig", "abc", .{ .path = true }).?;
    const strewn = score("a_b_x_c.zig", "abc", .{ .path = true }).?;
    try testing.expect(together > strewn);

    try testing.expect(score("src/agent/conversation.zig", "config", .{ .path = true }) == null);
    try testing.expect(score("src/core/config.zig", "config", .{ .path = true }) != null);
}

test "word starts are what initials match" {
    const initials = score("mention_popup.zig", "mp", .{ .path = true }).?;
    const buried = score("template.zig", "mp", .{ .path = true }).?;
    try testing.expect(initials > buried);

    try testing.expect(score("readFileAlloc", "rfa", .{}).? > score("refactor", "rfa", .{}).?);
}

test "the file name outranks the directories leading to it" {
    const in_name = score("src/tui/app.zig", "app", .{ .path = true }).?;
    const in_path = score("src/app/other.zig", "app", .{ .path = true }).?;
    try testing.expect(in_name > in_path);

    const plain_name = score("src/tui/app.zig", "app", .{}).?;
    const plain_path = score("src/app/other.zig", "app", .{}).?;
    try testing.expect((in_name - in_path) > (plain_name - plain_path));
}

test "order is what separates a match from a coincidence" {
    try testing.expect(score("src/tui/app.zig", "gizpa", .{ .path = true }) == null);
    try testing.expect(score("qwen3:8b", "8bq", .{}) == null);

    try testing.expect(score("app", "application", .{}) == null);

    try testing.expectEqual(@as(?i32, 0), score("anything", "", .{}));
}

test "matching ignores case, and shorter wins a tie" {
    try testing.expect(matches("Ollama Cloud", "cloud", .{}));
    try testing.expect(matches("BUILD.zig", "build", .{}));

    const short = score("app.zig", "app", .{}).?;
    const long = score("app_with_a_long_name.zig", "app", .{}).?;
    try testing.expect(short > long);
}

test "every space-separated part has to match" {
    const path = "src/provider/ollama.zig";

    try testing.expect(score(path, "ollama zig", .{ .path = true }) != null);
    try testing.expect(score(path, "zig ollama", .{ .path = true }) != null);
    try testing.expect(score(path, "provider ollama", .{ .path = true }) != null);

    try testing.expect(score(path, "ollama nope", .{ .path = true }) == null);

    try testing.expect(
        score(path, "ollama zig", .{ .path = true }).? > score(path, "ollama", .{ .path = true }).?,
    );

    try testing.expectEqual(
        score(path, "ollama", .{ .path = true }),
        score(path, "  ollama  ", .{ .path = true }),
    );
    try testing.expectEqual(@as(?i32, 0), score(path, "   ", .{ .path = true }));
}

test "a capital in the query asks for a capital in the match" {
    try testing.expect(matches("src/tui/App.zig", "app", .{ .path = true }));
    try testing.expect(matches("src/tui/app.zig", "app", .{ .path = true }));

    try testing.expect(matches("src/tui/App.zig", "App", .{ .path = true }));
    try testing.expect(!matches("src/tui/app.zig", "App", .{ .path = true }));

    try testing.expect(!matches("readfilealloc", "read Alloc", .{}));
    try testing.expect(matches("readFileAlloc", "read Alloc", .{}));
}

test "the top list keeps the best, and keeps ties in order" {
    var top: Top(3) = .{};
    top.offer(0, 10);
    top.offer(1, 30);
    top.offer(2, 20);
    top.offer(3, 40);

    try testing.expectEqual(@as(usize, 3), top.ranked().len);
    try testing.expectEqual(@as(usize, 3), top.ranked()[0].index);
    try testing.expectEqual(@as(usize, 1), top.ranked()[1].index);
    try testing.expectEqual(@as(usize, 2), top.ranked()[2].index);

    var ties: Top(3) = .{};
    ties.offer(7, 5);
    ties.offer(8, 5);
    ties.offer(9, 5);
    try testing.expectEqual(@as(usize, 7), ties.ranked()[0].index);
    try testing.expectEqual(@as(usize, 9), ties.ranked()[2].index);
}
