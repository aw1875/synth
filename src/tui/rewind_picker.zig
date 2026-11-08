//! Undoing what turns did to files: pick the prompt to go back to, see which
//! files that puts back, and confirm.
//!
//! Only changes made through synth's own `write` and `edit` are kept, so the
//! confirmation names every file and flags the ones changed since by anything
//! else, whose later changes going back would throw away.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Loop = @import("../agent/loop.zig");
const synth = @import("../acp/synth.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Picker = @This();

/// Rows visible at once, before the list scrolls.
const max_rows: usize = 12;
/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 76;
/// Left and right padding inside the box.
const pad: u16 = 2;

const Stage = enum { closed, turns, files };

stage: Stage = .closed,
/// The list was asked for, and opens when it arrives.
requested: bool = false,
cursor: usize = 0,
scroll: usize = 0,
allocator: std.mem.Allocator,
/// Newest first, in `arena`.
turns: []const synth.Checkpoint = &.{},
/// What going back to `chosen` puts back, in `arena`.
files: []const Loop.Rewound = &.{},
chosen: u64 = 0,
arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{ .allocator = allocator, .arena = .init(allocator) };
}

pub fn deinit(self: *Picker) void {
    self.arena.deinit();
}

pub fn isOpen(self: *const Picker) bool {
    return self.stage != .closed;
}

/// Open on `turns`, newest first, which are copied.
pub fn show(self: *Picker, turns: []const synth.Checkpoint) !void {
    self.requested = false;
    _ = self.arena.reset(.retain_capacity);
    const arena = self.arena.allocator();
    const copies = try arena.alloc(synth.Checkpoint, turns.len);
    for (turns, copies) |turn, *copy| copy.* = .{
        .seq = turn.seq,
        .prompt = try arena.dupe(u8, turn.prompt),
        .files = turn.files,
    };
    self.turns = copies;
    self.files = &.{};
    self.cursor = 0;
    self.scroll = 0;
    self.stage = .turns;
}

/// What going back to `seq` would put back, to confirm. Ignored unless it is
/// the turn asked about.
pub fn preview(self: *Picker, seq: u64, files: []const Loop.Rewound) !void {
    if (self.stage != .turns or seq != self.chosen) return;
    const arena = self.arena.allocator();
    const copies = try arena.alloc(Loop.Rewound, files.len);
    for (files, copies) |file, *copy| copy.* = .{
        .path = try arena.dupe(u8, file.path),
        .removed = file.removed,
        .changed = file.changed,
    };
    self.files = copies;
    self.stage = .files;
}

pub fn close(self: *Picker) void {
    self.stage = .closed;
    self.requested = false;
}

pub const Action = union(enum) {
    none,
    cancel,
    /// Ask what going back to the server's `seq` would put back.
    preview: u64,
    /// Go back to it.
    rewind: u64,
};

pub fn handleKey(self: *Picker, key: vaxis.Key) Action {
    switch (self.stage) {
        .closed => return .none,
        .turns => {
            if (key.matches(vaxis.Key.escape, .{})) return .cancel;
            if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) self.move(-1);
            if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) self.move(1);
            if (key.matches(vaxis.Key.enter, .{}) and self.cursor < self.turns.len) {
                self.chosen = self.turns[self.cursor].seq;
                return .{ .preview = self.chosen };
            }
            return .none;
        },
        .files => {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.stage = .turns;
                return .none;
            }
            if (key.matches(vaxis.Key.enter, .{})) return .{ .rewind = self.chosen };
            return .none;
        },
    }
}

fn move(self: *Picker, delta: i32) void {
    if (self.turns.len == 0) return;
    var at: i32 = @intCast(self.cursor);
    at += delta;
    if (at < 0 or at >= @as(i32, @intCast(self.turns.len))) return;
    self.cursor = @intCast(at);
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + max_rows) self.scroll = self.cursor - max_rows + 1;
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
};

