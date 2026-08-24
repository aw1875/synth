//! The draw tree: the Model's state rendered into vxfw surfaces.
//!
//! Split from the Model itself because drawing is the half that reads
//! everything and changes nothing. It calls back into the Model only for the
//! widget pools a surface has to borrow from.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Conversation = @import("../core/conversation.zig");
const humanize = @import("../core/humanize.zig");
const agents = @import("../agent/agent.zig");
const Model = @import("model.zig");
const widget_pool = @import("widget_pool.zig");
const AgentLoop = @import("../agent/loop.zig");
const ask_user = @import("../tools/ask.zig");
const pkg = @import("pkg");
const Input = @import("input.zig");
const markdown = @import("markdown.zig");
const Selection = @import("selection.zig");
const theme = @import("theme.zig");
const ThoughtView = @import("thought_view.zig");
const w = @import("widgets.zig");

pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    return draw(self, ctx);
}

pub fn draw(self: *Model, ctx: vxfw.DrawContext) !vxfw.Surface {
    const max = ctx.max.size();

    var root = try w.surfaceClamped(ctx.arena, self.widget(), max);
    w.fill(root, theme.base.cell);
    if (max.width == 0 or max.height == 0) return root;

    var children: std.ArrayList(vxfw.SubSurface) = .empty;

    const sidebar_w: u16 = if (max.width >= Model.sidebar_min_term_width) Model.sidebar_width else 0;
    const main_w = max.width - sidebar_w;
    self.sidebar_col = if (sidebar_w > 0) main_w else max.width;
    const content_h = max.height -| 3;
    const column_w = main_w -| (Model.gutter * 2);

    if (column_w > 0 and content_h > 0) {
        const prompt = if (self.loop.state == .awaiting_approval)
            try drawApproval(self, ctx, column_w)
        else
            try drawPrompt(self, ctx, column_w);
        const prompt_row = content_h -| prompt.size.height;
        try children.append(ctx.arena, .{
            .origin = .{ .row = @intCast(prompt_row), .col = Model.gutter },
            .surface = prompt,
        });

        if (self.input_cursor) |cursor| {
            root.cursor = .{
                .row = prompt_row + cursor.row,
                .col = Model.gutter + cursor.col,
                .shape = cursor.shape,
            };
        }

        if (self.slash.isOpen()) {
            const popup = try self.slash.draw(ctx, self.plainWidget(), column_w);
            const popup_row = prompt_row -| popup.size.height;
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(popup_row), .col = Model.gutter },
                .surface = popup,
                .z_index = 1,
            });
        }

        if (self.mentions.isOpen()) {
            const popup = try self.mentions.draw(ctx, self.plainWidget(), column_w);
            const popup_row = prompt_row -| popup.size.height;
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(popup_row), .col = Model.gutter },
                .surface = popup,
                .z_index = 1,
            });
        }

        const transcript_h = prompt_row -| Model.block_gap;
        if (try drawTranscript(self, ctx, column_w, transcript_h)) |transcript| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = Model.gutter },
                .surface = transcript,
            });
        }
    }

    if (max.height > 0) drawStatusBar(self, ctx, root, main_w, max.height - 2);

    if (sidebar_w > 0) {
        const sidebar = try drawSidebar(self, ctx, sidebar_w, max.height);
        try children.append(ctx.arena, .{
            .origin = .{ .row = 0, .col = @intCast(main_w) },
            .surface = sidebar,
        });
    }

    if (try self.sessions.draw(ctx, self.plainWidget(), max)) |dialog| {
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = null;
    }

    if (try self.models.draw(ctx, self.plainWidget(), max)) |dialog| {
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.mcp_picker.draw(ctx, self.plainWidget(), max)) |dialog| {
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.theme_picker.draw(ctx, self.plainWidget(), max)) |dialog| {
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.connect.draw(ctx, self.plainWidget(), max)) |dialog| {
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.rename.draw(ctx, self.plainWidget(), max)) |dialog| {
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (column_w > 0 and content_h > 0) {
        const area: vxfw.Size = .{ .width = column_w, .height = content_h };
        for (try self.notification.draw(ctx, area)) |toast| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = toast.origin.row, .col = Model.gutter + toast.origin.col },
                .surface = toast.surface,
                .z_index = 4,
            });
        }
    }

    root.children = children.items;

    try self.selection.capture(root);

    if (self.selection.isActive()) {
        if (try drawSelectionOverlay(self, ctx, max)) |overlay| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = overlay,
                .z_index = 2,
            });
            root.children = children.items;
        }
    }

    return root;
}

