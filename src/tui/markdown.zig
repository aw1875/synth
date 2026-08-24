//! Just enough markdown to render what a model actually emits: emphasis,
//! inline code, headings, bullets, and fenced code blocks.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const syntax = @import("syntax.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

/// Blank rows between a code fence and the prose around it.
const code_gap: u16 = 1;
/// Horizontal padding inside a code panel.
const code_pad: u16 = 2;

pub const Block = union(enum) {
    /// Styled prose, soft-wrapped by `RichText`.
    text: []const Cell.Segment,
    /// A fenced code block, highlighted and soft-wrapped.
    code: Code,
    /// A pipe table, aligned into columns.
    table: Table,
};

pub const Code = struct {
    language: []const u8,
    lines: []const []const u8,
};

pub const Table = struct {
    /// Cells, row-major, `columns` per row. The first row is the header.
    cells: []const []const u8,
    columns: usize,
};

/// Parse `source` into blocks. Everything returned borrows from `source` or is
/// allocated in `arena`.
pub fn parse(
    arena: std.mem.Allocator,
    source: []const u8,
    base: Cell.Style,
) ![]const Block {
    var blocks: std.ArrayList(Block) = .empty;
    var spans: std.ArrayList(Cell.Segment) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    var pending_newline = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");

        if (fenceLanguage(trimmed)) |language| {
            if (spans.items.len > 0) {
                try blocks.append(arena, .{ .text = try spans.toOwnedSlice(arena) });
                spans = .empty;
            }
            pending_newline = false;

            var code: std.ArrayList([]const u8) = .empty;
            while (lines.next()) |code_line| {
                const code_trimmed = std.mem.trimEnd(u8, code_line, "\r");
                if (fenceLanguage(code_trimmed) != null) break;
                try code.append(arena, code_trimmed);
            }
            try blocks.append(arena, .{ .code = .{
                .language = language,
                .lines = try code.toOwnedSlice(arena),
            } });
            continue;
        }

        if (tableRow(arena, trimmed)) |header| {
            if (lines.peek()) |next| {
                if (isTableSeparator(std.mem.trimEnd(u8, next, "\r"))) {
                    _ = lines.next();
                    if (spans.items.len > 0) {
                        try blocks.append(arena, .{ .text = try spans.toOwnedSlice(arena) });
                        spans = .empty;
                    }
                    pending_newline = false;
                    try blocks.append(arena, .{ .table = try parseTable(arena, header, &lines) });
                    continue;
                }
            }
        }

        if (pending_newline) try spans.append(arena, .{ .text = "\n", .style = base });
        try appendLine(arena, &spans, trimmed, base);
        pending_newline = true;
    }

    if (spans.items.len > 0) {
        try blocks.append(arena, .{ .text = try spans.toOwnedSlice(arena) });
    }

    return blocks.toOwnedSlice(arena);
}

/// Returns the language tag when `line` opens or closes a fence, else null.
fn fenceLanguage(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, trimmed, "```")) return null;
    return std.mem.trim(u8, trimmed[3..], " \t");
}

/// The cells of a pipe-table row, or null when `line` is not a table row. A
/// row must start and end with `|`; interior pipes separate cells. Cells are
/// allocated in `arena`.
fn tableRow(arena: std.mem.Allocator, line: []const u8) ?[]const []const u8 {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len < 2 or trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return null;
    return splitTableRow(arena, trimmed[1 .. trimmed.len - 1]) catch null;
}

/// Split the interior of a table row on `|`, trimming each cell.
fn splitTableRow(arena: std.mem.Allocator, interior: []const u8) ![]const []const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, interior, '|');
    while (it.next()) |cell| {
        try cells.append(arena, std.mem.trim(u8, cell, " "));
    }
    return cells.toOwnedSlice(arena);
}

/// `|---|` or `| :--- |` - the separator row under a table header.
fn isTableSeparator(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len < 2 or trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return false;
    const interior = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " ");
    if (interior.len == 0) return false;
    for (interior) |c| {
        if (c != '-' and c != ':' and c != '|' and c != ' ') return false;
    }
    return std.mem.indexOfScalar(u8, interior, '-') != null;
}

