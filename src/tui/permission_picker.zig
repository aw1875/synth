//! The project's standing allowances: what "allow always" has let through,
//! and the place to take it back or narrow it.
//!
//! The list lives on the server, which owns the database and tells every
//! session on the project when it changes. This only shows the last answer
//! and says what the person wants done to it.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fuzzy = @import("../core/fuzzy.zig");
const synth = @import("../acp/synth.zig");
const Input = @import("input.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Picker = @This();

/// Rows visible at once, before the list scrolls.
const max_rows: usize = 12;
/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 76;
/// Left and right padding inside the box.
const pad: u16 = 2;
/// Width of the tool column.
const tool_width: u16 = 7;

open: bool = false,
/// The list was asked for, and opens when it arrives.
requested: bool = false,
/// Indices into `rows` matching the search, in display order. One past the
/// last row stands for adding what was searched for.
matches: std.ArrayList(usize) = .empty,
cursor: usize = 0,
scroll: usize = 0,
search: Input,
/// The pattern being rewritten, while `editing` says which row it is.
edit: Input,
editing: ?usize = null,
allocator: std.mem.Allocator,
/// Every standing allowance, in `rows_arena`.
rows: []const synth.Allowance = &.{},
rows_arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{
        .allocator = allocator,
        .search = .init(allocator),
        .edit = .init(allocator),
        .rows_arena = .init(allocator),
    };
}

pub fn deinit(self: *Picker) void {
    self.matches.deinit(self.allocator);
    self.search.deinit();
    self.edit.deinit();
    self.rows_arena.deinit();
}

pub fn isOpen(self: *const Picker) bool {
    return self.open;
}

/// Open on `allowances`, which are copied.
pub fn show(self: *Picker, allowances: []const synth.Allowance) !void {
    self.search.clear();
    self.cursor = 0;
    self.scroll = 0;
    self.editing = null;
    try self.refresh(allowances);
    self.open = true;
}

/// The allowances as the server now has them: shown if asked for, or taken in
/// if already open, and otherwise not wanted.
pub fn receive(self: *Picker, allowances: []const synth.Allowance) !void {
    if (self.open) return self.refresh(allowances);
    if (!self.requested) return;
    self.requested = false;
    try self.show(allowances);
}

/// Take the allowances as they now stand, keeping the cursor and search.
pub fn refresh(self: *Picker, allowances: []const synth.Allowance) !void {
    self.matches.clearRetainingCapacity();
    self.rows = &.{};
    self.editing = null;
    _ = self.rows_arena.reset(.retain_capacity);
    const arena = self.rows_arena.allocator();
    const rows = try arena.alloc(synth.Allowance, allowances.len);
    for (allowances, rows) |allowance, *row| row.* = .{
        .tool = try arena.dupe(u8, allowance.tool),
        .pattern = try arena.dupe(u8, allowance.pattern),
    };
    self.rows = rows;
    try self.filter();
}

pub fn close(self: *Picker) void {
    self.open = false;
    self.editing = null;
    self.search.clear();
    self.edit.clear();
    self.matches.clearRetainingCapacity();
}

/// What the person asked for. Slices are the picker's, good until the next
/// `refresh`.
pub const Action = union(enum) {
    none,
    cancel,
    remove: synth.Allowance,
    add: synth.Allowance,
    amend: struct { old: synth.Allowance, new: synth.Allowance },
};

pub fn handleKey(self: *Picker, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
    if (self.editing) |index| return self.handleEditKey(ctx, key, index);

    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        self.move(-1);
        return .none;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        self.move(1);
        return .none;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (self.addable()) |pattern| {
            if (self.cursor == self.matches.items.len) return .{ .add = .{ .tool = "bash", .pattern = pattern } };
        }
        const index = self.selectedIndex() orelse return .none;
        self.edit.clear();
        try self.edit.insertText(self.rows[index].pattern);
        self.editing = index;
        return .none;
    }
    if (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
        const index = self.selectedIndex() orelse return .none;
        return .{ .remove = self.rows[index] };
    }

    try self.search.handleEvent(ctx, .{ .key_press = key });
    try self.filter();
    return .none;
}

