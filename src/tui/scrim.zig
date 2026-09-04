//! The dim behind a dialog.
//!
//! A cell has no alpha, so the translucent layer a dialog sits on cannot be
//! composited: there is nothing underneath to show through. The frame is
//! flattened into one surface instead and every cell repainted part of the way
//! toward the background, which arrives at the picture a translucent layer
//! would have produced.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const theme = @import("theme.zig");
const themes = @import("themes.zig");
const w = @import("widgets.zig");

/// How far a dimmed cell travels toward the background, out of 255. Far enough
/// that the dialog is plainly the thing being read, near enough that the
/// transcript behind it is still a transcript rather than a blank screen.
pub const strength: u8 = 150;

/// The frame as one dimmed layer, or null when there is nothing to cover.
///
/// `root` is the frame as it stands, dialog included. Dimming the dialog too
/// costs nothing: it is redrawn over this at a higher z-index, onto the same
/// cells it already occupies.
pub fn draw(
    arena: std.mem.Allocator,
    widget: vxfw.Widget,
    root: vxfw.Surface,
    size: vxfw.Size,
) std.mem.Allocator.Error!?vxfw.Surface {
    if (size.width == 0 or size.height == 0) return null;

    const surface = try w.surfaceClamped(arena, widget, size);
    w.fill(surface, dimStyle(theme.base.cell));
    blit(surface, root, 0, 0);
    return surface;
}

/// Flatten the tree the way the renderer will, so the cell that wins here is
/// the cell that would have been on screen. Children are visited in z order,
/// and `std.mem.sort` is stable, so siblings that share one keep the order they
/// were appended in.
fn blit(out: vxfw.Surface, surface: vxfw.Surface, row_off: i32, col_off: i32) void {
    if (surface.buffer.len > 0) {
        for (surface.buffer, 0..) |cell, i| {
            const row = row_off + @as(i32, @intCast(i / surface.size.width));
            const col = col_off + @as(i32, @intCast(i % surface.size.width));
            put(out, row, col, cell);
        }
    }

    std.mem.sort(vxfw.SubSurface, surface.children, {}, vxfw.SubSurface.lessThan);
    for (surface.children) |child| {
        blit(out, child.surface, row_off + child.origin.row, col_off + child.origin.col);
    }
}

fn put(out: vxfw.Surface, row: i32, col: i32, cell: Cell) void {
    if (row < 0 or col < 0) return;
    if (row >= out.size.height or col >= out.size.width) return;
    out.writeCell(@intCast(col), @intCast(row), dim(cell));
}

/// One cell as it reads under the dim. The grapheme stays; a link does not,
/// because nothing behind a dialog can be clicked while the dialog is up.
fn dim(cell: Cell) Cell {
    var out = cell;
    out.link = .{};
    out.style = dimStyle(cell.style);
    return out;
}

fn dimStyle(style: Cell.Style) Cell.Style {
    var out = style;
    out.fg = theme.toward(style.fg, theme.bg, strength);
    out.bg = theme.toward(style.bg, theme.bg, strength);
    return out;
}

const testing = std.testing;

/// A surface of one style, for standing in as a piece of a frame.
fn patch(arena: std.mem.Allocator, size: vxfw.Size, style: Cell.Style) !vxfw.Surface {
    const surface = try vxfw.Surface.init(arena, undefined, size);
    w.fill(surface, style);
    return surface;
}

