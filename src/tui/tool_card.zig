//! A tool call in the transcript: name, arguments, and its output.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Conversation = @import("../core/conversation.zig");
const diff = @import("diff.zig");
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const w = @import("widgets.zig");

const ToolCard = @This();

/// Result rows shown when expanded, before the output is truncated.
const max_body_rows: u16 = 20;
/// Diff rows shown collapsed, and expanded.
const collapsed_diff_rows: usize = 8;
const expanded_diff_rows: usize = 60;
/// Column the rule sits in: one level in from the reply that made the call, so
/// it lands where that reply's text is and reads as nested under it.
const rule_col: u16 = w.nest;
/// Column a call's own text starts at, a level in again from its rule.
const text_col: u16 = w.nest * 2;
/// Column output starts at, one clear of the box edge it sits inside.
const body_col: u16 = text_col + 2;
/// Rows of the app's own ground above and below the box, so it reads as a thing
/// set down under the call rather than as more of the call.
const box_margin: u16 = 1;
/// Row the box starts on: below the header, clear of the margin.
const box_row: u16 = 1 + box_margin;
/// How a call reports itself: one mark, coloured by how it went.
const dot = "\u{25cf}";

/// Borrowed from the conversation and refreshed every frame, since the
/// conversation owns this memory and may have reallocated it.
name: []const u8 = "",
arguments: []const u8 = "",
result: ?[]const u8 = null,
/// What the call says it is doing, while it is still doing it. Shown in place
/// of the summary line so a tool that runs for minutes says something other
/// than its own name.
note: ?[]const u8 = null,
status: Conversation.ToolCall.Status = .pending,
/// Line the diff starts at in the file, resolved by the app from the file on
/// disk. 1 when it could not be worked out.
start_line: usize = 1,

expanded: bool = false,
has_mouse: bool = false,
/// Set when this call left a subagent transcript, so the card opens it rather
/// than unfolding in place.
open: ?Open = null,
/// Set during the draw: a diff card is expandable even before it has a result,
/// since what is worth expanding is the change, not the output.
capped: bool = false,

/// How a card hands a click back to whoever can act on it.
///
/// A direct call rather than a flag polled later: an idle app schedules no
/// ticks, so a flag would sit raised until something else woke the loop.
pub const Open = struct {
    userdata: *anyopaque,
    key: u64,
    /// The message this call belongs to, for finding its stored transcript.
    seq: u64,
    /// Where the call sits in its message, which is how a run still going is
    /// found: it is not in the database yet to be looked up by key.
    index: usize,
    call: *const fn (*anyopaque, u64, u64, usize, []const u8) void,
};

pub fn widget(self: *ToolCard) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ToolCard = @ptrCast(@alignCast(ptr));
    switch (event) {
        .mouse => |mouse| {
            switch (mouse.button) {
                .wheel_up, .wheel_down, .wheel_left, .wheel_right => return,
                .left => {},
                else => return ctx.consumeEvent(),
            }
            if (mouse.type != .press) return;
            if (self.open) |open| {
                open.call(open.userdata, open.key, open.seq, open.index, self.name);
                return ctx.consumeAndRedraw();
            }
            if (self.result != null or self.capped) {
                self.expanded = !self.expanded;
                return ctx.consumeAndRedraw();
            }
        },
        .mouse_enter => {
            self.has_mouse = true;
            try ctx.setMouseShape(.pointer);
            return ctx.consumeAndRedraw();
        },
        .mouse_leave => {
            self.has_mouse = false;
            try ctx.setMouseShape(.default);
            ctx.redraw = true;
        },
        else => {},
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *ToolCard = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *ToolCard, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const width = ctx.max.width orelse 0;
    if (width <= text_col + 2) return .empty(self.widget());

    if (try diff.change(ctx.arena, self.name, self.arguments)) |change| {
        return self.drawDiff(ctx, change, width);
    }
    self.capped = false;

    // Collapsed, a call is one line; the output is what expanding is for.
    const body = if (self.expanded) try self.bodyLines(ctx.arena, width) else &.{};
    const boxed: u16 = if (body.len > 0) 2 + box_margin * 2 else 0;
    const height: u16 = 1 + @as(u16, @intCast(body.len)) + boxed;

    const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.base.cell);
    drawRule(surface, height);
    self.drawHeader(surface, width, try summarize(ctx.arena, self.name, self.arguments));

    if (body.len == 0) return surface;

    drawBox(surface, box_row, @intCast(body.len), width);
    const body_style = if (self.status == .failed)
        theme.on(theme.surface_alt, theme.danger)
    else
        theme.on(theme.surface_alt, theme.fg_muted);

    for (body, 0..) |line, i| {
        const row: u16 = box_row + 1 + @as(u16, @intCast(i));
        _ = w.writeText(surface, body_col, row, clip(line, width -| (body_col + 2)), body_style.cell);
    }

    return surface;
}

