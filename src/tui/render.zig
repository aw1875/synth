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
const Project = @import("../core/project.zig");
const mention = @import("../core/mention.zig");
const skill = @import("../core/skill.zig");
const todo = @import("../core/todo.zig");
const widget_pool = @import("widget_pool.zig");
const AgentLoop = @import("../agent/loop.zig");
const recap = @import("../agent/recap.zig");
const ask_user = @import("../tools/ask.zig");
const pkg = @import("pkg");
const Input = @import("input.zig");
const markdown = @import("markdown.zig");
const Selection = @import("selection.zig");
const scrim = @import("scrim.zig");
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const ThoughtView = @import("thought_view.zig");
const w = @import("widgets.zig");

pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
    const self: *Model = @ptrCast(@alignCast(ptr));
    return draw(self, ctx);
}

pub fn draw(self: *Model, ctx: vxfw.DrawContext) !vxfw.Surface {
    var root = try w.surfaceClamped(ctx.arena, self.widget(), ctx.max.size());
    // Rows past the root's clamped height are not addressable by vaxis.
    const max = root.size;
    w.fill(root, theme.base.cell);
    if (max.width == 0 or max.height == 0) return root;

    // The title row and the rule under it, which the frame starts below.
    const title_h: u16 = 2;

    const sidebar_w: u16 = if (self.sidebar_open and max.width >= Model.sidebar_min_term_width)
        Model.sidebar_width
    else
        0;
    const main_w = max.width - sidebar_w;
    self.sidebar_col = if (sidebar_w > 0) main_w else max.width;
    const column_w = main_w -| (Model.gutter * 2);

    // The composer spans the frame, so its rule reads as the frame's own edge.
    const approving = self.session.state() == .awaiting_approval;
    const bottom = if (approving)
        try drawApproval(self, ctx, column_w)
    else
        try drawPrompt(self, ctx, max.width);
    const bottom_col: u16 = if (approving) Model.gutter else 0;

    const body_h = max.height -| (title_h + bottom.size.height);

    var children: std.ArrayList(vxfw.SubSurface) = .empty;

    try children.append(ctx.arena, .{
        .origin = .{ .row = @intCast(title_h + body_h), .col = @intCast(bottom_col) },
        .surface = bottom,
    });

    if (self.input_cursor) |cursor| {
        root.cursor = .{
            .row = title_h + body_h + cursor.row,
            .col = bottom_col + cursor.col,
            .shape = cursor.shape,
        };
    }

    if (column_w > 0 and body_h > 0) {
        if (self.slash.isOpen()) {
            const popup = try self.slash.draw(ctx, self.plainWidget(), column_w);
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(title_h + (body_h -| popup.size.height)), .col = Model.gutter },
                .surface = popup,
                .z_index = 1,
            });
        }

        if (self.mentions.isOpen()) {
            const popup = try self.mentions.draw(ctx, self.plainWidget(), column_w);
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(title_h + (body_h -| popup.size.height)), .col = Model.gutter },
                .surface = popup,
                .z_index = 1,
            });
        }

        if (try drawTranscript(self, ctx, column_w, body_h -| Model.block_gap)) |transcript| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = title_h, .col = Model.gutter },
                .surface = transcript,
            });
        }
    }

    drawTitleBar(self, ctx, root, max.width);

    if (sidebar_w > 0) {
        const sidebar = try drawSidebar(self, ctx, sidebar_w, body_h, title_h);
        try children.append(ctx.arena, .{
            .origin = .{ .row = title_h, .col = @intCast(main_w) },
            .surface = sidebar,
        });
    } else {
        // Nothing drew the plan, so last frame's rows would catch a stray click.
        self.plan_top = 0;
        self.plan_bottom = 0;
    }

    var dialog_open = false;

    if (try self.sessions.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = null;
    }

    if (try self.models.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.mcp_picker.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.effort_picker.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
    }

    if (try self.theme_picker.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.connect.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (try self.rename.draw(ctx, self.plainWidget(), max)) |dialog| {
        dialog_open = true;
        try children.append(ctx.arena, .{
            .origin = .{ .row = dialog.origin.row, .col = dialog.origin.col },
            .surface = dialog.surface,
            .z_index = 3,
        });
        root.cursor = dialog.cursor;
    }

    if (column_w > 0 and body_h > 0) {
        const area: vxfw.Size = .{ .width = column_w, .height = body_h };
        for (try self.notification.draw(ctx, area)) |toast| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = title_h + toast.origin.row, .col = Model.gutter + toast.origin.col },
                .surface = toast.surface,
                .z_index = 4,
            });
        }
    }

    root.children = children.items;

    try self.selection.capture(root);

    if (dialog_open) {
        if (try scrim.draw(ctx.arena, self.plainWidget(), root, max)) |dim| {
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = dim,
                .z_index = 2,
            });
            root.children = children.items;
        }
    }

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
    steering: []const u8,
    steering_more: usize,
    /// What a finished turn did, as the harness wrote it down.
    recap: *Conversation.Message,

    /// Whether this block belongs to the live tail - the part that grows while
    /// a turn is in flight. Growth there is what the scroll offset has to be
    /// compensated for; growth anywhere else is history being paged in, which
    /// happens above the viewport and moves nothing.
    fn inTail(self: Block) bool {
        return switch (self) {
            .thinking, .streaming, .steering, .steering_more, .recap => true,
            else => false,
        };
    }
};