/// Redraw the selected cells in reverse video, on top of everything else. The
/// text comes from the captured grid, so no widget needs to know about it.
pub fn drawSelectionOverlay(self: *Model, ctx: vxfw.DrawContext, max: vxfw.Size) !?vxfw.Surface {
    const bounds = self.selection.range() orelse return null;

    const top = bounds.start.row;
    const bottom = @min(bounds.end.row, max.height -| 1);
    if (top > bottom) return null;

    var rows: std.ArrayList(vxfw.SubSurface) = .empty;

    var row = top;
    while (row <= bottom) : (row += 1) {
        const span = self.selection.rowSpan(row) orelse continue;
        const from = span.from;
        const to = @min(span.to, max.width -| 1);
        if (from > to) continue;

        const width = to - from + 1;
        const strip = try w.surfaceClamped(ctx.arena, self.plainWidget(), .{ .width = width, .height = 1 });

        var col = from;
        while (col <= to) : (col += 1) {
            const bytes = self.selection.cellText(row, col);
            strip.writeCell(col - from, 0, .{
                .char = .{ .grapheme = if (bytes.len == 0) " " else bytes, .width = 1 },
                .style = .{ .fg = theme.bg, .bg = theme.selection_bg },
            });
        }

        try rows.append(ctx.arena, .{ .origin = .{ .row = row, .col = from }, .surface = strip });
    }

    if (rows.items.len == 0) return null;

    return .{
        .size = max,
        .widget = self.plainWidget(),
        .buffer = &.{},
        .children = rows.items,
    };
}

/// Lay the conversation out in `height` rows. Content hugs the top until it
/// outgrows the viewport, after which the newest message stays pinned to the
/// bottom and older ones scroll off the top.
/// One thing the transcript stacks vertically.
///
/// Enumerated separately from being drawn, because the two cost wildly
/// different amounts: listing a block is a tag and a pointer, while building
/// its surface is a markdown parse and a syntax highlight. A long session has
/// thousands of blocks and a screen shows a handful, so the draw walks this
/// list backwards from the newest and stops as soon as it has covered the
/// viewport.
const Block = union(enum) {
    /// The "N earlier messages" line above trimmed history.
    notice,
    summary: *Conversation.Message,
    thought: *Conversation.Message,
    text: *Conversation.Message,
    attachment: struct { msg: *Conversation.Message, index: usize },
    tool: struct { msg: *Conversation.Message, index: usize },
    /// A question the model is waiting on, drawn as a question rather than as
    /// the tool call it technically is.
    question: *Conversation.ToolCall,
    /// The spinner shown while a turn is in flight.
    thinking,
    /// The reply as it streams in, before it becomes a message.
    streaming,
    queued: []const u8,
    queued_more: usize,

    /// Whether this block belongs to the live tail - the part that grows while
    /// a turn is in flight. Growth there is what the scroll offset has to be
    /// compensated for; growth anywhere else is history being paged in, which
    /// happens above the viewport and moves nothing.
    fn inTail(self: Block) bool {
        return switch (self) {
            .thinking, .streaming, .queued, .queued_more => true,
            else => false,
        };
    }
};

/// List every block the transcript would show, newest last. Cheap by design:
/// nothing here draws, allocates a surface, or touches a widget pool.
fn enumerateBlocks(self: *Model, arena: std.mem.Allocator, pending: usize) ![]Block {
    var blocks: std.ArrayList(Block) = .empty;

    if (self.conversation.dropped > 0) try blocks.append(arena, .notice);

    for (self.conversation.messages.items) |*msg| {
        if (msg.role == .tool) continue;

        if (msg.role == .system) {
            try blocks.append(arena, .{ .summary = msg });
            continue;
        }

        try blocks.append(arena, .{ .thought = msg });
        if (msg.text.len > 0) try blocks.append(arena, .{ .text = msg });

        for (msg.attachments, 0..) |*attachment, index| {
            if (std.mem.indexOf(u8, msg.text, attachment.path) != null) continue;
            try blocks.append(arena, .{ .attachment = .{ .msg = msg, .index = index } });
        }
        for (msg.tool_calls, 0..) |*call, index| {
            if (std.mem.eql(u8, call.name, ask_user.name) and call.status == .running) {
                try blocks.append(arena, .{ .question = call });
                continue;
            }
            try blocks.append(arena, .{ .tool = .{ .msg = msg, .index = index } });
        }
    }

    if (pending == 1) {
        try blocks.append(arena, .thinking);
        try blocks.append(arena, .streaming);
    }

    for (self.queued.items, 0..) |prompt, i| {
        if (i == Model.max_queued_shown) {
            try blocks.append(arena, .{ .queued_more = self.queued.items.len - i });
            break;
        }
        try blocks.append(arena, .{ .queued = prompt });
    }

    return blocks.toOwnedSlice(arena);
}