/// Consume the data rows of a table, starting after the separator. The header
/// row's cells are already owned by `arena`; data rows are appended after them.
/// Rows with fewer cells than the header are padded with empty cells, and extra
/// cells are dropped, so every row lines up.
fn parseTable(
    arena: std.mem.Allocator,
    header: []const []const u8,
    lines: *std.mem.SplitIterator(u8, .scalar),
) !Table {
    var cells: std.ArrayList([]const u8) = .empty;
    try cells.appendSlice(arena, header);

    while (lines.peek()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        const row = tableRow(arena, trimmed) orelse break;
        _ = lines.next();

        var col: usize = 0;
        while (col < header.len) : (col += 1) {
            try cells.append(arena, if (col < row.len) row[col] else "");
        }
    }

    return .{
        .cells = try cells.toOwnedSlice(arena),
        .columns = header.len,
    };
}

/// Emit one line of prose, handling headings and bullets before falling
/// through to inline formatting.
fn appendLine(
    arena: std.mem.Allocator,
    spans: *std.ArrayList(Cell.Segment),
    line: []const u8,
    base: Cell.Style,
) !void {
    const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
    const body = line[indent..];

    if (headingLevel(body)) |level| {
        const text = std.mem.trimStart(u8, body[level..], " ");
        try spans.append(arena, .{
            .text = text,
            .style = bold(withColor(base, theme.fg)),
        });
        return;
    }

    if (bulletBody(body)) |rest| {
        if (indent > 0) try spans.append(arena, .{ .text = line[0..indent], .style = base });
        try spans.append(arena, .{ .text = "• ", .style = withColor(base, theme.accent) });
        try appendInline(arena, spans, rest, base);
        return;
    }

    if (indent > 0) try spans.append(arena, .{ .text = line[0..indent], .style = base });
    try appendInline(arena, spans, body, base);
}

fn headingLevel(line: []const u8) ?usize {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level >= line.len or line[level] != ' ') return null;
    return level;
}

/// `- item`, `* item`, or `1. item` -> the text after the marker.
fn bulletBody(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
        return line[2..];
    }
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' ') {
        return line[i + 2 ..];
    }
    return null;
}

/// Scan for `` `code` ``, `**bold**`, `*italic*`, `[label](url)` links, and
/// bare URLs. An unmatched delimiter is emitted literally rather than
/// swallowing the rest of the line.
fn appendInline(
    arena: std.mem.Allocator,
    spans: *std.ArrayList(Cell.Segment),
    line: []const u8,
    base: Cell.Style,
) !void {
    var i: usize = 0;
    var plain_start: usize = 0;

    while (i < line.len) {
        if (line[i] == '[') {
            if (linkAt(line[i..])) |link| {
                if (i > plain_start) {
                    try spans.append(arena, .{ .text = line[plain_start..i], .style = base });
                }
                try spans.append(arena, .{
                    .text = link.label,
                    .style = linkStyle(base),
                    .link = .{ .uri = link.url },
                });
                i += link.len;
                plain_start = i;
                continue;
            }
        }

        if (bareUrlAt(line[i..])) |url| {
            if (i > plain_start) {
                try spans.append(arena, .{ .text = line[plain_start..i], .style = base });
            }
            try spans.append(arena, .{
                .text = url,
                .style = linkStyle(base),
                .link = .{ .uri = url },
            });
            i += url.len;
            plain_start = i;
            continue;
        }

        const marker: ?struct { delim: []const u8, style: Cell.Style } =
            if (line[i] == '`')
                .{ .delim = "`", .style = codeStyle(base) }
            else if (std.mem.startsWith(u8, line[i..], "**"))
                .{ .delim = "**", .style = bold(base) }
            else if (std.mem.startsWith(u8, line[i..], "__"))
                .{ .delim = "__", .style = bold(base) }
            else if (line[i] == '*' or line[i] == '_')
                .{ .delim = line[i .. i + 1], .style = italic(base) }
            else
                null;

        const found = marker orelse {
            i += 1;
            continue;
        };

        const content_start = i + found.delim.len;
        const end = std.mem.indexOfPos(u8, line, content_start, found.delim) orelse {
            i += found.delim.len;
            continue;
        };
        if (end == content_start) {
            i = end + found.delim.len;
            continue;
        }

        if (i > plain_start) {
            try spans.append(arena, .{ .text = line[plain_start..i], .style = base });
        }
        try spans.append(arena, .{ .text = line[content_start..end], .style = found.style });

        i = end + found.delim.len;
        plain_start = i;
    }

    if (plain_start < line.len) {
        try spans.append(arena, .{ .text = line[plain_start..], .style = base });
    }
}

