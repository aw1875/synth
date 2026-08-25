//! What a turn did, read back off the transcript.
//!
//! Derived rather than recorded: every tool call is already in the
//! conversation with its status, so counting them costs nothing and a resumed
//! session recaps correctly without anything having been stored.

const std = @import("std");

const Conversation = @import("../core/conversation.zig");

/// Most paths named before the rest become a count. A turn that touched twenty
/// files is better summed than listed.
pub const max_paths: usize = 5;

/// What one tool call did, as far as a recap cares.
pub const Kind = enum {
    wrote,
    edited,
    ran,
    read,
    other,

    /// Which kind a tool name counts as. Unknown tools - one from a server,
    /// say - are `other`: they ran, and nothing here can say what they touched.
    pub fn of(name: []const u8) Kind {
        if (std.mem.eql(u8, name, "write")) return .wrote;
        if (std.mem.eql(u8, name, "edit")) return .edited;
        if (std.mem.eql(u8, name, "bash")) return .ran;
        if (std.mem.eql(u8, name, "read")) return .read;
        if (std.mem.eql(u8, name, "list")) return .read;
        if (std.mem.eql(u8, name, "glob")) return .read;
        if (std.mem.eql(u8, name, "grep")) return .read;
        return .other;
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .wrote => "wrote",
            .edited => "edited",
            .ran => "ran",
            .read => "read",
            .other => "ran",
        };
    }
};

/// One line of the recap: what happened, and to what.
pub const Entry = struct {
    kind: Kind,
    /// The path written or edited, or the command run. Borrowed from the
    /// conversation, so it lives exactly as long as the message does.
    subject: []const u8,
};

pub const Recap = struct {
    /// Calls that ran and came back without an error.
    ok: usize = 0,
    failed: usize = 0,
    rejected: usize = 0,
    /// Distinct files written or edited.
    changed: usize = 0,
    entries: std.ArrayList(Entry) = .empty,
    /// How many entries were left out of `entries` once it filled up.
    more: usize = 0,

    pub fn deinit(self: *Recap, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Whether there is anything worth drawing. A turn that only answered has
    /// nothing to recap: the answer is already on screen.
    pub fn any(self: *const Recap) bool {
        return self.ok + self.failed + self.rejected > 0;
    }
};

/// Read back what the messages from `start_seq` onward did.
///
/// Only calls that reached a settled status count. A pending one belongs to a
/// turn that has not finished, and this is only ever asked about one that has.
///
/// A turn whose opening message has been trimmed out of the transcript recaps
/// as nothing rather than as the whole history that is left.
pub fn of(
    allocator: std.mem.Allocator,
    messages: []const Conversation.Message,
    start_seq: ?u64,
) !Recap {
    var recap: Recap = .{};
    errdefer recap.deinit(allocator);

    const start = indexOf(messages, start_seq) orelse return recap;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (messages[start..]) |msg| {
        for (msg.tool_calls) |call| {
            switch (call.status) {
                .ok => recap.ok += 1,
                .failed => recap.failed += 1,
                .rejected => {
                    recap.rejected += 1;
                    continue;
                },
                .pending, .running => continue,
            }

            const kind = Kind.of(call.name);
            const subject = subjectOf(kind, call.arguments) orelse continue;

            if (kind == .wrote or kind == .edited) {
                const entry = try seen.getOrPut(allocator, subject);
                if (entry.found_existing) continue;
                recap.changed += 1;
            } else if (kind == .read) {
                // Reads are counted, never listed: a turn that read nine files
                // to change one has one interesting line in it.
                continue;
            }

            if (recap.entries.items.len >= max_paths) {
                recap.more += 1;
                continue;
            }
            try recap.entries.append(allocator, .{ .kind = kind, .subject = subject });
        }
    }
    return recap;
}

fn indexOf(messages: []const Conversation.Message, seq: ?u64) ?usize {
    const want = seq orelse return null;
    for (messages, 0..) |msg, i| {
        if (msg.seq == want) return i;
    }
    return null;
}

/// The path or command a call was about, pulled back out of its arguments.
/// Null when they were not what the tool's schema asked for, which the recap
/// treats as nothing to say rather than as a failure of its own.
fn subjectOf(kind: Kind, arguments: []const u8) ?[]const u8 {
    const key = switch (kind) {
        .wrote, .edited => "path",
        .ran => "command",
        .read, .other => return null,
    };
    return jsonString(arguments, key);
}

/// The value of `key` in a flat JSON object, without allocating. Scans for the
/// quoted key at the top level and reads the string that follows.
fn jsonString(source: []const u8, key: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        switch (source[i]) {
            '{', '[' => depth += 1,
            '}', ']' => depth -|= 1,
            '"' => {
                const close = closingQuote(source, i) orelse return null;
                if (depth == 1 and std.mem.eql(u8, source[i + 1 .. close], key)) {
                    return valueAfter(source, close + 1);
                }
                i = close;
            },
            else => {},
        }
    }
    return null;
}

