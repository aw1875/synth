//! The transcript: the ordered messages that make up one session.

const std = @import("std");

const pkg = @import("pkg");

const mention = @import("mention.zig");
/// A file pulled in by an `@path` mention. Kept beside the message rather than
/// spliced into its text, so the transcript shows what was typed.
pub const Attachment = mention.Attachment;

const Conversation = @This();

/// Cap on the in-memory copy of a heavy body (reasoning, tool output). The full
/// text is persisted to the blob table; only this much is kept in memory, and
/// the rest is loaded on demand when a row is expanded.
pub const preview_bytes: usize = 4 * 1024;

pub const Role = enum {
    system,
    user,
    assistant,
    /// The result of a tool call, fed back to the model.
    tool,
    /// What a finished turn did, written by the harness for the person reading
    /// it. Never sent to a model: it performed those calls itself and they are
    /// already in its transcript, so this would be a worse copy of what it has.
    summary,
};

/// One tool invocation requested by the model.
pub const ToolCall = struct {
    /// Provider-assigned id, or "" when the provider does not supply one.
    id: []const u8,
    name: []const u8,
    /// Raw JSON object of arguments, as the model produced it.
    arguments: []const u8,
    status: Status = .pending,
    /// Tool output once it has run, or the failure message. May be truncated to
    /// `preview_bytes`; `result_bytes` holds the full length so the UI knows
    /// there is more to load.
    result: ?[]const u8 = null,
    /// Full length of `result` in bytes, or 0 when there is no result.
    result_bytes: u64 = 0,

    /// A unique id for a call whose provider supplied none.
    ///
    /// Unique across the whole conversation, not just the reply it came in.
    /// Results are matched back to calls by id, so a provider that numbers its
    /// calls from zero every reply would have every result in the transcript
    /// answer to the same call.
    pub fn synthesizeId(allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "call_{d}", .{next_id.fetchAdd(1, .monotonic)});
    }

    var next_id: std.atomic.Value(u64) = .init(0);

    pub const Status = enum {
        /// Waiting on the user.
        pending,
        rejected,
        running,
        ok,
        failed,

        /// Whether the call has reached a state the model can be told about.
        pub fn isSettled(self: Status) bool {
            return switch (self) {
                .pending, .running => false,
                .rejected, .ok, .failed => true,
            };
        }

        /// How the call is marked wherever it is shown. Here rather than in
        /// either front end, because the TUI card and the headless printer are
        /// two views of one thing and had drifted apart into separate sets.
        pub fn glyph(self: Status) []const u8 {
            return switch (self) {
                .pending => "●",
                .running => "◐",
                .ok => "✓",
                .failed => "✕",
                .rejected => "·",
            };
        }
    };

    pub fn deinit(self: *ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments);
        if (self.result) |result| allocator.free(result);
    }
};

test "every tool call status is marked differently" {
    const testing = std.testing;
    const every: []const ToolCall.Status = &.{ .pending, .running, .ok, .failed, .rejected };

    for (every, 0..) |status, i| {
        try testing.expect(status.glyph().len > 0);
        for (every[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, status.glyph(), other.glyph()));
        }
    }
}