/// Turn one block into a surface. Null means the block has nothing to show
/// after all - a message with no reasoning, or a reply that has not started
/// streaming - which the caller skips without charging it against the budget.
fn drawBlock(
    self: *Model,
    ctx: vxfw.DrawContext,
    constraints: vxfw.DrawContext,
    width: u16,
    block: Block,
) !?vxfw.Surface {
    switch (block) {
        .notice => return try noticeBlock(self, ctx, try std.fmt.allocPrint(
            ctx.arena,
            "... {d} earlier message(s) - scroll up to load",
            .{self.conversation.dropped},
        ), width),

        .summary => |msg| {
            var summarised: usize = 0;
            for (self.conversation.messages.items) |*earlier| {
                if (earlier.seq >= msg.seq) break;
                summarised += 1;
            }
            const card = try widget_pool.attachmentCard(self, msg, Model.summary_card_key, &.{
                .path = try std.fmt.allocPrint(
                    ctx.arena,
                    "context compacted \u{b7} {d} messages summarised",
                    .{summarised + self.conversation.dropped},
                ),
                .content = msg.text,
            });
            return try card.widget().draw(constraints);
        },

        .thought => |msg| {
            const row = try widget_pool.thoughtRow(self, msg) orelse return null;
            return try row.widget().draw(constraints);
        },

        .text => |msg| return try userOrPlainBlock(self, ctx, msg, width),

        .attachment => |at| {
            const card = try widget_pool.attachmentCard(self, at.msg, at.index, &at.msg.attachments[at.index]);
            return try card.widget().draw(constraints);
        },

        .tool => |at| {
            const card = try widget_pool.toolCard(self, at.msg, at.index, &at.msg.tool_calls[at.index]);
            return try card.widget().draw(constraints);
        },

        .question => |call| return try questionBlock(self, ctx, call, width),

        .thinking => return try self.thinking.widget().draw(constraints),

        .streaming => {
            const stream = self.loop.streamingText() orelse return null;
            const partial = try stream.snapshot(ctx.arena);
            if (partial.len == 0) return null;
            return try messageBlock(self, ctx, .{ .role = .assistant, .text = partial }, width);
        },

        .queued => |prompt| return try queuedBlock(self, ctx, prompt, width),

        .queued_more => |count| return try queuedBlock(
            self,
            ctx,
            try std.fmt.allocPrint(ctx.arena, "+{d} more queued", .{count}),
            width,
        ),
    }
}

/// A block placed in the layout: how tall it is, and its surface when it was
/// worth building one.
const Placed = struct {
    height: u16,
    surface: ?vxfw.Surface,
};

/// A stable name for a block, so a measured height can be used again.
///
/// Everything that changes how tall a block draws goes in: the width, what it
/// is, and whatever state it renders from. A block whose height cannot be
/// predicted - the spinner, the reply still streaming, the queue - has no key
/// and is measured every frame.
fn blockKey(self: *Model, block: Block, width: u16) ?u64 {
    var hasher = std.hash.Wyhash.init(width);

    switch (block) {
        .notice => {
            std.hash.autoHash(&hasher, @as(u8, 1));
            std.hash.autoHash(&hasher, self.conversation.dropped);
        },
        .summary => |msg| {
            std.hash.autoHash(&hasher, @as(u8, 2));
            std.hash.autoHash(&hasher, msg.seq);
            std.hash.autoHash(&hasher, msg.text.len);
        },
        .thought => |msg| {
            std.hash.autoHash(&hasher, @as(u8, 3));
            std.hash.autoHash(&hasher, msg.seq);
            std.hash.autoHash(&hasher, msg.thinking_bytes);
            if (self.thought_rows.get(msg.seq)) |row| std.hash.autoHash(&hasher, row.expanded);
        },
        .text => |msg| {
            std.hash.autoHash(&hasher, @as(u8, 4));
            std.hash.autoHash(&hasher, msg.seq);
            std.hash.autoHash(&hasher, msg.text.len);
            if (self.paste_toggles.get(msg.seq)) |toggle| std.hash.autoHash(&hasher, toggle.expanded);
        },
        .attachment => |at| {
            std.hash.autoHash(&hasher, @as(u8, 5));
            std.hash.autoHash(&hasher, at.msg.seq);
            std.hash.autoHash(&hasher, at.index);
            if (self.attachment_cards.get((at.msg.seq << 32) | at.index)) |card| {
                std.hash.autoHash(&hasher, card.expanded);
            }
        },
        .tool => |at| {
            const call = &at.msg.tool_calls[at.index];
            std.hash.autoHash(&hasher, @as(u8, 6));
            std.hash.autoHash(&hasher, at.msg.seq);
            std.hash.autoHash(&hasher, at.index);
            std.hash.autoHash(&hasher, call.status);
            std.hash.autoHash(&hasher, call.result_bytes);
            std.hash.autoHash(&hasher, call.arguments.len);
            if (self.tool_cards.get((at.msg.seq << 32) | at.index)) |card| {
                std.hash.autoHash(&hasher, card.expanded);
            }
        },
        .question, .thinking, .streaming, .queued, .queued_more => return null,
    }

    return hasher.final();
}

