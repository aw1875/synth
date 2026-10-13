//! Line diffs for `edit` and `write` calls.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const theme = @import("theme.zig");
const themes = @import("themes.zig");
const w = @import("widgets.zig");

/// Past this many lines on either side the quadratic match is skipped and the
/// hunk is shown as a wholesale replacement. A diff that large is unreadable in
/// a card anyway.
const max_diff_lines: usize = 400;
/// Below this width two columns stop being readable, so the diff goes unified.
pub const min_side_by_side_width: u16 = 76;

pub const Kind = enum { context, removed, added };

pub const Line = struct {
    kind: Kind,
    /// 1-based line number in the file the line belongs to.
    number: usize,
    text: []const u8,
};

/// One printed row. Side by side both halves are used; unified only ever fills
/// one of them.
pub const Row = struct {
    left: ?Line = null,
    right: ?Line = null,
};

/// Diff `old` against `new`, numbering from `start_line` on both sides.
pub fn rows(
    arena: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
    start_line: usize,
) ![]const Row {
    const old_lines = try splitLines(arena, old_text);
    const new_lines = try splitLines(arena, new_text);

    var out: std.ArrayList(Row) = .empty;
    var removed: std.ArrayList(Line) = .empty;
    var added: std.ArrayList(Line) = .empty;

    var old_no = start_line;
    var new_no = start_line;

    if (old_lines.len > max_diff_lines or new_lines.len > max_diff_lines) {
        for (old_lines) |line| {
            try removed.append(arena, .{ .kind = .removed, .number = old_no, .text = line });
            old_no += 1;
        }
        for (new_lines) |line| {
            try added.append(arena, .{ .kind = .added, .number = new_no, .text = line });
            new_no += 1;
        }
        try flush(arena, &out, &removed, &added);
        return out.toOwnedSlice(arena);
    }

    const table = try lcs(arena, old_lines, new_lines);
    const stride = new_lines.len + 1;

    var i: usize = 0;
    var j: usize = 0;
    while (i < old_lines.len and j < new_lines.len) {
        if (std.mem.eql(u8, old_lines[i], new_lines[j])) {
            try flush(arena, &out, &removed, &added);
            try out.append(arena, .{
                .left = .{ .kind = .context, .number = old_no, .text = old_lines[i] },
                .right = .{ .kind = .context, .number = new_no, .text = new_lines[j] },
            });
            i += 1;
            j += 1;
            old_no += 1;
            new_no += 1;
        } else if (table[(i + 1) * stride + j] >= table[i * stride + j + 1]) {
            try removed.append(arena, .{ .kind = .removed, .number = old_no, .text = old_lines[i] });
            i += 1;
            old_no += 1;
        } else {
            try added.append(arena, .{ .kind = .added, .number = new_no, .text = new_lines[j] });
            j += 1;
            new_no += 1;
        }
    }
    while (i < old_lines.len) : (i += 1) {
        try removed.append(arena, .{ .kind = .removed, .number = old_no, .text = old_lines[i] });
        old_no += 1;
    }
    while (j < new_lines.len) : (j += 1) {
        try added.append(arena, .{ .kind = .added, .number = new_no, .text = new_lines[j] });
        new_no += 1;
    }
    try flush(arena, &out, &removed, &added);

    return out.toOwnedSlice(arena);
}

/// Pair up a run of removals with the additions that replaced them, so a
/// changed line lands opposite its replacement instead of below it.
fn flush(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Row),
    removed: *std.ArrayList(Line),
    added: *std.ArrayList(Line),
) !void {
    const count = @max(removed.items.len, added.items.len);
    for (0..count) |i| {
        try out.append(arena, .{
            .left = if (i < removed.items.len) removed.items[i] else null,
            .right = if (i < added.items.len) added.items[i] else null,
        });
    }
    removed.clearRetainingCapacity();
    added.clearRetainingCapacity();
}

