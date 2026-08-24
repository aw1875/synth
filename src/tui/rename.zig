//! The rename dialog: a centred box holding one text field.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Input = @import("input.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Rename = @This();

/// Box size, clamped to the terminal when it is smaller. Wide enough that a
/// title at `max_title_bytes` fits on the field's two rows without the text
/// scrolling out from under the cursor.
const box_width: u16 = 72;
const box_height: u16 = 9;
/// Rows the field gets.
const field_rows: u16 = 2;
/// Left and right padding inside the box.
const pad: u16 = 2;
/// Ceiling on a title. The sidebar it has to fit in is 48 columns wide, so
/// anything much longer than this is only ever seen truncated.
pub const max_title_bytes: usize = 60;

open: bool = false,
field: Input,

pub fn init(allocator: std.mem.Allocator) Rename {
    return .{ .field = .init(allocator) };
}

pub fn deinit(self: *Rename) void {
    self.field.deinit();
}

/// Open the dialog, seeded with the current title.
pub fn show(self: *Rename, current: []const u8) !void {
    self.field.clear();
    try self.field.insertText(current[0..@min(current.len, max_title_bytes)]);
    self.open = true;
}

pub fn close(self: *Rename) void {
    self.open = false;
    self.field.clear();
}

/// The typed title, trimmed. Empty means "clear the title".
pub fn value(self: *const Rename) []const u8 {
    return std.mem.trim(u8, self.field.text.items, " \t\r\n");
}

/// Handle a key while the dialog is up. Returns what the caller should do with
/// it, since only the caller knows how to save a title.
pub const Action = enum { none, cancel, submit };

pub fn handleKey(self: *Rename, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{})) return .submit;

    if (self.field.text.items.len >= max_title_bytes and key.text != null) return .none;
    try self.field.handleEvent(ctx, .{ .key_press = key });
    return .none;
}

/// Draw the dialog centred in `size`, returning the surface and where the
/// cursor landed inside it.
pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
    cursor: ?vxfw.CursorState = null,
};

pub fn draw(self: *Rename, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (!self.open) return null;
    if (size.width < 20 or size.height < box_height) return null;

    const width = @min(box_width, size.width - 4);
    const inner = width -| (pad * 2);
    const origin_row = (size.height -| box_height) / 2;
    const origin_col = (size.width -| width) / 2;

    var surface = try w.surfaceClamped(ctx.arena, parent, .{
        .width = width,
        .height = box_height,
    });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "Rename Session", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    var cursor: ?vxfw.CursorState = null;
    if (inner > 0) {
        self.field.style = theme.card.cell;
        self.field.height = field_rows;
        const field = try self.field.draw(ctx.withConstraints(
            .{ .width = inner, .height = field_rows },
            .{ .width = inner, .height = field_rows },
        ));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = 3, .col = pad }, .surface = field };
        surface.children = children;

        if (self.field.text.items.len == 0) {
            _ = w.writeText(surface, pad, 3, "Untitled session", theme.on_card(theme.fg_dim).cell);
        }
        if (field.cursor) |position| {
            cursor = .{
                .row = origin_row + 3 + position.row,
                .col = origin_col + pad + position.col,
                .shape = .block,
            };
        }
    }

    const hint = w.writeText(surface, pad, box_height - 2, "enter", theme.on_card(theme.fg).bold().cell);
    _ = w.writeText(surface, hint, box_height - 2, " submit", theme.on_card(theme.fg_dim).cell);

    return .{
        .surface = surface,
        .origin = .{ .row = origin_row, .col = origin_col },
        .cursor = cursor,
    };
}

test "the dialog opens seeded and reports what was typed" {
    var rename: Rename = .init(std.testing.allocator);
    defer rename.deinit();

    try std.testing.expect(!rename.open);
    try rename.show("old name");
    try std.testing.expect(rename.open);
    try std.testing.expectEqualStrings("old name", rename.value());

    rename.field.clear();
    try rename.field.insertText("  spaced  ");
    try std.testing.expectEqualStrings("spaced", rename.value());

    rename.close();
    try std.testing.expect(!rename.open);
    try std.testing.expectEqualStrings("", rename.value());
}
