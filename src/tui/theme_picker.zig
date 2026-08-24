//! The theme switcher: a searchable list that repaints as the cursor moves.
//!
//! Preview is the point. A palette is hard to judge from a name, and the app is
//! already redrawn on every keystroke, so moving the cursor applies the theme
//! and escaping puts back the one that was in use.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fuzzy = @import("../core/fuzzy.zig");
const Input = @import("input.zig");
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const w = @import("widgets.zig");

const Picker = @This();

/// Rows visible at once, before the list scrolls.
const max_rows: usize = 12;
/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 52;
/// Left and right padding inside the box.
const pad: u16 = 2;

open: bool = false,
/// Indices into `themes.all` matching the search, in display order.
matches: std.ArrayList(usize) = .empty,
cursor: usize = 0,
scroll: usize = 0,
search: Input,
allocator: std.mem.Allocator,
/// The theme in use when the picker opened, restored on escape.
previous: []const u8 = themes.default_id,

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{ .allocator = allocator, .search = .init(allocator) };
}

pub fn deinit(self: *Picker) void {
    self.matches.deinit(self.allocator);
    self.search.deinit();
}

/// Show the list, starting on the theme in use.
pub fn show(self: *Picker, current: []const u8) !void {
    self.previous = themes.findOrDefault(current).id;
    self.search.clear();
    self.cursor = 0;
    self.scroll = 0;
    try self.filter();
    self.open = true;
}

pub fn close(self: *Picker) void {
    self.open = false;
    self.search.clear();
    self.matches.clearRetainingCapacity();
}

/// The highlighted theme, or null when nothing matches the search.
pub fn selected(self: *const Picker) ?themes.Theme {
    if (self.cursor >= self.matches.items.len) return null;
    return themes.all[self.matches.items[self.cursor]];
}

pub const Action = enum { none, cancel, choose };

pub fn handleKey(self: *Picker, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
    if (key.matches(vaxis.Key.escape, .{})) {
        _ = themes.apply(self.previous);
        return .cancel;
    }
    if (key.matches(vaxis.Key.enter, .{})) return .choose;

    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        self.move(-1);
        return .none;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        self.move(1);
        return .none;
    }

    try self.search.handleEvent(ctx, .{ .key_press = key });
    try self.filter();
    return .none;
}

/// Rank the themes against the search, then preview whatever the cursor lands
/// on.
fn filter(self: *Picker) !void {
    const query = std.mem.trim(u8, self.search.text.items, " \t");
    self.matches.clearRetainingCapacity();

    if (query.len == 0) {
        for (themes.all, 0..) |_, i| try self.matches.append(self.allocator, i);
    } else {
        var top: fuzzy.Top(max_rows) = .{};
        for (themes.all, 0..) |entry, i| top.consider(i, entry.label, query, .{});
        for (top.ranked()) |ranked| try self.matches.append(self.allocator, ranked.index);
    }

    self.cursor = 0;
    self.scroll = 0;
    self.preview();
}

/// Paint the app in the highlighted theme. Nothing matching leaves the last
/// preview standing rather than flashing back to the old one.
fn preview(self: *const Picker) void {
    const entry = self.selected() orelse return;
    _ = themes.apply(entry.id);
}

fn move(self: *Picker, delta: i32) void {
    if (self.matches.items.len == 0) return;

    var at: i32 = @intCast(self.cursor);
    at += delta;
    if (at < 0 or at >= @as(i32, @intCast(self.matches.items.len))) return;

    self.cursor = @intCast(at);
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + max_rows) self.scroll = self.cursor - max_rows + 1;
    self.preview();
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
    cursor: ?vxfw.CursorState = null,
};

