//! A tool call in the transcript: name, arguments, and its output.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const Conversation = @import("../core/conversation.zig");
const diff = @import("diff.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const ToolCard = @This();

/// Result rows shown when expanded, before the output is truncated.
const max_body_rows: u16 = 20;
/// Diff rows shown collapsed, and expanded.
const collapsed_diff_rows: usize = 8;
const expanded_diff_rows: usize = 60;
/// Column the text starts at, leaving room for the accent bar.
const indent: u16 = 3;

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
    if (width <= indent) return .empty(self.widget());

    if (try diff.change(ctx.arena, self.name, self.arguments)) |change| {
        return self.drawDiff(ctx, change, width);
    }
    self.capped = false;

    const body = try self.bodyLines(ctx.arena, width);
    const height: u16 = 2 + @as(u16, @intCast(body.len));

    const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.card.cell);

    const accent = self.accentColor();
    for (0..height) |row| {
        surface.writeCell(0, @intCast(row), .{
            .char = .{ .grapheme = "▌", .width = 1 },
            .style = .{ .fg = accent, .bg = theme.surface },
        });
    }

    var col = w.writeText(surface, indent, 0, self.status.glyph(), theme.on_card(accent).bold().cell);
    col = w.writeText(surface, col + 1, 0, self.name, theme.on_card(accent).bold().cell);

    if (self.open != null) {
        col = w.writeText(surface, col, 0, "  \u{bb}", theme.on_card(theme.fg_dim).cell);
        if (self.has_mouse) {
            _ = w.writeText(surface, col, 0, " click to open transcript", theme.on_card(theme.fg_dim).cell);
        }
    } else if (self.result != null) {
        const marker = if (self.expanded) "  ▾" else "  ▸";
        col = w.writeText(surface, col, 0, marker, theme.on_card(theme.fg_dim).cell);
        if (self.has_mouse) {
            const hint = if (self.expanded) " click to collapse" else " click to expand";
            _ = w.writeText(surface, col, 0, hint, theme.on_card(theme.fg_dim).cell);
        }
    }

    _ = w.writeText(
        surface,
        indent,
        1,
        clip(try summarize(ctx.arena, self.name, self.arguments), width -| (indent + 1)),
        theme.on_card(theme.fg_muted).cell,
    );

    const body_style = if (self.status == .failed)
        theme.on_card(theme.danger).cell
    else
        theme.on_card(theme.fg_dim).cell;

    for (body, 0..) |line, i| {
        _ = w.writeText(surface, indent, @intCast(2 + i), line, body_style);
    }

    return surface;
}

/// An `edit` or `write` call: the header names the file, and the body is the
/// change itself rather than the raw `old`/`new` strings.
fn drawDiff(
    self: *ToolCard,
    ctx: vxfw.DrawContext,
    change: diff.Change,
    width: u16,
) std.mem.Allocator.Error!vxfw.Surface {
    const body_width = width -| (indent + 1);
    var body = try diff.rows(ctx.arena, change.old, change.new, self.startLine());
    if (body_width < diff.min_side_by_side_width) body = try diff.unify(ctx.arena, body);

    const cap: usize = if (self.expanded) expanded_diff_rows else collapsed_diff_rows;
    self.capped = body.len > cap;

    const failure: u16 = if (self.status == .failed and self.result != null) 2 else 0;
    const height: u16 = 2 + diff.height(body, cap) + failure;

    const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.card.cell);

    const accent = self.accentColor();
    for (0..height) |row| {
        surface.writeCell(0, @intCast(row), .{
            .char = .{ .grapheme = "▌", .width = 1 },
            .style = .{ .fg = accent, .bg = theme.surface },
        });
    }

    var col = w.writeText(surface, indent, 0, self.status.glyph(), theme.on_card(accent).bold().cell);
    col = w.writeText(surface, col + 1, 0, self.name, theme.on_card(accent).bold().cell);
    col = w.writeText(surface, col + 1, 0, change.path, theme.on_card(theme.fg_muted).cell);

    if (self.capped or self.expanded) {
        const marker = if (self.expanded) "  ▾" else "  ▸";
        col = w.writeText(surface, col, 0, marker, theme.on_card(theme.fg_dim).cell);
        if (self.has_mouse) {
            const hint = if (self.expanded) " click to collapse" else " click to expand";
            _ = w.writeText(surface, col, 0, hint, theme.on_card(theme.fg_dim).cell);
        }
    }

    diff.draw(surface, body, .{
        .arena = ctx.arena,
        .row = 2,
        .col = indent,
        .width = body_width,
        .max_rows = cap,
    });

    if (failure > 0) {
        _ = w.writeText(
            surface,
            indent,
            height - 1,
            clip(try oneLine(ctx.arena, self.result.?), body_width),
            theme.on_card(theme.danger).cell,
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
        try lines.append(arena, clip(note, width -| (indent + 1)));
        return lines.toOwnedSlice(arena);
    }

    const result = self.result orelse return &.{};
    const trimmed = std.mem.trim(u8, result, " \t\r\n");
    if (trimmed.len == 0) return &.{};

    var lines: std.ArrayList([]const u8) = .empty;
    const available = width -| (indent + 1);

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