/// List every block the transcript would show, newest last. Cheap by design:
/// nothing here draws, allocates a surface, or touches a widget pool.
fn enumerateBlocks(self: *Model, arena: std.mem.Allocator, pending: usize) ![]Block {
    var blocks: std.ArrayList(Block) = .empty;

    if (self.shown().dropped > 0) try blocks.append(arena, .notice);

    for (self.shown().messages.items) |*msg| {
        if (msg.role == .tool) continue;

        if (msg.role == .system) {
            try blocks.append(arena, .{ .summary = msg });
            continue;
        }

        if (msg.role == .summary) {
            try blocks.append(arena, .{ .recap = msg });
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

    const steering = self.session.pendingSteering();
    for (steering, 0..) |prompt, i| {
        if (i == Model.max_steering_shown) {
            try blocks.append(arena, .{ .steering_more = steering.len - i });
            break;
        }
        try blocks.append(arena, .{ .steering = prompt });
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
            .{self.shown().dropped},
        ), width),

        .summary => |msg| {
            var summarised: usize = 0;
            for (self.shown().messages.items) |*earlier| {
                if (earlier.seq >= msg.seq) break;
                summarised += 1;
            }
            const card = try widget_pool.attachmentCard(self, msg, Model.summary_card_key, &.{
                .path = try std.fmt.allocPrint(
                    ctx.arena,
                    "context compacted \u{b7} {d} messages summarised",
                    .{summarised + self.shown().dropped},
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
            const stream = self.shownLoop().streamingText() orelse return null;
            const partial = try stream.snapshot(ctx.arena);
            if (partial.len == 0) return null;
            return try messageBlock(self, ctx, .{ .role = .assistant, .text = partial }, width);
        },

        .recap => |msg| return try recapBlock(self, ctx, msg.text, width),

        .steering => |prompt| return try steeringBlock(self, ctx, prompt, width),

        .steering_more => |count| return try steeringBlock(
            self,
            ctx,
            try std.fmt.allocPrint(ctx.arena, "+{d} more waiting", .{count}),
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

    // A subagent and a session message share a seq, so not the measured height.
    std.hash.autoHash(&hasher, self.viewTag());

    switch (block) {
        .notice => {
            std.hash.autoHash(&hasher, @as(u8, 1));
            std.hash.autoHash(&hasher, self.shown().dropped);
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
            if (self.thought_rows.get(self.viewKey(msg.seq))) |row| std.hash.autoHash(&hasher, row.expanded);
        },
        .text => |msg| {
            std.hash.autoHash(&hasher, @as(u8, 4));
            std.hash.autoHash(&hasher, msg.seq);
            std.hash.autoHash(&hasher, msg.text.len);
            if (self.paste_toggles.get(self.viewKey(msg.seq))) |toggle| std.hash.autoHash(&hasher, toggle.expanded);
        },
        .attachment => |at| {
            std.hash.autoHash(&hasher, @as(u8, 5));
            std.hash.autoHash(&hasher, at.msg.seq);
            std.hash.autoHash(&hasher, at.index);
            if (self.attachment_cards.get(self.widgetKey(at.msg.seq, at.index))) |card| {
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
            if (self.tool_cards.get(self.widgetKey(at.msg.seq, at.index))) |card| {
                std.hash.autoHash(&hasher, card.expanded);
            }
        },
        .question, .thinking, .streaming, .steering, .steering_more, .recap => return null,
    }

    return hasher.final();
}

pub fn drawTranscript(
    self: *Model,
    ctx: vxfw.DrawContext,
    width: u16,
    height: u16,
) !?vxfw.Surface {
    const messages = self.shown().messages.items;
    const watched = self.shownLoop();
    const pending: usize = if (watched.isBusy() and
        watched.state() != .awaiting_approval) 1 else 0;
    if (height == 0 or messages.len + pending + self.session.pendingSteering().len == 0) return null;

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

    // The offset counts back from the newest row, so a growing tail slides the view.
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

/// A message block, with its held-back pastes folded in when the message has
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
    const entry = try self.paste_toggles.getOrPut(self.allocator, self.viewKey(seq));
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
    const mine = msg.role == .user;
    const invoked = invokedSkill(msg);

    // What the reader typed is what the rest of the turn is answering.
    const style = if (mine) theme.base.cell else theme.on_bg(theme.fg_muted).cell;

    const opts: w.PanelOptions = .{
        .style = theme.base.cell,
        .left = 1,
        .right = 2,
        .accent = if (invoked != null) theme.accent_alt else if (mine) theme.accent else theme.border,
        .rule = w.solid_rule,
        .mark = if (mine) w.prompt_mark else null,
        .width = width,
    };

    const constraints = ctx.withConstraints(.{}, .{ .width = width, .height = null });
    const inner_width = w.panelInnerWidth(constraints, opts);
    if (inner_width == 0) return .empty(self.plainWidget());

    const content = if (invoked) |id|
        try skillLine(self, ctx, id, arguments(msg.text), style, inner_width)
    else if (mine)
        try plainText(ctx, msg.text, style, inner_width)
    else
        try markdown.draw(constraints, self.plainWidget(), msg.text, style, inner_width);

    return w.wrap(constraints, content, opts);
}

/// The skill a user turn invoked, or null for an ordinary message.
///
/// Read off the attachment rather than the text: what makes this a skill run is
/// that the instructions were attached to it, and a message that merely starts
/// with a slash is not one.
fn invokedSkill(msg: Conversation.Message) ?[]const u8 {
    if (msg.role != .user) return null;
    for (msg.attachments) |attachment| {
        if (skill.idFromPath(attachment.path)) |id| return id;
    }
    return null;
}

/// Whatever followed the command word, which is what the skill was run against.
fn arguments(text: []const u8) []const u8 {
    const space = std.mem.indexOfAny(u8, text, " \t") orelse return "";
    return std.mem.trim(u8, text[space..], " \t");
}

/// A skill run, headed so it reads as neither a message nor a tool call. It is
/// both - a turn the reader started, carrying instructions the model was given -
/// and the accent is the one questions use, since those are the other blocks
/// that are not quite either.
fn skillLine(
    self: *Model,
    ctx: vxfw.DrawContext,
    id: []const u8,
    args: []const u8,
    style: vaxis.Cell.Style,
    width: u16,
) !vxfw.Surface {
    const surface = try w.surfaceClamped(ctx.arena, self.plainWidget(), .{ .width = width, .height = 1 });
    w.fill(surface, style);

    var col = w.writeText(surface, 0, 0, "skill", theme.on_bg(theme.fg_dim).cell);
    col = w.writeText(surface, col + 1, 0, id, theme.on_bg(theme.accent_alt).bold().cell);
    if (args.len > 0) {
        _ = w.writeText(surface, col + 1, 0, args, theme.on_bg(theme.fg_muted).cell);
    }
    return surface;
}

/// Something typed while the turn was running: the user's card, dimmed, so it
/// reads as not yet sent rather than as part of the transcript. It reaches the
/// model at its next step.
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

/// How the turn ended, and the files and commands it touched.
pub fn recapBlock(self: *Model, ctx: vxfw.DrawContext, body: []const u8, width: u16) !vxfw.Surface {
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

    return w.wrap(constraints, try plainText(ctx, body, style, inner_width), opts);
}

pub fn steeringBlock(self: *Model, ctx: vxfw.DrawContext, text: []const u8, width: u16) !vxfw.Surface {
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

    const call = self.session.pendingCall() orelse return drawPrompt(self, ctx, width);
    const seq = self.session.pendingSeq() orelse 0;
    const call_index = self.session.firstPending() orelse 0;
    self.approval.sync((seq << 32) | call_index);

    const definition = self.registry.get(call.name);
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
    const text_col = Model.gutter + 2;

    const chip = try modeChip(self, ctx.arena);
    const chip_w = w.textWidth(chip.text);
    const waiting = if (self.session.pendingSteering().len > 0)
        try std.fmt.allocPrint(ctx.arena, "{d} waiting", .{self.session.pendingSteering().len})
    else
        "";
    const right_w = chip_w + if (waiting.len > 0) w.textWidth(waiting) + 1 else 0;

    self.input.style = theme.base.cell;
    self.input.tokens = self.held.tokens();
    self.input.token_style = theme.on_bg(theme.warning).withBg(theme.surface_alt).cell;

    const inner = width -| (text_col + right_w + 1 + Model.gutter);

    const rows: u16 = if (inner == 0)
        1
    else
        std.math.clamp(self.input.lineCount(inner), 1, Model.max_input_rows);
    self.input.height = rows;

    // The rule above it, the rows it takes, and the blank one under it.
    const height = rows + 2;

    var surface = try w.surfaceClamped(ctx.arena, self.input.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.base.cell);
    w.rule(surface, 0, 0, width, theme.on_bg(theme.border).cell);

    // The mark a sent turn wears, so the composer reads as the next one.
    _ = w.writeText(surface, Model.gutter, 1, w.prompt_mark, theme.on_bg(if (self.inSubagent())
        theme.fg_dim
    else
        Model.agentColor(self.session.agentId())).bold().cell);

    self.input_cursor = null;
    if (inner > 0) {
        self.input.placeholder = if (self.viewing) |view|
            view.hint
        else if (self.session.state() == .awaiting_answer)
            "Answer to continue..."
        else if (self.session.isBusy())
            "Type to queue a message..."
        else
            "Ask anything...    / for commands, @ for files";
        self.input.placeholder_style = theme.on_bg(theme.fg_dim).cell;

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

    var col = width -| (Model.gutter + chip_w);
    if (waiting.len > 0) {
        _ = w.writeText(surface, col -| (w.textWidth(waiting) + 1), 1, waiting, theme.on_bg(theme.accent_alt).cell);
    }

    col = w.writeText(surface, col, 1, chip.lead, theme.on_bg(chip.color).cell);
    _ = w.writeText(surface, col, 1, chip.text[chip.lead.len..], theme.on_bg(theme.fg_dim).cell);

    return surface;
}

/// The chip at the right of the composer: which agent is answering and how to
/// change it, or whatever the composer needs to say instead.
const Chip = struct {
    /// The whole chip, `lead` included.
    text: []const u8,
    /// The part set in `color`, which is always what the text starts with.
    lead: []const u8,
    color: vaxis.Cell.Color,
};

fn modeChip(self: *Model, arena: std.mem.Allocator) !Chip {
    if (self.quit_confirm.armed(self.io)) {
        return .{ .text = "ctrl+c again to quit", .lead = "ctrl+c", .color = theme.warning };
    }

    const carries_image = self.held.imageCount() > 0 or mention.mentionsImage(self.input.text.items);
    if (!self.provider.vision and carries_image) {
        return .{ .text = "ctrl+o  this model cannot see images", .lead = "ctrl+o", .color = theme.warning };
    }

    const id = self.session.agentId();
    return .{
        .text = try std.fmt.allocPrint(arena, "{s} mode{s}tab to switch", .{ id, w.separator }),
        .lead = id,
        .color = if (self.inSubagent()) theme.fg_dim else Model.agentColor(id),
    };
}

/// The top line: which session, where it is, and what is answering.
///
/// Everything here is true of the whole run rather than of any one turn, which
/// is why it sits above the transcript instead of scrolling away inside it.
pub fn drawTitleBar(self: *Model, ctx: vxfw.DrawContext, root: vxfw.Surface, width: u16) void {
    w.rule(root, 1, 0, width, theme.on_bg(theme.border).cell);
    if (width <= Model.gutter * 2) return;
    const room = width - Model.gutter * 2;

    // Both: the same model tag is served by a local process and by a cloud.
    const answering = if (self.provider_missing)
        "no provider"
    else if (self.provider.model.len > 0)
        std.fmt.allocPrint(ctx.arena, "{s}{s}{s}{s}{s}", .{
            self.provider.model,
            if (self.provider.effort.len > 0) " " else "",
            self.provider.effort,
            w.separator,
            self.provider.name,
        }) catch self.provider.name
    else
        self.provider.name;
    const answering_w = w.textWidth(answering);
    const gap = w.textWidth(w.separator);

    // The model gives up its edge before the session gives up any of its own.
    const right_fits = answering_w > 0 and answering_w + gap < room;
    const left_room = if (right_fits) room - answering_w - gap else room;
    const end = Model.gutter + left_room;

    var col = w.writeText(root, Model.gutter, 0, fitRight(projectName(self), left_room), theme.on_bg(theme.fg).bold().cell);

    const branch = if (self.project) |project| project.branch orelse "" else "";
    const on_branch = if (branch.len > 0)
        std.fmt.allocPrint(ctx.arena, "on {s}", .{branch}) catch ""
    else
        "";

    // The branch takes its room first: a path can be trimmed and still read.
    const held: u16 = if (on_branch.len > 0) 1 + w.textWidth(on_branch) else 0;
    const path_room = (end -| col) -| (gap + held);
    if (path_room > 0 and self.cwd_display.len > 0) {
        const at = w.writeText(root, col, 0, w.separator, theme.on_bg(theme.fg_dim).cell);
        col = w.writeText(root, at, 0, fitLeft(ctx.arena, self.cwd_display, path_room), theme.on_bg(theme.fg).cell);
    }

    if (on_branch.len > 0 and col + held <= end) {
        col = w.writeText(root, col + 1, 0, on_branch, theme.on_bg(theme.success).cell);
    }

    if (right_fits) {
        _ = w.writeText(root, width - Model.gutter - answering_w, 0, answering, theme.on_bg(theme.fg_muted).cell);
    }
}

/// A label and its value, set against the two edges of the rail the way the
/// design's context rows are.
fn railRow(
    surface: vxfw.Surface,
    left: u16,
    inner: u16,
    row: u16,
    label: []const u8,
    value: []const u8,
    style: vaxis.Cell.Style,
) void {
    _ = w.writeText(surface, left, row, label, style);
    const value_w = w.textWidth(value);
    if (value_w > inner) return;
    _ = w.writeText(surface, left + inner - value_w, row, value, style);
}

/// How full the context window is, as a bar of its own width.
fn railBar(surface: vxfw.Surface, left: u16, inner: u16, row: u16, fraction: f64) void {
    w.fillRow(surface, row, left, inner, theme.on(theme.border, theme.border).cell);

    const clamped = std.math.clamp(fraction, 0, 1);
    const filled: u16 = @intFromFloat(@round(clamped * @as(f64, @floatFromInt(inner))));
    if (filled == 0) return;
    w.fillRow(surface, row, left, filled, theme.on(theme.accent, theme.accent).cell);
}

/// The rule between one part of the rail and the next.
fn railSeparator(surface: vxfw.Surface, left: u16, inner: u16, row: u16) void {
    w.rule(surface, row, left, inner, theme.on_bg(theme.border).cell);
}

/// The right-hand rail: how much room is left, then what the model is working
/// through. No ground of its own - a border down its edge is what divides it
/// from the transcript.
pub fn drawSidebar(self: *Model, ctx: vxfw.DrawContext, width: u16, height: u16, top: u16) !vxfw.Surface {
    const surface = try w.surfaceClamped(ctx.arena, self.plainWidget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.base.cell);

    for (0..height) |row| {
        surface.writeCell(0, @intCast(row), .{
            .char = .{ .grapheme = w.solid_rule, .width = 1 },
            .style = theme.on_bg(theme.border).cell,
        });
    }

    const left: u16 = 2;
    const inner = width -| (left + 1);
    if (inner == 0 or height == 0) return surface;

    const faint = theme.on_bg(theme.fg_dim).cell;
    const usage = self.session.usage();
    const limit = self.provider.context_limit;

    var row: u16 = 1;
    _ = w.writeHeading(surface, left, row, "context", faint, theme.fg_dim);
    row += 1;

    if (usage.context_tokens == 0) {
        railRow(surface, left, inner, row, "no requests yet", "", faint);
        row += 1;
    } else if (limit > 0) {
        railRow(
            surface,
            left,
            inner,
            row,
            try std.fmt.allocPrint(ctx.arena, "{s} used", .{try compact(ctx.arena, usage.context_tokens)}),
            try compact(ctx.arena, limit),
            faint,
        );
        row += 1;
        if (usage.contextFraction(limit)) |fraction| {
            railBar(surface, left, inner, row, fraction);
            row += 1;
        }
    } else {
        railRow(surface, left, inner, row, "used", try compact(ctx.arena, usage.context_tokens), faint);
        row += 1;
    }

    row += 1;
    railRow(surface, left, inner, row, "in", try compact(ctx.arena, usage.input_tokens), faint);
    row += 1;
    railRow(surface, left, inner, row, "out", try compact(ctx.arena, usage.output_tokens), faint);
    row += 1;
    railRow(surface, left, inner, row, "model calls", try std.fmt.allocPrint(ctx.arena, "{d}", .{usage.calls}), faint);
    row += 1;
    if (usage.tokensPerSecond()) |rate| {
        railRow(surface, left, inner, row, "tok/s", try std.fmt.allocPrint(ctx.arena, "{d:.0}", .{rate}), faint);
        row += 1;
    }

    if (self.session.todos().any() and row + 2 < height) {
        row += 1;
        railSeparator(surface, left, inner, row);
        row += 2;
        _ = try drawPlan(self, ctx, surface, left, inner, height -| 2, row, top);
    } else {
        self.plan_top = 0;
        self.plan_bottom = 0;
    }

    if (height >= 3) {
        const at = w.writeText(surface, left, height - 2, pkg.name ++ " ", theme.on_bg(theme.fg_dim).cell);
        _ = w.writeText(surface, at, height - 2, pkg.version, theme.on_bg(theme.fg_dim).cell);
    }

    return surface;
}

/// The steps the model is working through, at the top of the sidebar where a
/// glance lands. Returns the row after it.
///
/// Collapsed it is one line - the step in hand - because that is the part worth
/// a permanent place. Expanded it is the whole list, which the sidebar has the
/// room for and the transcript does not.
fn drawPlan(
    self: *Model,
    ctx: vxfw.DrawContext,
    surface: vxfw.Surface,
    left: u16,
    inner: u16,
    height: u16,
    start: u16,
    /// Screen row the rail is drawn at. The rows recorded for the hit test are
    /// the ones a mouse event arrives in, not the rail's own.
    top: u16,
) !u16 {
    const list = self.session.todos();
    self.plan_top = 0;
    self.plan_bottom = 0;
    if (!list.any() or start >= height) return start;

    var row = start;
    const faint = theme.on_bg(theme.fg_dim).cell;
    const title = w.writeHeading(surface, left, row, "plan", faint, theme.fg_dim);
    const counted = w.writeText(surface, title + 1, row, try std.fmt.allocPrint(
        ctx.arena,
        "{d}/{d}",
        .{ list.done(), list.items.items.len },
    ), faint);
    if (self.plan_hover) {
        const hint = if (list.expanded) " hide" else " show";
        _ = w.writeText(surface, counted, row, hint, faint);
    }
    row += 1;

    if (list.expanded) {
        for (list.items.items) |item| {
            if (row >= height) break;
            row = drawStep(surface, left, inner, height, row, item);
        }
    } else if (list.current()) |item| {
        row = drawStep(surface, left, inner, height, row, item);
    }

    self.plan_top = top + start;
    self.plan_bottom = top + row;
    return row + 1;
}

/// One step, its text wrapped under its own mark. The sidebar is narrow and
/// tall, so a step that does not fit is given another line rather than cut.
fn drawStep(
    surface: vxfw.Surface,
    left: u16,
    inner: u16,
    height: u16,
    start: u16,
    item: todo.Item,
) u16 {
    // The marks carry the state, so a done step is struck through, not coloured.
    const style = switch (item.status) {
        .active => theme.on_bg(theme.fg),
        .done => theme.on_bg(theme.fg_dim).strikethrough(),
        .pending => theme.on_bg(theme.fg_muted),
    };
    const mark = switch (item.status) {
        .active => theme.on_bg(theme.accent),
        .done => theme.on_bg(theme.success),
        .pending => theme.on_bg(theme.fg_dim),
    };

    _ = w.writeText(surface, left, start, item.status.mark(), mark.cell);

    const text_col = left + 2;
    const text_width = inner -| 2;
    if (text_width == 0) return start + 1;

    var row = start;
    var rest = item.text;
    while (rest.len > 0 and row < height) {
        const cut = wrapPoint(rest, text_width);
        _ = w.writeText(surface, text_col, row, rest[0..cut], style.cell);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
        row += 1;
        if (row - start >= plan_step_rows) break;
    }
    return row;
}

/// Rows one step may take before the rest of it is dropped. Three is enough for
/// any step worth writing down, and stops one runaway line pushing the whole
/// list off the screen.
const plan_step_rows: u16 = 3;

/// How much of `text` fits in `width`, broken at a space where there is one.
fn wrapPoint(text: []const u8, width: u16) usize {
    if (w.textWidth(text) <= width) return text.len;

    var kept: u16 = 0;
    var last_space: ?usize = null;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const cw = vaxis.gwidth.gwidth(bytes, .unicode);
        if (kept + cw > width) {
            return last_space orelse g.start;
        }
        if (bytes.len == 1 and bytes[0] == ' ') last_space = g.start;
        kept += cw;
    }
    return text.len;
}

/// Group digits so six-figure token counts stay readable at a glance.
/// A token count as it reads at a glance: `19.2K`, `1.4M`, `842`. The sidebar
/// is 48 columns wide and these sit two to a line, so the exact digits cost
/// more room than they are worth.
pub fn compact(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    const n: u64 = @intCast(value);
    if (n < 1000) return std.fmt.allocPrint(arena, "{d}", .{n});

    const units = [_][]const u8{ "k", "M", "B" };
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
    if (self.session.title().len > 0) return self.session.title();
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
    try std.testing.expectEqualStrings("1.0k", try compact(arena, @as(u32, 1000)));
    try std.testing.expectEqualStrings("19.2k", try compact(arena, @as(u32, 19_210)));
    try std.testing.expectEqualStrings("32.8k", try compact(arena, @as(u32, 32_768)));
    try std.testing.expectEqualStrings("142k", try compact(arena, @as(u32, 142_000)));
    try std.testing.expectEqualStrings("1.2M", try compact(arena, @as(u64, 1_234_567)));
}

test "a long name is trimmed from the end, a path from the front" {
    try std.testing.expectEqualStrings("abc", fitRight("abc", 5));
    try std.testing.expectEqualStrings("abc", fitRight("abcdef", 3));

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The marker is part of the width, so the result never overflows.
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

test "a skill run is told apart from a message that merely starts with a slash" {
    var attachments = [_]Conversation.Attachment{
        .{ .path = "/p/.agents/skills/caveman/SKILL.md", .content = "body" },
    };
    const invoked: Conversation.Message = .{
        .role = .user,
        .text = "/caveman ultra",
        .attachments = &attachments,
    };
    try std.testing.expectEqualStrings("caveman", invokedSkill(invoked).?);

    const typed: Conversation.Message = .{ .role = .user, .text = "/caveman ultra" };
    try std.testing.expect(invokedSkill(typed) == null);

    var mentioned = [_]Conversation.Attachment{
        .{ .path = "src/main.zig", .content = "body" },
    };
    const mention_msg: Conversation.Message = .{
        .role = .user,
        .text = "look at @src/main.zig",
        .attachments = &mentioned,
    };
    try std.testing.expect(invokedSkill(mention_msg) == null);

    const from_model: Conversation.Message = .{
        .role = .assistant,
        .text = "/caveman",
        .attachments = &attachments,
    };
    try std.testing.expect(invokedSkill(from_model) == null);
}

test "the arguments a skill was run against are what followed its name" {
    try std.testing.expectEqualStrings("ultra", arguments("/caveman ultra"));
    try std.testing.expectEqualStrings("2.1 --dry-run", arguments("/release  2.1 --dry-run"));
    try std.testing.expectEqualStrings("", arguments("/caveman"));
    try std.testing.expectEqualStrings("", arguments("/caveman   "));
}

test "a step breaks at a space, and mid-word only when it has to" {
    try std.testing.expectEqual(@as(usize, 11), wrapPoint("write tests", 20));
    try std.testing.expectEqual(@as(usize, 5), wrapPoint("write tests", 8));
    try std.testing.expectEqual(@as(usize, 5), wrapPoint("write tests", 5));
    try std.testing.expectEqual(@as(usize, 4), wrapPoint("supercalifragilistic", 4));
    try std.testing.expectEqual(@as(usize, 0), wrapPoint("supercalifragilistic", 0));
}

test "a reply hangs off a rule, and its text sits one level in" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = undefined,
        .plain_vtable = .{ .userdata = &userdata, .drawFn = Dummy.drawFn },
    };
    defer model.conversation.deinit();

    const width: u16 = 40;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const msg: Conversation.Message = .{ .role = .assistant, .text = "hello" };
    const surface = try messageBlock(&model, ctx, msg, width);

    // The rule is the reply's own, at the margin, in the colour rules take.
    try testing.expectEqualStrings(w.solid_rule, surface.buffer[0].char.grapheme);
    try testing.expectEqual(theme.border, surface.buffer[0].style.fg);

    // Its text starts a level in, which is where a call it made hangs its rule.
    try testing.expectEqual(@as(i17, w.nest), surface.children[0].origin.col);
}

/// The style of the first cell in `surface`, or anything under it, carrying a
/// visible grapheme.
fn firstTextStyle(surface: vxfw.Surface) ?vaxis.Cell.Style {
    for (surface.buffer) |cell| {
        if (cell.char.grapheme.len == 0) continue;
        if (std.mem.eql(u8, cell.char.grapheme, " ")) continue;
        return cell.style;
    }
    for (surface.children) |child| {
        if (firstTextStyle(child.surface)) |style| return style;
    }
    return null;
}

test "a reply is set a step back from the words it answers" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = undefined,
        .plain_vtable = .{ .userdata = &userdata, .drawFn = Dummy.drawFn },
    };
    defer model.conversation.deinit();

    const width: u16 = 40;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const reply = try messageBlock(&model, ctx, .{ .role = .assistant, .text = "checked" }, width);
    const mine = try messageBlock(&model, ctx, .{ .role = .user, .text = "check it" }, width);

    // Told apart by weight, not only by their rules.
    try testing.expectEqual(theme.fg_muted, firstTextStyle(reply.children[0].surface).?.fg);
    try testing.expectEqual(theme.fg, firstTextStyle(mine.children[0].surface).?.fg);
}

test "your own turn is marked at its head, not down its side" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    var model: Model = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .provider = undefined,
        .input = undefined,
        .plain_vtable = .{ .userdata = &userdata, .drawFn = Dummy.drawFn },
    };
    defer model.conversation.deinit();

    const width: u16 = 20;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const text = "a message long enough to want a second row";
    const surface = try messageBlock(&model, ctx, .{ .role = .user, .text = text }, width);
    try testing.expect(surface.size.height > 1);

    try testing.expectEqualStrings(w.prompt_mark, surface.buffer[0].char.grapheme);
    try testing.expectEqual(theme.accent, surface.buffer[0].style.fg);

    // Nothing below it: the mark opens the turn rather than fencing it in.
    for (1..surface.size.height) |row| {
        try testing.expectEqualStrings(" ", surface.buffer[row * width].char.grapheme);
    }

    // On the app background, like every other block in the transcript.
    try testing.expectEqual(theme.bg, surface.buffer[0].style.bg);
    try testing.expectEqual(@as(i17, w.nest), surface.children[0].origin.col);
}

/// One row of a surface as text, for tests.
fn rowText(arena: std.mem.Allocator, surface: vxfw.Surface, row: u16) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        const cell = surface.buffer[@as(usize, row) * surface.size.width + col];
        try out.appendSlice(arena, if (cell.char.grapheme.len == 0) " " else cell.char.grapheme);
    }
    return out.items;
}