/// The rule a call hangs off, one step in from the margin. Neutral: what the
/// call is doing is the dot's job, and a rule that changed colour with it would
/// repeat the same fact loudly.
fn drawRule(surface: vxfw.Surface, height: u16) void {
    for (0..height) |row| {
        surface.writeCell(rule_col, @intCast(row), .{
            .char = .{ .grapheme = w.solid_rule, .width = 1 },
            .style = .{ .fg = theme.border, .bg = theme.bg },
        });
    }
}

/// The box output sits in, drawn from `top` around `rows` of content.
///
/// The rules carry the box's own ground rather than the app's. A rule glyph is
/// centred in its cell, so the half of that cell facing the contents is painted
/// too: on the app's ground it reads as a gap between the box and its edge.
fn drawBox(surface: vxfw.Surface, top: u16, rows: u16, width: u16) void {
    const right = width -| 1;
    if (right <= text_col) return;

    const edge = theme.on(theme.surface_alt, theme.border).cell;
    const inner = theme.on(theme.surface_alt, theme.fg_muted).cell;
    const bottom = top + rows + 1;

    for (0..rows + 2) |i| {
        const row = top + @as(u16, @intCast(i));
        w.fillRow(surface, row, text_col, width -| text_col, inner);

        const corners: [2][]const u8, const span: []const u8 = if (row == top)
            .{ .{ "\u{250c}", "\u{2510}" }, "\u{2500}" }
        else if (row == bottom)
            .{ .{ "\u{2514}", "\u{2518}" }, "\u{2500}" }
        else
            .{ .{ "\u{2502}", "\u{2502}" }, "" };

        surface.writeCell(text_col, row, .{ .char = .{ .grapheme = corners[0], .width = 1 }, .style = edge });
        surface.writeCell(right, row, .{ .char = .{ .grapheme = corners[1], .width = 1 }, .style = edge });
        if (span.len == 0) continue;

        var col = text_col + 1;
        while (col < right) : (col += 1) {
            surface.writeCell(col, row, .{ .char = .{ .grapheme = span, .width = 1 }, .style = edge });
        }
    }
}

/// The one line a call reads as: a dot for how it went, what it did, and to
/// what. `target` is the argument worth showing, already summarized.
fn drawHeader(self: *ToolCard, surface: vxfw.Surface, width: u16, target: []const u8) void {
    const style = theme.on_bg(theme.fg);
    var col = w.writeText(surface, text_col, 0, dot, style.withFg(self.accentColor()).cell);
    col = w.writeText(surface, col + 1, 0, self.name, style.bold().cell);

    const trailing = self.trailingText();
    const room = width -| (col + 2 + @as(u16, @intCast(w.textWidth(trailing))));
    if (target.len > 0 and room > 0) {
        col = w.writeText(surface, col + 1, 0, clip(target, room), style.withFg(theme.fg_muted).cell);
    }

    if (trailing.len == 0) return;
    const at = width -| (1 + @as(u16, @intCast(w.textWidth(trailing))));
    if (at > col) _ = w.writeText(surface, at, 0, trailing, style.withFg(theme.fg_dim).cell);
}

/// What sits at the far right of the header: what the call is doing while it
/// runs, and the hint while the pointer is over it. Right-aligned, where a
/// duration will go once a call records one.
fn trailingText(self: *const ToolCard) []const u8 {
    if (self.has_mouse) {
        if (self.open != null) return "click to open transcript";
        if (self.result != null or self.capped) {
            return if (self.expanded) "click to collapse" else "click to expand";
        }
    }
    return switch (self.status) {
        .running => "running...",
        .pending => "waiting...",
        else => "",
    };
}

