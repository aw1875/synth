//! The permission panel, shown in place of the prompt box while a tool call is
//! waiting on a decision.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Loop = @import("../agent/loop.zig");
const permission = @import("../agent/permission.zig");
const diff = @import("diff.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Approval = @This();

/// Argument lines shown before the rest is summarised away.
const max_value_rows: usize = 10;
/// Longest command shown before it is cut. The full text is one line up in the
/// transcript card, which is where the detail belongs.
const max_summary_width: u16 = 120;
/// Column the text starts at, leaving room for the accent bar.
const indent: u16 = 3;
/// Blank rows above the header and below the buttons.
const pad_top: u16 = 1;
const pad_bottom: u16 = 1;
/// Extra indent for an argument's value under its label.
const value_indent: u16 = 4;

pub const Choice = enum {
    once,
    always,
    reject,

    fn label(self: Choice) []const u8 {
        return switch (self) {
            .once => " Allow once ",
            .always => " Allow always ",
            .reject => " Reject ",
        };
    }

    fn color(self: Choice) vaxis.Cell.Color {
        return switch (self) {
            .once => theme.warning,
            .always => theme.success,
            .reject => theme.danger,
        };
    }
};

const order: []const Choice = &.{ .once, .always, .reject };

selected: Choice = .once,
/// Which of the call's proposals "allow always" stores, once moved off the
/// default.
reach: ?usize = null,
/// Identifies the call the current selection belongs to, so the next prompt
/// starts back at "Allow once" instead of inheriting the last answer.
token: u64 = 0,

/// Point the panel at a call. Resets the selection when it is a new one.
pub fn sync(self: *Approval, token: u64) void {
    if (self.token == token) return;
    self.token = token;
    self.selected = .once;
    self.reach = null;
}

/// What "allow always" stores: the proposal picked, or else the widest one
/// that names no more than a subcommand.
pub fn proposal(self: *const Approval, proposals: []const Loop.Proposal) ?Loop.Proposal {
    if (proposals.len == 0) return null;
    return proposals[self.reachIndex(proposals)];
}

/// Reach `delta` proposals wider, stopping at either end.
pub fn widen(self: *Approval, delta: i32, proposals: []const Loop.Proposal) void {
    if (proposals.len == 0) return;
    const current: i32 = @intCast(self.reachIndex(proposals));
    self.reach = @intCast(std.math.clamp(current + delta, 0, @as(i32, @intCast(proposals.len - 1))));
}

fn reachIndex(self: *const Approval, proposals: []const Loop.Proposal) usize {
    if (self.reach) |index| return @min(index, proposals.len - 1);
    var index: usize = 0;
    for (proposals, 0..) |candidate, i| {
        if (@intFromEnum(candidate.breadth) <= @intFromEnum(permission.Breadth.subcommand)) index = i;
    }
    return index;
}

/// Move `delta` buttons, stopping at the ends rather than wrapping: the row is
/// short enough that wrapping past "Reject" back onto "Allow once" is a way to
/// approve something by accident.
pub fn move(self: *Approval, delta: i32) void {
    const current: i32 = @intCast(std.mem.indexOfScalar(Choice, order, self.selected) orelse 0);
    const next = std.math.clamp(current + delta, 0, @as(i32, @intCast(order.len - 1)));
    self.selected = order[@intCast(next)];
}

pub const DrawArgs = struct {
    /// Tool name, as the model called it.
    name: []const u8,
    /// The tool's own description, or "" when it is not registered.
    description: []const u8,
    /// Raw JSON object of arguments, as the model produced it.
    arguments: []const u8,
    /// Project the allowance would be scoped to, for the "allow always" hint.
    project: []const u8 = "",
    /// What an "allow always" could store, narrowest first.
    proposals: []const Loop.Proposal = &.{},
    width: u16,
};

pub fn draw(self: *Approval, ctx: vxfw.DrawContext, parent: vxfw.Widget, args: DrawArgs) !vxfw.Surface {
    const width = args.width;
    if (width <= indent) return .empty(parent);
    const available = width -| (indent + 2);

    const change = try diff.change(ctx.arena, args.name, args.arguments);
    const body: []const Line = if (change) |c|
        try changeSummary(ctx.arena, c)
    else
        try argumentLines(ctx.arena, args.arguments, @min(available, max_summary_width));
    const body_height: u16 = @intCast(body.len);

    const height: u16 = pad_top + 3 + body_height + 3 + pad_bottom;
    const surface = try w.surfaceClamped(ctx.arena, parent, .{
        .width = width,
        .height = height,
    });
    w.fill(surface, theme.card.cell);
    for (0..height) |row| {
        surface.writeCell(0, @intCast(row), .{
            .char = .{ .grapheme = "▌", .width = 1 },
            .style = theme.on_card(theme.warning).cell,
        });
    }

    var x = w.writeText(surface, indent, pad_top, "! ", theme.on_card(theme.warning).bold().cell);
    _ = w.writeText(surface, x, pad_top, "Permission required", theme.on_card(theme.fg).bold().cell);

    x = w.writeText(surface, indent + 2, pad_top + 1, args.name, theme.on_card(theme.warning).bold().cell);
    const subtitle = if (change) |c| c.path else args.description;
    if (subtitle.len > 0) {
        x = w.writeText(surface, x, pad_top + 1, " · ", theme.on_card(theme.fg_dim).cell);
        _ = w.writeText(surface, x, pad_top + 1, clip(subtitle, width -| x), theme.on_card(theme.fg_muted).cell);
    }

    for (body, 0..) |line, i| {
        _ = w.writeText(
            surface,
            indent + line.indent,
            @intCast(pad_top + 3 + i),
            line.text,
            switch (line.kind) {
                .label => theme.on_card(theme.fg_dim).cell,
                .value => theme.on_card(theme.fg).cell,
            },
        );
    }

    const consequence_line = try self.consequence(ctx.arena, args);
    _ = w.writeText(
        surface,
        indent,
        height - 2 - pad_bottom,
        consequence_line.text,
        consequence_line.style,
    );

    self.drawButtons(surface, height - 1 - pad_bottom, self.selected == .always and args.proposals.len > 1);
    return surface;
}

/// What the highlighted choice does, and how loudly to say it. "Allow always"
/// is the dangerous one: it reaches past this call, as far as the proposal
/// picked for it.
fn consequence(self: *Approval, arena: std.mem.Allocator, args: DrawArgs) !struct {
    text: []const u8,
    style: vaxis.Cell.Style,
} {
    return switch (self.selected) {
        .once => .{
            .text = try std.fmt.allocPrint(arena, "Runs this {s} call only.", .{args.name}),
            .style = theme.on_card(theme.fg_dim).cell,
        },
        .always => .{
            .text = try std.fmt.allocPrint(
                arena,
                "Allows {s} in {s} from now on. Nothing clears it yet.",
                .{ try self.scope(arena, args), if (args.project.len > 0) args.project else "this project" },
            ),
            .style = theme.on_card(theme.warning).cell,
        },
        .reject => .{
            .text = try std.fmt.allocPrint(arena, "Tells the model the {s} call was refused.", .{args.name}),
            .style = theme.on_card(theme.fg_dim).cell,
        },
    };
}

/// What the allowance covers, as it reads in a sentence. A pipeline names each
/// command that needed asking, since approving it allows all of them. A long
/// pattern is shortened so it cannot push the rest of the line off the panel.
fn scope(self: *const Approval, arena: std.mem.Allocator, args: DrawArgs) ![]const u8 {
    const patterns = if (self.proposal(args.proposals)) |chosen| chosen.patterns else &.{};
    if (patterns.len == 0 or (patterns.len == 1 and std.mem.eql(u8, patterns[0], "*"))) {
        return std.fmt.allocPrint(arena, "EVERY {s} call, on any file,", .{args.name});
    }
    if (!std.mem.eql(u8, args.name, "bash")) {
        return std.fmt.allocPrint(arena, "{s} on `{s}`", .{ args.name, patterns[0] });
    }

    const max_shown = 40;
    var out: std.ArrayList(u8) = .empty;
    for (patterns, 0..) |pattern, i| {
        if (i > 0) try out.appendSlice(arena, if (i == patterns.len - 1) " and " else ", ");
        if (pattern.len > max_shown) {
            try out.print(arena, "`{s}...`", .{pattern[0..max_shown]});
        } else {
            try out.print(arena, "`{s}`", .{pattern});
        }
    }
    return out.toOwnedSlice(arena);
}

fn drawButtons(self: *Approval, surface: vxfw.Surface, row: u16, reachable: bool) void {
    var x: u16 = indent;
    for (order) |choice| {
        const style = if (choice == self.selected)
            theme.card.withBg(choice.color()).withFg(theme.bg).bold()
        else
            theme.on_card(theme.fg_dim);
        x = w.writeText(surface, x, row, choice.label(), style.cell);
        x += 1;
    }

    const reach = if (reachable) "↑ ↓ reach   " else "";
    var hint = w.textWidth(reach) + w.textWidth("← → select   enter confirm");
    if (surface.size.width > x + hint + 2) {
        hint = surface.size.width - hint - 2;
        var h = hint;
        if (reachable) {
            h = w.writeText(surface, h, row, "↑ ↓", theme.on_card(theme.fg_muted).bold().cell);
            h = w.writeText(surface, h, row, " reach   ", theme.on_card(theme.fg_dim).cell);
        }
        h = w.writeText(surface, h, row, "← →", theme.on_card(theme.fg_muted).bold().cell);
        h = w.writeText(surface, h, row, " select   ", theme.on_card(theme.fg_dim).cell);
        h = w.writeText(surface, h, row, "enter", theme.on_card(theme.fg_muted).bold().cell);
        _ = w.writeText(surface, h, row, " confirm", theme.on_card(theme.fg_dim).cell);
    }
}

/// How much an `edit` or `write` changes, in one line.
fn changeSummary(arena: std.mem.Allocator, change: diff.Change) ![]const Line {
    var added: usize = 0;
    var removed: usize = 0;
    for (try diff.rows(arena, change.old, change.new, 1)) |row| {
        if (row.left) |left| {
            if (left.kind == .removed) removed += 1;
        }
        if (row.right) |right| {
            if (right.kind == .added) added += 1;
        }
    }

    const lines = try arena.alloc(Line, 1);
    lines[0] = .{
        .kind = .value,
        .indent = 2,
        .text = try std.fmt.allocPrint(arena, "+{d} added   -{d} removed", .{ added, removed }),
    };
    return lines;
}

const Line = struct {
    const Kind = enum { label, value };

    kind: Kind,
    indent: u16,
    text: []const u8,
};

/// Turn the raw argument JSON into labelled rows. Anything that does not parse
/// as an object is shown verbatim, since a prompt that hides what it is asking
/// about is worse than an ugly one.
fn argumentLines(arena: std.mem.Allocator, arguments: []const u8, width: u16) ![]const Line {
    var lines: std.ArrayList(Line) = .empty;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, arguments, .{}) catch {
        try appendValue(arena, &lines, arguments, width);
        return lines.toOwnedSlice(arena);
    };
    if (parsed.value != .object) {
        try appendValue(arena, &lines, arguments, width);
        return lines.toOwnedSlice(arena);
    }

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (lines.items.len > 0) try lines.append(arena, .{ .kind = .value, .indent = 0, .text = "" });
        try lines.append(arena, .{ .kind = .label, .indent = 0, .text = entry.key_ptr.* });
        try appendValue(arena, &lines, try scalarText(arena, entry.value_ptr.*), width);
    }

    if (lines.items.len == 0) {
        try lines.append(arena, .{ .kind = .label, .indent = 0, .text = "no arguments" });
    }
    return lines.toOwnedSlice(arena);
}