fn bold(base: Cell.Style) Cell.Style {
    var out = base;
    out.bold = true;
    return out;
}

fn italic(base: Cell.Style) Cell.Style {
    var out = base;
    out.italic = true;
    return out;
}

fn withColor(base: Cell.Style, color: Cell.Color) Cell.Style {
    var out = base;
    out.fg = color;
    return out;
}

fn codeStyle(base: Cell.Style) Cell.Style {
    var out = base;
    out.fg = theme.success;
    return out;
}

fn linkStyle(base: Cell.Style) Cell.Style {
    var out = base;
    out.fg = theme.accent_alt;
    out.ul_style = .single;
    return out;
}

const Link = struct {
    /// The text shown in place of the whole `[label](url)`.
    label: []const u8,
    /// Where it points. Borrowed from the source, which outlives the draw.
    url: []const u8,
    /// Bytes consumed from the start of the match, including both delimiters.
    len: usize,
};

/// `[label](url)` at the start of `line`, else null. The URL may be empty but
/// the label may not; an unmatched `[` is left for the caller to treat as
/// plain text.
fn linkAt(line: []const u8) ?Link {
    if (line.len < 2 or line[0] != '[') return null;
    const close = std.mem.indexOfScalarPos(u8, line, 1, ']') orelse return null;
    if (close == 1) return null;
    if (close + 1 >= line.len or line[close + 1] != '(') return null;

    const url_start = close + 2;
    const url_end = std.mem.indexOfScalarPos(u8, line, url_start, ')') orelse return null;

    return .{
        .label = line[1..close],
        .url = line[url_start..url_end],
        .len = url_end + 1,
    };
}

/// A bare `http://` or `https://` URL at the start of `line`, or null.
fn bareUrlAt(line: []const u8) ?[]const u8 {
    const scheme = if (std.mem.startsWith(u8, line, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, line, "http://"))
        "http://".len
    else
        return null;

    var end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    while (end > scheme) : (end -= 1) {
        switch (line[end - 1]) {
            '.', ',', ';', ':', '!', '?', ')', ']', '}', '"', '\'', '>' => {},
            else => break,
        }
    }
    if (end <= scheme) return null;
    return line[0..end];
}

/// Parse and draw `source`, stacking the blocks vertically. The returned
/// surface is exactly as tall as its content.
pub fn draw(
    ctx: vxfw.DrawContext,
    widget: vxfw.Widget,
    source: []const u8,
    base: Cell.Style,
    width: u16,
) !vxfw.Surface {
    const blocks = try parse(ctx.arena, source, base);

    var surfaces: std.ArrayList(vxfw.Surface) = .empty;
    for (blocks) |block| {
        switch (block) {
            .text => |spans| {
                const text = try ctx.arena.create(vxfw.RichText);
                text.* = .{ .text = spans, .base_style = base, .width_basis = .parent };
                try surfaces.append(ctx.arena, try text.widget().draw(
                    ctx.withConstraints(
                        .{ .width = width },
                        .{ .width = width, .height = w.maxRows(width) },
                    ),
                ));
            },
            .code => |code| try surfaces.append(ctx.arena, try drawCode(ctx, widget, code, width)),
            .table => |table| try surfaces.append(ctx.arena, try drawTable(ctx, widget, table, width, base)),
        }
    }

    var height: u16 = 0;
    for (surfaces.items) |surface| height +|= surface.size.height;

    const container = try w.surfaceClamped(ctx.arena, widget, .{
        .width = width,
        .height = height,
    });
    w.fill(container, base);

    const children = try ctx.arena.alloc(vxfw.SubSurface, surfaces.items.len);
    var row: u16 = 0;
    for (surfaces.items, children) |surface, *child| {
        child.* = .{ .origin = .{ .row = @intCast(row), .col = 0 }, .surface = surface };
        row += surface.size.height;
    }

    return .{
        .size = container.size,
        .widget = container.widget,
        .buffer = container.buffer,
        .children = children,
    };
}