fn handleEditKey(self: *Picker, ctx: *vxfw.EventContext, key: vaxis.Key, index: usize) !Action {
    if (key.matches(vaxis.Key.escape, .{})) {
        self.editing = null;
        return .none;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const old = self.rows[index];
        const pattern = std.mem.trim(u8, self.edit.text.items, " \t");
        self.editing = null;
        if (pattern.len == 0 or std.mem.eql(u8, pattern, old.pattern)) return .none;
        return .{ .amend = .{ .old = old, .new = .{ .tool = old.tool, .pattern = pattern } } };
    }
    try self.edit.handleEvent(ctx, .{ .key_press = key });
    return .none;
}

/// The highlighted allowance, by index into `rows`.
fn selectedIndex(self: *const Picker) ?usize {
    if (self.cursor >= self.matches.items.len) return null;
    return self.matches.items[self.cursor];
}

/// What was searched for, when it could be added as a shell allowance: it is
/// not empty, and not one already standing.
fn addable(self: *const Picker) ?[]const u8 {
    const query = std.mem.trim(u8, self.search.text.items, " \t");
    if (query.len == 0) return null;
    for (self.rows) |row| {
        if (std.mem.eql(u8, row.tool, "bash") and std.mem.eql(u8, row.pattern, query)) return null;
    }
    return query;
}

/// Positions the cursor can take: every match, and the add row when there is
/// one.
fn positions(self: *const Picker) usize {
    return self.matches.items.len + @intFromBool(self.addable() != null);
}

pub fn filter(self: *Picker) !void {
    const query = std.mem.trim(u8, self.search.text.items, " \t");
    const was = self.cursor;

    self.matches.clearRetainingCapacity();
    if (query.len == 0) {
        for (self.rows, 0..) |_, i| try self.matches.append(self.allocator, i);
    } else {
        var top: fuzzy.Top(max_rows) = .{};
        for (self.rows, 0..) |row, i| top.consider(i, row.pattern, query, .{});
        for (top.ranked()) |ranked| try self.matches.append(self.allocator, ranked.index);
    }

    self.cursor = if (was < self.positions()) was else 0;
    if (self.cursor < self.scroll) self.scroll = self.cursor;
}

fn move(self: *Picker, delta: i32) void {
    const count = self.positions();
    if (count == 0) return;

    var at: i32 = @intCast(self.cursor);
    at += delta;
    if (at < 0 or at >= @as(i32, @intCast(count))) return;

    self.cursor = @intCast(at);
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + max_rows) self.scroll = self.cursor - max_rows + 1;
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
    cursor: ?vxfw.CursorState = null,
};

