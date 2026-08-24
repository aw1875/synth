//! Small drawing helpers layered on top of vxfw. Everything here paints an
//! opaque background so surfaces stack without letting the terminal show
//! through the gaps.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const humanize = @import("../core/humanize.zig");

/// Fill every cell of `surface` with `style`.
pub fn fill(surface: vxfw.Surface, style: Cell.Style) void {
    @memset(surface.buffer, .{ .style = style });
}

pub const PanelOptions = struct {
    /// Background/foreground of the panel itself.
    style: Cell.Style,
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,
    /// When set, draws a one-column vertical bar down the left edge.
    accent: ?Cell.Color = null,
    /// Defaults to the full available width.
    width: ?u16 = null,
    min_height: u16 = 0,
};

/// Width available to a panel's contents, given the same options.
pub fn panelInnerWidth(ctx: vxfw.DrawContext, opts: PanelOptions) u16 {
    const outer_width = opts.width orelse (ctx.max.width orelse 0);
    const bar: u16 = if (opts.accent != null) 1 else 0;
    return outer_width -| (bar + opts.left + opts.right);
}

/// Draw `child` inside an opaque, padded box. The panel's height grows to fit
/// the child; its width fills the available space unless overridden.
pub fn panel(ctx: vxfw.DrawContext, child: vxfw.Widget, opts: PanelOptions) !vxfw.Surface {
    const inner_width = panelInnerWidth(ctx, opts);

    const child_surface: vxfw.Surface = if (inner_width == 0)
        .empty(child)
    else
        try child.draw(ctx.withConstraints(
            .{ .width = inner_width, .height = 0 },
            .{
                .width = inner_width,
                .height = if (ctx.max.height) |h| h -| (opts.top + opts.bottom) else null,
            },
        ));

    return wrap(ctx, child_surface, opts);
}

/// Wrap an already-drawn surface in the same padded box. Used when the content
/// is assembled from several surfaces rather than a single widget.
pub fn wrap(ctx: vxfw.DrawContext, child_surface: vxfw.Surface, opts: PanelOptions) !vxfw.Surface {
    const outer_width = opts.width orelse (ctx.max.width orelse 0);
    const bar: u16 = if (opts.accent != null) 1 else 0;

    const wanted = @max(opts.min_height, child_surface.size.height +| opts.top +| opts.bottom);
    var surface = try surfaceClamped(ctx.arena, child_surface.widget, .{
        .width = outer_width,
        .height = wanted,
    });
    const height = surface.size.height;
    fill(surface, opts.style);

    if (opts.accent) |color| {
        for (0..height) |row| {
            surface.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "▌", .width = 1 },
                .style = .{ .fg = color, .bg = opts.style.bg },
            });
        }
    }

    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = .{
        .origin = .{ .row = opts.top, .col = bar + opts.left },
        .surface = child_surface,
    };
    surface.children = children;

    return surface;
}

/// Paint `width` cells of `row`, starting at `col`, clipped to the surface.
pub fn fillRow(surface: vxfw.Surface, row: u16, col: u16, width: u16, style: Cell.Style) void {
    if (row >= surface.size.height) return;
    const end = @min(col + width, surface.size.width);
    var x = col;
    while (x < end) : (x += 1) {
        surface.writeCell(x, row, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    }
}

/// Write `text` at (col, row), clipped to the surface. Returns the column just
/// past the last cell written.
pub fn writeText(surface: vxfw.Surface, col: u16, row: u16, text: []const u8, style: Cell.Style) u16 {
    var x = col;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const w: u16 = vaxis.gwidth.gwidth(bytes, .unicode);
        if (x + w > surface.size.width) break;
        surface.writeCell(x, row, .{
            .char = .{ .grapheme = bytes, .width = @intCast(w) },
            .style = style,
        });
        x += w;
    }
    return x;
}

/// Write `text` so that it ends at the surface's right edge, inset by `margin`.
pub fn writeTextRight(surface: vxfw.Surface, row: u16, margin: u16, text: []const u8, style: Cell.Style) void {
    const w = textWidth(text);
    const right = surface.size.width -| margin;
    if (w > right) return;
    _ = writeText(surface, right - w, row, text, style);
}

pub fn textWidth(text: []const u8) u16 {
    var w: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| w += vaxis.gwidth.gwidth(g.bytes(text), .unicode);
    return w;
}

/// The tallest surface that can be addressed at `width`. Cells are indexed
/// `row * width` in u16, and vaxis does not widen: past this it writes off the
/// end of the buffer.
pub fn maxRows(width: u16) u16 {
    if (width <= 1) return std.math.maxInt(u16);
    return @intCast(@as(u32, std.math.maxInt(u16)) / width);
}

/// `vxfw.Surface.init` with the height clamped to `maxRows`.
pub fn surfaceClamped(
    arena: std.mem.Allocator,
    widget: vxfw.Widget,
    size: vxfw.Size,
) std.mem.Allocator.Error!vxfw.Surface {
    return vxfw.Surface.init(arena, widget, .{
        .width = size.width,
        .height = @min(size.height, maxRows(size.width)),
    });
}

test "a surface height is clamped to what its width can address" {
    try std.testing.expectEqual(@as(u16, 819), maxRows(80));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), maxRows(1));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), maxRows(0));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const widget: vxfw.Widget = .{
        .userdata = @ptrFromInt(@alignOf(usize)),
        .drawFn = undefined,
    };
    const surface = try surfaceClamped(arena.allocator(), widget, .{ .width = 80, .height = 5000 });
    try std.testing.expectEqual(@as(u16, 819), surface.size.height);
    try std.testing.expectEqual(
        @as(usize, 80 * 819),
        surface.buffer.len,
    );
}

/// `humanize.duration`, copied into the frame arena.
pub fn duration(arena: std.mem.Allocator, ms: u64) ![]const u8 {
    var buffer: [humanize.duration_bytes]u8 = undefined;
    return arena.dupe(u8, humanize.duration(&buffer, ms));
}