/// A model wired up enough to draw chrome against, built where it will stay:
/// a wired model points into itself.
fn chromeFixture(model: *Model, allocator: std.mem.Allocator, userdata: *u8, project: *Project) !void {
    model.* = .{
        .allocator = allocator,
        .io = std.testing.io,
        .conversation = .init(allocator),
        .provider = .{
            .userdata = userdata,
            .respond = undefined,
            .name = "ollama",
            .model = "qwen3-coder:30b",
        },
        .input = .init(allocator),
        .cwd = try allocator.dupe(u8, "/repo"),
        .cwd_display = try allocator.dupe(u8, "~/dev/zig/harness"),
        .project = project,
        .plain_vtable = .{ .userdata = userdata, .drawFn = undefined },
    };
    try model.wire();
}

/// A project with a branch, for drawing chrome against.
fn chromeProject(allocator: std.mem.Allocator, branch: ?[]const u8) !Project {
    return .{
        .root = try allocator.dupe(u8, "/repo"),
        .cwd = try allocator.dupe(u8, "/repo"),
        .vcs = if (branch == null) .none else .git,
        .branch = if (branch) |name| try allocator.dupe(u8, name) else null,
    };
}

test "the title row names the session, the path, and the branch it is on" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, "fix/flaky-session-test");
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    const width: u16 = 96;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try w.surfaceClamped(arena, model.plainWidget(), .{ .width = width, .height = 2 });
    w.fill(surface, theme.base.cell);
    drawTitleBar(&model, ctx, surface, width);

    const row = try rowText(arena, surface, 0);
    try testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, row, " "), "repo"));
    try testing.expect(std.mem.indexOf(u8, row, "~/dev/zig/harness") != null);
    try testing.expect(std.mem.indexOf(u8, row, "on fix/flaky-session-test") != null);

    // The backend beside it: the same model tag is served from more than one.
    try testing.expect(std.mem.indexOf(u8, row, "qwen3-coder:30b") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, row, " "), "ollama"));

    // Session and path both in the text colour; only the separator is faint.
    const at = std.mem.indexOf(u8, row, "~/dev").?;
    try testing.expectEqual(theme.fg, surface.buffer[Model.gutter].style.fg);
    try testing.expectEqual(theme.fg, surface.buffer[at].style.fg);
    try testing.expectEqual(theme.fg_dim, surface.buffer[at - 2].style.fg);
    try testing.expectEqual(theme.success, surface.buffer[std.mem.indexOf(u8, row, "on fix").?].style.fg);
    try testing.expectEqual(theme.fg_muted, surface.buffer[width - Model.gutter - 1].style.fg);

    // A rule under it, edge to edge, is what divides it from the frame.
    for (0..width) |col| {
        const cell = surface.buffer[width + col];
        try testing.expectEqualStrings("\u{2500}", cell.char.grapheme);
        try testing.expectEqual(theme.border, cell.style.fg);
    }
}

