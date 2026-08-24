//! The session switcher: a centred list of this project's past sessions.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Database = @import("../core/database.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Picker = @This();

/// Sessions fetched. More than this and the list stops being a list.
const fetch_limit: usize = 50;
/// Rows visible at once.
const max_rows: usize = 10;
/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 72;
/// Left and right padding inside the box.
const pad: u16 = 2;
/// Blank rows above the title and below the hint.
const pad_top: u16 = 1;
const pad_bottom: u16 = 1;

allocator: std.mem.Allocator,
open: bool = false,
/// Owned; refreshed every time the picker is opened.
sessions: []Database.SessionInfo = &.{},
selected: usize = 0,
/// First visible row, so a long list scrolls under the cursor.
scroll: usize = 0,
/// The session showing in the transcript right now, marked in the list.
current: ?i64 = null,

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Picker) void {
    self.release();
}

fn release(self: *Picker) void {
    for (self.sessions) |info| info.deinit(self.allocator);
    self.allocator.free(self.sessions);
    self.sessions = &.{};
}

/// Load the project's sessions and show the list. The cursor starts on the
/// session already open, which is the one you are most likely comparing against.
pub fn show(self: *Picker, db: *Database, project_id: i64, current: ?i64) !void {
    self.release();
    self.sessions = try db.listSessions(self.allocator, project_id, fetch_limit);
    self.current = current;
    self.selected = 0;
    self.scroll = 0;

    if (current) |id| {
        for (self.sessions, 0..) |info, i| {
            if (info.id == id) self.selected = i;
        }
    }
    self.clampScroll();
    self.open = true;
}

pub fn close(self: *Picker) void {
    self.open = false;
    self.release();
}

/// The session under the cursor, or null when the list is empty.
pub fn selectedId(self: *const Picker) ?i64 {
    if (self.selected >= self.sessions.len) return null;
    return self.sessions[self.selected].id;
}

pub const Action = enum { none, cancel, choose };

pub fn handleKey(self: *Picker, key: vaxis.Key) Action {
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{})) return .choose;

    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        self.move(-1);
        return .none;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        self.move(1);
        return .none;
    }
    return .none;
}

fn move(self: *Picker, delta: i32) void {
    if (self.sessions.len == 0) return;
    const current: i32 = @intCast(self.selected);
    const last: i32 = @intCast(self.sessions.len - 1);
    self.selected = @intCast(std.math.clamp(current + delta, 0, last));
    self.clampScroll();
}

fn clampScroll(self: *Picker) void {
    if (self.selected < self.scroll) self.scroll = self.selected;
    if (self.selected >= self.scroll + max_rows) self.scroll = self.selected - max_rows + 1;
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
};

pub fn draw(self: *Picker, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (!self.open) return null;

    const rows = @min(self.sessions.len, max_rows);
    const height: u16 = @intCast(pad_top + 3 + @max(rows, 1) + 1 + pad_bottom);
    if (size.width < 24 or size.height < height) return null;

    const width = @min(box_width, size.width - 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    const surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, pad_top, "Sessions", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, pad_top, pad, "esc", theme.on_card(theme.fg_dim).cell);

    if (self.sessions.len == 0) {
        _ = w.writeText(surface, pad, pad_top + 2, "nothing saved yet", theme.on_card(theme.fg_dim).cell);
    }

    for (self.sessions[self.scroll..][0..rows], 0..) |info, i| {
        const row: u16 = @intCast(pad_top + 2 + i);
        const chosen = self.scroll + i == self.selected;

        if (chosen) {
            w.fillRow(surface, row, 1, width - 2, theme.card.withBg(theme.surface_alt).cell);
            _ = w.writeText(surface, 1, row, "▌", theme.on_card(theme.accent).withBg(theme.surface_alt).cell);
        }

        const base = if (chosen)
            theme.card.withBg(theme.surface_alt)
        else
            theme.card;

        var x = w.writeText(surface, pad + 1, row, info.public_id, base.withFg(theme.accent_alt).cell);
        x = w.writeText(surface, x + 1, row, "  ", base.cell);

        const label = if (info.title.len > 0) info.title else "untitled";
        const label_style = if (info.title.len > 0) base.withFg(theme.fg) else base.withFg(theme.fg_dim);
        const room = width -| (x + pad + 14);
        x = w.writeText(surface, x, row, clip(label, room), label_style.cell);

        var count: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&count, "{d} msgs", .{info.messages}) catch "";
        const at = width -| (pad + @as(u16, @intCast(text.len)));
        _ = w.writeText(surface, at, row, try ctx.arena.dupe(u8, text), base.withFg(theme.fg_dim).cell);

        if (self.current) |id| {
            if (id == info.id) {
                _ = w.writeText(surface, width -| (pad + 1), row, "•", base.withFg(theme.success).cell);
            }
        }
    }

    const hint_row = height - 1 - pad_bottom;
    var hint = w.writeText(surface, pad, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " select   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, hint, hint_row, " open", theme.on_card(theme.fg_dim).cell);

    return .{ .surface = surface, .origin = .{ .row = origin_row, .col = origin_col } };
}

fn clip(text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    if (text.len <= width) return text;
    return text[0..width];
}

test "the cursor clamps and the window follows it" {
    var picker: Picker = .init(std.testing.allocator);
    defer picker.deinit();

    var rows: [15]Database.SessionInfo = undefined;
    for (&rows, 0..) |*info, i| {
        info.* = .{ .id = @intCast(i), .public_id = "", .title = "", .updated_at = 0, .messages = 0 };
    }
    picker.sessions = &rows;
    defer picker.sessions = &.{};

    picker.move(-1);
    try std.testing.expectEqual(@as(usize, 0), picker.selected);

    for (0..12) |_| picker.move(1);
    try std.testing.expectEqual(@as(usize, 12), picker.selected);
    try std.testing.expectEqual(@as(usize, 12 - max_rows + 1), picker.scroll);

    for (0..99) |_| picker.move(1);
    try std.testing.expectEqual(@as(usize, 14), picker.selected);
}

test "the box draws at every size, however many sessions" {
    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    var rows: [30]Database.SessionInfo = undefined;
    for (&rows, 0..) |*info, i| {
        info.* = .{
            .id = @intCast(i),
            .public_id = "ses_0000",
            .title = "a session",
            .updated_at = 0,
            .messages = 3,
        };
    }

    for ([_]usize{ 0, 1, 9, 10, 11, 30 }) |count| {
        var picker: Picker = .init(std.testing.allocator);
        picker.sessions = rows[0..count];
        picker.open = true;
        defer {
            picker.sessions = &.{};
            picker.deinit();
        }

        var height: u16 = 0;
        while (height <= 40) : (height += 3) {
            var width: u16 = 0;
            while (width <= 120) : (width += 9) {
                var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena_state.deinit();

                const ctx: vxfw.DrawContext = .{
                    .arena = arena_state.allocator(),
                    .min = .{},
                    .max = .{ .width = width, .height = height },
                    .cell_size = .{ .width = 10, .height = 20 },
                };
                const drawn = try picker.draw(ctx, widget, .{ .width = width, .height = height });
                if (drawn) |box| {
                    try std.testing.expect(box.surface.size.width <= width);
                    try std.testing.expect(box.surface.size.height <= height);
                }
            }
        }
    }
}