/// One row of a drawn code block: pieces of a source line, already cut to the
/// panel's width.
const CodeRow = struct {
    pieces: []const Piece,
    /// Whether this row is the tail of a line that did not fit.
    continued: bool,

    const Piece = struct {
        /// Column inside the code area, not on the surface.
        col: u16,
        text: []const u8,
        kind: syntax.Kind,
    };
};

/// A code fence: its own background, padded, highlighted, and soft-wrapped.
fn drawCode(ctx: vxfw.DrawContext, widget: vxfw.Widget, code: Code, width: u16) !vxfw.Surface {
    const has_label = code.language.len > 0;
    const inner = width -| (code_pad * 2);
    if (inner == 0) return .empty(widget);

    const rows = try codeRows(ctx.arena, code, inner);
    const body_rows: u16 = @intCast(@min(rows.len, std.math.maxInt(u16) - 4));
    const height = code_gap * 2 + body_rows + @as(u16, if (has_label) 1 else 0);

    const surface = try w.surfaceClamped(ctx.arena, widget, .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.base.cell);

    var row: u16 = code_gap;
    if (has_label) {
        fillRow(surface, row, theme.on_card(theme.fg_dim).cell);
        _ = w.writeText(surface, code_pad, row, code.language, theme.on_card(theme.fg_dim).cell);
        row += 1;
    }

    const base = theme.on_card(theme.fg).cell;
    for (rows) |line| {
        if (row >= surface.size.height) break;
        fillRow(surface, row, base);

        if (line.continued) {
            _ = w.writeText(surface, code_pad -| 1, row, "↳", theme.on_card(theme.fg_dim).cell);
        }
        for (line.pieces) |piece| {
            _ = w.writeText(surface, code_pad + piece.col, row, piece.text, piece.kind.style(base));
        }
        row += 1;
    }

    return surface;
}

/// Highlight every line of `code` and cut the result into rows of `width`.
fn codeRows(arena: std.mem.Allocator, code: Code, width: u16) ![]const CodeRow {
    var rows: std.ArrayList(CodeRow) = .empty;
    var state: syntax.State = .{};
    const language = syntax.fromLabel(code.language);

    for (code.lines) |line| {
        const spans = try syntax.highlight(arena, language, line, &state);

        var pieces: std.ArrayList(CodeRow.Piece) = .empty;
        var col: u16 = 0;
        var continued = false;

        for (spans) |span| {
            var rest = span.text;
            while (rest.len > 0) {
                const room = width - col;
                const cut = takeWidth(rest, room);
                if (cut > 0) {
                    try pieces.append(arena, .{ .col = col, .text = rest[0..cut], .kind = span.kind });
                    col += w.textWidth(rest[0..cut]);
                    rest = rest[cut..];
                }
                if (rest.len == 0) break;

                try rows.append(arena, .{ .pieces = try pieces.toOwnedSlice(arena), .continued = continued });
                pieces = .empty;
                col = 0;
                continued = true;
            }
        }

        try rows.append(arena, .{ .pieces = try pieces.toOwnedSlice(arena), .continued = continued });
    }

    return rows.toOwnedSlice(arena);
}

/// Bytes of `text` that fit in `room` columns, cut on a grapheme boundary. Zero
/// when even the first grapheme is too wide, which is what tells the caller to
/// start a new row.
fn takeWidth(text: []const u8, room: u16) usize {
    var taken: usize = 0;
    var used: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const cells: u16 = @intCast(vaxis.gwidth.gwidth(bytes, .unicode));
        if (used + cells > room) break;
        used += cells;
        taken += bytes.len;
    }
    return taken;
}

