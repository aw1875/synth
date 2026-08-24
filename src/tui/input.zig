const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Input = @This();

allocator: std.mem.Allocator,
text: std.ArrayList(u8) = .empty,
/// Byte offset of the cursor within `text`.
cursor: usize = 0,
/// Number of visible rows.
height: u16 = 3,
/// Index of the first visible line (for vertical scrolling).
scroll: usize = 0,
style: Cell.Style = .{},
/// Substrings drawn as chips: the tokens standing in for pasted text and
/// images. Borrowed from whoever holds the attachments.
tokens: []const []const u8 = &.{},
token_style: Cell.Style = .{},
/// Shown in place of the text while the field is empty. Drawn here rather than
/// by whoever owns the field: this surface is composited over its parent's, and
/// it paints every cell, so a placeholder written underneath never survives.
/// Borrowed; must outlive the draw.
placeholder: []const u8 = "",
placeholder_style: Cell.Style = .{},
userdata: ?*anyopaque = null,
onSubmit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,

const Line = struct {
    start: usize,
    end: usize,
    width: u16,
};

pub fn init(allocator: std.mem.Allocator) Input {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Input) void {
    self.text.deinit(self.allocator);
}

pub fn widget(self: *Input) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Input = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
    const self: *Input = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn handleEvent(self: *Input, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                self.clear();
                return ctx.consumeAndRedraw();
            }

            // ctrl+j is ASCII LF; shift/alt+enter need the kitty protocol.
            if (key.matches(vaxis.Key.enter, .{ .shift = true }) or
                key.matches(vaxis.Key.enter, .{ .alt = true }) or
                key.matches('j', .{ .ctrl = true }))
            {
                try self.insert("\n");
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                if (self.onSubmit) |onSubmit| {
                    const value = try self.text.toOwnedSlice(self.allocator);
                    defer self.allocator.free(value);
                    self.cursor = 0;
                    self.scroll = 0;
                    try onSubmit(self.userdata, ctx, value);
                    return ctx.consumeAndRedraw();
                }
            } else if (key.matches(vaxis.Key.backspace, .{})) {
                self.backspace();
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.delete, .{})) {
                self.deleteForward();
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.left, .{ .ctrl = true }) or
                key.matches(vaxis.Key.left, .{ .alt = true }))
            {
                self.cursor = wordLeft(self.text.items, self.cursor);
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.right, .{ .ctrl = true }) or
                key.matches(vaxis.Key.right, .{ .alt = true }))
            {
                self.cursor = wordRight(self.text.items, self.cursor);
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.left, .{})) {
                self.cursor = graphemeLeft(self.text.items, self.cursor);
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.right, .{})) {
                self.cursor = graphemeRight(self.text.items, self.cursor);
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.up, .{})) {
                self.moveVertical(-1);
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.down, .{})) {
                self.moveVertical(1);
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.home, .{})) {
                self.cursor = 0;
                return ctx.consumeAndRedraw();
            } else if (key.matches(vaxis.Key.end, .{})) {
                self.cursor = self.text.items.len;
                return ctx.consumeAndRedraw();
            } else if (key.text) |text| {
                try self.insert(text);
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }
}

/// Discard the draft.
pub fn clear(self: *Input) void {
    self.text.clearRetainingCapacity();
    self.cursor = 0;
    self.scroll = 0;
}

/// Replace the bytes in `[start, end)` with `replacement`, leaving the cursor
/// just after it. Used by the mention popup to swap a partial `@path` for the
/// completed one.
pub fn replaceRange(self: *Input, start: usize, end: usize, replacement: []const u8) !void {
    if (start > end or end > self.text.items.len) return;
    try self.text.replaceRange(self.allocator, start, end - start, replacement);
    self.cursor = start + replacement.len;
}

/// Insert `data` at the cursor. Used for pastes and for the tokens that stand
/// in for them.
pub fn insertText(self: *Input, data: []const u8) !void {
    return self.insert(data);
}

fn insert(self: *Input, data: []const u8) !void {
    try self.text.insertSlice(self.allocator, self.cursor, data);
    self.cursor += data.len;
}

fn backspace(self: *Input) void {
    if (self.cursor == 0) return;

    if (self.tokenEndingAt(self.cursor)) |start| {
        self.text.replaceRange(self.allocator, start, self.cursor - start, &.{}) catch return;
        self.cursor = start;
        return;
    }

    const start = graphemeLeft(self.text.items, self.cursor);
    self.text.replaceRange(self.allocator, start, self.cursor - start, &.{}) catch return;
    self.cursor = start;
}

/// Start of the token ending exactly at `at`, if there is one.
fn tokenEndingAt(self: *const Input, at: usize) ?usize {
    for (self.tokens) |token| {
        if (token.len == 0 or token.len > at) continue;
        const start = at - token.len;
        if (std.mem.eql(u8, self.text.items[start..at], token)) return start;
    }
    return null;
}