/// An `edit` or `write` call: the header names the file, and the box below it
/// holds the change itself rather than the raw `old`/`new` strings.
fn drawDiff(
    self: *ToolCard,
    ctx: vxfw.DrawContext,
    change: diff.Change,
    width: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    const body_width = width -| (text_col + 2);
    var body = try diff.rows(ctx.arena, change.old, change.new, self.startLine());
    if (body_width < diff.min_side_by_side_width or diff.oneSided(body)) {
        body = try diff.unify(ctx.arena, body);
    }

    const cap: usize = if (self.expanded) expanded_diff_rows else collapsed_diff_rows;
    self.capped = body.len > cap;

    const failure: u16 = if (self.status == .failed and self.result != null) 1 else 0;
    const rows = diff.height(body, cap);
    const height: u16 = box_row + rows + failure + 2 + box_margin;

    const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.base.cell);
    drawRule(surface, height);
    self.drawHeader(surface, width, change.path);
    drawBox(surface, box_row, rows + failure, width);

    diff.draw(surface, body, .{
        .arena = ctx.arena,
        .row = box_row + 1,
        .col = text_col + 1,
        .width = body_width,
        .max_rows = cap,
        .background = theme.on(theme.surface_alt, theme.fg).cell,
    });

    if (failure > 0) {
        _ = w.writeText(
            surface,
            body_col,
            box_row + rows + failure,
            clip(try oneLine(ctx.arena, self.result.?), body_width),
            theme.on(theme.surface_alt, theme.danger).cell,
        );
    }

    return surface;
}

/// Where the diff sits in the file. The `edit` tool reports it once the call
/// has run; before that there is nothing to go on, so it numbers from 1.
fn startLine(self: *const ToolCard) usize {
    if (self.start_line > 1) return self.start_line;

    const result = self.result orelse return 1;
    const marker = " at line ";
    const at = std.mem.lastIndexOf(u8, result, marker) orelse return 1;
    const digits = std.mem.trim(u8, result[at + marker.len ..], " \t\r\n");
    return std.fmt.parseInt(usize, digits, 10) catch 1;
}

/// The argument worth showing for a call, as a single line: `echo hello` beats
/// `{"command":"echo hello"}`. The rest of the arguments stay in the approval
/// panel, which is where they matter.
fn summarize(arena: std.mem.Allocator, name: []const u8, arguments: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, arguments, .{}) catch
        return oneLine(arena, arguments);
    if (parsed.value != .object) return oneLine(arena, arguments);
    const object = parsed.value.object;

    for (primaryKeys(name)) |key| {
        const value = object.get(key) orelse continue;
        if (value == .string and value.string.len > 0) return oneLine(arena, value.string);
    }

    var it = object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            return std.fmt.allocPrint(arena, "{s}: {s}", .{
                entry.key_ptr.*,
                try oneLine(arena, entry.value_ptr.string),
            });
        }
    }
    return "";
}

/// The arguments that name what a call does, per tool, best first. More than
/// one because a call can leave the best one out: `task` takes an optional
/// description, and without it the prompt is what there is to show.
fn primaryKeys(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "bash")) return &.{"command"};
    if (std.mem.eql(u8, name, "grep")) return &.{"pattern"};
    if (std.mem.eql(u8, name, "glob")) return &.{"pattern"};
    if (std.mem.eql(u8, name, "task")) return &.{ "description", "prompt" };
    if (std.mem.eql(u8, name, "read")) return &.{"path"};
    if (std.mem.eql(u8, name, "list")) return &.{"path"};
    if (std.mem.eql(u8, name, "write")) return &.{"path"};
    if (std.mem.eql(u8, name, "edit")) return &.{"path"};
    if (std.mem.eql(u8, name, "skill")) return &.{"name"};
    return &.{};
}

/// Flatten to one row: a multi-line command would otherwise overwrite whatever
/// the card drew underneath it.
fn oneLine(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return trimmed;
    return std.fmt.allocPrint(arena, "{s} ...", .{std.mem.trimEnd(u8, trimmed[0..end], " \t\r")});
}

