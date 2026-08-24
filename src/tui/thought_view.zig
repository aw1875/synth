//! The clickable "Thinking" row in the transcript. Renders a
//! `agent/thought.zig` stream that a provider is filling from a worker thread.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Thought = @import("../agent/thought.zig");
pub const Stream = Thought.Stream;
const markdown = @import("markdown.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

/// Spinner animation frames and the delay between them.
pub const spinner_frames: []const []const u8 = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
pub const spinner_interval_ms: u32 = 100;

/// The in-transcript loading indicator. Click the header to expand it and watch
/// the thoughts stream in.
pub const View = struct {
    /// The in-flight request's thoughts, or null when nothing is running.
    stream: ?*Stream = null,
    /// Finished reasoning, borrowed from the message that owns it. Used when
    /// `stream` is null, which is what keeps a thought readable after the
    /// request that produced it is gone.
    text: []const u8 = "",
    /// Time spent reasoning. Non-null switches the header from the live
    /// "Thinking" spinner to a settled "Thought: 882ms".
    elapsed_ms: ?u64 = null,
    expanded: bool = false,
    has_mouse: bool = false,
    /// Index into `spinner_frames`, advanced by the model's tick handler.
    frame: u8 = 0,
    /// Column the header text starts at, to line up with assistant messages.
    indent: u16 = 3,
    /// Cap on visible thought rows; the newest are kept.
    max_body_rows: u16 = 12,
    /// Header text while the request is running. The loop swaps this to say
    /// what it is actually doing.
    label: []const u8 = "Thinking",

    pub fn widget(self: *View) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *View = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    pub fn handleEvent(self: *View, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .mouse => |mouse| {
                switch (mouse.button) {
                    .wheel_up, .wheel_down, .wheel_left, .wheel_right => return,
                    .left => {},
                    else => return ctx.consumeEvent(),
                }
                if (mouse.type == .press and mouse.row == 0) {
                    self.expanded = !self.expanded;
                    return ctx.consumeAndRedraw();
                }
                return ctx.consumeEvent();
            },
            .mouse_enter => {
                self.has_mouse = true;
                try ctx.setMouseShape(.pointer);
                return ctx.consumeAndRedraw();
            },
            .mouse_leave => {
                self.has_mouse = false;
                try ctx.setMouseShape(.default);
                ctx.redraw = true;
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *View = @ptrCast(@alignCast(ptr));
        return self.draw(ctx);
    }

    pub fn draw(self: *View, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const width = ctx.max.width orelse 0;

        const thoughts: []const u8 = if (self.stream) |stream|
            try stream.snapshot(ctx.arena)
        else
            self.text;

        const body = if (self.expanded and thoughts.len > 0)
            try self.drawBody(ctx, width, thoughts)
        else
            null;

        const height: u16 = 1 + if (body) |b| b.size.height else 0;
        const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        w.fill(surface, theme.base.cell);

        try self.drawHeader(ctx.arena, surface, thoughts.len > 0);

        if (body) |b| {
            const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
            children[0] = .{
                .origin = .{ .row = 1, .col = @intCast(self.indent + 2) },
                .surface = b,
            };
            return .{
                .size = surface.size,
                .widget = surface.widget,
                .buffer = surface.buffer,
                .children = children,
            };
        }

        return surface;
    }

    fn drawHeader(
        self: *View,
        arena: std.mem.Allocator,
        surface: vxfw.Surface,
        have_thoughts: bool,
    ) std.mem.Allocator.Error!void {
        var col = self.indent;

        if (self.elapsed_ms) |ms| {
            const label = try std.fmt.allocPrint(arena, "Thought: {s}", .{try w.duration(arena, ms)});
            var style = theme.on_bg(theme.warning);
            if (self.has_mouse and have_thoughts) style = style.underline(.single);
            col = w.writeText(surface, col, 0, label, style.cell);
        } else {
            const frame = spinner_frames[self.frame % spinner_frames.len];
            col = w.writeText(surface, col, 0, frame, theme.on_bg(theme.accent).cell);

            var style = theme.on_bg(theme.fg_dim);
            if (self.has_mouse and have_thoughts) style = style.underline(.single);
            col = w.writeText(surface, col + 1, 0, self.label, style.cell);

            if (self.stream) |stream| {
                if (stream.liveElapsedMs() > 0) {
                    const elapsed = stream.liveElapsedMs();
                    const text = try std.fmt.allocPrint(arena, " {s}", .{try w.duration(arena, elapsed)});
                    col = w.writeText(surface, col, 0, text, theme.on_bg(theme.fg_dim).cell);
                }
            }

            if (!have_thoughts) {
                _ = w.writeText(surface, col + 1, 0, "esc to cancel", theme.on_bg(theme.fg_dim).cell);
            }
        }

        if (!have_thoughts) return;

        const marker = if (self.expanded) " ▾ " else " ▸ ";
        col = w.writeText(surface, col, 0, marker, theme.on_bg(theme.fg_dim).cell);

        if (self.has_mouse) {
            const hint = if (self.expanded) "click to collapse" else "click to expand";
            _ = w.writeText(surface, col, 0, hint, theme.on_bg(theme.fg_dim).cell);
        }
    }

    /// Render the thoughts, keeping the newest `max_body_rows` rows.
    fn drawBody(
        self: *View,
        ctx: vxfw.DrawContext,
        width: u16,
        thoughts: []const u8,
    ) std.mem.Allocator.Error!?vxfw.Surface {
        const body_width = width -| (self.indent + 4);
        if (body_width == 0) return null;

        // Not italic: tmux renders it as reverse video without `sitm`.
        const style = theme.on_bg(theme.fg_dim).cell;
        const full = try markdown.draw(
            ctx,
            self.widget(),
            tail(thoughts, body_width, self.max_body_rows),
            style,
            body_width,
        );
        if (full.size.height == 0 or full.size.width == 0) return null;
        if (full.size.height <= self.max_body_rows) return full;

        const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
            .width = full.size.width,
            .height = self.max_body_rows,
        });
        w.fill(surface, theme.base.cell);

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = -@as(i17, @intCast(full.size.height - self.max_body_rows)), .col = 0 },
            .surface = full,
        };

        return .{
            .size = surface.size,
            .widget = surface.widget,
            .buffer = surface.buffer,
            .children = children,
        };
    }

    /// The tail of `text` that is enough to fill the last `rows` display rows
    /// once it wraps at `width`, cut on a UTF-8 boundary.
    fn tail(text: []const u8, width: u16, rows: u16) []const u8 {
        if (text.len == 0 or width == 0) return text;

        const budget = rows *| 4;
        var counted: u16 = 1;
        var col: u16 = 0;
        var i: usize = text.len;

        while (i > 0) {
            i -= 1;
            if (text[i] == '\n') {
                counted +|= 1;
                col = 0;
            } else {
                col += 1;
                if (col >= width) {
                    counted +|= 1;
                    col = 0;
                }
            }
            if (counted > budget) {
                while (i < text.len and text[i] & 0xc0 == 0x80) i += 1;
                return text[i..];
            }
        }
        return text;
    }
};