pub fn drawTranscript(
    self: *Model,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
) !?vxfw.Surface {
    const messages = self.conversation.messages.items;
    const pending: usize = if (self.loop.isBusy() and
        self.loop.state != .awaiting_approval) 1 else 0;
    if (height == 0 or messages.len + pending + self.queued.items.len == 0) return null;

    const constraints = ctx.withConstraints(
        .{ .width = width },
        .{ .width = width, .height = height },
    );

    const blocks = try enumerateBlocks(self, ctx.arena, pending);
    if (blocks.len == 0) return null;

    if (self.heights_width != width) {
        self.block_heights.clearRetainingCapacity();
        self.heights_width = width;
    }

    const budget: i32 = @as(i32, height) * 2 + @as(i32, self.scroll);
    const visible_from: i32 = @as(i32, self.scroll);
    const visible_to: i32 = visible_from + height;

    var shown: std.ArrayList(Placed) = .empty;
    var total: i32 = 0;
    var tail: i32 = 0;
    var exhausted = true;

    var i = blocks.len;
    while (i > 0) {
        i -= 1;

        const key = blockKey(self, blocks[i], width);
        const cached: ?u16 = if (key) |k| self.block_heights.get(k) else null;

        // Counting past a block must not build it: that is the whole point.
        const build = if (cached) |known|
            total < visible_to and total + @as(i32, known) > visible_from
        else
            true;

        var placed: Placed = .{ .height = cached orelse 0, .surface = null };
        if (build) {
            const surface = try drawBlock(self, ctx, constraints, width, blocks[i]);
            if (key) |k| {
                try self.block_heights.put(self.allocator, k, if (surface) |sf| sf.size.height else 0);
            }
            const shape = surface orelse continue;
            placed = .{ .height = shape.size.height, .surface = shape };
        } else if (placed.height == 0) {
            continue;
        }

        try shown.append(ctx.arena, placed);

        const consumed = @as(i32, placed.height) + Model.block_gap;
        total += consumed;
        if (blocks[i].inTail()) tail += consumed;

        if (total >= budget and i > 0) {
            exhausted = false;
            break;
        }
    }

    if (shown.items.len == 0) return null;
    total -= Model.block_gap;

    std.mem.reverse(Placed, shown.items);

    // The scroll offset counts rows back from the newest content, so anything
    // appended at the bottom slides the view. While a turn streams, hold the
    // reader's place by growing the offset in step with the tail.
    if (self.scroll > 0 and tail > self.tail_height) {
        const growth: u16 = @intCast(@min(tail - @as(i32, self.tail_height), std.math.maxInt(u16)));
        self.scroll +|= growth;
    }
    self.tail_height = @intCast(@min(tail, std.math.maxInt(u16)));
    self.transcript_exhausted = exhausted;

    const overflow = total + Model.transcript_top - @as(i32, height);
    self.max_scroll = if (overflow > 0) @intCast(@min(overflow, std.math.maxInt(u16))) else 0;
    if (self.scroll > self.max_scroll) self.scroll = self.max_scroll;

    var y: i32 = if (overflow <= 0) Model.transcript_top else height - total;
    y += self.scroll;

    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    for (shown.items) |block| {
        defer y += @as(i32, block.height) + Model.block_gap;
        if (y + @as(i32, block.height) <= 0) continue;
        if (y >= height) break;

        const surface = block.surface orelse continue;
        try children.append(ctx.arena, .{
            .origin = .{ .row = @intCast(y), .col = 0 },
            .surface = surface,
        });
    }

    return .{
        .size = .{ .width = width, .height = height },
        .widget = self.plainWidget(),
        .buffer = &.{},
        .children = children.items,
    };
}

/// User turns are raised cards with an accent rule; assistant turns are plain
/// text on the app background, the way a reply reads in a chat log.
/// A message bubble, with its held-back pastes folded in when the message has
/// been clicked open.
pub fn userOrPlainBlock(
    self: *Model,
    ctx: vxfw.DrawContext,
    msg: *Conversation.Message,
    width: u16,
) !vxfw.Surface {
    if (!hasPaste(msg)) return messageBlock(self, ctx, msg.*, width);

    const toggle = try pasteToggle(self, msg.seq);
    var shown = msg.*;
    if (toggle.expanded) shown.text = try expandPastes(ctx.arena, msg);

    const block = try messageBlock(self, ctx, shown, width);

    var surface = try w.surfaceClamped(ctx.arena, toggle.widget(), block.size);
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = block };
    surface.children = children;
    return surface;
}