/// Collapsed: one summary line. Expanded: the output, capped.
fn bodyLines(self: *ToolCard, arena: std.mem.Allocator, width: u16) ![]const []const u8 {
    if (self.result == null) {
        const note = self.note orelse return &.{};
        if (note.len == 0) return &.{};

        var lines: std.ArrayList([]const u8) = .empty;
        try lines.append(arena, clip(note, width -| (body_col + 2)));
        return lines.toOwnedSlice(arena);
    }

    const result = self.result orelse return &.{};
    // Only blank lines come off the front; spaces there are the first line's indent.
    const trimmed = std.mem.trimEnd(u8, std.mem.trimStart(u8, result, "\r\n"), " \t\r\n");
    if (trimmed.len == 0) return &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    const available = width -| (body_col + 2);

    if (!self.expanded) {
        const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
        const first = std.mem.trim(u8, trimmed[0..end], " \t\r");
        if (end == trimmed.len) {
            try lines.append(arena, clip(first, available));
        } else {
            const count = std.mem.count(u8, trimmed, "\n") + 1;
            try lines.append(arena, clip(
                try std.fmt.allocPrint(arena, "{s} ... ({d} lines)", .{ first, count }),
                available,
            ));
        }
        return lines.toOwnedSlice(arena);
    }

    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (lines.items.len >= max_body_rows) {
            try lines.append(arena, "...");
            break;
        }
        try lines.append(arena, clip(std.mem.trimEnd(u8, line, "\r"), available));
    }
    return lines.toOwnedSlice(arena);
}

/// Truncate to the visible width. Tool output is frequently much wider than
/// the pane and wrapping it would bury the card.
fn clip(text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    if (text.len <= width) return text;
    return text[0..width];
}

fn accentColor(self: *const ToolCard) Cell.Color {
    return switch (self.status) {
        .pending => theme.warning,
        .running => theme.accent_alt,
        .ok => theme.success,
        .failed => theme.danger,
        .rejected => theme.fg_dim,
    };
}

test "collapsed shows a summary, expanded shows the lines" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var card: ToolCard = .{ .name = "list", .result = "a\nb\nc" };

    const collapsed = try card.bodyLines(arena, 40);
    try std.testing.expectEqual(@as(usize, 1), collapsed.len);
    try std.testing.expect(std.mem.indexOf(u8, collapsed[0], "(3 lines)") != null);

    card.expanded = true;
    const expanded = try card.bodyLines(arena, 40);
    try std.testing.expectEqual(@as(usize, 3), expanded.len);
    try std.testing.expectEqualStrings("b", expanded[1]);
}

test "output longer than the cap is truncated" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.Io.Writer.Allocating = .init(arena);
    for (0..50) |i| try body.writer.print("line {d}\n", .{i});

    var card: ToolCard = .{ .name = "bash", .result = body.written(), .expanded = true };
    const lines = try card.bodyLines(arena, 40);

    try std.testing.expectEqual(@as(usize, max_body_rows + 1), lines.len);
    try std.testing.expectEqualStrings("...", lines[lines.len - 1]);
}

test "the card shows the argument that names the call, not its json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "echo hello world",
        try summarize(arena, "bash", "{\"command\":\"echo hello world\"}"),
    );
    try std.testing.expectEqualStrings(
        "src/main.zig",
        try summarize(arena, "write", "{\"path\":\"src/main.zig\",\"contents\":\"anything\"}"),
    );
    try std.testing.expectEqualStrings(
        "cd src ...",
        try summarize(arena, "bash", "{\"command\":\"cd src\\nls\"}"),
    );
    try std.testing.expectEqualStrings(
        "query: zig",
        try summarize(arena, "search", "{\"query\":\"zig\"}"),
    );
    try std.testing.expectEqualStrings("raw", try summarize(arena, "bash", "raw"));

    try std.testing.expectEqualStrings(
        "find the parser",
        try summarize(arena, "task", "{\"prompt\":\"where is it\",\"description\":\"find the parser\"}"),
    );
    // Without a description the prompt is what there is to show.
    try std.testing.expectEqualStrings(
        "where is it",
        try summarize(arena, "task", "{\"prompt\":\"where is it\"}"),
    );
    try std.testing.expectEqualStrings(
        "src/**/*.zig",
        try summarize(arena, "glob", "{\"pattern\":\"src/**/*.zig\"}"),
    );
}

test "the diff is numbered from the line the edit tool reported" {
    var card: ToolCard = .{ .name = "edit" };
    try std.testing.expectEqual(@as(usize, 1), card.startLine());

    card.result = "edited src/tui/app.zig at line 485";
    try std.testing.expectEqual(@as(usize, 485), card.startLine());

    card.result = "edited src/tui/app.zig";
    try std.testing.expectEqual(@as(usize, 1), card.startLine());
}

/// Everything on one row of a drawn card, for asserting on the layout.
fn rowText(arena: std.mem.Allocator, surface: vxfw.Surface, row: u16) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (0..surface.size.width) |col| {
        try out.writer.writeAll(surface.buffer[row * surface.size.width + col].char.grapheme);
    }
    return std.mem.trimEnd(u8, out.written(), " ");
}