/// Split a value across rows, capped so a large `write` body cannot push the
/// buttons off the bottom of the screen.
fn appendValue(arena: std.mem.Allocator, lines: *std.ArrayList(Line), text: []const u8, width: u16) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        try lines.append(arena, .{ .kind = .value, .indent = value_indent, .text = "(empty)" });
        return;
    }

    var shown: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (shown == max_value_rows) {
            const rest = std.mem.count(u8, trimmed, "\n") + 1 - shown;
            try lines.append(arena, .{
                .kind = .label,
                .indent = value_indent,
                .text = try std.fmt.allocPrint(arena, "... {d} more lines", .{rest}),
            });
            return;
        }
        try lines.append(arena, .{
            .kind = .value,
            .indent = value_indent,
            .text = clip(std.mem.trimEnd(u8, line, "\r"), width -| value_indent),
        });
        shown += 1;
    }
}

fn scalarText(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(value, .{})}),
    };
}

fn clip(text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    if (text.len <= width) return text;
    return text[0..width];
}

test "selection clamps at both ends and resets for a new call" {
    var approval: Approval = .{};
    approval.sync(1);

    approval.move(-1);
    try std.testing.expectEqual(Choice.once, approval.selected);
    approval.move(1);
    approval.move(1);
    try std.testing.expectEqual(Choice.reject, approval.selected);
    approval.move(1);
    try std.testing.expectEqual(Choice.reject, approval.selected);

    approval.sync(1);
    try std.testing.expectEqual(Choice.reject, approval.selected);

    approval.sync(2);
    try std.testing.expectEqual(Choice.once, approval.selected);
}