/// Byte ranges of every held token in the draft, so the draw can style them.
fn tokenRanges(self: *const Input, arena: std.mem.Allocator) ![]const [2]usize {
    var ranges: std.ArrayList([2]usize) = .empty;
    for (self.tokens) |token| {
        if (token.len == 0) continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, self.text.items, from, token)) |at| {
            try ranges.append(arena, .{ at, at + token.len });
            from = at + token.len;
        }
    }
    return ranges.toOwnedSlice(arena);
}

fn inToken(ranges: []const [2]usize, offset: usize) bool {
    for (ranges) |range| {
        if (offset >= range[0] and offset < range[1]) return true;
    }
    return false;
}

fn deleteForward(self: *Input) void {
    if (self.cursor >= self.text.items.len) return;
    const end = graphemeRight(self.text.items, self.cursor);
    self.text.replaceRange(self.allocator, self.cursor, end - self.cursor, &.{}) catch return;
}

fn moveVertical(self: *Input, delta: isize) void {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(self.allocator);
    self.layout(0, &lines) catch return;

    const pos = self.cursorLineCol(lines.items);
    const target: isize = @as(isize, @intCast(pos.line)) + delta;
    if (target < 0 or target >= lines.items.len) return;
    const line = lines.items[@intCast(target)];
    self.cursor = self.byteOffsetAtCol(line, pos.col);
}

fn cursorLineCol(self: *const Input, lines: []const Line) struct { line: usize, col: u16 } {
    for (lines, 0..) |ln, i| {
        if (self.cursor >= ln.start and self.cursor <= ln.end) {
            return .{ .line = i, .col = width(self.text.items[ln.start..self.cursor]) };
        }
    }
    const last = lines[lines.len - 1];
    return .{ .line = lines.len - 1, .col = width(self.text.items[last.start..self.cursor]) };
}

fn byteOffsetAtCol(self: *const Input, line: Line, col: u16) usize {
    var iter = vaxis.unicode.graphemeIterator(self.text.items[line.start..line.end]);
    var w: u16 = 0;
    var off: usize = line.start;
    while (iter.next()) |g| {
        const bytes = g.bytes(self.text.items[line.start..line.end]);
        const gw = width(bytes);
        if (w + gw > col) return off;
        w += gw;
        off = line.start + g.start + g.len;
    }
    return line.end;
}

/// Compute wrapped lines. `max_width` of 0 means no wrapping.
///
/// Greedy wrapping that prefers to break at whitespace: a line ends at the last
/// space that fit on it, and that space belongs to the line it ends, so the
/// next line never opens with one. A token longer than the line itself has to
/// break somewhere, so it splits mid-word.
fn layout(self: *const Input, max_width: u16, lines: *std.ArrayList(Line)) !void {
    lines.clearRetainingCapacity();
    var iter = vaxis.unicode.graphemeIterator(self.text.items);
    var line_start: usize = 0;
    // `line_width` counts spaces like anything else; `word_width` is the part
    // after `break_at`, which carries to the next line when the break happens.
    var line_width: u16 = 0;
    var break_at: ?usize = null;
    var break_width: u16 = 0;
    var word_width: u16 = 0;
    while (iter.next()) |g| {
        const bytes = g.bytes(self.text.items);
        if (std.mem.eql(u8, bytes, "\n")) {
            try lines.append(self.allocator, .{ .start = line_start, .end = g.start, .width = line_width });
            line_start = g.start + g.len;
            line_width = 0;
            break_at = null;
            break_width = 0;
            word_width = 0;
            continue;
        }

        const gw = width(bytes);
        const space = isWrapSpace(bytes);

        if (!space and max_width > 0 and line_width + gw > max_width and line_width > 0) {
            if (break_at) |at| {
                try lines.append(self.allocator, .{ .start = line_start, .end = at, .width = break_width });
                line_start = at + 1;
                line_width = word_width;
            } else {
                try lines.append(self.allocator, .{ .start = line_start, .end = g.start, .width = line_width });
                line_start = g.start;
                line_width = 0;
            }
            break_at = null;
            break_width = 0;
            word_width = 0;
        }

        const before = line_width;
        line_width += gw;
        if (space and before > 0 and (max_width == 0 or before <= max_width)) {
            break_at = g.start;
            break_width = before;
            word_width = 0;
        } else {
            word_width += gw;
        }
    }
    try lines.append(self.allocator, .{ .start = line_start, .end = self.text.items.len, .width = line_width });
}

/// Whitespace a line may break at. Single byte, so a break can step over it.
fn isWrapSpace(bytes: []const u8) bool {
    return bytes.len == 1 and (bytes[0] == ' ' or bytes[0] == '\t');
}