fn drawContext(arena: std.mem.Allocator, width: u16) vxfw.DrawContext {
    return .{
        .arena = arena,
        .min = .{},
        .max = .{ .width = width, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };
}

test "a call collapses to one line, and expanding boxes its output" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var card: ToolCard = .{
        .name = "read",
        .arguments = "{\"path\":\"auth.spec.ts\"}",
        .result = "one\ntwo",
        .status = .ok,
    };

    const width: u16 = 60;
    const collapsed = try card.draw(drawContext(arena, width));
    try testing.expectEqual(@as(u16, 1), collapsed.size.height);

    const header = try rowText(arena, collapsed, 0);
    try testing.expectEqualStrings("  \u{2502} \u{25cf} read auth.spec.ts", header);

    // Expanded, the output arrives in a box of its own rather than in the line.
    card.expanded = true;
    const open = try card.draw(drawContext(arena, width));
    try testing.expect(open.size.height > 3);
    try testing.expectEqualStrings(header, try rowText(arena, open, 0));

    // Set down under the call, with a row of clear ground either side of it.
    const margin = "  " ++ w.solid_rule;
    try testing.expectEqualStrings(margin, try rowText(arena, open, 1));
    try testing.expectEqualStrings(margin, try rowText(arena, open, open.size.height - 1));

    // Framed above and below, and down both sides of every row between.
    const top = try rowText(arena, open, box_row);
    try testing.expect(std.mem.startsWith(u8, top, margin ++ " \u{250c}"));
    try testing.expect(std.mem.endsWith(u8, top, "\u{2510}"));

    const content = try rowText(arena, open, box_row + 1);
    try testing.expect(std.mem.indexOf(u8, content, "one") != null);
    try testing.expect(std.mem.endsWith(u8, content, w.solid_rule));

    const bottom = try rowText(arena, open, open.size.height - 1 - box_margin);
    try testing.expect(std.mem.indexOf(u8, bottom, "\u{2514}") != null);
    try testing.expect(std.mem.endsWith(u8, bottom, "\u{2518}"));
}

test "the frame carries the box's ground, not the app's" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var card: ToolCard = .{ .name = "read", .arguments = "{}", .status = .ok, .expanded = true, .result = "one\n" };
    const width: u16 = 40;
    const surface = try card.draw(drawContext(arena, width));

    // A rule is centred in its cell, so the half facing the contents is painted too.
    for (box_row..surface.size.height - box_margin) |row| {
        for ([_]u16{ text_col, width - 1 }) |col| {
            const cell = surface.buffer[row * width + col];
            try testing.expectEqual(theme.surface_alt, cell.style.bg);
            try testing.expectEqual(theme.border, cell.style.fg);
        }
    }

    // The rows either side of it are the app's ground, not the box's.
    for ([_]usize{ 1, surface.size.height - 1 }) |row| {
        try testing.expectEqual(theme.bg, surface.buffer[row * width + text_col].style.bg);
    }
}

test "a call says what it is doing while it does it" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const width: u16 = 60;
    const label = "running...";
    var card: ToolCard = .{ .name = "bash", .arguments = "{\"command\":\"go\"}", .status = .running };

    const surface = try card.draw(drawContext(arena, width));
    const running = try rowText(arena, surface, 0);
    try testing.expect(std.mem.endsWith(u8, running, label));

    // Right-aligned in cells, not bytes: the spine and dot are three bytes each.
    const at: u16 = width - label.len - 1;
    for (label, 0..) |char, i| {
        try testing.expectEqualStrings(&.{char}, surface.buffer[at + i].char.grapheme);
    }

    // Finished, it goes quiet again rather than reporting a state it is not in.
    card.status = .ok;
    card.result = "done";
    const settled = try rowText(arena, try card.draw(drawContext(arena, width)), 0);
    try testing.expect(std.mem.indexOf(u8, settled, "running") == null);
}

test "the header sits on the app's ground, the boxed output on the raised one" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var card: ToolCard = .{
        .name = "list",
        .arguments = "{}",
        .result = "one\ntwo",
        .status = .ok,
        .expanded = true,
    };

    const width: u16 = 40;
    const surface = try card.draw(drawContext(arena, width));

    // Sampled past the text, so the ground is the fill's rather than a glyph's.
    try testing.expectEqual(theme.bg, surface.buffer[width - 1].style.bg);
    // Sampled inside the box but past the output, so the fill is what set it.
    const first = (box_row + 1) * width;
    try testing.expectEqual(theme.surface_alt, surface.buffer[first + width - 2].style.bg);
    try testing.expectEqual(theme.surface_alt, surface.buffer[first + body_col].style.bg);

    // The margin outside the box stays the app's ground on every row.
    for (0..surface.size.height) |row| {
        try testing.expectEqual(theme.bg, surface.buffer[row * width].style.bg);
        try testing.expectEqual(theme.bg, surface.buffer[row * width + rule_col].style.bg);
    }
}