pub const Message = struct {
    /// Stable, monotonic position in the session. Never reused, even when the
    /// message is trimmed from memory, so it matches the database `seq` column
    /// and lets the UI key per-message state (thought rows, tool cards) without
    /// index arithmetic that breaks when older messages are dropped.
    seq: u64 = 0,
    role: Role,
    text: []const u8,
    /// Reasoning the model emitted for this turn. Assistant messages only. May
    /// be truncated to `preview_bytes`; `thinking_bytes` holds the full length.
    thinking: ?[]const u8 = null,
    /// How long that reasoning took, for the collapsed "Thought: 882ms" row.
    thinking_ms: ?u64 = null,
    /// Full length of `thinking` in bytes, or 0 when there is none.
    thinking_bytes: u64 = 0,
    /// Tool calls requested by this message. Assistant messages only.
    tool_calls: []ToolCall = &.{},
    /// Which call this message answers. Tool messages only.
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    /// Files referenced by `@path` in this message. User messages only.
    attachments: []Attachment = &.{},
    /// Base64-encoded images pasted with this message. User messages only, and
    /// memory-only: nothing persists them yet.
    images: [][]const u8 = &.{},

    /// Whether every tool call on this message has finished. An unsettled
    /// message is still being written to, so it must stay in memory.
    pub fn isSettled(self: *const Message) bool {
        for (self.tool_calls) |call| {
            if (!call.status.isSettled()) return false;
        }
        return true;
    }

    pub fn prefix(role: Role) []const u8 {
        return switch (role) {
            .system => "system » ",
            .user => "you » ",
            .assistant => pkg.name ++ " » ",
            .tool => "tool » ",
            // Nobody said it, so nobody is named.
            .summary => "",
        };
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.thinking) |thinking| allocator.free(thinking);
        if (self.tool_name) |name| allocator.free(name);
        if (self.tool_call_id) |id| allocator.free(id);
        for (self.tool_calls) |*call| call.deinit(allocator);
        allocator.free(self.tool_calls);
        for (self.attachments) |*attachment| attachment.deinit(allocator);
        allocator.free(self.attachments);
        for (self.images) |image| allocator.free(image);
        allocator.free(self.images);
    }
};

allocator: std.mem.Allocator,
messages: std.ArrayList(Message) = .empty,
/// The `seq` the next appended message will get. Monotonic across the whole
/// session, so trimming never reuses a number.
next_seq: u64 = 0,
/// Messages trimmed from the front of `messages` to keep memory bounded. The
/// UI pages these back in from the database.
dropped: u64 = 0,
/// Cap on in-memory messages. When an append would exceed it, the oldest are
/// dropped. Zero means unbounded (tests, `synth run`).
max_messages: usize = 0,

pub fn init(allocator: std.mem.Allocator) Conversation {
    return .{ .allocator = allocator };
}

/// Total messages in the session, including any trimmed from memory.
pub fn totalCount(self: *const Conversation) u64 {
    return self.dropped + self.messages.items.len;
}

/// The `seq` of the oldest message still in memory, or null when empty.
pub fn firstSeq(self: *const Conversation) ?u64 {
    if (self.messages.items.len == 0) return null;
    return self.messages.items[0].seq;
}

pub fn deinit(self: *Conversation) void {
    self.clear();
    self.messages.deinit(self.allocator);
}

/// Empty the transcript and restart its sequence numbers for a new session.
pub fn clear(self: *Conversation) void {
    for (self.messages.items) |*msg| msg.deinit(self.allocator);
    self.messages.clearRetainingCapacity();
    self.next_seq = 0;
    self.dropped = 0;
}

/// Append a plain text message.
pub fn add(self: *Conversation, role: Role, text: []const u8) !void {
    _ = try self.append(.{ .role = role, .text = text });
}

/// Append a user turn along with any files it mentioned.
pub fn addUser(
    self: *Conversation,
    text: []const u8,
    attachments: []const Attachment,
    images: []const []const u8,
) !*Message {
    return self.append(.{
        .role = .user,
        .text = text,
        .attachments = @constCast(attachments),
        .images = @constCast(images),
    });
}

/// Append an assistant turn, optionally carrying the reasoning behind it.
pub fn addAssistant(
    self: *Conversation,
    text: []const u8,
    thinking: ?[]const u8,
    thinking_ms: ?u64,
) !*Message {
    return self.append(.{
        .role = .assistant,
        .text = text,
        .thinking = thinking,
        .thinking_ms = thinking_ms,
    });
}

/// Append the result of a tool call.
pub fn addToolResult(
    self: *Conversation,
    tool_name: []const u8,
    tool_call_id: []const u8,
    output: []const u8,
) !*Message {
    return self.append(.{
        .role = .tool,
        .text = output,
        .tool_name = tool_name,
        .tool_call_id = tool_call_id,
    });
}