/// Number of rows the text occupies when wrapped to `max_width`.
pub fn lineCount(self: *const Input, max_width: u16) u16 {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(self.allocator);
    self.layout(max_width, &lines) catch return 1;
    return @intCast(@min(@max(lines.items.len, 1), std.math.maxInt(u16)));
}

pub fn draw(self: *Input, ctx: vxfw.DrawContext) !vxfw.Surface {
    const max_width = ctx.max.width orelse 0;
    const height = @max(self.height, 1);

    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(self.allocator);
    try self.layout(max_width, &lines);

    const pos = self.cursorLineCol(lines.items);
    if (pos.line < self.scroll) self.scroll = pos.line;
    if (pos.line >= self.scroll + height) self.scroll = pos.line - height + 1;
    const max_scroll = if (lines.items.len > height) lines.items.len - height else 0;
    if (self.scroll > max_scroll) self.scroll = max_scroll;

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
        .width = max_width,
        .height = height,
    });
    const base: Cell = .{ .style = self.style };
    @memset(surface.buffer, base);

    if (self.text.items.len == 0 and self.placeholder.len > 0) {
        var col: u16 = 0;
        var hint = vaxis.unicode.graphemeIterator(self.placeholder);
        while (hint.next()) |g| {
            const bytes = g.bytes(self.placeholder);
            const gw = width(bytes);
            if (col + gw > max_width) break;
            surface.writeCell(col, 0, .{
                .char = .{ .grapheme = bytes, .width = @intCast(gw) },
                .style = self.placeholder_style,
            });
            col += gw;
        }
    }

    const ranges = try self.tokenRanges(ctx.arena);

    var row: u16 = 0;
    var i: usize = self.scroll;
    while (row < height and i < lines.items.len) : ({
        row += 1;
        i += 1;
    }) {
        const line = lines.items[i];
        var col: u16 = 0;
        var offset = line.start;
        var iter = vaxis.unicode.graphemeIterator(self.text.items[line.start..line.end]);
        while (iter.next()) |g| {
            const bytes = g.bytes(self.text.items[line.start..line.end]);
            const gw = width(bytes);
            if (col + gw > max_width) break;
            surface.writeCell(col, row, .{
                .char = .{ .grapheme = bytes, .width = @intCast(gw) },
                .style = if (inToken(ranges, offset)) self.token_style else self.style,
            });
            offset += bytes.len;
            col += gw;
        }
    }

    const cursor_row: u16 = @intCast(pos.line - self.scroll);
    surface.cursor = .{
        .row = cursor_row,
        .col = pos.col,
    };

    return surface;
}

fn width(bytes: []const u8) u16 {
    return vaxis.gwidth.gwidth(bytes, .unicode);
}

/// Whether the cursor sits on the draft's first or last line. Logical lines,
/// the same ones `moveVertical` steps through, so history navigation triggers
/// exactly where a further up or down would have nowhere to go.
pub fn onFirstLine(self: *const Input) bool {
    return std.mem.indexOfScalar(u8, self.text.items[0..self.cursor], '\n') == null;
}

pub fn onLastLine(self: *const Input) bool {
    return std.mem.indexOfScalar(u8, self.text.items[self.cursor..], '\n') == null;
}

/// Start of the word before `pos`: skip whatever separates words, then the word
/// itself.
fn wordLeft(text: []const u8, pos: usize) usize {
    var at = pos;
    while (at > 0 and isSeparator(text[at - 1])) at -= 1;
    while (at > 0 and !isSeparator(text[at - 1])) at -= 1;
    return at;
}

/// End of the word after `pos`.
fn wordRight(text: []const u8, pos: usize) usize {
    var at = pos;
    while (at < text.len and isSeparator(text[at])) at += 1;
    while (at < text.len and !isSeparator(text[at])) at += 1;
    return at;
}

/// Word motion stops at punctuation as well as whitespace, so `src/tui/app.zig`
/// is several stops rather than one.
fn isSeparator(c: u8) bool {
    if (std.ascii.isAlphanumeric(c) or c == '_') return false;
    return true;
}

fn graphemeLeft(text: []const u8, pos: usize) usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        if (g.start + g.len == pos) return g.start;
    }
    return pos;
}

fn graphemeRight(text: []const u8, pos: usize) usize {
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        if (g.start == pos) return g.start + g.len;
    }
    return pos;
}

test "backspace removes a held token in one press" {
    var input: Input = .init(std.testing.allocator);
    defer input.deinit();
    input.tokens = &.{"[Image 1]"};

    try input.insertText("look ");
    try input.insertText("[Image 1]");
    try std.testing.expectEqual(@as(usize, 14), input.cursor);

    input.backspace();
    try std.testing.expectEqualStrings("look ", input.text.items);

    input.backspace();
    try std.testing.expectEqualStrings("look", input.text.items);
}