/// A pipe table: bold header on a tinted row, dim divider line under it, and
/// thin vertical gutters between columns so cells read as separate. Column
/// widths are sized to the widest cell in each column.
fn drawTable(ctx: vxfw.DrawContext, widget: vxfw.Widget, table: Table, width: u16, base: Cell.Style) !vxfw.Surface {
    const rows = table.cells.len / table.columns;
    const height: u16 = if (rows == 0) 0 else @intCast(@min(rows + 1, std.math.maxInt(u16)));

    const surface = try w.surfaceClamped(ctx.arena, widget, .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.base.cell);

    const col_widths = try ctx.arena.alloc(u16, table.columns);
    @memset(col_widths, 0);
    for (table.cells, 0..) |cell, i| {
        const col = i % table.columns;
        col_widths[col] = @max(col_widths[col], w.textWidth(cell));
    }

    const header_fill = theme.on_card(theme.fg_dim);
    const divider_style = withColor(base, theme.fg_dim);
    const gutter_style = withColor(base, theme.fg_dim);
    const header_cell = vaxis.Cell{
        .style = theme.on_card(theme.fg).bold().cell,
        .char = .{ .grapheme = " ", .width = 1 },
    };
    const body_cell = vaxis.Cell{
        .style = base,
        .char = .{ .grapheme = " ", .width = 1 },
    };
    const divider_cell = vaxis.Cell{
        .style = divider_style,
        .char = .{ .grapheme = "─", .width = 1 },
    };
    const gutter_cell = vaxis.Cell{
        .style = gutter_style,
        .char = .{ .grapheme = "│", .width = 1 },
    };

    const drawRow = struct {
        cells_in_row: []const []const u8,
        widths: []const u16,
        cols: usize,
        text_style: Cell.Style,
        bg_cell: vaxis.Cell,
        gutter: vaxis.Cell,
        pub fn draw(self: @This(), surf: vxfw.Surface, row_idx: u16) void {
            var x: u16 = 0;
            var col: usize = 0;
            while (col < self.cols) : (col += 1) {
                if (col > 0) {
                    if (x < surf.size.width) surf.writeCell(x, row_idx, self.gutter);
                    x += 1;
                }
                if (x < surf.size.width) surf.writeCell(x, row_idx, self.bg_cell);
                const written = w.writeText(surf, x, row_idx, self.cells_in_row[col], self.text_style);
                const written_width = written - x;
                var pad: u16 = 0;
                while (pad < self.widths[col] +% 1 -% written_width) : (pad += 1) {
                    const px = x + written_width + pad;
                    if (px < surf.size.width) surf.writeCell(px, row_idx, self.bg_cell);
                }
                x += self.widths[col] + 1;
            }
        }
    };

    {
        var x: u16 = 0;
        var col: usize = 0;
        while (col < table.columns) : (col += 1) {
            if (col > 0) {
                if (x < surface.size.width) surface.writeCell(x, 1, gutter_cell);
                x += 1;
            }
            var k: u16 = 0;
            while (k < col_widths[col] + 1) : (k += 1) {
                if (x < surface.size.width) surface.writeCell(x, 1, divider_cell);
                x += 1;
            }
        }
    }

    const data_rows = rows - 1;
    const row0_cells = table.cells[0..table.columns];

    w.fillRow(surface, 0, 0, width, header_fill.cell);
    const header_row = drawRow{
        .cells_in_row = row0_cells,
        .widths = col_widths,
        .cols = table.columns,
        .text_style = theme.on_card(theme.fg).bold().cell,
        .bg_cell = header_cell,
        .gutter = gutter_cell,
    };
    header_row.draw(surface, 0);

    var data_row: usize = 0;
    while (data_row < data_rows) : (data_row += 1) {
        const start = (data_row + 1) * table.columns;
        const end = start + table.columns;
        const surf_row: u16 = @intCast(data_row + 2);
        if (surf_row >= height) break;

        const body_row = drawRow{
            .cells_in_row = table.cells[start..end],
            .widths = col_widths,
            .cols = table.columns,
            .text_style = base,
            .bg_cell = body_cell,
            .gutter = gutter_cell,
        };
        body_row.draw(surface, surf_row);
    }

    return surface;
}