/// Copy `msg`'s borrowed strings into the conversation and append it. The
/// returned pointer is invalidated by the next append.
pub fn append(self: *Conversation, msg: Message) !*Message {
    var owned: Message = .{
        .seq = self.next_seq,
        .role = msg.role,
        .text = try self.allocator.dupe(u8, msg.text),
        .thinking_ms = msg.thinking_ms,
        .thinking_bytes = if (msg.thinking_bytes > 0) msg.thinking_bytes else (if (msg.thinking) |t| t.len else 0),
    };
    self.next_seq += 1;
    errdefer owned.deinit(self.allocator);

    if (msg.thinking) |thinking| owned.thinking = try self.allocator.dupe(u8, thinking);
    if (msg.tool_name) |name| owned.tool_name = try self.allocator.dupe(u8, name);
    if (msg.tool_call_id) |id| owned.tool_call_id = try self.allocator.dupe(u8, id);

    if (msg.tool_calls.len > 0) {
        const calls = try self.allocator.alloc(ToolCall, msg.tool_calls.len);
        var built: usize = 0;
        errdefer {
            for (calls[0..built]) |*call| call.deinit(self.allocator);
            self.allocator.free(calls);
        }

        for (msg.tool_calls, calls) |call, *out| {
            out.* = .{
                .id = try self.allocator.dupe(u8, call.id),
                .name = try self.allocator.dupe(u8, call.name),
                .arguments = try self.allocator.dupe(u8, call.arguments),
                .status = call.status,
                .result = if (call.result) |result| try self.allocator.dupe(u8, result) else null,
                .result_bytes = call.result_bytes,
            };
            built += 1;
        }
        owned.tool_calls = calls;
    }

    if (msg.attachments.len > 0) {
        const copies = try self.allocator.alloc(Attachment, msg.attachments.len);
        var built: usize = 0;
        errdefer {
            for (copies[0..built]) |*a| a.deinit(self.allocator);
            self.allocator.free(copies);
        }

        for (msg.attachments, copies) |attachment, *out| {
            out.* = .{
                .path = try self.allocator.dupe(u8, attachment.path),
                .content = try self.allocator.dupe(u8, attachment.content),
            };
            built += 1;
        }
        owned.attachments = copies;
    }

    if (msg.images.len > 0) {
        const copies = try self.allocator.alloc([]const u8, msg.images.len);
        var built: usize = 0;
        errdefer {
            for (copies[0..built]) |image| self.allocator.free(image);
            self.allocator.free(copies);
        }

        for (msg.images, copies) |image, *out| {
            out.* = try self.allocator.dupe(u8, image);
            built += 1;
        }
        owned.images = copies;
    }

    try self.messages.append(self.allocator, owned);
    self.trim();
    return &self.messages.items[self.messages.items.len - 1];
}

/// Drop the oldest messages until the in-memory count is within `max_messages`.
/// The dropped count is remembered so `totalCount` stays correct and the UI
/// knows there is history to page in.
fn trim(self: *Conversation) void {
    if (self.max_messages == 0) return;
    while (self.messages.items.len > self.max_messages) {
        if (!self.messages.items[0].isSettled()) return;
        var removed = self.messages.orderedRemove(0);
        removed.deinit(self.allocator);
        self.dropped += 1;
    }
}

/// Take over `messages` as the whole in-memory transcript, with `dropped`
/// older ones left in the database. Ownership of every string passes here.
/// Used by resume, where the conversation starts part way through a session.
pub fn adopt(self: *Conversation, messages: []Conversation.Message, dropped_count: u64) !void {
    self.clear();

    try self.messages.appendSlice(self.allocator, messages);
    self.dropped = dropped_count;
    self.next_seq = if (self.messages.items.len > 0)
        self.messages.items[self.messages.items.len - 1].seq + 1
    else
        dropped_count;
}

/// Free the image data on every message but the newest `keep` that carry any.
/// The bodies stay in the blob table; base64 of a screenshot is megabytes.
pub fn dropOldImages(self: *Conversation, keep: usize) void {
    var seen: usize = 0;
    var i = self.messages.items.len;
    while (i > 0) {
        i -= 1;
        const msg = &self.messages.items[i];
        if (msg.images.len == 0) continue;

        seen += 1;
        if (seen <= keep) continue;

        for (msg.images) |image| self.allocator.free(image);
        self.allocator.free(msg.images);
        msg.images = &.{};
    }
}