/// Where the string opening at `open` ends, skipping anything escaped.
fn closingQuote(source: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == '"') return i;
    }
    return null;
}

/// The string value following a key, or null when the value is not a string.
fn valueAfter(source: []const u8, from: usize) ?[]const u8 {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == ':')) : (i += 1) {}
    if (i >= source.len or source[i] != '"') return null;
    const close = closingQuote(source, i) orelse return null;
    return source[i + 1 .. close];
}

const testing = std.testing;

fn made(name: []const u8, arguments: []const u8, status: Conversation.ToolCall.Status) Conversation.ToolCall {
    return .{ .id = "", .name = name, .arguments = arguments, .status = status };
}

test "a turn is read back as what it changed and what it ran" {
    var calls = [_]Conversation.ToolCall{
        made("read", "{\"path\":\"src/a.zig\"}", .ok),
        made("edit", "{\"path\":\"src/a.zig\"}", .ok),
        made("write", "{\"path\":\"src/b.zig\",\"content\":\"x\"}", .ok),
        made("bash", "{\"command\":\"zig build test\"}", .ok),
    };
    const messages = [_]Conversation.Message{
        .{ .role = .user, .text = "go", .seq = 1 },
        .{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 2 },
    };

    var recap = try of(testing.allocator, &messages, 1);
    defer recap.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), recap.ok);
    try testing.expectEqual(@as(usize, 2), recap.changed);
    try testing.expectEqual(@as(usize, 3), recap.entries.items.len);
    try testing.expectEqual(Kind.edited, recap.entries.items[0].kind);
    try testing.expectEqualStrings("src/a.zig", recap.entries.items[0].subject);
    try testing.expectEqualStrings("src/b.zig", recap.entries.items[1].subject);
    try testing.expectEqualStrings("zig build test", recap.entries.items[2].subject);
}

test "the same file touched twice is one change" {
    var calls = [_]Conversation.ToolCall{
        made("edit", "{\"path\":\"src/a.zig\"}", .ok),
        made("edit", "{\"path\":\"src/a.zig\"}", .ok),
        made("edit", "{\"path\":\"src/b.zig\"}", .ok),
    };
    const messages = [_]Conversation.Message{.{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 1 }};

    var recap = try of(testing.allocator, &messages, 1);
    defer recap.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), recap.changed);
    try testing.expectEqual(@as(usize, 2), recap.entries.items.len);
}

test "only the messages from the turn's start count" {
    var earlier = [_]Conversation.ToolCall{made("write", "{\"path\":\"old.zig\"}", .ok)};
    var later = [_]Conversation.ToolCall{made("write", "{\"path\":\"new.zig\"}", .ok)};
    const messages = [_]Conversation.Message{
        .{ .role = .assistant, .text = "", .tool_calls = &earlier, .seq = 1 },
        .{ .role = .user, .text = "again", .seq = 2 },
        .{ .role = .assistant, .text = "", .tool_calls = &later, .seq = 3 },
    };

    var recap = try of(testing.allocator, &messages, 2);
    defer recap.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), recap.changed);
    try testing.expectEqualStrings("new.zig", recap.entries.items[0].subject);
}

test "calls that failed or were refused are counted, not listed" {
    var calls = [_]Conversation.ToolCall{
        made("bash", "{\"command\":\"false\"}", .failed),
        made("write", "{\"path\":\"nope.zig\"}", .rejected),
        made("edit", "{\"path\":\"yes.zig\"}", .ok),
        made("read", "{\"path\":\"x.zig\"}", .pending),
    };
    const messages = [_]Conversation.Message{.{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 1 }};

    var recap = try of(testing.allocator, &messages, 1);
    defer recap.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), recap.ok);
    try testing.expectEqual(@as(usize, 1), recap.failed);
    try testing.expectEqual(@as(usize, 1), recap.rejected);
    try testing.expectEqual(@as(usize, 1), recap.changed);
    // The refused write is not a change, and the failed command still ran.
    try testing.expectEqual(@as(usize, 2), recap.entries.items.len);
}