/// Whether a message carries a paste the composer held back. A `@path` mention
/// is left alone: its text was never replaced by a token.
pub fn hasPaste(msg: *const Conversation.Message) bool {
    for (msg.attachments) |attachment| {
        if (std.mem.indexOf(u8, msg.text, attachment.path) != null) return true;
    }
    return false;
}

/// The message text with each token swapped back for what it stood in for.
pub fn expandPastes(arena: std.mem.Allocator, msg: *const Conversation.Message) ![]const u8 {
    var text: []const u8 = msg.text;
    for (msg.attachments) |attachment| {
        const at = std.mem.indexOf(u8, text, attachment.path) orelse continue;
        text = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
            text[0..at],
            attachment.content,
            text[at + attachment.path.len ..],
        });
    }
    return text;
}

pub fn pasteToggle(self: *Model, seq: u64) !*Model.PasteToggle {
    const entry = try self.paste_toggles.getOrPut(self.allocator, seq);
    if (!entry.found_existing) {
        const toggle = try self.allocator.create(Model.PasteToggle);
        toggle.* = .{};
        entry.value_ptr.* = toggle;
    }
    return entry.value_ptr.*;
}

/// Click target for a message carrying a paste: it holds nothing but whether
/// that message is currently showing the full text.
pub fn messageBlock(self: *Model, ctx: vxfw.DrawContext, msg: Conversation.Message, width: u16) !vxfw.Surface {
    const on_card = msg.role == .user;
    const style = if (on_card) theme.card.cell else theme.base.cell;

    const opts: w.PanelOptions = .{
        .style = style,
        .left = if (on_card) 2 else 3,
        .right = 2,
        .accent = if (on_card) theme.accent else null,
        .width = width,
    };

    const constraints = ctx.withConstraints(.{}, .{ .width = width, .height = null });
    const inner_width = w.panelInnerWidth(constraints, opts);
    if (inner_width == 0) return .empty(self.plainWidget());

    const content = if (msg.role == .user)
        try plainText(ctx, msg.text, style, inner_width)
    else
        try markdown.draw(constraints, self.plainWidget(), msg.text, style, inner_width);

    return w.wrap(constraints, content, opts);
}

/// A prompt waiting its turn: the user's card, dimmed, so it reads as not yet
/// sent rather than as part of the transcript.
/// A dim one-line note in the transcript, for things that are neither a
/// message nor a tool call.
pub fn noticeBlock(self: *Model, ctx: vxfw.DrawContext, text: []const u8, width: u16) !vxfw.Surface {
    const surface = try w.surfaceClamped(ctx.arena, self.plainWidget(), .{ .width = width, .height = 1 });
    w.fill(surface, theme.base.cell);
    _ = w.writeText(surface, 3, 0, text, theme.on_bg(theme.fg_dim).cell);
    return surface;
}

/// A question the model asked, with whatever answers it offered. Drawn like a
/// message rather than a tool card: it is addressed to the reader, and the
/// composer below it is where the answer goes.
pub fn questionBlock(
    self: *Model,
    ctx: vxfw.DrawContext,
    call: *Conversation.ToolCall,
    width: u16,
) !vxfw.Surface {
    const opts: w.PanelOptions = .{
        .style = theme.card.cell,
        .left = 2,
        .right = 2,
        .accent = theme.accent_alt,
        .width = width,
    };

    const constraints = ctx.withConstraints(.{}, .{ .width = width, .height = null });
    const inner_width = w.panelInnerWidth(constraints, opts);
    if (inner_width == 0) return .empty(self.plainWidget());

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(ctx.arena, ask_user.question(ctx.arena, call.arguments));

    for (ask_user.options(ctx.arena, call.arguments), 1..) |option, n| {
        const line = try std.fmt.allocPrint(ctx.arena, "\n  {d}. {s}", .{ n, option });
        try text.appendSlice(ctx.arena, line);
    }

    const style = theme.on_card(theme.fg).cell;
    return w.wrap(constraints, try plainText(ctx, text.items, style, inner_width), opts);
}