/// Hold the newest attachments in full and cut the rest back to a preview,
/// keeping the total under `budget` bytes.
///
/// Unlike an image, an attachment is text the model is still reading: the
/// instructions a skill was invoked with, the file a mention pulled in. So the
/// recent ones are kept whole and only what has scrolled out of relevance is
/// cut, rather than dropped outright. The full text stays in the `attachment`
/// table, and expanding a card fetches it back.
pub fn shrinkAttachments(self: *Conversation, budget: usize) void {
    var kept: usize = 0;
    var i = self.messages.items.len;
    while (i > 0) {
        i -= 1;
        for (self.messages.items[i].attachments) |*attachment| {
            if (attachment.content_bytes == 0) {
                attachment.content_bytes = attachment.content.len;
            }
            if (attachment.content.len <= preview_bytes) {
                kept += attachment.content.len;
                continue;
            }
            if (kept + attachment.content.len <= budget) {
                kept += attachment.content.len;
                continue;
            }

            const cut = preview(self.allocator, attachment.content) catch continue;
            self.allocator.free(attachment.content);
            attachment.content = cut;
            kept += cut.len;
        }
    }
}

/// The most recent message, if any.
pub fn last(self: *Conversation) ?*Message {
    if (self.messages.items.len == 0) return null;
    return &self.messages.items[self.messages.items.len - 1];
}

/// Prepend a batch of older messages paged in from the database. They must be
/// in ascending `seq` order and all older than the current first message. The
/// `dropped` count is reduced by the number prepended.
pub fn prepend(self: *Conversation, older: []Message) !void {
    if (older.len == 0) return;
    try self.messages.insertSlice(self.allocator, 0, older);
    self.dropped -= @min(self.dropped, older.len);
}

/// Whether any tool call anywhere is still waiting on the user.
pub fn hasPendingToolCalls(self: *Conversation) bool {
    for (self.messages.items) |msg| {
        for (msg.tool_calls) |call| {
            if (call.status == .pending) return true;
        }
    }
    return false;
}

/// Truncate a heavy body to `preview_bytes`, cut at a line boundary so the
/// preview does not end mid-line. Returns the original slice when it already
/// fits. The caller owns the returned slice when it differs from `body`.
pub fn preview(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (body.len <= preview_bytes) return body;
    var cut = preview_bytes;
    if (std.mem.lastIndexOfScalar(u8, body[0..cut], '\n')) |newline| cut = newline;
    return allocator.dupe(u8, body[0..cut]);
}

test "messages own their strings" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    try convo.add(.user, buf[0..5]);
    @memset(&buf, 'x');

    try std.testing.expectEqualStrings("hello", convo.messages.items[0].text);
}

test "tool calls round-trip through append" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read",
        .arguments = "{\"path\":\"src/main.zig\"}",
    }};
    _ = try convo.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });

    try std.testing.expect(convo.hasPendingToolCalls());
    try std.testing.expectEqualStrings("read", convo.messages.items[0].tool_calls[0].name);
}

test "seq is monotonic and survives trimming" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();
    convo.max_messages = 2;

    try convo.add(.user, "one");
    try convo.add(.assistant, "two");
    try convo.add(.user, "three");

    try std.testing.expectEqual(@as(u64, 1), convo.dropped);
    try std.testing.expectEqual(@as(u64, 3), convo.totalCount());
    try std.testing.expectEqual(@as(u64, 1), convo.messages.items[0].seq);
    try std.testing.expectEqual(@as(u64, 2), convo.messages.items[1].seq);
    try std.testing.expectEqual(@as(u64, 1), convo.firstSeq().?);
}

test "prepend pages older messages back in" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();
    convo.max_messages = 2;

    try convo.add(.user, "one");
    try convo.add(.assistant, "two");
    try convo.add(.user, "three");
    try std.testing.expectEqual(@as(u64, 1), convo.dropped);

    var older = [_]Message{.{
        .seq = 0,
        .role = .user,
        .text = try std.testing.allocator.dupe(u8, "one"),
    }};
    try convo.prepend(&older);

    try std.testing.expectEqual(@as(u64, 0), convo.dropped);
    try std.testing.expectEqual(@as(u64, 3), convo.messages.items.len);
    try std.testing.expectEqualStrings("one", convo.messages.items[0].text);
}

