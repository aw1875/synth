//! A file an `@path` mention pulled into a message, shown under it.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const w = @import("widgets.zig");

const AttachmentCard = @This();

/// Body rows shown when expanded, before the rest is summarised away.
const max_body_rows: usize = 60;
/// Column the text starts at, leaving room for the accent bar.
const indent: u16 = 3;

/// Borrowed from the conversation and refreshed every frame.
label: []const u8 = "",
/// What kind of thing the label names, drawn after it. Empty for a mentioned
/// file, whose path already says what it is.
kind: []const u8 = "",
body: []const u8 = "",

expanded: bool = false,
has_mouse: bool = false,

pub fn widget(self: *AttachmentCard) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *AttachmentCard = @ptrCast(@alignCast(ptr));
    switch (event) {
        .mouse => |mouse| {
            switch (mouse.button) {
                .wheel_up, .wheel_down, .wheel_left, .wheel_right => return,
                .left => {},
                else => return ctx.consumeEvent(),
            }
            if (mouse.type == .press) {
                self.expanded = !self.expanded;
                return ctx.consumeAndRedraw();
            }
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
    const self: *AttachmentCard = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *AttachmentCard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    if (width <= indent) return .empty(self.widget());

    const body = try self.bodyLines(ctx.arena, width);
    const height: u16 = @intCast(1 + body.len);

    const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.card.cell);
    for (0..height) |row| {
        surface.writeCell(0, @intCast(row), .{
            .char = .{ .grapheme = "▌", .width = 1 },
            .style = theme.on_card(theme.fg_dim).cell,
        });
    }

    const marker = if (self.expanded) "▾ " else "▸ ";
    var col = w.writeText(surface, indent, 0, marker, theme.on_card(theme.fg_dim).cell);
    col = w.writeText(surface, col, 0, self.label, theme.on_card(theme.accent_alt).cell);
    if (self.kind.len > 0) {
        col = w.writeText(surface, col + 1, 0, self.kind, theme.on_card(theme.fg_dim).cell);
    }
    col = w.writeText(surface, col, 0, try std.fmt.allocPrint(
        ctx.arena,
        "  {d} lines",
        .{std.mem.count(u8, std.mem.trimEnd(u8, self.body, "\n"), "\n") + 1},
    ), theme.on_card(theme.fg_dim).cell);
    if (self.has_mouse) {
        const hint = if (self.expanded) "  click to collapse" else "  click to expand";
        _ = w.writeText(surface, col, 0, hint, theme.on_card(theme.fg_dim).cell);
    }

    for (body, 0..) |line, i| {
        _ = w.writeText(surface, indent, @intCast(1 + i), line, theme.on_card(theme.fg_muted).cell);
    }

    return surface;
}

/// Nothing collapsed; the body, capped, when open.
fn bodyLines(self: *AttachmentCard, arena: std.mem.Allocator, width: u16) ![]const []const u8 {
    if (!self.expanded) return &.{};

    const trimmed = std.mem.trimEnd(u8, self.body, "\n");
    if (trimmed.len == 0) return &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    const available = width -| (indent + 1);

    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (lines.items.len >= max_body_rows) {
            const rest = std.mem.count(u8, trimmed, "\n") + 1 - lines.items.len;
            try lines.append(arena, try std.fmt.allocPrint(arena, "... {d} more lines", .{rest}));
            break;
        }
        const text = std.mem.trimEnd(u8, line, "\r");
        try lines.append(arena, if (text.len <= available) text else text[0..available]);
    }
    return lines.toOwnedSlice(arena);
}

test "the body only appears once the card is open" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var card: AttachmentCard = .{ .label = "src/main.zig", .body = "a\nb\nc\n" };
    try std.testing.expectEqual(@as(usize, 0), (try card.bodyLines(arena, 40)).len);

    card.expanded = true;
    const lines = try card.bodyLines(arena, 40);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("c", lines[2]);
}

test "a long body is capped and says how much is left" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: []const u8 = "";
    for (0..max_body_rows + 5) |i| body = try std.fmt.allocPrint(arena, "{s}line {d}\n", .{ body, i });

    var card: AttachmentCard = .{ .label = "src/main.zig", .body = body, .expanded = true };
    const lines = try card.bodyLines(arena, 40);
    try std.testing.expectEqual(max_body_rows + 1, lines.len);
    try std.testing.expectEqualStrings("... 5 more lines", lines[max_body_rows]);
}