fn fillRow(surface: vxfw.Surface, row: u16, style: Cell.Style) void {
    var col: u16 = 0;
    while (col < surface.size.width) : (col += 1) {
        surface.writeCell(col, row, .{ .style = style });
    }
}

fn expectSpans(source: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(arena.allocator(), source, .{});
    try std.testing.expectEqual(@as(usize, 1), blocks.len);

    const spans = blocks[0].text;
    try std.testing.expectEqual(expected.len, spans.len);
    for (expected, spans) |want, got| {
        try std.testing.expectEqualStrings(want, got.text);
    }
}

test "inline emphasis and code split into spans" {
    try expectSpans("a **b** c", &.{ "a ", "b", " c" });
    try expectSpans("use `zig build` now", &.{ "use ", "zig build", " now" });
}

test "unmatched delimiters stay literal" {
    try expectSpans("2 * 3 is 6", &.{"2 * 3 is 6"});
    try expectSpans("a `unclosed", &.{"a `unclosed"});
}

test "a link carries its URL, so the terminal can open it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(arena.allocator(), "see [the docs](https://ziglang.org/x) now", .{});
    const spans = blocks[0].text;

    try std.testing.expectEqualStrings("the docs", spans[1].text);
    try std.testing.expectEqualStrings("https://ziglang.org/x", spans[1].link.uri);
    try std.testing.expectEqualStrings("", spans[0].link.uri);
    try std.testing.expectEqualStrings("", spans[2].link.uri);
}

test "a bare URL becomes a link of its own" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(arena.allocator(), "docs at https://ziglang.org/learn, or not", .{});
    const spans = blocks[0].text;

    try std.testing.expectEqualStrings("docs at ", spans[0].text);
    try std.testing.expectEqualStrings("https://ziglang.org/learn", spans[1].text);
    try std.testing.expectEqualStrings("https://ziglang.org/learn", spans[1].link.uri);
    try std.testing.expectEqualStrings(", or not", spans[2].text);

    try std.testing.expectEqualStrings("http://a.b/c", bareUrlAt("http://a.b/c)").?);
    try std.testing.expect(bareUrlAt("ftp://a.b") == null);
    try std.testing.expect(bareUrlAt("https://") == null);
}

test "links render their label underlined" {
    try expectSpans("see [the docs](https://x) now", &.{ "see ", "the docs", " now" });
    try expectSpans("[bare](url)", &.{"bare"});
    try expectSpans("a [b c", &.{"a [b c"});
    try expectSpans("[a * b](url)", &.{"a * b"});
}

test "nested bullets keep their indent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(arena.allocator(), "- one\n  - two", .{});
    const spans = blocks[0].text;

    try std.testing.expectEqualStrings("• ", spans[0].text);
    try std.testing.expectEqualStrings("one", spans[1].text);
    try std.testing.expectEqualStrings("\n", spans[2].text);
    try std.testing.expectEqualStrings("  ", spans[3].text);
    try std.testing.expectEqualStrings("• ", spans[4].text);
    try std.testing.expectEqualStrings("two", spans[5].text);
}

test "pipe tables become their own block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(
        arena.allocator(),
        "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    const table = blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), table.columns);
    try std.testing.expectEqual(@as(usize, 6), table.cells.len);
    try std.testing.expectEqualStrings("a", table.cells[0]);
    try std.testing.expectEqualStrings("b", table.cells[1]);
    try std.testing.expectEqualStrings("1", table.cells[2]);
    try std.testing.expectEqualStrings("2", table.cells[3]);
    try std.testing.expectEqualStrings("3", table.cells[4]);
    try std.testing.expectEqualStrings("4", table.cells[5]);
}

test "a lone pipe row is prose, not a table" {
    try expectSpans("| not a table", &.{"| not a table"});
}