test "a long turn names some paths and counts the rest" {
    var calls: [max_paths + 4]Conversation.ToolCall = undefined;
    const paths = [_][]const u8{
        "{\"path\":\"a\"}", "{\"path\":\"b\"}", "{\"path\":\"c\"}",
        "{\"path\":\"d\"}", "{\"path\":\"e\"}", "{\"path\":\"f\"}",
        "{\"path\":\"g\"}", "{\"path\":\"h\"}", "{\"path\":\"i\"}",
    };
    for (&calls, paths[0..calls.len]) |*c, args| c.* = made("write", args, .ok);
    const messages = [_]Conversation.Message{.{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 1 }};

    var recap = try of(testing.allocator, &messages, 1);
    defer recap.deinit(testing.allocator);

    try testing.expectEqual(max_paths, recap.entries.items.len);
    try testing.expectEqual(calls.len - max_paths, recap.more);
    try testing.expectEqual(calls.len, recap.changed);
}

test "a turn that only answered has nothing to recap" {
    const messages = [_]Conversation.Message{
        .{ .role = .user, .text = "hello", .seq = 1 },
        .{ .role = .assistant, .text = "hi", .seq = 2 },
    };

    var recap = try of(testing.allocator, &messages, 1);
    defer recap.deinit(testing.allocator);
    try testing.expect(!recap.any());
}

test "arguments that are not what the tool asked for are skipped" {
    var calls = [_]Conversation.ToolCall{
        made("write", "not json", .ok),
        made("write", "{\"content\":\"no path here\"}", .ok),
        made("bash", "{\"command\":42}", .ok),
        made("edit", "{\"nested\":{\"path\":\"decoy.zig\"},\"path\":\"real.zig\"}", .ok),
    };
    const messages = [_]Conversation.Message{.{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 1 }};

    var recap = try of(testing.allocator, &messages, 1);
    defer recap.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), recap.ok);
    try testing.expectEqual(@as(usize, 1), recap.entries.items.len);
    try testing.expectEqualStrings("real.zig", recap.entries.items[0].subject);
}

test "paging older history in does not move the turn a recap covers" {
    var older_calls = [_]Conversation.ToolCall{made("write", "{\"path\":\"ancient.zig\"}", .ok)};
    var calls = [_]Conversation.ToolCall{made("write", "{\"path\":\"today.zig\"}", .ok)};

    const before = [_]Conversation.Message{
        .{ .role = .user, .text = "go", .seq = 7 },
        .{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 8 },
    };
    var first = try of(testing.allocator, &before, 7);
    defer first.deinit(testing.allocator);

    // The same transcript with two older messages paged in front of it: every
    // index has moved, and the seq has not.
    const after = [_]Conversation.Message{
        .{ .role = .user, .text = "long ago", .seq = 1 },
        .{ .role = .assistant, .text = "", .tool_calls = &older_calls, .seq = 2 },
        .{ .role = .user, .text = "go", .seq = 7 },
        .{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 8 },
    };
    var second = try of(testing.allocator, &after, 7);
    defer second.deinit(testing.allocator);

    try testing.expectEqual(first.changed, second.changed);
    try testing.expectEqual(@as(usize, 1), second.changed);
    try testing.expectEqualStrings("today.zig", second.entries.items[0].subject);
}

test "a turn whose opening message has been trimmed away recaps as nothing" {
    var calls = [_]Conversation.ToolCall{made("write", "{\"path\":\"a.zig\"}", .ok)};
    const messages = [_]Conversation.Message{
        .{ .role = .assistant, .text = "", .tool_calls = &calls, .seq = 9 },
    };

    var recap = try of(testing.allocator, &messages, 4);
    defer recap.deinit(testing.allocator);
    try testing.expect(!recap.any());

    var none = try of(testing.allocator, &messages, null);
    defer none.deinit(testing.allocator);
    try testing.expect(!none.any());
}