pub fn queuedBlock(self: *Model, ctx: vxfw.DrawContext, text: []const u8, width: u16) !vxfw.Surface {
    const style = theme.on_card(theme.fg_dim).cell;

    const opts: w.PanelOptions = .{
        .style = theme.card.cell,
        .left = 2,
        .right = 2,
        .accent = theme.fg_dim,
        .width = width,
    };

    const constraints = ctx.withConstraints(.{}, .{ .width = width, .height = null });
    const inner_width = w.panelInnerWidth(constraints, opts);
    if (inner_width == 0) return .empty(self.plainWidget());

    const label = try std.fmt.allocPrint(ctx.arena, "queued · {s}", .{text});
    return w.wrap(constraints, try plainText(ctx, label, style, inner_width), opts);
}

pub fn plainText(
    ctx: vxfw.DrawContext,
    source: []const u8,
    style: Cell.Style,
    width: u16,
) !vxfw.Surface {
    const spans = try ctx.arena.alloc(Cell.Segment, 1);
    spans[0] = .{ .text = source, .style = style };

    const text = try ctx.arena.create(vxfw.RichText);
    text.* = .{ .text = spans, .base_style = style, .width_basis = .parent };

    return text.widget().draw(
        ctx.withConstraints(.{ .width = width }, .{ .width = width, .height = w.maxRows(width) }),
    );
}

/// The permission panel, drawn where the prompt box normally sits.
pub fn drawApproval(self: *Model, ctx: vxfw.DrawContext, width: u16) !vxfw.Surface {
    self.input_cursor = null;

    const call = self.loop.pendingCall() orelse return drawPrompt(self, ctx, width);
    const seq = self.loop.pending_seq orelse 0;
    const call_index = self.loop.firstPending() orelse 0;
    self.approval.sync((seq << 32) | call_index);

    const definition = self.loop.registry.get(call.name);
    return self.approval.draw(ctx, self.plainWidget(), .{
        .name = call.name,
        .description = if (definition) |found| found.description else "",
        .arguments = call.arguments,
        .project = if (self.project) |project| project.name() else "",
        .patterns = AgentLoop.approvalPatterns(ctx.arena, call.name, call.arguments) catch &.{},
        .width = width,
    });
}

/// The prompt box: an accent-barred card holding the editable field, with a
/// provider footer tucked inside the same card.
pub fn drawPrompt(self: *Model, ctx: vxfw.DrawContext, width: u16) !vxfw.Surface {
    const bar: u16 = 1;
    const pad_left: u16 = 2;
    const pad_right: u16 = 2;
    const text_col = bar + pad_left;
    const inner = width -| (text_col + pad_right);

    self.input.style = theme.card.cell;
    self.input.tokens = self.held.tokens();
    self.input.token_style = theme.on_card(theme.warning).withBg(theme.surface_alt).cell;

    const rows: u16 = if (inner == 0)
        1
    else
        std.math.clamp(self.input.lineCount(inner), 1, Model.max_input_rows);
    self.input.height = rows;

    const height = 1 + rows + 3;

    var surface = try w.surfaceClamped(ctx.arena, self.input.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.card.cell);
    for (0..height) |row| {
        surface.writeCell(0, @intCast(row), .{
            .char = .{ .grapheme = "▌", .width = 1 },
            .style = theme.on_card(Model.agentColor(self.loop.agent.id)).cell,
        });
    }

    self.input_cursor = null;
    if (inner > 0) {
        self.input.placeholder = if (self.loop.state == .awaiting_answer)
            "Answer to continue..."
        else if (self.loop.isBusy())
            "Type to queue a message..."
        else
            "Ask anything...    / for commands, @ for files";
        self.input.placeholder_style = theme.on_card(theme.fg_dim).cell;

        const field = try self.input.draw(ctx.withConstraints(
            .{ .width = inner, .height = rows },
            .{ .width = inner, .height = rows },
        ));
        const kids = try ctx.arena.alloc(vxfw.SubSurface, 1);
        kids[0] = .{ .origin = .{ .row = 1, .col = @intCast(text_col) }, .surface = field };
        surface.children = kids;

        if (field.cursor) |cursor| {
            self.input_cursor = .{
                .row = 1 + cursor.row,
                .col = text_col + cursor.col,
                .shape = .block,
            };
        }
    }

    const footer = height - 2;

    var col = w.writeText(
        surface,
        text_col,
        footer,
        self.loop.agent.label,
        theme.on_card(Model.agentColor(self.loop.agent.id)).bold().cell,
    );
    col = w.writeText(surface, col, footer, " · ", theme.on_card(theme.fg_dim).cell);
    if (self.provider.model.len > 0) {
        col = w.writeText(surface, col, footer, self.provider.model, theme.on_card(theme.fg_muted).cell);
        col = w.writeText(surface, col, footer, " · ", theme.on_card(theme.fg_dim).cell);
    }
    _ = w.writeText(surface, col, footer, self.provider.name, theme.on_card(theme.fg_muted).cell);
    if (self.queued.items.len > 0) {
        col = w.writeText(surface, col, footer, " · ", theme.on_card(theme.fg_dim).cell);
        col = w.writeText(surface, col, footer, try std.fmt.allocPrint(
            ctx.arena,
            "{d} queued",
            .{self.queued.items.len},
        ), theme.on_card(theme.accent_alt).cell);
    }

    const armed = self.quit_confirm.armed(self.io);
    const blind = !self.provider.vision and self.held.imageCount() > 0;
    const hint = if (armed)
        "ctrl+c again to quit"
    else if (blind)
        "this model cannot see images · ctrl+o"
    else
        "alt+enter to add a line";
    const hint_style = if (armed or blind)
        theme.on_card(theme.warning).bold().cell
    else
        theme.on_card(theme.fg_dim).cell;
    w.writeTextRight(surface, footer, pad_right, hint, hint_style);

    return surface;
}