test "the branch keeps its room when the path has to be trimmed" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, "fix/flaky-session-test");
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    const width: u16 = 73;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try w.surfaceClamped(arena, model.plainWidget(), .{ .width = width, .height = 2 });
    w.fill(surface, theme.base.cell);
    drawTitleBar(&model, ctx, surface, width);

    // The path is trimmed to make room rather than the branch being dropped.
    const row = try rowText(arena, surface, 0);
    try testing.expect(std.mem.indexOf(u8, row, "on fix/flaky-session-test") != null);
    try testing.expect(std.mem.indexOf(u8, row, marker) != null);
    try testing.expect(std.mem.indexOf(u8, row, "~/dev/zig/harness") == null);
}

test "a title row too narrow for everything keeps the session and the model" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, "fix/flaky-session-test");
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    const width: u16 = 43;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try w.surfaceClamped(arena, model.plainWidget(), .{ .width = width, .height = 2 });
    w.fill(surface, theme.base.cell);
    drawTitleBar(&model, ctx, surface, width);

    const row = try rowText(arena, surface, 0);
    try testing.expect(std.mem.indexOf(u8, row, "repo") != null);
    try testing.expect(std.mem.indexOf(u8, row, "qwen3-coder:30b") != null);

    // Nothing is allowed to run off the edge or wrap onto the frame below.
    try testing.expect(std.mem.indexOf(u8, row, "on fix") == null);
    try testing.expect(std.mem.indexOf(u8, row, "~/dev") == null);
    try testing.expectEqualStrings(" ", surface.buffer[width - 1].char.grapheme);
}