/// Longest-common-subsequence lengths, `(old.len + 1) * (new.len + 1)`.
fn lcs(arena: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) ![]usize {
    const stride = new_lines.len + 1;
    const table = try arena.alloc(usize, (old_lines.len + 1) * stride);
    @memset(table, 0);

    var i = old_lines.len;
    while (i > 0) {
        i -= 1;
        var j = new_lines.len;
        while (j > 0) {
            j -= 1;
            table[i * stride + j] = if (std.mem.eql(u8, old_lines[i], new_lines[j]))
                table[(i + 1) * stride + j + 1] + 1
            else
                @max(table[(i + 1) * stride + j], table[i * stride + j + 1]);
        }
    }
    return table;
}

fn splitLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    if (text.len == 0) return &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, std.mem.trimEnd(u8, line, "\r"));

    if (lines.items.len > 1 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines.toOwnedSlice(arena);
}

/// What a call would change, pulled out of its raw argument JSON.
pub const Change = struct {
    path: []const u8,
    /// Empty for `write`: the whole file is the addition.
    old: []const u8,
    new: []const u8,
};

/// The change a call describes, or null when the tool does not edit a file.
pub fn change(arena: std.mem.Allocator, name: []const u8, arguments: []const u8) !?Change {
    const is_edit = std.mem.eql(u8, name, "edit");
    const is_write = std.mem.eql(u8, name, "write");
    if (!is_edit and !is_write) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, arguments, .{}) catch return null;
    if (parsed.value != .object) return null;
    const object = parsed.value.object;

    const path = string(object, "path") orelse return null;
    if (is_write) {
        return .{ .path = path, .old = "", .new = string(object, "content") orelse return null };
    }
    return .{
        .path = path,
        .old = string(object, "old") orelse return null,
        .new = string(object, "new") orelse return null,
    };
}