pub fn draw(self: *Picker, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (self.stage == .closed) return null;

    const listed = switch (self.stage) {
        .closed => unreachable,
        .turns => self.turns.len - self.scroll,
        .files => self.files.len,
    };
    const visible: u16 = @intCast(@min(listed, max_rows));
    const chrome: u16 = 6;
    const height: u16 = chrome + @max(visible, 1);
    if (size.width < 40 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;
    const surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    const first_row: u16 = 3;
    const hint_row = height - 2;
    switch (self.stage) {
        .closed => unreachable,
        .turns => {
            _ = w.writeText(surface, pad, 1, "Go back to before", theme.on_card(theme.fg).bold().cell);
            for (0..visible) |i| {
                const turn = self.turns[self.scroll + i];
                const y: u16 = @intCast(first_row + i);
                const chosen = self.scroll + i == self.cursor;
                const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;
                if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

                const count = try std.fmt.allocPrint(ctx.arena, "{d} file{s}", .{ turn.files, if (turn.files == 1) "" else "s" });
                const room = (width -| pad * 2) -| w.textWidth(count) -| 2;
                const prompt = if (turn.prompt.len > 0) turn.prompt else "(no prompt)";
                _ = w.writeText(surface, pad, y, try fit(ctx.arena, prompt, room), base.withFg(theme.fg).cell);
                w.writeTextRight(surface, y, pad, count, base.withFg(theme.fg_muted).cell);
            }
            var hint = w.writeText(surface, pad, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
            hint = w.writeText(surface, hint, hint_row, " choose   ", theme.on_card(theme.fg_dim).cell);
            hint = w.writeText(surface, hint, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
            _ = w.writeText(surface, hint, hint_row, " move", theme.on_card(theme.fg_dim).cell);
        },
        .files => {
            _ = w.writeText(surface, pad, 1, "Put these back?", theme.on_card(theme.fg).bold().cell);
            if (self.files.len == 0) _ = w.writeText(surface, pad, first_row, "nothing left to put back", theme.on_card(theme.fg_dim).cell);
            for (self.files[0..visible], 0..) |file, i| {
                const y: u16 = @intCast(first_row + i);
                const verb = if (file.removed) "remove " else "restore";
                const x = w.writeText(surface, pad, y, verb, theme.on_card(if (file.removed) theme.danger else theme.fg_muted).cell);
                const note = if (file.changed) "changed since" else "";
                const room = (width -| pad) -| (x + 1) -| w.textWidth(note) -| 2;
                _ = w.writeText(surface, x + 1, y, try fit(ctx.arena, file.path, room), theme.on_card(theme.fg).cell);
                if (file.changed) w.writeTextRight(surface, y, pad, note, theme.on_card(theme.warning).cell);
            }
            if (self.files.len > visible) {
                const more = try std.fmt.allocPrint(ctx.arena, "and {d} more", .{self.files.len - visible});
                w.writeTextRight(surface, hint_row, pad, more, theme.on_card(theme.fg_dim).cell);
            }
            var hint = w.writeText(surface, pad, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
            hint = w.writeText(surface, hint, hint_row, " put back   ", theme.on_card(theme.fg_dim).cell);
            hint = w.writeText(surface, hint, hint_row, "esc", theme.on_card(theme.fg_muted).bold().cell);
            _ = w.writeText(surface, hint, hint_row, " pick another", theme.on_card(theme.fg_dim).cell);
        },
    }

    return .{ .surface = surface, .origin = .{ .row = origin_row, .col = origin_col } };
}

/// `text` cut to `width` cells, marked where it was cut.
fn fit(arena: std.mem.Allocator, text: []const u8, width: u16) ![]const u8 {
    if (w.textWidth(text) <= width) return text;
    if (width == 0) return "";
    var used: u16 = 0;
    var end: usize = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const cells = w.textWidth(g.bytes(text));
        if (used + cells + 1 > width) break;
        used += cells;
        end = g.start + g.len;
    }
    return std.fmt.allocPrint(arena, "{s}…", .{text[0..end]});
}

test "a turn is chosen, its files are shown, and only then put back" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    try picker.show(&.{
        .{ .seq = 8, .prompt = "make b", .files = 1 },
        .{ .seq = 2, .prompt = "change a", .files = 2 },
    });

    try testing.expectEqual(Action.none, picker.handleKey(.{ .codepoint = vaxis.Key.down }));
    const asked = picker.handleKey(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(@as(u64, 2), asked.preview);

    try picker.preview(8, &.{.{ .path = "stale.txt", .removed = false, .changed = false }});
    try testing.expectEqual(Stage.turns, picker.stage);
    try picker.preview(2, &.{
        .{ .path = "a.txt", .removed = false, .changed = true },
        .{ .path = "b.txt", .removed = true, .changed = false },
    });
    try testing.expectEqual(Stage.files, picker.stage);
    try testing.expectEqual(@as(usize, 2), picker.files.len);

    try testing.expectEqual(Action.none, picker.handleKey(.{ .codepoint = vaxis.Key.escape }));
    try testing.expectEqual(Stage.turns, picker.stage);
    _ = picker.handleKey(.{ .codepoint = vaxis.Key.enter });
    try picker.preview(2, &.{});
    try testing.expectEqual(@as(u64, 2), picker.handleKey(.{ .codepoint = vaxis.Key.enter }).rewind);
    try testing.expectEqual(Action.cancel, blk: {
        picker.stage = .turns;
        break :blk picker.handleKey(.{ .codepoint = vaxis.Key.escape });
    });
}
