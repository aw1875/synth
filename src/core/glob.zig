//! Shell-style path patterns: `*`, `**`, `?`, `[abc]` and `{a,b}`.
//!
//! The conventions are the ones a person already expects from `.gitignore` and
//! from every other agent's file tools, because a pattern the model has seen a
//! thousand times should behave the way it did there:
//!
//! - `*` matches within one path segment; `**` crosses separators.
//! - `**/` may match no segments at all, so `**/x.zig` finds `x.zig` at the root.
//! - A pattern with no `/` in it is matched against the basename too, which is
//!   what makes `*.zig` mean "every zig file" rather than "every zig file in
//!   the root".

const std = @import("std");
const testing = std.testing;

/// Cap on what one pattern's braces may expand to. `{a,b}{c,d}{e,f}` is
/// already eight; anything past this is a mistake being made expensively.
pub const max_alternatives: usize = 64;

pub const Error = error{TooManyAlternatives} || std.mem.Allocator.Error;

/// A pattern with its braces expanded, ready to match many paths.
pub const Set = struct {
    arena: std.heap.ArenaAllocator,
    patterns: []const []const u8,

    /// Expand `pattern` into its brace-free forms.
    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) Error!Set {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();

        var out: std.ArrayList([]const u8) = .empty;
        try expand(arena.allocator(), pattern, &out);

        const patterns = try out.toOwnedSlice(arena.allocator());
        return .{ .arena = arena, .patterns = patterns };
    }

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
    }

    pub fn matches(self: *const Set, path: []const u8) bool {
        for (self.patterns) |pattern| {
            if (match(pattern, path)) return true;
        }
        return false;
    }
};

/// Whether `path` matches a single brace-free `pattern`.
pub fn match(pattern: []const u8, path: []const u8) bool {
    if (matchFrom(pattern, 0, path, 0)) return true;

    // A bare `*.zig` means every zig file, not only one at the root. Anchored
    // patterns say so with a `/`, so only unanchored ones get this.
    if (std.mem.indexOfScalar(u8, pattern, '/') != null) return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    return matchFrom(pattern, 0, path[slash + 1 ..], 0);
}

fn matchFrom(pattern: []const u8, from: usize, path: []const u8, at: usize) bool {
    var p = from;
    var s = at;

    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                if (p + 1 < pattern.len and pattern[p + 1] == '*') {
                    const rest = p + 2;
                    // `**/` is allowed to match no segments, so the separator
                    // it carries has to be skippable.
                    if (rest < pattern.len and pattern[rest] == '/' and
                        matchFrom(pattern, rest + 1, path, s))
                    {
                        return true;
                    }
                    var t = s;
                    while (true) {
                        if (matchFrom(pattern, rest, path, t)) return true;
                        if (t >= path.len) return false;
                        t += 1;
                    }
                }

                var t = s;
                while (true) {
                    if (matchFrom(pattern, p + 1, path, t)) return true;
                    if (t >= path.len or path[t] == '/') return false;
                    t += 1;
                }
            },
            '?' => {
                if (s >= path.len or path[s] == '/') return false;
                p += 1;
                s += 1;
            },
            '[' => {
                if (s >= path.len or path[s] == '/') return false;
                const close = classEnd(pattern, p) orelse {
                    // An unclosed `[` is a literal bracket, not an error: the
                    // pattern came from a model, and refusing it teaches
                    // nothing.
                    if (path[s] != '[') return false;
                    p += 1;
                    s += 1;
                    continue;
                };
                if (!classMatches(pattern[p + 1 .. close], path[s])) return false;
                p = close + 1;
                s += 1;
            },
            '\\' => {
                if (p + 1 >= pattern.len) return false;
                if (s >= path.len or path[s] != pattern[p + 1]) return false;
                p += 2;
                s += 1;
            },
            else => {
                if (s >= path.len or path[s] != pattern[p]) return false;
                p += 1;
                s += 1;
            },
        }
    }

    return s == path.len;
}

/// Index of the `]` closing the class opened at `open`, or null.
fn classEnd(pattern: []const u8, open: usize) ?usize {
    var at = open + 1;
    if (at < pattern.len and (pattern[at] == '!' or pattern[at] == '^')) at += 1;
    // A `]` in first position is the character itself.
    if (at < pattern.len and pattern[at] == ']') at += 1;
    while (at < pattern.len) : (at += 1) {
        if (pattern[at] == ']') return at;
    }
    return null;
}

fn classMatches(body: []const u8, c: u8) bool {
    var at: usize = 0;
    var negated = false;
    if (body.len > 0 and (body[0] == '!' or body[0] == '^')) {
        negated = true;
        at = 1;
    }

    var hit = false;
    while (at < body.len) {
        if (at + 2 < body.len and body[at + 1] == '-') {
            if (c >= body[at] and c <= body[at + 2]) hit = true;
            at += 3;
        } else {
            if (c == body[at]) hit = true;
            at += 1;
        }
    }
    return hit != negated;
}