fn string(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

pub const DrawOptions = struct {
    /// Frame arena. Cells hold the text they were given by reference, so every
    /// string drawn has to outlive the draw call that produced it.
    arena: std.mem.Allocator,
    /// Top-left of the diff within the surface.
    row: u16,
    col: u16,
    width: u16,
    /// Rows to print before the rest is summarised away. 0 means no limit.
    max_rows: usize = 0,
    /// Background the diff sits on, for the parts no line covers. Null takes
    /// the card style, which a default cannot: the palette is set at runtime.
    background: ?Cell.Style = null,
};

/// Rows this diff needs, including the "N more lines" marker when capped.
pub fn height(diff: []const Row, max_rows: usize) u16 {
    if (max_rows == 0 or diff.len <= max_rows) return @intCast(diff.len);
    return @intCast(max_rows + 1);
}

/// Paint the diff into an already-sized surface.
pub fn draw(surface: vxfw.Surface, diff: []const Row, opts: DrawOptions) void {
    const background = opts.background orelse theme.card.cell;
    const shown = if (opts.max_rows == 0 or diff.len <= opts.max_rows) diff.len else opts.max_rows;
    const numbers = numberWidth(diff);
    const side_by_side = opts.width >= min_side_by_side_width and twoSided(diff);

    for (diff[0..shown], 0..) |row, i| {
        const y = opts.row + @as(u16, @intCast(i));
        if (side_by_side) {
            const column = (opts.width -| 1) / 2;
            drawLine(opts.arena, surface, y, opts.col, column, numbers, row.left, background);
            const split = opts.col + column;
            surface.writeCell(split, y, .{
                .char = .{ .grapheme = w.solid_rule, .width = 1 },
                .style = .{ .fg = theme.border, .bg = background.bg },
            });
            drawLine(opts.arena, surface, y, split + 1, column, numbers, row.right, background);
        } else {
            const line = row.left orelse row.right;
            drawLine(opts.arena, surface, y, opts.col, opts.width, numbers, line, background);
        }
    }

    if (shown < diff.len) {
        const text = std.fmt.allocPrint(opts.arena, "... {d} more lines", .{diff.len - shown}) catch "...";
        _ = w.writeText(
            surface,
            opts.col,
            opts.row + @as(u16, @intCast(shown)),
            text,
            theme.on_card(theme.fg_dim).cell,
        );
    }
}

/// Unified rendering needs one row per side, so a changed pair has to be split
/// before it is drawn. Side-by-side leaves the rows alone.
pub fn unify(arena: std.mem.Allocator, diff: []const Row) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    for (diff) |row| {
        const changed = row.left != null and row.right != null and
            row.left.?.kind != .context;
        if (changed) {
            try out.append(arena, .{ .left = row.left });
            try out.append(arena, .{ .right = row.right });
        } else if (row.left != null and row.right != null) {
            try out.append(arena, .{ .left = row.left });
        } else {
            try out.append(arena, .{ .left = row.left orelse row.right });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Whether any row has a right side to put opposite its left.
fn twoSided(diff: []const Row) bool {
    for (diff) |row| {
        if (row.right != null) return true;
    }
    return false;
}

/// Whether every row of a diff sits on the same side, which a new or deleted
/// file is. Side by side then spends half the width on a column that is empty
/// all the way down, and the change reads as though it had been indented.
pub fn oneSided(diff: []const Row) bool {
    var left = false;
    var right = false;
    for (diff) |row| {
        if (row.left) |l| left = left or l.kind != .context;
        if (row.right) |r| right = right or r.kind != .context;
        if (left and right) return false;
    }
    return true;
}

fn drawLine(
    arena: std.mem.Allocator,
    surface: vxfw.Surface,
    row: u16,
    col: u16,
    width: u16,
    /// Width of the number gutter, shared by every row so the columns line up.
    numbers: u16,
    line: ?Line,
    background: Cell.Style,
) void {
    if (width == 0) return;

    const ground: theme.Style = .{ .cell = background };
    w.fillRow(surface, row, col, width, background);

    const l = line orelse return;
    if (width <= numbers + 8) return;

    const at = col + 1;
    const marker: []const u8 = switch (l.kind) {
        .context => " ",
        .removed => "-",
        .added => "+",
    };
    _ = w.writeText(surface, at, row, marker, ground.withFg(foregroundFor(l.kind)).bold().cell);

    const text = std.fmt.allocPrint(arena, "{d}", .{l.number}) catch "";
    _ = w.writeText(
        surface,
        at + 2 + numbers -| @as(u16, @intCast(text.len)),
        row,
        text,
        ground.withFg(theme.fg_dim).cell,
    );

    // The gutter says which line, which is not what the tint has to report.
    const rule_at = at + numbers + 3;
    _ = w.writeText(surface, rule_at, row, w.solid_rule, ground.withFg(theme.border).cell);

    const text_col = rule_at + 2;
    const fill_style = backgroundFor(l.kind, background);
    w.fillRow(surface, row, text_col -| 1, col + width -| (text_col -| 1), fill_style.cell);
    _ = w.writeText(surface, text_col, row, l.text, fill_style.withFg(foregroundFor(l.kind)).cell);
}

fn foregroundFor(kind: Kind) theme.Color {
    return switch (kind) {
        .context => theme.fg,
        .removed => theme.diff_removed_fg,
        .added => theme.diff_added_fg,
    };
}

fn backgroundFor(kind: ?Kind, background: Cell.Style) theme.Style {
    const style: theme.Style = .{ .cell = background };
    return switch (kind orelse return style) {
        .context => style,
        .removed => style.withBg(theme.diff_removed_bg),
        .added => style.withBg(theme.diff_added_bg),
    };
}

/// Width of the number gutter, from the largest line number in the diff.
fn numberWidth(diff: []const Row) u16 {
    var largest: usize = 0;
    for (diff) |row| {
        if (row.left) |l| largest = @max(largest, l.number);
        if (row.right) |r| largest = @max(largest, r.number);
    }
    return @max(3, digits(largest));
}

fn digits(value: usize) u16 {
    var count: u16 = 1;
    var rest = value;
    while (rest >= 10) : (rest /= 10) count += 1;
    return count;
}

test "unchanged lines pair up and changed ones sit opposite each other" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const diff = try rows(arena_state.allocator(), "one\ntwo\nthree\n", "one\n2\nthree\n", 10);
    try std.testing.expectEqual(@as(usize, 3), diff.len);

    try std.testing.expectEqual(Kind.context, diff[0].left.?.kind);
    try std.testing.expectEqual(@as(usize, 10), diff[0].left.?.number);

    try std.testing.expectEqual(Kind.removed, diff[1].left.?.kind);
    try std.testing.expectEqualStrings("two", diff[1].left.?.text);
    try std.testing.expectEqual(Kind.added, diff[1].right.?.kind);
    try std.testing.expectEqualStrings("2", diff[1].right.?.text);
    try std.testing.expectEqual(@as(usize, 11), diff[1].right.?.number);

    try std.testing.expectEqual(Kind.context, diff[2].left.?.kind);
    try std.testing.expectEqual(@as(usize, 12), diff[2].left.?.number);
}

test "a new file is all additions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const diff = try rows(arena_state.allocator(), "", "a\nb\n", 1);
    try std.testing.expectEqual(@as(usize, 2), diff.len);
    for (diff) |row| {
        try std.testing.expect(row.left == null);
        try std.testing.expectEqual(Kind.added, row.right.?.kind);
    }
}

test "unified splits a changed pair across two rows" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff = try rows(arena, "one\ntwo\n", "one\n2\n", 1);
    const flat = try unify(arena, diff);

    try std.testing.expectEqual(@as(usize, 3), flat.len);
    try std.testing.expectEqualStrings("one", flat[0].left.?.text);
    try std.testing.expectEqualStrings("two", flat[1].left.?.text);
    try std.testing.expectEqualStrings("2", flat[2].right.?.text);
}