test "the frame comes back dimmed toward the background" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The palette is global, so a test that pins it has to hand it back.
    defer _ = themes.apply(themes.default_id);
    theme.apply(.{
        .bg = 0x000000,
        .surface = 0x000000,
        .surface_alt = 0x000000,
        .fg = 0xffffff,
        .fg_muted = 0xffffff,
        .fg_dim = 0xffffff,
        .accent = 0xffffff,
        .accent_alt = 0xffffff,
        .success = 0xffffff,
        .warning = 0xffffff,
        .danger = 0xffffff,
        .selection_bg = 0xffffff,
        .diff_added_bg = 0x000000,
        .diff_removed_bg = 0x000000,
        .diff_added_fg = 0xffffff,
        .diff_removed_fg = 0xffffff,
    });

    const size: vxfw.Size = .{ .width = 4, .height = 2 };
    const root = try patch(arena, size, .{ .fg = theme.rgbOf(0xffffff), .bg = theme.rgbOf(0xffffff) });

    const dimmed = (try draw(arena, undefined, root, size)).?;

    // White over black at 150/255 leaves the 105/255 that did not travel.
    const expected: [3]u8 = .{ 105, 105, 105 };
    for (dimmed.buffer) |cell| {
        try testing.expectEqual(expected, cell.style.fg.rgb);
        try testing.expectEqual(expected, cell.style.bg.rgb);
    }
}

test "a child covers its parent, and the higher z-index covers them both" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const size: vxfw.Size = .{ .width = 3, .height = 1 };
    var root = try patch(arena, size, .{ .fg = theme.rgbOf(0x111111) });

    const under = try patch(arena, .{ .width = 2, .height = 1 }, .{ .fg = theme.rgbOf(0x222222) });
    const over = try patch(arena, .{ .width = 1, .height = 1 }, .{ .fg = theme.rgbOf(0x333333) });

    // Appended out of z order, to prove the sort and not the order decides.
    const children = try arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = over, .z_index = 1 };
    children[1] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = under, .z_index = 0 };
    root.children = children;

    const dimmed = (try draw(arena, undefined, root, size)).?;

    // Column 0 is the z-index 1 patch, column 1 the one under it, column 2 the root.
    try testing.expectEqual(theme.toward(theme.rgbOf(0x333333), theme.bg, strength), dimmed.buffer[0].style.fg);
    try testing.expectEqual(theme.toward(theme.rgbOf(0x222222), theme.bg, strength), dimmed.buffer[1].style.fg);
    try testing.expectEqual(theme.toward(theme.rgbOf(0x111111), theme.bg, strength), dimmed.buffer[2].style.fg);
}

test "a child hanging off the edge is clipped rather than wrapped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const size: vxfw.Size = .{ .width = 2, .height = 2 };
    var root = try patch(arena, size, .{ .fg = theme.rgbOf(0x111111) });

    const wide = try patch(arena, .{ .width = 4, .height = 1 }, .{ .fg = theme.rgbOf(0x222222) });
    const children = try arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{ .origin = .{ .row = 1, .col = 1 }, .surface = wide };
    root.children = children;

    const dimmed = (try draw(arena, undefined, root, size)).?;

    const covered = theme.toward(theme.rgbOf(0x222222), theme.bg, strength);
    const bare = theme.toward(theme.rgbOf(0x111111), theme.bg, strength);
    try testing.expectEqual(bare, dimmed.buffer[0].style.fg);
    try testing.expectEqual(bare, dimmed.buffer[1].style.fg);
    try testing.expectEqual(bare, dimmed.buffer[2].style.fg);
    try testing.expectEqual(covered, dimmed.buffer[3].style.fg);
}

test "a link behind the dim is dropped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const size: vxfw.Size = .{ .width = 1, .height = 1 };
    const root = try vxfw.Surface.init(arena, undefined, size);
    root.writeCell(0, 0, .{
        .char = .{ .grapheme = "x", .width = 1 },
        .link = .{ .uri = "https://example.com" },
    });

    const dimmed = (try draw(arena, undefined, root, size)).?;
    try testing.expectEqualStrings("x", dimmed.buffer[0].char.grapheme);
    try testing.expectEqualStrings("", dimmed.buffer[0].link.uri);
}

test "an empty frame draws nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try vxfw.Surface.init(arena, undefined, .{ .width = 0, .height = 0 });
    try testing.expect(try draw(arena, undefined, root, .{ .width = 0, .height = 0 }) == null);
    try testing.expect(try draw(arena, undefined, root, .{ .width = 4, .height = 0 }) == null);
}
