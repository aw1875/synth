//! The reasoning effort switcher: the current model's levels, the one in use
//! on top.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Picker = @This();

const box_width: u16 = 44;
const pad: u16 = 2;

allocator: std.mem.Allocator,
open: bool = false,
/// The levels in display order: the current one first, the rest mildest
/// first. Owned.
levels: [][]const u8 = &.{},
cursor: usize = 0,
/// Whether the first level is the one in use, and so marked.
current_on_top: bool = false,
/// Owned.
model: []const u8 = "",

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Picker) void {
    self.release();
}

fn release(self: *Picker) void {
    for (self.levels) |level| self.allocator.free(level);
    self.allocator.free(self.levels);
    self.levels = &.{};
    self.allocator.free(self.model);
    self.model = "";
}

/// Show `offered` with `current` on top. Both are borrowed for the call.
pub fn show(self: *Picker, model: []const u8, offered: []const []const u8, current: []const u8) !void {
    self.release();
    self.model = try self.allocator.dupe(u8, model);

    const ordered = try self.allocator.alloc([]const u8, offered.len);
    var filled: usize = 0;
    errdefer {
        for (ordered[0..filled]) |level| self.allocator.free(level);
        self.allocator.free(ordered);
    }
    self.current_on_top = contains(offered, current);
    if (self.current_on_top) {
        ordered[filled] = try self.allocator.dupe(u8, current);
        filled += 1;
    }
    for (offered) |level| {
        if (std.mem.eql(u8, level, current)) continue;
        ordered[filled] = try self.allocator.dupe(u8, level);
        filled += 1;
    }
    self.levels = ordered[0..filled];
    self.cursor = 0;
    self.open = true;
}

fn contains(levels: []const []const u8, level: []const u8) bool {
    for (levels) |candidate| {
        if (std.mem.eql(u8, candidate, level)) return true;
    }
    return false;
}

pub fn close(self: *Picker) void {
    self.open = false;
    self.release();
}

pub fn selected(self: *const Picker) ?[]const u8 {
    if (self.cursor >= self.levels.len) return null;
    return self.levels[self.cursor];
}

pub const Action = enum { none, cancel, choose };

pub fn handleKey(self: *Picker, key: vaxis.Key) Action {
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{})) return .choose;
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) self.move(-1);
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) self.move(1);
    return .none;
}

fn move(self: *Picker, delta: i32) void {
    if (self.levels.len == 0) return;
    const current: i32 = @intCast(self.cursor);
    const last: i32 = @intCast(self.levels.len - 1);
    const stepped = std.math.clamp(current + delta, 0, last);
    self.cursor = @intCast(stepped);
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
};

pub fn draw(self: *Picker, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (!self.open) return null;

    const frame_rows: u16 = 6;
    const visible: u16 = @intCast(self.levels.len);
    const height: u16 = frame_rows + @max(visible, 1);
    if (size.width < 32 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    const surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    const title_end = w.writeText(surface, pad, 1, "Effort", theme.on_card(theme.fg).bold().cell);
    _ = w.writeText(surface, title_end + 1, 1, self.model, theme.on_card(theme.fg_dim).cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    const first_row: u16 = 3;
    for (self.levels, 0..) |level, i| {
        const y: u16 = @intCast(first_row + i);
        const chosen = i == self.cursor;
        const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;
        if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

        const in_use = i == 0 and self.current_on_top;
        if (in_use) _ = w.writeText(surface, pad, y, "●", base.withFg(theme.success).cell);
        _ = w.writeText(surface, pad + 2, y, level, base.withFg(theme.fg).cell);
    }

    const hint_row = height - 2;
    var hint = w.writeText(surface, pad, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " select   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, hint, hint_row, " set", theme.on_card(theme.fg_dim).cell);

    return .{ .surface = surface, .origin = .{ .row = origin_row, .col = origin_col } };
}

test "the level in use comes first, then the rest mildest first" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();

    try picker.show("gpt-test", &.{ "low", "medium", "high", "ultra" }, "high");
    try testing.expectEqual(@as(usize, 4), picker.levels.len);
    try testing.expectEqualStrings("high", picker.levels[0]);
    try testing.expectEqualStrings("low", picker.levels[1]);
    try testing.expectEqualStrings("medium", picker.levels[2]);
    try testing.expectEqualStrings("ultra", picker.levels[3]);
    try testing.expectEqualStrings("high", picker.selected().?);
}

test "arrows move the choice and stop at the ends" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();

    try picker.show("gpt-test", &.{ "low", "medium" }, "medium");
    try testing.expectEqual(Action.none, picker.handleKey(.{ .codepoint = vaxis.Key.up }));
    try testing.expectEqualStrings("medium", picker.selected().?);
    _ = picker.handleKey(.{ .codepoint = vaxis.Key.down });
    _ = picker.handleKey(.{ .codepoint = vaxis.Key.down });
    try testing.expectEqualStrings("low", picker.selected().?);
    try testing.expectEqual(Action.choose, picker.handleKey(.{ .codepoint = vaxis.Key.enter }));
    try testing.expectEqual(Action.cancel, picker.handleKey(.{ .codepoint = vaxis.Key.escape }));
}

test "a current level the model does not list is simply not shown" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();

    try picker.show("gpt-test", &.{ "low", "medium" }, "");
    try testing.expectEqual(@as(usize, 2), picker.levels.len);
    try testing.expectEqualStrings("low", picker.selected().?);
}