test "a change is only pulled from the tools that edit files" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(try change(arena, "bash", "{\"command\":\"ls\"}") == null);
    try std.testing.expect(try change(arena, "edit", "{\"path\":\"a.zig\"}") == null);

    const edited = (try change(arena, "edit", "{\"path\":\"a.zig\",\"old\":\"x\",\"new\":\"y\"}")).?;
    try std.testing.expectEqualStrings("a.zig", edited.path);
    try std.testing.expectEqualStrings("x", edited.old);

    const written = (try change(arena, "write", "{\"path\":\"a.zig\",\"content\":\"y\"}")).?;
    try std.testing.expectEqualStrings("", written.old);
    try std.testing.expectEqualStrings("y", written.new);
}

test "each row prints its own line number" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    const diff = try rows(arena, "a\nb\nc\nd\n", "b\nd\n", 1);
    const surface = try vxfw.Surface.init(arena, widget, .{ .width = 100, .height = 4 });
    draw(surface, diff, .{ .arena = arena, .row = 0, .col = 0, .width = 100 });

    for (0..4) |row| {
        const cell = surface.buffer[row * 100 + 5];
        const expected = [_][]const u8{ "1", "2", "3", "4" };
        try std.testing.expectEqualStrings(expected[row], cell.char.grapheme);
    }
}

