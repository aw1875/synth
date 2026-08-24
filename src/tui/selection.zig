//! Mouse text selection.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Selection = @This();

/// Bytes stored per cell. Enough for any grapheme worth selecting; longer ones
/// are truncated rather than allocated for.
const cell_bytes = 12;

const GridCell = struct {
    bytes: [cell_bytes]u8 = @splat(0),
    len: u8 = 0,
    /// One-based index into `uris`, or 0 when the cell is not part of a link.
    /// An index rather than a slice so a cell painted over by a later surface
    /// loses the link along with the text, which is what makes hit testing
    /// agree with what is on screen.
    link: u16 = 0,

    fn slice(self: *const GridCell) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Point = struct {
    row: u16,
    col: u16,

    fn beforeOrEqual(self: Point, other: Point) bool {
        if (self.row != other.row) return self.row < other.row;
        return self.col <= other.col;
    }
};

allocator: std.mem.Allocator,
/// Row-major snapshot of the last frame, rebuilt on every draw.
cells: []GridCell = &.{},
/// Link targets referenced by the grid, in the order they were first drawn.
/// The slices borrow from whatever drew them - a message's own text - which
/// outlives the frame.
uris: std.ArrayList([]const u8) = .empty,
width: u16 = 0,
height: u16 = 0,

/// Where the drag started, and where it currently is. Both null when nothing
/// is selected.
anchor: ?Point = null,
head: ?Point = null,
dragging: bool = false,
/// Columns the selection is confined to: the pane the drag started in. Without
/// this a linear selection spanning two rows swallows the sidebar, which is
/// never what was meant - the panes are separate documents that happen to share
/// a screen.
left: u16 = 0,
right: u16 = std.math.maxInt(u16),

pub fn init(allocator: std.mem.Allocator) Selection {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Selection) void {
    self.allocator.free(self.cells);
    self.uris.deinit(self.allocator);
}

pub fn isActive(self: *const Selection) bool {
    return self.anchor != null and self.head != null;
}

pub fn clear(self: *Selection) void {
    self.anchor = null;
    self.head = null;
    self.dragging = false;
    self.left = 0;
    self.right = std.math.maxInt(u16);
}

/// Confine the selection to `[left, right]`, the pane it started in.
pub fn confine(self: *Selection, left: u16, right: u16) void {
    self.left = left;
    self.right = right;
}

pub fn begin(self: *Selection, point: Point) void {
    self.anchor = point;
    self.head = point;
    self.dragging = true;
}

pub fn extend(self: *Selection, point: Point) void {
    if (self.anchor == null) return;
    self.head = point;
}

pub fn end(self: *Selection) void {
    self.dragging = false;
    if (self.anchor) |anchor| {
        if (self.head) |head| {
            if (anchor.row == head.row and anchor.col == head.col) self.clear();
        }
    }
}

pub const Bounds = struct { start: Point, end: Point };

/// Selection bounds in draw order, regardless of drag direction.
pub fn range(self: *const Selection) ?Bounds {
    const anchor = self.anchor orelse return null;
    const head = self.head orelse return null;
    return if (anchor.beforeOrEqual(head))
        .{ .start = anchor, .end = head }
    else
        .{ .start = head, .end = anchor };
}

/// Whether a cell falls inside the selection. Selection is linear, like a text
/// editor, not rectangular: full rows between the endpoints are included.
pub fn contains(self: *const Selection, row: u16, col: u16) bool {
    const bounds = self.range() orelse return false;
    if (col < self.left or col > self.right) return false;
    if (row < bounds.start.row or row > bounds.end.row) return false;
    if (row == bounds.start.row and col < bounds.start.col) return false;
    if (row == bounds.end.row and col > bounds.end.col) return false;
    return true;
}

/// The columns of `row` worth highlighting: the selected range, clamped to the
/// pane, hugging the text on both sides. Highlighting the padding a card drew
/// makes the selection look like a block of colour rather than like selected
/// text.
pub fn rowSpan(self: *const Selection, row: u16) ?struct { from: u16, to: u16 } {
    const bounds = self.range() orelse return null;
    if (row < bounds.start.row or row > bounds.end.row or row >= self.height) return null;

    const limit = self.rowLimit(bounds, row);
    const from: u16 = if (row == bounds.start.row)
        @max(self.left, bounds.start.col)
    else
        self.bodyLeft(bounds);
    if (from > limit) return null;

    var last: ?u16 = null;
    var col = from;
    while (col <= limit) : (col += 1) {
        const bytes = self.cells[@as(usize, row) * self.width + col].slice();
        if (bytes.len > 0 and !std.mem.eql(u8, bytes, " ")) last = col;
    }

    return .{ .from = from, .to = last orelse return null };
}

/// The last column of `row` the selection could reach.
fn rowLimit(self: *const Selection, bounds: Bounds, row: u16) u16 {
    return @min(
        self.right,
        if (row == bounds.end.row) @min(bounds.end.col, self.width -| 1) else self.width -| 1,
    );
}

/// The column the selected block's text starts at: the leftmost cell holding
/// anything, across every row but the first.
fn bodyLeft(self: *const Selection, bounds: Bounds) u16 {
    var shared: ?u16 = null;

    var row = bounds.start.row +| 1;
    while (row <= bounds.end.row and row < self.height) : (row += 1) {
        const limit = self.rowLimit(bounds, row);
        var col = self.left;
        while (col <= limit and col < self.width) : (col += 1) {
            if (isChrome(self.cells[@as(usize, row) * self.width + col].slice())) continue;
            shared = @min(shared orelse col, col);
            break;
        }
    }

    return shared orelse self.left;
}

/// Whether a cell is part of the frame a card drew rather than of its text.
/// Blanks, and the bar a user's message is drawn with - both sit to the left of
/// the text on every row, and neither is worth highlighting.
fn isChrome(bytes: []const u8) bool {
    return bytes.len == 0 or std.mem.eql(u8, bytes, " ") or std.mem.eql(u8, bytes, "▌");
}

/// Copy the composited frame into the grid. Called at the end of `draw`, with
/// the tree the model is about to return.
pub fn capture(self: *Selection, surface: vxfw.Surface) !void {
    const size = surface.size;
    if (size.width != self.width or size.height != self.height) {
        self.allocator.free(self.cells);
        self.cells = try self.allocator.alloc(GridCell, @as(usize, size.width) * size.height);
        self.width = size.width;
        self.height = size.height;
        self.clear();
    }
    @memset(self.cells, .{});
    self.uris.clearRetainingCapacity();

    self.blit(surface, 0, 0);
}

/// The link under a cell, or null. Empty for anything the frame drew over.
pub fn linkAt(self: *const Selection, row: u16, col: u16) ?[]const u8 {
    if (row >= self.height or col >= self.width) return null;
    const index = self.cells[@as(usize, row) * self.width + col].link;
    if (index == 0) return null;
    return self.uris.items[index - 1];
}

/// Walk the tree the same way the renderer does, newest child winning.
fn blit(self: *Selection, surface: vxfw.Surface, row_off: i32, col_off: i32) void {
    if (surface.buffer.len > 0) {
        for (surface.buffer, 0..) |cell, i| {
            const row = row_off + @as(i32, @intCast(i / surface.size.width));
            const col = col_off + @as(i32, @intCast(i % surface.size.width));
            self.put(row, col, cell.char.grapheme, cell.link.uri);
        }
    }
    for (surface.children) |child| {
        self.blit(child.surface, row_off + child.origin.row, col_off + child.origin.col);
    }
}

fn put(self: *Selection, row: i32, col: i32, grapheme: []const u8, uri: []const u8) void {
    if (row < 0 or col < 0) return;
    if (row >= self.height or col >= self.width) return;

    const index = @as(usize, @intCast(row)) * self.width + @as(usize, @intCast(col));
    const len = @min(grapheme.len, cell_bytes);
    var cell: GridCell = .{ .len = @intCast(len), .link = self.uriIndex(uri) };
    @memcpy(cell.bytes[0..len], grapheme[0..len]);
    self.cells[index] = cell;
}

/// The one-based index of `uri` in `uris`, adding it if this is the first cell
/// of the run. A link covers many cells in a row, so the last entry is checked
/// first and the list stays as short as the number of links on screen.
fn uriIndex(self: *Selection, uri: []const u8) u16 {
    if (uri.len == 0) return 0;
    if (self.uris.items.len > 0) {
        const last = self.uris.items[self.uris.items.len - 1];
        if (last.ptr == uri.ptr and last.len == uri.len) return @intCast(self.uris.items.len);
    }
    if (self.uris.items.len >= std.math.maxInt(u16)) return 0;
    self.uris.append(self.allocator, uri) catch return 0;
    return @intCast(self.uris.items.len);
}

/// The grapheme at a cell, or empty when out of range. Borrowed from the grid,
/// which lives until the next capture.
pub fn cellText(self: *const Selection, row: u16, col: u16) []const u8 {
    if (row >= self.height or col >= self.width) return "";
    return self.cells[@as(usize, row) * self.width + col].slice();
}

/// The selected text, with trailing blanks trimmed from each row. Caller owns
/// the result; returns null when nothing is selected.
pub fn text(self: *const Selection, allocator: std.mem.Allocator) !?[]u8 {
    const bounds = self.range() orelse return null;
    if (self.cells.len == 0) return null;

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rows: std.ArrayList([]const u8) = .empty;

    var row = bounds.start.row;
    while (row <= bounds.end.row and row < self.height) : (row += 1) {
        const span = self.rowSpan(row) orelse {
            try rows.append(arena, "");
            continue;
        };

        var line: std.Io.Writer.Allocating = .init(arena);
        var col = span.from;
        while (col <= span.to) : (col += 1) {
            const bytes = self.cells[@as(usize, row) * self.width + col].slice();
            try line.writer.writeAll(if (bytes.len == 0) " " else bytes);
        }
        try rows.append(arena, line.written());
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (rows.items, 0..) |line, i| {
        if (i > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
    }
    return try out.toOwnedSlice();
}

test "linear selection spans whole rows between endpoints" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 12);
    @memset(selection.cells, .{});
    selection.width = 4;
    selection.height = 3;

    selection.begin(.{ .row = 0, .col = 2 });
    selection.extend(.{ .row = 2, .col = 1 });

    try std.testing.expect(!selection.contains(0, 1));
    try std.testing.expect(selection.contains(0, 3));
    try std.testing.expect(selection.contains(1, 0));
    try std.testing.expect(selection.contains(1, 3));
    try std.testing.expect(selection.contains(2, 1));
    try std.testing.expect(!selection.contains(2, 2));
}

test "dragging backwards selects the same range" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.begin(.{ .row = 2, .col = 1 });
    selection.extend(.{ .row = 0, .col = 2 });

    const bounds = selection.range().?;
    try std.testing.expectEqual(@as(u16, 0), bounds.start.row);
    try std.testing.expectEqual(@as(u16, 2), bounds.end.row);
}