pub fn draw(self: *Picker, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (!self.open) return null;

    const chrome: u16 = 8;
    const listed = self.positions() - self.scroll;
    const visible: u16 = @intCast(@min(listed, max_rows));
    const height: u16 = chrome + @max(visible, 1);
    if (size.width < 40 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;
    const inner = width -| (pad * 2);

    var surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "Allowed in this project", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    var children: std.ArrayList(vxfw.SubSurface) = .empty;
    var cursor: ?vxfw.CursorState = null;
    const field_row: u16 = 2;
    if (inner > 0) {
        self.search.style = theme.card.cell;
        self.search.placeholder = "Search, or type a command to allow";
        self.search.placeholder_style = theme.on_card(theme.fg_dim).cell;
        self.search.height = 1;
        const field = try self.search.draw(ctx.withConstraints(
            .{ .width = inner, .height = 1 },
            .{ .width = inner, .height = 1 },
        ));
        try children.append(ctx.arena, .{ .origin = .{ .row = field_row, .col = pad }, .surface = field });
        if (self.editing == null) {
            if (field.cursor) |position| cursor = .{
                .row = origin_row + field_row + position.row,
                .col = origin_col + pad + position.col,
                .shape = .block,
            };
        }
    }

    const first_row: u16 = field_row + 2;
    if (self.positions() == 0) {
        const empty = if (self.rows.len == 0) "nothing allowed yet" else "no matches";
        _ = w.writeText(surface, pad, first_row, empty, theme.on_card(theme.fg_dim).cell);
    }

    for (0..visible) |i| {
        const position = self.scroll + i;
        const y: u16 = @intCast(first_row + i);
        const chosen = position == self.cursor;
        const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;
        if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

        if (position == self.matches.items.len) {
            const x = w.writeText(surface, pad, y, "+ allow ", base.withFg(theme.success).cell);
            _ = w.writeText(surface, x, y, self.addable().?, base.withFg(theme.fg).cell);
            continue;
        }

        const index = self.matches.items[position];
        const row = self.rows[index];
        _ = w.writeText(surface, pad, y, row.tool, base.withFg(theme.fg_dim).cell);

        const reach = describe(row);
        const detail_width = w.textWidth(reach.detail);
        const pattern_col = pad + tool_width;
        const pattern_width = (width -| pad) -| pattern_col -| detail_width -| 2;

        if (self.editing == index) {
            self.edit.style = base.withFg(theme.fg).cell;
            self.edit.height = 1;
            const field = try self.edit.draw(ctx.withConstraints(
                .{ .width = pattern_width, .height = 1 },
                .{ .width = pattern_width, .height = 1 },
            ));
            try children.append(ctx.arena, .{ .origin = .{ .row = y, .col = pattern_col }, .surface = field });
            if (field.cursor) |at| cursor = .{
                .row = origin_row + y + at.row,
                .col = origin_col + pattern_col + at.col,
                .shape = .block,
            };
        } else {
            _ = w.writeText(surface, pattern_col, y, try fit(ctx.arena, row.pattern, pattern_width), base.withFg(theme.fg).cell);
        }
        w.writeTextRight(surface, y, pad, reach.detail, base.withFg(reach.color).cell);
    }
    surface.children = children.items;

    const hint_row = height - 2;
    if (self.editing != null) {
        var hint = w.writeText(surface, pad, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
        hint = w.writeText(surface, hint, hint_row, " save   ", theme.on_card(theme.fg_dim).cell);
        hint = w.writeText(surface, hint, hint_row, "esc", theme.on_card(theme.fg_muted).bold().cell);
        _ = w.writeText(surface, hint, hint_row, " keep it", theme.on_card(theme.fg_dim).cell);
    } else if (self.cursor == self.matches.items.len and self.addable() != null) {
        const hint = w.writeText(surface, pad, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
        _ = w.writeText(surface, hint, hint_row, " allow this shell command", theme.on_card(theme.fg_dim).cell);
    } else {
        var hint = w.writeText(surface, pad, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
        hint = w.writeText(surface, hint, hint_row, " edit   ", theme.on_card(theme.fg_dim).cell);
        hint = w.writeText(surface, hint, hint_row, "del", theme.on_card(theme.fg_muted).bold().cell);
        hint = w.writeText(surface, hint, hint_row, " remove   ", theme.on_card(theme.fg_dim).cell);
        hint = w.writeText(surface, hint, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
        _ = w.writeText(surface, hint, hint_row, " move", theme.on_card(theme.fg_dim).cell);
    }

    return .{
        .surface = surface,
        .origin = .{ .row = origin_row, .col = origin_col },
        .cursor = cursor,
    };
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

const Reach = struct {
    detail: []const u8,
    color: theme.Color,
};

/// How far one allowance reaches, in a few words, loudest where it reaches
/// furthest.
fn describe(allowance: synth.Allowance) Reach {
    const is_shell = std.mem.eql(u8, allowance.tool, "bash");
    if (std.mem.eql(u8, allowance.pattern, "*")) {
        return if (is_shell)
            .{ .detail = "every command", .color = theme.danger }
        else
            .{ .detail = "every call", .color = theme.warning };
    }
    if (!is_shell) return .{ .detail = "this path", .color = theme.fg_muted };
    if (!std.mem.endsWith(u8, allowance.pattern, " *")) return .{ .detail = "exactly", .color = theme.fg_muted };
    const words = std.mem.trimEnd(u8, allowance.pattern, " *");
    if (std.mem.indexOfAny(u8, words, " \t") == null) return .{ .detail = "every use", .color = theme.warning };
    return .{ .detail = "any arguments", .color = theme.fg_muted };
}

const sample: []const synth.Allowance = &.{
    .{ .tool = "bash", .pattern = "git *" },
    .{ .tool = "bash", .pattern = "git commit *" },
    .{ .tool = "bash", .pattern = "rm -rf build" },
    .{ .tool = "write", .pattern = "*" },
};

test "every allowance is listed, and says how far it reaches" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    try picker.show(sample);
    try testing.expectEqual(@as(usize, 4), picker.matches.items.len);

    try testing.expectEqualStrings("every use", describe(sample[0]).detail);
    try testing.expectEqualStrings("any arguments", describe(sample[1]).detail);
    try testing.expectEqualStrings("exactly", describe(sample[2]).detail);
    try testing.expectEqualStrings("every call", describe(sample[3]).detail);
    try testing.expectEqualStrings("every command", describe(.{ .tool = "bash", .pattern = "*" }).detail);
    try testing.expectEqualStrings("this path", describe(.{ .tool = "read", .pattern = "/etc/hosts" }).detail);
}

fn press(picker: *Picker, key: vaxis.Key) !Action {
    var ctx: vxfw.EventContext = .{
        .phase = .at_target,
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(testing.allocator);
    return picker.handleKey(&ctx, key);
}

fn typeText(picker: *Picker, text: []const u8) !void {
    for (text) |byte| {
        const buffer = [_]u8{byte};
        _ = try press(picker, .{ .codepoint = byte, .text = &buffer });
    }
}

test "the list opens when it was asked for, and is otherwise only kept current" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();

    try picker.receive(sample);
    try testing.expect(!picker.isOpen());

    picker.requested = true;
    try picker.receive(sample);
    try testing.expect(picker.isOpen());
    try picker.receive(sample[0..1]);
    try testing.expectEqual(@as(usize, 1), picker.rows.len);

    picker.close();
    try picker.receive(sample);
    try testing.expect(!picker.isOpen());
}

test "an allowance is removed, or rewritten in place" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    try picker.show(sample);

    const removed = try press(&picker, .{ .codepoint = vaxis.Key.delete });
    try testing.expectEqualStrings("git *", removed.remove.pattern);

    _ = try press(&picker, .{ .codepoint = vaxis.Key.down });
    try testing.expectEqual(Action.none, try press(&picker, .{ .codepoint = vaxis.Key.enter }));
    try testing.expectEqual(@as(?usize, 1), picker.editing);
    try testing.expectEqualStrings("git commit *", picker.edit.text.items);

    picker.edit.clear();
    try picker.edit.insertText("git commit --amend *");
    const amended = try press(&picker, .{ .codepoint = vaxis.Key.enter });
    try testing.expectEqualStrings("git commit *", amended.amend.old.pattern);
    try testing.expectEqualStrings("git commit --amend *", amended.amend.new.pattern);
    try testing.expectEqualStrings("bash", amended.amend.new.tool);
    try testing.expectEqual(null, picker.editing);

    _ = try press(&picker, .{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(Action.none, try press(&picker, .{ .codepoint = vaxis.Key.escape }));
    try testing.expectEqual(null, picker.editing);
    try testing.expectEqual(Action.cancel, try press(&picker, .{ .codepoint = vaxis.Key.escape }));
}

test "a search that matches nothing standing can be added as a shell allowance" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();
    try picker.show(sample);

    try typeText(&picker, "zig build *");
    try testing.expectEqualStrings("zig build *", picker.addable().?);
    while (picker.cursor < picker.matches.items.len) _ = try press(&picker, .{ .codepoint = vaxis.Key.down });
    const added = try press(&picker, .{ .codepoint = vaxis.Key.enter });
    try testing.expectEqualStrings("bash", added.add.tool);
    try testing.expectEqualStrings("zig build *", added.add.pattern);

    picker.search.clear();
    try typeText(&picker, "rm -rf build");
    try testing.expectEqual(null, picker.addable());
}