test "the composer hangs under a rule rather than sitting in a box" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    const width: u16 = 72;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try drawPrompt(&model, ctx, width);

    // The rule, the row typed into, and the blank one under it.
    try testing.expectEqual(@as(u16, 3), surface.size.height);

    for (0..width) |col| {
        try testing.expectEqualStrings("\u{2500}", surface.buffer[col].char.grapheme);
        try testing.expectEqual(theme.border, surface.buffer[col].style.fg);
    }

    // No box: the rule is the only edge the composer has.
    const typed = try rowText(arena, surface, 1);
    try testing.expect(std.mem.indexOf(u8, typed, "\u{2502}") == null);
    try testing.expect(std.mem.indexOf(u8, typed, "\u{250c}") == null);

    // The mark a sent turn wears, in the colour of whichever agent answers.
    try testing.expectEqualStrings(w.prompt_mark, surface.buffer[width + Model.gutter].char.grapheme);
    try testing.expectEqual(Model.agentColor(model.local_loop.agent.id), surface.buffer[width + Model.gutter].style.fg);

    // The mode closes the row, on the same ground as everything else.
    try testing.expect(std.mem.indexOf(u8, typed, "build mode") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, typed, " "), "tab to switch"));
    for (0..width) |col| {
        try testing.expectEqual(theme.bg, surface.buffer[width + col].style.bg);
    }
}