test "headings and bullets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(arena.allocator(), "# Title\n- one\n2. two", .{});
    const spans = blocks[0].text;

    try std.testing.expectEqualStrings("Title", spans[0].text);
    try std.testing.expect(spans[0].style.bold);
    try std.testing.expectEqualStrings("\n", spans[1].text);
    try std.testing.expectEqualStrings("• ", spans[2].text);
    try std.testing.expectEqualStrings("one", spans[3].text);
    try std.testing.expectEqualStrings("• ", spans[5].text);
    try std.testing.expectEqualStrings("two", spans[6].text);
}

test "fenced code becomes its own block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(
        arena.allocator(),
        "before\n```zig\nconst x = 1;\nconst y = 2;\n```\nafter",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("before", blocks[0].text[0].text);
    try std.testing.expectEqualStrings("zig", blocks[1].code.language);
    try std.testing.expectEqual(@as(usize, 2), blocks[1].code.lines.len);
    try std.testing.expectEqualStrings("const x = 1;", blocks[1].code.lines[0]);
    try std.testing.expectEqualStrings("after", blocks[2].text[0].text);
}

test "unterminated fence runs to the end, as a streaming reply would" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const blocks = try parse(arena.allocator(), "```\npartial line", .{});
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("partial line", blocks[0].code.lines[0]);
}

test "a long code line wraps instead of being clipped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code: Code = .{
        .language = "zig",
        .lines = &.{ "const value = 1234567890;", "x" },
    };
    const rows = try codeRows(arena, code, 10);

    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expect(!rows[0].continued);
    try std.testing.expect(rows[1].continued);
    try std.testing.expect(rows[2].continued);
    try std.testing.expect(!rows[3].continued);

    var rebuilt: std.ArrayList(u8) = .empty;
    for (rows[0..3]) |row| {
        for (row.pieces) |piece| try rebuilt.appendSlice(arena, piece.text);
    }
    try std.testing.expectEqualStrings("const value = 1234567890;", rebuilt.items);

    for (rows) |row| {
        var used: u16 = 0;
        for (row.pieces) |piece| used += w.textWidth(piece.text);
        try std.testing.expect(used <= 10);
    }
}

test "a wrap splits a span without losing its colour" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code: Code = .{ .language = "zig", .lines = &.{"// a longer note"} };
    const rows = try codeRows(arena, code, 8);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(syntax.Kind.comment, rows[0].pieces[0].kind);
    try std.testing.expectEqual(syntax.Kind.comment, rows[1].pieces[0].kind);
    try std.testing.expectEqualStrings("// a lon", rows[0].pieces[0].text);
    try std.testing.expectEqualStrings("ger note", rows[1].pieces[0].text);
}

test "a code panel is drawn highlighted, wrapped and marked" {
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

    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 12, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try drawCode(ctx, widget, .{ .language = "zig", .lines = &.{"const x = 1;"} }, 12);

    const code_row = 2;
    const keyword = surface.buffer[code_row * 12 + code_pad];
    try std.testing.expectEqualStrings("c", keyword.char.grapheme);
    try std.testing.expectEqual(theme.accent, keyword.style.fg);

    const marker = surface.buffer[(code_row + 1) * 12 + code_pad - 1];
    try std.testing.expectEqualStrings("↳", marker.char.grapheme);
    const number = surface.buffer[(code_row + 1) * 12 + code_pad + 2];
    try std.testing.expectEqualStrings("1", number.char.grapheme);
    try std.testing.expectEqual(theme.warning, number.style.fg);
}

test "a drawn link reaches the cells as an OSC 8 hyperlink" {
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

    const ctx: vxfw.DrawContext = .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = 40, .height = 10 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    const surface = try draw(ctx, widget, "go [here](https://example.com) now", .{}, 40);
    const text = surface.children[0].surface;

    try std.testing.expectEqualStrings("h", text.buffer[3].char.grapheme);
    try std.testing.expectEqualStrings("https://example.com", text.buffer[3].link.uri);
    try std.testing.expectEqualStrings("", text.buffer[2].link.uri);
}
