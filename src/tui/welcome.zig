const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const pkg = @import("pkg");
const theme = @import("theme.zig");
const w = @import("widgets.zig");
const themes = @import("themes.zig");

const pixels = [_][]const u8{
    "##..........................##...##...",
    ".##.........................##...##...",
    "..##......####.##.##.####..#####.####.",
    "...#.....##....##.##.##.##..##...##.##",
    "..##......###..##.##.##.##..##...##.##",
    ".##.oooo....##..####.##.##..##...##.##",
    "##..oooo.####.....##.##.##...###.##.##",
    "................###...................",
    "......................................",
};

fn pixel(x: usize, y: usize) vaxis.Cell.Color {
    if (x < pixels[0].len and y < pixels.len) {
        switch (pixels[y][x]) {
            '#' => return theme.fg,
            'o' => return theme.accent,
            else => {},
        }
    }
    if (x > 0 and y > 0 and x <= pixels[0].len and y <= pixels.len) {
        switch (pixels[y - 1][x - 1]) {
            '#' => return theme.toward(theme.fg, theme.bg, 128),
            'o' => return theme.toward(theme.accent, theme.bg, 128),
            else => {},
        }
    }
    return theme.bg;
}

pub fn draw(ctx: vxfw.DrawContext, widget: vxfw.Widget, width: u16, height: u16) !?vxfw.Surface {
    if (width < 20 or height < 5) return null;
    const large = width >= pixels[0].len + 5 and height >= 11;
    const size: vxfw.Size = .{
        .width = if (large) pixels[0].len + 5 else @min(width, 32),
        .height = if (large) 11 else 5,
    };
    const surface = try w.surfaceClamped(ctx.arena, widget, size);
    w.fill(surface, theme.base.cell);
    const edge = theme.on_bg(theme.fg_muted).cell;
    _ = w.writeText(surface, 0, 0, "┌─", edge);
    _ = w.writeText(surface, size.width - 2, 0, "─┐", edge);
    _ = w.writeText(surface, 0, size.height - 1, "└─", edge);
    _ = w.writeText(surface, size.width - 2, size.height - 1, "─┘", edge);
    _ = w.writeText(surface, 3, 1, "Welcome to", theme.on_bg(theme.fg).cell);
    if (large) {
        for (0..(pixels.len + 2) / 2) |row| {
            for (0..pixels[0].len + 1) |col| {
                surface.writeCell(@intCast(col + 2), @intCast(row + 3), .{
                    .char = .{ .grapheme = "▀", .width = 1 },
                    .style = .{ .fg = pixel(col, row * 2), .bg = pixel(col, row * 2 + 1) },
                });
            }
        }
    } else {
        _ = w.writeText(surface, 3, 2, ">", theme.on_bg(theme.fg).cell);
        _ = w.writeText(surface, 4, 2, "_", theme.on_bg(theme.accent).cell);
        _ = w.writeText(surface, 6, 2, "synth", theme.on_bg(theme.fg).cell);
    }
    _ = w.writeText(surface, 3, size.height - 2, "CLI Version " ++ pkg.version, edge);
    return surface;
}

test "welcome follows every theme in its full and compact layouts" {
    defer _ = themes.apply(themes.default_id);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = undefined };
    const ctx: vxfw.DrawContext = .{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 100, .height = 30 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
    for (themes.all) |entry| {
        _ = themes.apply(entry.id);
        for ([_]vxfw.Size{ .{ .width = 43, .height = 11 }, .{ .width = 24, .height = 8 }, .{ .width = 100, .height = 5 } }) |available| {
            const surface = (try draw(ctx, widget, available.width, available.height)).?;
            try std.testing.expect(surface.size.width <= available.width);
            try std.testing.expect(surface.size.height <= available.height);
            try std.testing.expectEqualStrings("┌", surface.buffer[0].char.grapheme);
            try std.testing.expectEqual(theme.fg, surface.buffer[surface.size.width + 3].style.fg);
            if (surface.size.height == 11) {
                try std.testing.expectEqual(theme.fg, surface.buffer[3 * surface.size.width + 2].style.fg);
                try std.testing.expectEqual(theme.accent, surface.buffer[5 * surface.size.width + 6].style.bg);
            } else {
                try std.testing.expectEqual(theme.fg, surface.buffer[2 * surface.size.width + 3].style.fg);
                try std.testing.expectEqual(theme.accent, surface.buffer[2 * surface.size.width + 4].style.fg);
            }
            const version_start = @as(usize, surface.size.height - 2) * surface.size.width + 3;
            for ("CLI Version " ++ pkg.version, 0..) |byte, i| {
                try std.testing.expectEqual(byte, surface.buffer[version_start + i].char.grapheme[0]);
            }
        }
        try std.testing.expectEqual(theme.fg, pixel(0, 0));
        try std.testing.expectEqual(theme.fg, pixel(0, 6));
        try std.testing.expectEqual(theme.fg, pixel(3, 3));
        try std.testing.expectEqual(theme.toward(theme.fg, theme.bg, 128), pixel(4, 3));
        try std.testing.expectEqual(theme.accent, pixel(4, 5));
        try std.testing.expectEqual(theme.toward(theme.accent, theme.bg, 128), pixel(8, 7));
        try std.testing.expectEqual(theme.bg, pixel(0, 8));
    }
    try std.testing.expect(try draw(ctx, widget, 19, 30) == null);
    try std.testing.expect(try draw(ctx, widget, 100, 4) == null);
}