/// Write every brace-free form of `pattern` into `out`.
fn expand(
    arena: std.mem.Allocator,
    pattern: []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    if (out.items.len >= max_alternatives) return error.TooManyAlternatives;

    const open = findBrace(pattern) orelse {
        try out.append(arena, try arena.dupe(u8, pattern));
        return;
    };
    const close = matchingBrace(pattern, open) orelse {
        try out.append(arena, try arena.dupe(u8, pattern));
        return;
    };

    const head = pattern[0..open];
    const tail = pattern[close + 1 ..];

    var alternative = open + 1;
    var at = alternative;
    var depth: usize = 0;
    while (at <= close) : (at += 1) {
        const boundary = at == close or (depth == 0 and pattern[at] == ',');
        if (!boundary) {
            switch (pattern[at]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
            continue;
        }

        const joined = try std.mem.concat(arena, u8, &.{ head, pattern[alternative..at], tail });
        try expand(arena, joined, out);
        alternative = at + 1;
    }
}

/// The first `{` that is not escaped.
fn findBrace(pattern: []const u8) ?usize {
    var at: usize = 0;
    while (at < pattern.len) : (at += 1) {
        switch (pattern[at]) {
            '\\' => at += 1,
            '{' => return at,
            else => {},
        }
    }
    return null;
}

fn matchingBrace(pattern: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var at = open;
    while (at < pattern.len) : (at += 1) {
        switch (pattern[at]) {
            '\\' => at += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return at;
            },
            else => {},
        }
    }
    return null;
}

test "a star stays inside one segment" {
    try testing.expect(match("*.zig", "main.zig"));
    try testing.expect(match("src/*.zig", "src/main.zig"));
    try testing.expect(!match("src/*.zig", "src/tui/main.zig"));
    try testing.expect(match("src/*/*.zig", "src/tui/main.zig"));
    try testing.expect(!match("*.zig", "main.zon"));
}

test "a double star crosses them" {
    try testing.expect(match("src/**/*.zig", "src/tui/app.zig"));
    try testing.expect(match("src/**/*.zig", "src/main.zig"));
    try testing.expect(match("**/*.zig", "main.zig"));
    try testing.expect(match("**", "any/depth/at/all.txt"));
    try testing.expect(!match("src/**/*.zig", "docs/tui/app.zig"));
}

test "an unanchored pattern matches the basename anywhere" {
    try testing.expect(match("*.zig", "src/provider/openai.zig"));
    try testing.expect(match("build.zig", "build.zig"));
    try testing.expect(!match("src/*.zig", "other/src/main.zig"));
}

test "question marks and classes" {
    try testing.expect(match("?.zig", "a.zig"));
    try testing.expect(!match("?.zig", "ab.zig"));
    try testing.expect(match("[abc]*.zig", "brain.zig"));
    try testing.expect(!match("[abc]*.zig", "zebra.zig"));
    try testing.expect(match("[!abc]*.zig", "zebra.zig"));
    try testing.expect(match("[a-f]oo.zig", "boo.zig"));
    try testing.expect(match("a[[]b", "a[b"));
}

test "braces expand to alternatives" {
    var set: Set = try .init(testing.allocator, "src/**/*.{zig,zon}");
    defer set.deinit();

    try testing.expectEqual(@as(usize, 2), set.patterns.len);
    try testing.expect(set.matches("src/main.zig"));
    try testing.expect(set.matches("src/tui/app.zon"));
    try testing.expect(!set.matches("src/main.txt"));
}

test "nested and empty alternatives" {
    var set: Set = try .init(testing.allocator, "{a,b{c,d}}.txt");
    defer set.deinit();

    try testing.expectEqual(@as(usize, 3), set.patterns.len);
    try testing.expect(set.matches("a.txt"));
    try testing.expect(set.matches("bc.txt"));
    try testing.expect(set.matches("bd.txt"));
    try testing.expect(!set.matches("b.txt"));

    var trailing: Set = try .init(testing.allocator, "x{,.zig}");
    defer trailing.deinit();
    try testing.expect(trailing.matches("x"));
    try testing.expect(trailing.matches("x.zig"));
}

test "a pattern without braces expands to itself" {
    var set: Set = try .init(testing.allocator, "src/**/*.zig");
    defer set.deinit();

    try testing.expectEqual(@as(usize, 1), set.patterns.len);
    try testing.expectEqualStrings("src/**/*.zig", set.patterns[0]);
}

test "an unbalanced brace is a literal, not an error" {
    var set: Set = try .init(testing.allocator, "src/{a.zig");
    defer set.deinit();

    try testing.expectEqual(@as(usize, 1), set.patterns.len);
    try testing.expect(set.matches("src/{a.zig"));
}