test "word motion stops at word edges" {
    var input: Input = .init(std.testing.allocator);
    defer input.deinit();

    try input.insertText("hello world");
    try std.testing.expectEqual(@as(usize, 6), wordLeft(input.text.items, input.cursor));
    try std.testing.expectEqual(@as(usize, 0), wordLeft(input.text.items, 6));

    input.cursor = 0;
    try std.testing.expectEqual(@as(usize, 5), wordRight(input.text.items, 0));
    try std.testing.expectEqual(@as(usize, 11), wordRight(input.text.items, 5));

    input.clear();
    try input.insertText("src/tui/app.zig");
    try std.testing.expectEqual(@as(usize, 3), wordRight(input.text.items, 0));
    try std.testing.expectEqual(@as(usize, 7), wordRight(input.text.items, 3));
}

test "line edges are where history takes over" {
    var input: Input = .init(std.testing.allocator);
    defer input.deinit();

    try input.insertText("one\ntwo");
    try std.testing.expect(input.onLastLine());
    try std.testing.expect(!input.onFirstLine());

    input.cursor = 1;
    try std.testing.expect(input.onFirstLine());
    try std.testing.expect(!input.onLastLine());
}

test "wrapping breaks on whitespace, not mid-word" {
    var input: Input = .init(std.testing.allocator);
    defer input.deinit();

    try input.insertText("hello world");
    try std.testing.expectEqual(@as(u16, 2), input.lineCount(5));
    try std.testing.expectEqual(@as(u16, 1), input.lineCount(11));

    input.clear();
    try input.insertText("the quick brown fox");
    try std.testing.expectEqual(@as(u16, 1), input.lineCount(19));
    try std.testing.expectEqual(@as(u16, 2), input.lineCount(16));
    try std.testing.expectEqual(@as(u16, 2), input.lineCount(10));
    try std.testing.expectEqual(@as(u16, 4), input.lineCount(5));

    input.clear();
    try input.insertText("supercalifragilistic");
    try std.testing.expectEqual(@as(u16, 4), input.lineCount(5));
    try std.testing.expectEqual(@as(u16, 1), input.lineCount(20));
}

test "a wrapped line is as wide as it says, and no wider than the field" {
    const testing = std.testing;
    var input: Input = .init(testing.allocator);
    defer input.deinit();
    try input.insertText("the quick brown fox jumps over it");

    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(testing.allocator);
    try input.layout(12, &lines);
    try testing.expect(lines.items.len > 1);

    var at: usize = 0;
    for (lines.items) |line| {
        try testing.expectEqual(width(input.text.items[line.start..line.end]), line.width);
        try testing.expect(line.width <= 12);
        try testing.expect(input.text.items[line.start] != ' ');

        try testing.expect(line.start == at or line.start == at + 1);
        at = line.end;
    }
    try testing.expectEqual(input.text.items.len, at);
}

test "the placeholder is drawn by the field, not under it" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var input: Input = .init(testing.allocator);
    defer input.deinit();
    input.height = 1;
    input.placeholder = "Search";

    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 20, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const empty = try input.draw(ctx);
    try testing.expectEqualStrings("S", empty.buffer[0].char.grapheme);
    try testing.expectEqualStrings("h", empty.buffer[5].char.grapheme);

    try input.insertText("q");
    const typed = try input.draw(ctx);
    try testing.expectEqualStrings("q", typed.buffer[0].char.grapheme);
    try testing.expectEqualStrings(" ", typed.buffer[5].char.grapheme);
}

test "a placeholder wider than the field is cut, not wrapped" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var input: Input = .init(testing.allocator);
    defer input.deinit();
    input.height = 1;
    input.placeholder = "leave empty to keep the stored key";

    const surface = try input.draw(.{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 8, .height = 1 },
        .cell_size = .{ .width = 10, .height = 20 },
    });

    try testing.expectEqual(@as(usize, 8), surface.buffer.len);
    try testing.expectEqualStrings("l", surface.buffer[0].char.grapheme);
    try testing.expectEqualStrings("m", surface.buffer[7].char.grapheme);
}

test "ctrl+c empties the field" {
    const testing = std.testing;

    var input: Input = .init(testing.allocator);
    defer input.deinit();
    try input.insertText("sk-mistyped");

    var ctx: vxfw.EventContext = .{
        .phase = .at_target,
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(testing.allocator);

    try input.handleEvent(&ctx, .{ .key_press = .{ .codepoint = 'c', .mods = .{ .ctrl = true } } });

    try testing.expectEqualStrings("", input.text.items);
    try testing.expectEqual(@as(usize, 0), input.cursor);
    try testing.expect(ctx.consume_event);
}