test "reach starts at the subcommand and moves between the call's proposals" {
    const proposals: []const Loop.Proposal = &.{
        .{ .breadth = .command, .patterns = &.{"git commit -m x"} },
        .{ .breadth = .subcommand, .patterns = &.{"git commit *"} },
        .{ .breadth = .program, .patterns = &.{"git *"} },
    };
    var approval: Approval = .{};
    approval.sync(1);
    try std.testing.expectEqual(permission.Breadth.subcommand, approval.proposal(proposals).?.breadth);
    approval.widen(1, proposals);
    approval.widen(1, proposals);
    try std.testing.expectEqual(permission.Breadth.program, approval.proposal(proposals).?.breadth);
    approval.widen(-5, proposals);
    try std.testing.expectEqual(permission.Breadth.command, approval.proposal(proposals).?.breadth);

    approval.sync(2);
    const exact_only: []const Loop.Proposal = &.{
        .{ .breadth = .command, .patterns = &.{"rm -rf build"} },
        .{ .breadth = .program, .patterns = &.{"rm *"} },
    };
    try std.testing.expectEqual(permission.Breadth.command, approval.proposal(exact_only).?.breadth);
    try std.testing.expectEqual(null, approval.proposal(&.{}));
}

test "arguments are labelled, and a long value is capped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lines = try argumentLines(arena, "{\"command\":\"ls -la\"}", 40);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("command", lines[0].text);
    try std.testing.expectEqualStrings("ls -la", lines[1].text);

    var body: []const u8 = "";
    for (0..30) |i| body = try std.fmt.allocPrint(arena, "{s}line {d}\\n", .{ body, i });
    const args = try std.fmt.allocPrint(arena, "{{\"text\":\"{s}\"}}", .{body});

    const capped = try argumentLines(arena, args, 40);
    try std.testing.expectEqual(@as(usize, 1 + max_value_rows + 1), capped.len);
    try std.testing.expect(std.mem.startsWith(u8, capped[capped.len - 1].text, "..."));
}

test "unparseable arguments are shown verbatim" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const lines = try argumentLines(arena_state.allocator(), "not json", 40);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("not json", lines[0].text);
}

test "an edit is summarised by how many lines it touches" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const lines = try changeSummary(arena_state.allocator(), .{
        .path = "index.js",
        .old = "debug\ninfo\nwarn\nerror\n",
        .new = "info\nerror\n",
    });
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("+0 added   -2 removed", lines[0].text);
}