test "a changed line is written in the colour of its kind" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    // The palette is global, so a test that pins it has to hand it back.
    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    // One line kept, one replaced, so the row carries a removal and an addition.
    const diff = try rows(arena, "keep\nold\n", "keep\nnew\n", 1);
    const width: u16 = 100;
    const surface = try vxfw.Surface.init(arena, widget, .{ .width = width, .height = 2 });
    draw(surface, diff, .{ .arena = arena, .row = 0, .col = 0, .width = width });

    const column = (width -| 1) / 2;
    const text_col = numberWidth(diff) + 6;
    const context_cell = surface.buffer[text_col];
    const removed_cell = surface.buffer[width + text_col];
    const added_cell = surface.buffer[width + column + 1 + text_col];

    try testing.expectEqualStrings("k", context_cell.char.grapheme);
    try testing.expectEqualStrings("o", removed_cell.char.grapheme);
    try testing.expectEqualStrings("n", added_cell.char.grapheme);

    try testing.expectEqual(theme.fg, context_cell.style.fg);
    try testing.expectEqual(theme.diff_removed_fg, removed_cell.style.fg);
    try testing.expectEqual(theme.diff_added_fg, added_cell.style.fg);

    // The colours are the theme's own, not one shared value standing in.
    try testing.expect(!std.meta.eql(theme.diff_added_fg, theme.diff_removed_fg));
    try testing.expect(!std.meta.eql(theme.diff_added_fg, theme.fg));
}

test "a new file fills one column rather than only the right half" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const added = try rows(arena, "", "Hello world\nsecond line\n", 1);
    try testing.expect(oneSided(added));

    const flat = try unify(arena, added);
    for (flat) |row| {
        try testing.expect(row.right == null);
        try testing.expectEqual(Kind.added, row.left.?.kind);
    }

    // A change with both sides still has something to put opposite it.
    const edited = try rows(arena, "old\nkeep\n", "new\nkeep\n", 1);
    try testing.expect(!oneSided(edited));
}

test "a unified diff stays in one column however wide the pane is" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    const width: u16 = min_side_by_side_width + 20;
    const flat = try unify(arena, try rows(arena, "", "Hello world\n", 1));
    const surface = try vxfw.Surface.init(arena, widget, .{ .width = width, .height = 1 });
    draw(surface, flat, .{ .arena = arena, .row = 0, .col = 0, .width = width });

    var text: std.Io.Writer.Allocating = .init(arena);
    for (0..width) |col| try text.writer.writeAll(surface.buffer[col].char.grapheme);
    const line = text.written();

    // In the left column, not past the midpoint a second column would force.
    const at = std.mem.indexOf(u8, line, "Hello world").?;
    try testing.expect(at < (width -| 1) / 2);
    try testing.expectEqualStrings("+", line[1..2]);

    // And it has the whole pane, not the half a second column would have left.
    const long = "x" ** 90;
    const wide = try unify(arena, try rows(arena, "", long ++ "\n", 1));
    const room = try vxfw.Surface.init(arena, widget, .{ .width = width, .height = 1 });
    draw(room, wide, .{ .arena = arena, .row = 0, .col = 0, .width = width });

    var written: usize = 0;
    for (0..width) |col| {
        if (std.mem.eql(u8, room.buffer[col].char.grapheme, "x")) written += 1;
    }
    try testing.expect(written > (width -| 1) / 2);
}

test "side by side rules off the gutters and the two halves" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    const width: u16 = min_side_by_side_width + 20;
    const body = try rows(arena, "old line\n", "new line\n", 1);
    const ground: Cell.Style = .{ .fg = theme.fg, .bg = theme.surface };
    const surface = try vxfw.Surface.init(arena, widget, .{ .width = width, .height = 1 });
    w.fill(surface, ground);
    draw(surface, body, .{ .arena = arena, .row = 0, .col = 0, .width = width, .background = ground });

    var rules: usize = 0;
    var tinted: usize = 0;
    for (0..width) |col| {
        const cell = surface.buffer[col];
        if (std.mem.eql(u8, cell.char.grapheme, w.solid_rule)) rules += 1;
        if (!std.meta.eql(cell.style.bg, theme.surface)) tinted += 1;
    }

    // One down each gutter, and one between the halves.
    try testing.expectEqual(@as(usize, 3), rules);

    // The tint covers the code and stops short of the whole row.
    try testing.expect(tinted > 0);
    try testing.expect(tinted < width - 10);

    // The gutter naming the line is never tinted, so the number reads as fact.
    const numbers = numberWidth(body);
    try testing.expectEqual(theme.surface, surface.buffer[3 + numbers].style.bg);
}