pub fn draw(self: *Picker, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (!self.open) return null;

    const chrome: u16 = 8;
    const visible: u16 = @intCast(@min(self.matches.items.len, max_rows));
    const height: u16 = chrome + @max(visible, 1);
    if (size.width < 32 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    var surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "Theme", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    var cursor: ?vxfw.CursorState = null;
    const field_row: u16 = 2;
    const inner = width -| (pad * 2);
    if (inner > 0) {
        self.search.style = theme.card.cell;
        self.search.placeholder = "Search";
        self.search.placeholder_style = theme.on_card(theme.fg_dim).cell;
        self.search.height = 1;

        const field = try self.search.draw(ctx.withConstraints(
            .{ .width = inner, .height = 1 },
            .{ .width = inner, .height = 1 },
        ));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = field_row, .col = pad }, .surface = field };
        surface.children = children;

        if (field.cursor) |position| {
            cursor = .{
                .row = origin_row + field_row + position.row,
                .col = origin_col + pad + position.col,
                .shape = .block,
            };
        }
    }

    const first_row: u16 = field_row + 2;
    if (self.matches.items.len == 0) {
        _ = w.writeText(surface, pad, first_row, "no themes", theme.on_card(theme.fg_dim).cell);
    }

    for (self.matches.items[self.scroll..][0..visible], 0..) |index, i| {
        const entry = themes.all[index];
        const y: u16 = @intCast(first_row + i);
        const chosen = self.scroll + i == self.cursor;
        const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;

        if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

        const in_use = std.mem.eql(u8, entry.id, self.previous);
        if (in_use) _ = w.writeText(surface, pad, y, "●", base.withFg(theme.success).cell);

        const x = w.writeText(surface, pad + 2, y, entry.label, base.withFg(theme.fg).cell);
        swatch(surface, x + 1, y, entry, base);
    }

    const hint_row = height - 2;
    var hint = w.writeText(surface, pad, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " preview   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, hint, hint_row, " keep", theme.on_card(theme.fg_dim).cell);

    return .{
        .surface = surface,
        .origin = .{ .row = origin_row, .col = origin_col },
        .cursor = cursor,
    };
}

/// Four blocks of a theme's own colors, so a row says something before it is
/// previewed. Drawn in the theme's colors, not the palette in use.
fn swatch(surface: vxfw.Surface, col: u16, row: u16, entry: themes.Theme, base: theme.Style) void {
    const colors = [_]u24{
        entry.palette.accent,
        entry.palette.accent_alt,
        entry.palette.success,
        entry.palette.danger,
    };
    var x = col;
    for (colors) |color| {
        x = w.writeText(surface, x, row, "█", base.withFg(theme.rgbOf(color)).cell);
    }
}

fn press(self: *Picker, key: vaxis.Key) !Action {
    var ctx: vxfw.EventContext = .{
        .phase = .at_target,
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(testing.allocator);
    return self.handleKey(&ctx, key);
}

test "moving the cursor previews, and escape puts the old one back" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    defer _ = themes.apply(themes.default_id);

    _ = themes.apply(themes.default_id);
    try picker.show(themes.default_id);

    try testing.expectEqualStrings(themes.default_id, picker.selected().?.id);
    try testing.expectEqual(theme.rgbOf(themes.findOrDefault(themes.default_id).palette.bg), theme.bg);

    _ = try picker.press(.{ .codepoint = vaxis.Key.down });
    const previewed = picker.selected().?;
    try testing.expect(!std.mem.eql(u8, previewed.id, themes.default_id));
    try testing.expectEqual(theme.rgbOf(previewed.palette.bg), theme.bg);

    try testing.expectEqual(Action.cancel, try picker.press(.{ .codepoint = vaxis.Key.escape }));
    try testing.expectEqual(theme.rgbOf(themes.findOrDefault(themes.default_id).palette.bg), theme.bg);
}

test "typing filters on the theme's name" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    defer _ = themes.apply(themes.default_id);

    try picker.show(themes.default_id);
    try testing.expectEqual(themes.all.len, picker.matches.items.len);

    try picker.search.insertText("gruv");
    try picker.filter();
    try testing.expectEqualStrings("gruvbox", picker.selected().?.id);

    picker.search.clear();
    try picker.search.insertText("nope");
    try picker.filter();
    try testing.expect(picker.selected() == null);
}

test "enter is the caller's to act on" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    defer _ = themes.apply(themes.default_id);

    try picker.show(themes.default_id);
    _ = try picker.press(.{ .codepoint = vaxis.Key.down });
    const wanted = picker.selected().?;

    try testing.expectEqual(Action.choose, try picker.press(.{ .codepoint = vaxis.Key.enter }));
    try testing.expectEqual(theme.rgbOf(wanted.palette.bg), theme.bg);
}