/// Bottom status bar: working directory on the left, key hint on the right.
pub fn drawStatusBar(self: *Model, ctx: vxfw.DrawContext, root: vxfw.Surface, width: u16, row: u16) void {
    if (width <= Model.gutter) return;

    const path = self.cwd_display;
    const hint = "ctrl+r rename ctrl+c quit";
    const hint_w = w.textWidth(hint);
    const path_room = width -| (Model.gutter * 2 + hint_w + 2);

    _ = w.writeText(root, Model.gutter, row, fitLeft(ctx.arena, path, path_room), theme.on_bg(theme.fg_dim).cell);

    if (width > hint_w + Model.gutter) {
        _ = w.writeText(root, width - hint_w - Model.gutter, row, hint, theme.on_bg(theme.fg_dim).cell);
    }
}

pub const Section = struct {
    title: []const u8,
    lines: []const []const u8,
};

pub fn drawSidebar(self: *Model, ctx: vxfw.DrawContext, width: u16, height: u16) !vxfw.Surface {
    const surface = try w.surfaceClamped(ctx.arena, self.plainWidget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.card.cell);

    const left: u16 = 2;
    const inner = width -| (left + 1);
    if (inner == 0 or height == 0) return surface;

    const usage = self.loop.usage;
    const limit = self.provider.context_limit;

    var context_lines: std.ArrayList([]const u8) = .empty;
    if (usage.context_tokens == 0) {
        try context_lines.append(ctx.arena, "no requests yet");
    } else if (limit > 0) {
        try context_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s} / {s}", .{
            try compact(ctx.arena, usage.context_tokens),
            try compact(ctx.arena, limit),
        }));
        if (usage.contextFraction(limit)) |fraction| {
            try context_lines.append(ctx.arena, try std.fmt.allocPrint(
                ctx.arena,
                "{d:.0}% used",
                .{fraction * 100},
            ));
        }
    } else {
        try context_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s} tokens", .{
            try compact(ctx.arena, usage.context_tokens),
        }));
    }

    var session_lines: std.ArrayList([]const u8) = .empty;
    try session_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s} in · {s} out", .{
        try compact(ctx.arena, usage.input_tokens),
        try compact(ctx.arena, usage.output_tokens),
    }));
    try session_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{d} model calls", .{usage.calls}));
    if (usage.tokensPerSecond()) |rate| {
        try session_lines.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{d:.0} tok/s", .{rate}));
    }

    const model_line = if (self.provider.model.len > 0)
        try std.fmt.allocPrint(ctx.arena, "{s} · {s}", .{ self.provider.model, self.provider.name })
    else
        self.provider.name;

    const sections = [_]Section{
        .{ .title = "Context", .lines = context_lines.items },
        .{ .title = "Session", .lines = session_lines.items },
        .{ .title = "Model", .lines = &.{model_line} },
    };

    var row: u16 = 1;
    const heading = if (self.loop.title().len > 0)
        fitRight(self.loop.title(), inner)
    else
        fitLeft(ctx.arena, projectName(self), inner);
    _ = w.writeText(surface, left, row, heading, theme.on_card(theme.fg).bold().cell);
    row += 2;

    for (sections) |section| {
        if (row >= height) break;
        _ = w.writeText(surface, left, row, section.title, theme.on_card(theme.fg).bold().cell);
        row += 1;
        for (section.lines) |line| {
            if (row >= height) break;
            _ = w.writeText(surface, left, row, fitLeft(ctx.arena, line, inner), theme.on_card(theme.fg_dim).cell);
            row += 1;
        }
        row += 1;
    }

    if (height >= 3) {
        const col = w.writeText(surface, left, height - 2, "• ", theme.on_card(theme.accent).cell);
        const title_col = w.writeText(surface, col, height - 2, pkg.name ++ " ", theme.on_card(theme.fg_muted).cell);
        _ = w.writeText(surface, title_col, height - 2, pkg.version, theme.on_card(theme.fg_dim).cell);
    }

    return surface;
}

