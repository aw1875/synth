//! Line diffs for `edit` and `write` calls.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const theme = @import("theme.zig");
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
    const side_by_side = opts.width >= min_side_by_side_width;

    for (diff[0..shown], 0..) |row, i| {
        const y = opts.row + @as(u16, @intCast(i));
        if (side_by_side) {
            const column = (opts.width -| 1) / 2;
            drawLine(opts.arena, surface, y, opts.col, column, numbers, row.left, background);
            drawLine(opts.arena, surface, y, opts.col + column + 1, column, numbers, row.right, background);
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
            try out.append(arena, row);
        }
    }
    return out.toOwnedSlice(arena);
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

    const kind: ?Kind = if (line) |l| l.kind else null;
    const fill_style = backgroundFor(kind, background);
    w.fillRow(surface, row, col, width, fill_style.cell);

    const l = line orelse return;
    if (width <= numbers + 4) return;

    const marker: []const u8 = switch (l.kind) {
        .context => " ",
        .removed => "-",
        .added => "+",
    };
    const marker_style = fill_style.withFg(switch (l.kind) {
        .context => theme.fg_dim,
        .removed => theme.danger,
        .added => theme.success,
    });
    _ = w.writeText(surface, col, row, marker, marker_style.bold().cell);

    const text = std.fmt.allocPrint(arena, "{d}", .{l.number}) catch "";
    const number_style = fill_style.withFg(theme.fg_dim);
    _ = w.writeText(
        surface,
        col + 2 + numbers -| @as(u16, @intCast(text.len)),
        row,
        text,
        number_style.cell,
    );

    const text_col = col + numbers + 4;
    _ = w.writeText(surface, text_col, row, l.text, fill_style.withFg(theme.fg).cell);
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
        const cell = surface.buffer[row * 100 + 4];
        const expected = [_][]const u8{ "1", "2", "3", "4" };
        try std.testing.expectEqualStrings(expected[row], cell.char.grapheme);
    }
}