test "the frame runs from the title rule down to the composer rule" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    // Something to lay out: with nothing said yet there is no transcript to place.
    _ = try model.conversation.addUser("hello", &.{}, &.{});

    const size: vxfw.Size = .{ .width = Model.sidebar_min_term_width, .height = 24 };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = size.width, .height = size.height },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const root = try draw(&model, ctx);

    // The title is painted onto the root itself, above everything laid out.
    try testing.expectEqualStrings("\u{2500}", root.buffer[size.width].char.grapheme);

    var composer: ?vxfw.SubSurface = null;
    for (root.children) |child| {
        // Everything in the frame starts under the title rule.
        try testing.expect(child.origin.row >= 2);
        if (child.origin.col == 0) composer = child;
    }

    // The composer spans the frame, and the rails stop above its rule.
    const bottom = composer.?;
    try testing.expectEqual(@as(u16, size.width), bottom.surface.size.width);
    try testing.expectEqual(@as(i17, size.height), bottom.origin.row + @as(i17, @intCast(bottom.surface.size.height)));

    for (root.children) |child| {
        if (child.origin.col != @as(i17, @intCast(size.width - Model.sidebar_width))) continue;
        try testing.expectEqual(bottom.origin.row, child.origin.row + @as(i17, @intCast(child.surface.size.height)));
    }
}