test "the first line of output keeps the indentation the rest has" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var card: ToolCard = .{
        .name = "read",
        .arguments = "{}",
        .status = .ok,
        .expanded = true,
        .result = "\n   1  first\n   2  second\n",
    };

    const lines = try card.bodyLines(arena, 60);
    try testing.expectEqualStrings("   1  first", lines[0]);
    try testing.expectEqualStrings("   2  second", lines[1]);
}

test "a new file's diff starts at the margin, not half way across" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var card: ToolCard = .{
        .name = "write",
        .arguments = "{\"path\":\"hello.txt\",\"content\":\"Hello world\\n\"}",
        .status = .ok,
    };

    const width: u16 = diff.min_side_by_side_width + 20;
    const surface = try card.draw(drawContext(arena, width));

    const line = try rowText(arena, surface, box_row + 1);
    const at = std.mem.indexOf(u8, line, "Hello world").?;
    try testing.expect(at < width / 2);
}

test "the box has no ground of its own showing between its edge and its contents" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    const width: u16 = 60;
    var cards = [_]ToolCard{
        .{
            .name = "edit",
            .arguments = "{\"path\":\"h.txt\",\"old\":\"Hello world\\n\",\"new\":\"Hello, world!\\n\"}",
            .status = .ok,
        },
        .{ .name = "read", .arguments = "{}", .status = .ok, .expanded = true, .result = "  1  abc\n" },
    };

    for (&cards) |*card| {
        const surface = try card.draw(drawContext(arena, width));
        try testing.expect(surface.size.height > 2);

        // Every row unbroken edge to edge; the app's ground between them is the gap.
        for (box_row..surface.size.height - box_margin) |row| {
            for (text_col..width) |col| {
                const cell = surface.buffer[row * width + col];
                try testing.expect(!std.meta.eql(cell.style.bg, theme.bg));
            }
        }

        // Squared off: every row reaches the same first and last column.
        for (box_row..surface.size.height - box_margin) |row| {
            try testing.expectEqual(theme.surface_alt, surface.buffer[row * width + text_col].style.bg);
            try testing.expect(!std.meta.eql(surface.buffer[row * width + width - 1].style.bg, theme.bg));
            try testing.expectEqual(theme.bg, surface.buffer[row * width + text_col - 1].style.bg);
        }
    }

    // The tint is the code column's; the gutter keeps the box's own ground.
    const surface = try cards[0].draw(drawContext(arena, width));
    const row = (box_row + 1) * width;
    try testing.expectEqual(theme.surface_alt, surface.buffer[row + text_col + 1].style.bg);
    try testing.expectEqual(theme.diff_removed_bg, surface.buffer[row + width - 2].style.bg);

    // With no unpainted column left between the code and the box around it.
    var tinted: usize = 0;
    for (text_col + 1..width - 1) |col| {
        if (std.meta.eql(surface.buffer[row + col].style.bg, theme.diff_removed_bg)) tinted += 1;
    }
    try testing.expect(tinted > (width - text_col) / 2);
}




test "a call hangs off a rule one level in from the reply that made it" {
    const testing = std.testing;

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    defer _ = themes.apply(themes.default_id);
    _ = themes.apply("synth");

    var card: ToolCard = .{ .name = "read", .arguments = "{}", .result = "x", .status = .ok };
    const width: u16 = 40;
    const surface = try card.draw(drawContext(arena, width));

    // The call's rule lands on the reply's text column, its own text a level on.
    try testing.expectEqualStrings(w.solid_rule, surface.buffer[w.nest].char.grapheme);
    try testing.expectEqual(theme.border, surface.buffer[w.nest].style.fg);
    try testing.expectEqualStrings(dot, surface.buffer[w.nest * 2].char.grapheme);

    // Nothing is painted in the reply's own column: that rule is the reply's.
    for (0..w.nest) |col| {
        try testing.expectEqualStrings(" ", surface.buffer[col].char.grapheme);
    }
}
