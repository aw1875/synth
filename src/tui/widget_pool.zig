//! The widgets a drawn message borrows.
//!
//! A tool call, an attachment and a reasoning block each keep state a surface
//! cannot: whether they are expanded, where they are scrolled. They live longer
//! than a frame and are keyed to the message they belong to, so they are pooled
//! here and pruned when their message leaves the transcript.

const std = @import("std");

const Conversation = @import("../core/conversation.zig");
const AttachmentCard = @import("attachment_card.zig");
const diff = @import("diff.zig");
const Model = @import("model.zig");
const ThoughtView = @import("thought_view.zig");
const ToolCard = @import("tool_card.zig");

pub fn diffStart(self: *Model, key: u64, call: *Conversation.ToolCall) usize {
    if (self.diff_starts.get(key)) |line| return line;

    const line = resolveDiffStart(self, call) orelse return 1;
    self.diff_starts.put(self.allocator, key, line) catch {};
    return line;
}

pub fn resolveDiffStart(self: *Model, call: *Conversation.ToolCall) ?usize {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const change = (diff.change(arena, call.name, call.arguments) catch return null) orelse return null;
    if (change.old.len == 0) return 1;

    const project = self.project orelse return null;
    const path = std.fs.path.join(arena, &.{ project.root, change.path }) catch return null;
    const source = std.Io.Dir.cwd().readFileAlloc(self.io, path, arena, Model.max_diff_file_bytes) catch return null;

    const at = std.mem.indexOf(u8, source, change.old) orelse
        std.mem.indexOf(u8, source, change.new) orelse return null;
    return std.mem.count(u8, source[0..at], "\n") + 1;
}

/// Drop the per-message widgets for messages no longer in memory.
pub fn pruneWidgets(self: *Model) void {
    // Keyed by a hash, so there is no evicting just the departed messages.
    if (self.block_heights.count() > Model.max_measured_blocks) {
        self.block_heights.clearRetainingCapacity();
    }

    const oldest = self.conversation.firstSeq() orelse return;

    var thoughts = self.thought_rows.iterator();
    while (thoughts.next()) |entry| {
        if (entry.key_ptr.* >= oldest) continue;
        self.allocator.destroy(entry.value_ptr.*);
        _ = self.thought_rows.remove(entry.key_ptr.*);
    }

    var toggles = self.paste_toggles.iterator();
    while (toggles.next()) |entry| {
        if (entry.key_ptr.* >= oldest) continue;
        self.allocator.destroy(entry.value_ptr.*);
        _ = self.paste_toggles.remove(entry.key_ptr.*);
    }

    var cards = self.tool_cards.iterator();
    while (cards.next()) |entry| {
        if (entry.key_ptr.* >> 32 >= oldest) continue;
        self.allocator.destroy(entry.value_ptr.*);
        _ = self.tool_cards.remove(entry.key_ptr.*);
    }

    var attachments = self.attachment_cards.iterator();
    while (attachments.next()) |entry| {
        if (entry.key_ptr.* >> 32 >= oldest) continue;
        self.allocator.destroy(entry.value_ptr.*);
        _ = self.attachment_cards.remove(entry.key_ptr.*);
    }

    var starts = self.diff_starts.iterator();
    while (starts.next()) |entry| {
        if (entry.key_ptr.* >> 32 >= oldest) continue;
        _ = self.diff_starts.remove(entry.key_ptr.*);
    }
}

/// The persistent card for one mentioned file, created on first use.
pub fn attachmentCard(
    self: *Model,
    msg: *Conversation.Message,
    index: usize,
    attachment: *const Conversation.Attachment,
) !*AttachmentCard {
    const key = (msg.seq << 32) | @as(u64, index);

    const entry = try self.attachment_cards.getOrPut(self.allocator, key);
    if (!entry.found_existing) {
        const card = try self.allocator.create(AttachmentCard);
        card.* = .{};
        entry.value_ptr.* = card;
    }

    const card = entry.value_ptr.*;
    card.label = attachment.path;
    card.body = attachment.content;
    return card;
}

/// The persistent card for one tool call, created on first use. Loads the full
/// result from the database when the card is expanded and the in-memory copy is
/// only a preview.
pub fn toolCard(
    self: *Model,
    msg: *Conversation.Message,
    call_index: usize,
    call: *Conversation.ToolCall,
) !*ToolCard {
    const key = (msg.seq << 32) | @as(u64, call_index);

    const entry = try self.tool_cards.getOrPut(self.allocator, key);
    if (!entry.found_existing) {
        const card = try self.allocator.create(ToolCard);
        card.* = .{};
        entry.value_ptr.* = card;
    }

    const card = entry.value_ptr.*;
    card.name = call.name;
    card.arguments = call.arguments;
    card.start_line = diffStart(self, key, call);
    card.result = call.result;
    card.status = call.status;

    if (card.expanded and call.result_bytes > Conversation.preview_bytes) {
        if (call.result) |r| {
            if (r.len < call.result_bytes) {
                self.loop.loadToolResult(msg, call_index) catch {};
                card.result = call.result;
            }
        }
    }

    return card;
}

/// The persistent view for a message, created on first use. Returns null when
/// that message has no reasoning to show. Loads the full reasoning from the
/// database when the row is expanded and the in-memory copy is only a preview.
pub fn thoughtRow(self: *Model, msg: *Conversation.Message) !?*ThoughtView.View {
    const thinking = msg.thinking orelse return null;
    if (thinking.len == 0) return null;

    const entry = try self.thought_rows.getOrPut(self.allocator, msg.seq);
    if (!entry.found_existing) {
        const row = try self.allocator.create(ThoughtView.View);
        row.* = .{};
        entry.value_ptr.* = row;
    }

    const row = entry.value_ptr.*;
    row.text = thinking;
    row.elapsed_ms = msg.thinking_ms orelse 0;

    if (row.expanded and msg.thinking_bytes > Conversation.preview_bytes) {
        if (msg.thinking) |t| {
            if (t.len < msg.thinking_bytes) {
                self.loop.loadThinking(msg) catch {};
                row.text = msg.thinking.?;
            }
        }
    }

    return row;
}