test "a terminal too big to address still keeps the composer on screen" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    _ = try model.conversation.addUser("hello", &.{}, &.{});

    const size: vxfw.Size = .{ .width = 400, .height = 300 };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = size.width, .height = size.height },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const root = try draw(&model, ctx);
    try testing.expectEqual(w.maxRows(size.width), root.size.height);

    var composer: ?vxfw.SubSurface = null;
    for (root.children) |child| {
        if (child.origin.col == 0) composer = child;
    }

    const bottom = composer.?;
    try testing.expect(bottom.surface.size.height > 0);
    try testing.expectEqual(
        @as(i17, root.size.height),
        bottom.origin.row + @as(i17, @intCast(bottom.surface.size.height)),
    );
}

test "the rail divides itself from the transcript with a border, not a ground" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    const width: u16 = Model.sidebar_width;
    const height: u16 = 20;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = height },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const rail = try drawSidebar(&model, ctx, width, height, 0);

    for (0..height) |row| {
        const edge = rail.buffer[row * width];
        try testing.expectEqualStrings(w.solid_rule, edge.char.grapheme);
        try testing.expectEqual(theme.border, edge.style.fg);
        try testing.expectEqual(theme.bg, edge.style.bg);

        // Nothing raised behind it: the rail is the app's own ground.
        try testing.expectEqual(theme.bg, rail.buffer[row * width + width - 1].style.bg);
    }
}