test "trimming stops at a message whose tools are still running" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();
    convo.max_messages = 2;

    var calls = [_]ToolCall{.{ .id = "1", .name = "bash", .arguments = "{}", .status = .running }};
    _ = try convo.append(.{ .role = .assistant, .text = "working", .tool_calls = &calls });
    try convo.add(.user, "a");
    try convo.add(.user, "b");

    try std.testing.expectEqual(@as(usize, 3), convo.messages.items.len);
    try std.testing.expectEqual(@as(u64, 0), convo.dropped);

    convo.messages.items[0].tool_calls[0].status = .ok;
    try convo.add(.user, "c");
    try std.testing.expectEqual(@as(usize, 2), convo.messages.items.len);
    try std.testing.expectEqual(@as(u64, 2), convo.dropped);
}

test "adopting a session continues its numbering" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    var loaded = [_]Message{
        .{ .seq = 40, .role = .user, .text = try std.testing.allocator.dupe(u8, "older") },
        .{ .seq = 41, .role = .assistant, .text = try std.testing.allocator.dupe(u8, "newer") },
    };
    try convo.adopt(&loaded, 40);

    try std.testing.expectEqual(@as(usize, 2), convo.messages.items.len);
    try std.testing.expectEqual(@as(u64, 40), convo.dropped);
    try std.testing.expectEqual(@as(u64, 42), convo.totalCount());

    _ = try convo.addUser("next", &.{}, &.{});
    try std.testing.expectEqual(@as(u64, 42), convo.messages.items[2].seq);
}

test "only the newest images stay in memory" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    for (0..3) |i| {
        const images = try std.testing.allocator.alloc([]const u8, 1);
        images[0] = try std.fmt.allocPrint(std.testing.allocator, "image {d}", .{i});
        _ = try convo.append(.{ .role = .user, .text = "look", .images = images });
        std.testing.allocator.free(images[0]);
        std.testing.allocator.free(images);
    }

    convo.dropOldImages(1);

    try std.testing.expectEqual(@as(usize, 0), convo.messages.items[0].images.len);
    try std.testing.expectEqual(@as(usize, 0), convo.messages.items[1].images.len);
    try std.testing.expectEqual(@as(usize, 1), convo.messages.items[2].images.len);
    try std.testing.expectEqualStrings("image 2", convo.messages.items[2].images[0]);
}

test "the newest attachments stay whole and older ones fall back to a preview" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const big = try std.testing.allocator.alloc(u8, preview_bytes * 4);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    for (0..3) |_| {
        var one = [_]Attachment{.{ .path = "skill/SKILL.md", .content = big }};
        _ = try convo.addUser("/skill", &one, &.{});
    }

    convo.shrinkAttachments(preview_bytes * 5);

    const oldest = convo.messages.items[0].attachments[0];
    const newest = convo.messages.items[2].attachments[0];

    try std.testing.expectEqual(big.len, newest.content.len);
    try std.testing.expect(!newest.shortened());

    try std.testing.expect(oldest.content.len <= preview_bytes);
    try std.testing.expect(oldest.shortened());
    try std.testing.expectEqual(@as(u64, big.len), oldest.content_bytes);
}

test "shrinking twice does not shrink what is already a preview" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    const big = try std.testing.allocator.alloc(u8, preview_bytes * 2);
    defer std.testing.allocator.free(big);
    @memset(big, 'y');

    var one = [_]Attachment{.{ .path = "a/SKILL.md", .content = big }};
    _ = try convo.addUser("/a", &one, &.{});

    convo.shrinkAttachments(0);
    const after_first = convo.messages.items[0].attachments[0].content;

    convo.shrinkAttachments(0);
    const after_second = convo.messages.items[0].attachments[0].content;

    try std.testing.expectEqual(after_first.ptr, after_second.ptr);
    try std.testing.expectEqual(@as(u64, big.len), convo.messages.items[0].attachments[0].content_bytes);
}

test "a small attachment is left alone whatever the budget" {
    var convo: Conversation = .init(std.testing.allocator);
    defer convo.deinit();

    var one = [_]Attachment{.{ .path = "small.zig", .content = "two lines\nof it\n" }};
    _ = try convo.addUser("look", &one, &.{});

    convo.shrinkAttachments(0);

    const kept = convo.messages.items[0].attachments[0];
    try std.testing.expectEqualStrings("two lines\nof it\n", kept.content);
    try std.testing.expect(!kept.shortened());
}