test "a long trace is cut to its tail before it is drawn" {
    const short = "0123456789" ** 4;
    try std.testing.expectEqualStrings(short, View.tail(short, 10, 1));

    const long = "0123456789" ** 40;
    const cut = View.tail(long, 10, 1);
    try std.testing.expect(cut.len < long.len);
    try std.testing.expectEqualStrings(long[long.len - cut.len ..], cut);

    const lines = "a\n" ** 40;
    try std.testing.expect(View.tail(lines, 80, 1).len < lines.len);

    const wide = "é" ** 200;
    const wide_cut = View.tail(wide, 8, 1);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide_cut));
}

test "reasoning longer than a surface can address still draws" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const trace = "the model thinks at length. " ** 8000;

    var view: View = .{ .text = trace, .expanded = true, .elapsed_ms = 12 };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 100, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try view.draw(ctx);
    try std.testing.expectEqual(@as(u16, 1 + view.max_body_rows), surface.size.height);
    try std.testing.expectEqual(surface.size.width * surface.size.height, surface.buffer.len);

    const body = surface.children[0].surface;
    try std.testing.expectEqual(@as(u16, view.max_body_rows), body.size.height);
    try std.testing.expectEqual(
        @as(usize, body.size.width) * body.size.height,
        body.buffer.len,
    );
}

/// Flatten a drawn surface tree into its text, for tests. Children are walked
/// the way the renderer walks them, so what this returns is what would be on
/// screen; anything hanging off the top edge is dropped, as the terminal drops
/// it.
fn flatten(out: *std.ArrayList(u8), allocator: std.mem.Allocator, surface: vxfw.Surface, row_off: i32) !void {
    for (surface.buffer, 0..) |cell, i| {
        const row = row_off + @as(i32, @intCast(i / surface.size.width));
        if (row < 0) continue;
        try out.appendSlice(allocator, cell.char.grapheme);
    }
    for (surface.children) |child| {
        try flatten(out, allocator, child.surface, row_off + child.origin.row);
    }
}

test "reasoning is rendered as markdown, not as its source" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var view: View = .{
        .text = "Checking **two** things, starting with `main.zig`.",
        .expanded = true,
        .elapsed_ms = 40,
    };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 60, .height = 20 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try view.draw(ctx);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try flatten(&text, std.testing.allocator, surface, 0);

    try std.testing.expect(std.mem.indexOf(u8, text.items, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "**") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "`") == null);
}

test "a long trace shows its newest rows, not its first" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..40) |i| try source.print(std.testing.allocator, "line-{d}\n", .{i});

    var view: View = .{ .text = source.items, .expanded = true, .elapsed_ms = 40 };
    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 60, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try view.draw(ctx);
    try std.testing.expectEqual(@as(u16, 1 + view.max_body_rows), surface.size.height);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try flatten(&text, std.testing.allocator, surface, 0);

    try std.testing.expect(std.mem.indexOf(u8, text.items, "line-39") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "line-0\n") == null);
}