test "the rail counts the context down before it lists the plan" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    model.provider.context_limit = 200_000;
    model.local_loop.usage = .{ .context_tokens = 42_300, .input_tokens = 12_100, .output_tokens = 3_400, .calls = 7 };
    try model.local_loop.todos.replace(&.{
        .{ .text = "add fake clock helper", .status = .done },
        .{ .text = "run 20x to confirm no flake", .status = .active },
        .{ .text = "apply same fix to token.spec.ts", .status = .pending },
    });
    model.local_loop.todos.expanded = true;

    const width: u16 = Model.sidebar_width;
    const height: u16 = 26;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = height },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const rail = try drawSidebar(&model, ctx, width, height, 0);

    var context_row: ?usize = null;
    var plan_row: ?usize = null;
    var bar_row: ?usize = null;
    for (0..height) |row| {
        const text = try rowText(arena, rail, @intCast(row));
        if (std.mem.indexOf(u8, text, "context") != null) context_row = row;
        if (std.mem.indexOf(u8, text, "plan") != null) plan_row = row;
        if (std.meta.eql(rail.buffer[row * width + 2].style.bg, theme.accent)) bar_row = row;
    }

    // Context first: how much room is left outranks what is being done with it.
    const context_at = context_row orelse return error.TestUnexpectedResult;
    const plan_at = plan_row orelse return error.TestUnexpectedResult;
    try testing.expect(context_at < plan_at);

    // Both headed the way every rail heading is.
    const heading = try rowText(arena, rail, @intCast(context_at));
    try testing.expect(std.mem.indexOf(u8, heading, w.rail_head) != null);
    try testing.expectEqual(theme.fg_dim, rail.buffer[context_at * width + 2].style.fg);

    // The bar is drawn to the fraction used, not to the whole width.
    const bar = bar_row orelse return error.TestUnexpectedResult;
    try testing.expect(bar > context_at and bar < plan_at);
    const inner = width - 3;
    const filled: u16 = @intFromFloat(@round(0.2115 * @as(f64, @floatFromInt(inner))));
    try testing.expectEqual(theme.accent, rail.buffer[bar * width + 2 + filled - 1].style.bg);
    try testing.expectEqual(theme.border, rail.buffer[bar * width + 2 + filled].style.bg);

    // A step in hand reads plainly; a finished one is struck through.
    const steps = try rowText(arena, rail, @intCast(plan_at + 2));
    try testing.expect(std.mem.indexOf(u8, steps, "\u{25b8} run 20x") != null);
    try testing.expect(rail.buffer[(plan_at + 1) * width + 2 + 2].style.strikethrough);
}

test "the rows the plan records are the ones a click arrives in" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    try model.local_loop.todos.replace(&.{
        .{ .text = "add fake clock helper", .status = .done },
        .{ .text = "run 20x to confirm no flake", .status = .active },
    });
    model.local_loop.todos.expanded = false;

    const size: vxfw.Size = .{ .width = Model.sidebar_min_term_width, .height = 30 };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = size.width, .height = size.height },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const root = try draw(&model, ctx);
    try testing.expect(model.plan_bottom > model.plan_top);

    var rail: ?vxfw.SubSurface = null;
    for (root.children) |child| {
        if (child.origin.col == @as(i17, @intCast(size.width - Model.sidebar_width))) rail = child;
    }
    const sidebar = rail orelse return error.TestUnexpectedResult;

    // Collapsed it is two rows, so a click recorded in the wrong space misses.
    const local = model.plan_top - @as(u16, @intCast(sidebar.origin.row));
    const heading = try rowText(arena, sidebar.surface, local);
    try testing.expect(std.mem.indexOf(u8, heading, "plan") != null);
    try testing.expectEqual(@as(u16, 2), model.plan_bottom - model.plan_top);
}

test "the rail is narrow enough to be the design's and wide enough for its numbers" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    model.provider.context_limit = 200_000;
    model.local_loop.usage = .{ .context_tokens = 142_300, .input_tokens = 12_100, .output_tokens = 3_400, .calls = 7 };

    const width: u16 = Model.sidebar_width;
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 20 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const rail = try drawSidebar(&model, ctx, width, 20, 0);

    // A label and its value share one row, and the value keeps the inner edge.
    const row = try rowText(arena, rail, 2);
    try testing.expect(std.mem.indexOf(u8, row, "142k used") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, row, " "), "200k"));
    try testing.expectEqualStrings("k", rail.buffer[2 * width + width - 2].char.grapheme);
}

test "the rail can be sent away, and takes its click targets with it" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var project = try chromeProject(testing.allocator, null);
    defer project.deinit(testing.allocator);

    var userdata: u8 = 0;
    var model: Model = undefined;
    try chromeFixture(&model, testing.allocator, &userdata, &project);
    defer model.deinit();

    _ = try model.conversation.addUser("hello", &.{}, &.{});
    try model.local_loop.todos.replace(&.{.{ .text = "run the suite", .status = .active }});

    const size: vxfw.Size = .{ .width = Model.sidebar_min_term_width, .height = 24 };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = size.width, .height = size.height },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    _ = try draw(&model, ctx);
    try testing.expect(model.plan_bottom > model.plan_top);
    try testing.expectEqual(size.width - Model.sidebar_width, model.sidebar_col);

    model.sidebar_open = false;
    const root = try draw(&model, ctx);

    // The transcript takes the frame, and nothing is left at the rail's column.
    try testing.expectEqual(size.width, model.sidebar_col);
    try testing.expectEqual(@as(u16, 0), model.plan_bottom);
    for (root.children) |child| {
        try testing.expect(child.origin.col < @as(i17, @intCast(size.width - Model.sidebar_width)));
    }
}