/// Group digits so six-figure token counts stay readable at a glance.
/// A token count as it reads at a glance: `19.2K`, `1.4M`, `842`. The sidebar
/// is 48 columns wide and these sit two to a line, so the exact digits cost
/// more room than they are worth.
pub fn compact(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    const n: u64 = @intCast(value);
    if (n < 1000) return std.fmt.allocPrint(arena, "{d}", .{n});

    const units = [_][]const u8{ "K", "M", "B" };
    var scaled: f64 = @floatFromInt(n);
    var unit: usize = 0;
    while (scaled >= 1000 and unit + 1 < units.len) : (unit += 1) {
        scaled /= 1000;
        if (scaled < 1000) break;
    }

    if (scaled < 100) return std.fmt.allocPrint(arena, "{d:.1}{s}", .{ scaled, units[unit] });
    return std.fmt.allocPrint(arena, "{d:.0}{s}", .{ scaled, units[unit] });
}

pub fn projectName(self: *Model) []const u8 {
    if (self.loop.title().len > 0) return self.loop.title();
    if (self.cwd.len == 0) return pkg.name;
    return std.fs.path.basename(self.cwd);
}

/// Clip to `width` from the right, keeping the beginning. Returns a slice of
/// the original, so there is no ellipsis to allocate.
pub fn fitRight(text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    if (w.textWidth(text) <= width) return text;

    var kept: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const cw = vaxis.gwidth.gwidth(g.bytes(text), .unicode);
        if (kept + cw > width) return text[0..g.start];
        kept += cw;
    }
    return text;
}

/// The marker a clipped string ends or starts with, and what fits when the
/// space is narrower than it is.
const marker = "...";

fn markerFor(width: u16) []const u8 {
    return marker[0..@min(@as(usize, width), marker.len)];
}

/// Clip to `width` from the left, keeping the tail - the part of a path that
/// identifies it - behind a leading marker. The marker is three cells, so a
/// width narrower than that is all marker and no text.
pub fn fitLeft(arena: std.mem.Allocator, text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    const text_w = w.textWidth(text);
    if (text_w <= width) return text;
    if (width <= marker.len) return markerFor(width);

    var drop = text_w - width + @as(u16, marker.len);
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const cw = vaxis.gwidth.gwidth(g.bytes(text), .unicode);
        if (drop <= cw) {
            const tail = text[g.start + g.len ..];
            return std.fmt.allocPrint(arena, marker ++ "{s}", .{tail}) catch tail;
        }
        drop -= cw;
    }
    return marker;
}

test "token counts read at a glance" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("0", try compact(arena, @as(u32, 0)));
    try std.testing.expectEqualStrings("999", try compact(arena, @as(u32, 999)));
    try std.testing.expectEqualStrings("1.0K", try compact(arena, @as(u32, 1000)));
    try std.testing.expectEqualStrings("19.2K", try compact(arena, @as(u32, 19_210)));
    try std.testing.expectEqualStrings("32.8K", try compact(arena, @as(u32, 32_768)));
    try std.testing.expectEqualStrings("142K", try compact(arena, @as(u32, 142_000)));
    try std.testing.expectEqualStrings("1.2M", try compact(arena, @as(u64, 1_234_567)));
}

test "a long name is trimmed from the end, a path from the front" {
    try std.testing.expectEqualStrings("abc", fitRight("abc", 5));
    try std.testing.expectEqualStrings("abc", fitRight("abcdef", 3));

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The marker is part of the width, so the result never overflows what it
    // was asked to fit.
    try std.testing.expectEqualStrings("...", fitLeft(arena, "/home/dev", 3));
    try std.testing.expectEqualStrings("...v", fitLeft(arena, "/home/dev", 4));
    try std.testing.expectEqualStrings("...dev", fitLeft(arena, "/home/dev", 6));
    try std.testing.expectEqualStrings("/home/dev", fitLeft(arena, "/home/dev", 9));

    // Narrower than the marker: as much of it as fits, and nothing wider.
    try std.testing.expectEqualStrings("", fitLeft(arena, "/home/dev", 0));
    try std.testing.expectEqualStrings(".", fitLeft(arena, "/home/dev", 1));
    try std.testing.expectEqualStrings("..", fitLeft(arena, "/home/dev", 2));

    for (0..12) |width| {
        const fitted = fitLeft(arena, "/home/dev", @intCast(width));
        try std.testing.expect(w.textWidth(fitted) <= width);
    }
}