test "text trims the padding panels draw" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 8);
    @memset(selection.cells, .{});
    selection.width = 4;
    selection.height = 2;

    for ("hi  ", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("yo  ", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");

    selection.begin(.{ .row = 0, .col = 0 });
    selection.extend(.{ .row = 1, .col = 3 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("hi\nyo", copied);
}

test "a click without movement selects nothing" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.begin(.{ .row = 1, .col = 1 });
    selection.end();
    try std.testing.expect(!selection.isActive());
}

test "a selection stays inside the pane it started in" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 20);
    @memset(selection.cells, .{});
    selection.width = 10;
    selection.height = 2;

    for ("abcd", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("SIDE", 0..) |c, i| selection.put(0, @intCast(6 + i), &.{c}, "");
    for ("efgh", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");

    selection.begin(.{ .row = 0, .col = 0 });
    selection.confine(0, 4);
    selection.extend(.{ .row = 1, .col = 3 });

    try std.testing.expect(selection.contains(0, 3));
    try std.testing.expect(!selection.contains(0, 7));

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("abcd\nefgh", copied);
}

test "copied rows lose the chrome they share, not their own indentation" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 60);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 3;

    for ("    const std = x;", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("    pub fn main() {", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");
    for ("        print();", 0..) |c, i| selection.put(2, @intCast(i), &.{c}, "");

    selection.begin(.{ .row = 0, .col = 4 });
    selection.extend(.{ .row = 2, .col = 19 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("const std = x;\npub fn main() {\n    print();", copied);
}

test "rows after the first hug the text, not the pane" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 60);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 3;

    for ("    pub fn main() {", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("        print();", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");
    for ("    }", 0..) |c, i| selection.put(2, @intCast(i), &.{c}, "");

    selection.begin(.{ .row = 0, .col = 4 });
    selection.extend(.{ .row = 2, .col = 19 });

    try std.testing.expectEqual(@as(u16, 4), selection.rowSpan(0).?.from);
    try std.testing.expectEqual(@as(u16, 4), selection.rowSpan(1).?.from);
    try std.testing.expectEqual(@as(u16, 4), selection.rowSpan(2).?.from);
    try std.testing.expectEqual(@as(u16, 18), selection.rowSpan(0).?.to);

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("pub fn main() {\n    print();\n}", copied);
}

test "a card's bar is chrome, not the start of the text" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 40);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 2;

    selection.put(0, 0, "▌", "");
    for ("  first line", 0..) |c, i| selection.put(0, @intCast(2 + i), &.{c}, "");
    selection.put(1, 0, "▌", "");
    for ("  second line", 0..) |c, i| selection.put(1, @intCast(2 + i), &.{c}, "");

    selection.begin(.{ .row = 0, .col = 4 });
    selection.extend(.{ .row = 1, .col = 19 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("first line\nsecond line", copied);
}

test "the grid remembers what a cell links to" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    var buffer: [4]vaxis.Cell = undefined;
    for (&buffer, "abcd", 0..) |*cell, c, i| {
        cell.* = .{
            .char = .{ .grapheme = ([_][]const u8{ "a", "b", "c", "d" })[i], .width = 1 },
            .link = .{ .uri = if (c == 'c' or c == 'd') "https://example.com" else "" },
        };
    }
    const surface: vxfw.Surface = .{
        .size = .{ .width = 4, .height = 1 },
        .widget = widget,
        .buffer = &buffer,
        .children = &.{},
    };

    try selection.capture(surface);

    try std.testing.expect(selection.linkAt(0, 0) == null);
    try std.testing.expectEqualStrings("https://example.com", selection.linkAt(0, 2).?);
    try std.testing.expectEqualStrings("https://example.com", selection.linkAt(0, 3).?);
    try std.testing.expectEqual(@as(usize, 1), selection.uris.items.len);
    try std.testing.expect(selection.linkAt(9, 9) == null);

    var cover: [2]vaxis.Cell = @splat(.{ .char = .{ .grapheme = "x", .width = 1 } });
    const child: vxfw.Surface = .{
        .size = .{ .width = 2, .height = 1 },
        .widget = widget,
        .buffer = &cover,
        .children = &.{},
    };
    var children = [_]vxfw.SubSurface{.{ .origin = .{ .row = 0, .col = 2 }, .surface = child }};
    var covered = surface;
    covered.children = &children;

    try selection.capture(covered);
    try std.testing.expect(selection.linkAt(0, 2) == null);
}
