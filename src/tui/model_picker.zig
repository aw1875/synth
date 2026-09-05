//! The model switcher: a search box over every model the configured providers
//! offer, grouped by where each one comes from.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fuzzy = @import("../core/fuzzy.zig");
const Input = @import("input.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Picker = @This();

/// Rows visible at once, before the list scrolls.
const max_rows: usize = 12;
/// Recent models shown above the full list.
pub const max_recent: usize = 5;
/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 76;
/// Left and right padding inside the box.
const pad: u16 = 2;

/// One model on offer.
pub const Entry = struct {
    /// The tag a provider is switched to, e.g. `qwen3:8b`.
    name: []const u8,
    /// Which backend offers it, e.g. `Ollama`. Shown dim beside the name.
    provider: []const u8,
    /// Catalog id of that backend. Picking a model from a provider that is not
    /// the one in use switches to it first.
    provider_id: []const u8 = "",
    /// Whether this project has used it before.
    recent: bool = false,
};

/// A row of the drawn list: either a group heading or a model.
const Row = union(enum) {
    heading: []const u8,
    entry: usize,
};

allocator: std.mem.Allocator,
open: bool = false,
/// Owned: names and provider labels are duped when the picker is shown, since
/// the provider's own list is freed straight after.
entries: []Entry = &.{},
/// Indices into `entries` matching the search, in display order.
matches: std.ArrayList(usize) = .empty,
/// The drawn list, headings included. Rebuilt with `matches`.
rows: std.ArrayList(Row) = .empty,
/// Index into `rows`; always on an entry, never on a heading.
cursor: usize = 0,
/// First visible row.
scroll: usize = 0,
search: Input,
/// The model in use, marked in the list.
current: []const u8 = "",

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{ .allocator = allocator, .search = .init(allocator) };
}

pub fn deinit(self: *Picker) void {
    self.release();
    self.matches.deinit(self.allocator);
    self.rows.deinit(self.allocator);
    self.search.deinit();
}

fn release(self: *Picker) void {
    for (self.entries) |entry| {
        self.allocator.free(entry.name);
        self.allocator.free(entry.provider);
        self.allocator.free(entry.provider_id);
    }
    self.allocator.free(self.entries);
    self.entries = &.{};
}

/// Show the list. `models` and `recent` are borrowed for the length of the
/// call; everything kept is duped.
pub fn show(
    self: *Picker,
    models: []const Entry,
    recent: []const []const u8,
    current: []const u8,
) !void {
    self.release();

    const entries = try self.allocator.alloc(Entry, models.len);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.provider);
            self.allocator.free(entry.provider_id);
        }
        self.allocator.free(entries);
    }
    for (models, entries) |src, *dst| {
        dst.* = .{
            .name = try self.allocator.dupe(u8, src.name),
            .provider = try self.allocator.dupe(u8, src.provider),
            .provider_id = try self.allocator.dupe(u8, src.provider_id),
            .recent = isRecent(src.name, recent),
        };
        filled += 1;
    }
    self.entries = entries;

    self.current = current;
    if (!self.open) self.search.clear();
    self.cursor = 0;
    self.scroll = 0;
    try self.filter();
    self.open = true;
}

fn isRecent(name: []const u8, recent: []const []const u8) bool {
    for (recent) |used| {
        if (std.mem.eql(u8, used, name)) return true;
    }
    return false;
}

pub fn close(self: *Picker) void {
    self.open = false;
    self.search.clear();
    self.release();
    self.matches.clearRetainingCapacity();
    self.rows.clearRetainingCapacity();
}

/// The highlighted model, or null when nothing matches the search.
pub fn selected(self: *const Picker) ?Entry {
    if (self.cursor >= self.rows.items.len) return null;
    return switch (self.rows.items[self.cursor]) {
        .heading => null,
        .entry => |index| self.entries[index],
    };
}

pub const Action = enum { none, cancel, choose };

pub fn handleKey(self: *Picker, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{})) return .choose;

    if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
        self.move(-1);
        return .none;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
        self.move(1);
        return .none;
    }

    try self.search.handleEvent(ctx, .{ .key_press = key });
    try self.filter();
    return .none;
}

/// Rebuild the match list and the rows drawn from it. Recent models are lifted
/// into a group of their own; the rest keep provider order.
fn filter(self: *Picker) !void {
    const query = std.mem.trim(u8, self.search.text.items, " \t");

    self.matches.clearRetainingCapacity();
    self.rows.clearRetainingCapacity();

    var recent_count: usize = 0;
    for (self.entries, 0..) |entry, i| {
        if (!wanted(entry, query)) continue;
        if (!entry.recent) continue;
        if (recent_count == 0) try self.rows.append(self.allocator, .{ .heading = "Recent" });
        if (recent_count >= max_recent) break;
        try self.rows.append(self.allocator, .{ .entry = i });
        try self.matches.append(self.allocator, i);
        recent_count += 1;
    }

    var group: []const u8 = "";
    for (self.entries, 0..) |entry, i| {
        if (!wanted(entry, query)) continue;
        if (!std.mem.eql(u8, group, entry.provider)) {
            group = entry.provider;
            try self.rows.append(self.allocator, .{ .heading = entry.provider });
        }
        try self.rows.append(self.allocator, .{ .entry = i });
        try self.matches.append(self.allocator, i);
    }

    self.cursor = 0;
    self.scroll = 0;
    if (self.rows.items.len > 0 and self.rows.items[0] == .heading) self.move(1);
}

/// Whether an entry survives the search.
fn wanted(entry: Entry, query: []const u8) bool {
    if (query.len == 0) return true;
    return fuzzy.matches(entry.name, query, .{}) or startsAWord(entry.provider, query);
}

fn startsAWord(text: []const u8, needle: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t-_");
    while (words.next()) |word| {
        if (word.len < needle.len) continue;
        if (std.ascii.eqlIgnoreCase(word[0..needle.len], needle)) return true;
    }
    return false;
}

/// Step the cursor by `delta` rows, skipping headings and stopping at the ends.
fn move(self: *Picker, delta: i32) void {
    if (self.rows.items.len == 0) return;

    var at: i32 = @intCast(self.cursor);
    const last: i32 = @intCast(self.rows.items.len - 1);
    while (true) {
        at += delta;
        if (at < 0 or at > last) return;
        if (self.rows.items[@intCast(at)] == .entry) break;
    }

    self.cursor = @intCast(at);
    if (self.cursor < self.scroll) self.scroll = self.cursor;
    if (self.cursor >= self.scroll + max_rows) self.scroll = self.cursor - max_rows + 1;
    if (self.scroll > 0 and self.rows.items[self.scroll - 1] == .heading) self.scroll -= 1;
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
    cursor: ?vxfw.CursorState = null,
};

pub fn draw(self: *Picker, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (!self.open) return null;

    const chrome: u16 = 8;
    const visible: u16 = @intCast(@min(self.rows.items.len, max_rows));
    const height: u16 = chrome + @max(visible, 1);
    if (size.width < 32 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    var surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "Select model", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    var cursor: ?vxfw.CursorState = null;
    const field_row: u16 = 2;
    const inner = width -| (pad * 2);
    if (inner > 0) {
        self.search.style = theme.card.cell;
        self.search.placeholder = "Search";
        self.search.placeholder_style = theme.on_card(theme.fg_dim).cell;
        self.search.height = 1;
        const field = try self.search.draw(ctx.withConstraints(
            .{ .width = inner, .height = 1 },
            .{ .width = inner, .height = 1 },
        ));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = field_row, .col = pad }, .surface = field };
        surface.children = children;

        if (field.cursor) |position| {
            cursor = .{
                .row = origin_row + field_row + position.row,
                .col = origin_col + pad + position.col,
                .shape = .block,
            };
        }
    }

    const first_row: u16 = field_row + 2;
    if (self.rows.items.len == 0) {
        _ = w.writeText(surface, pad, first_row, "no models", theme.on_card(theme.fg_dim).cell);
    }

    for (self.rows.items[self.scroll..][0..visible], 0..) |row, i| {
        const y: u16 = @intCast(first_row + i);
        switch (row) {
            .heading => |title| {
                _ = w.writeText(surface, pad, y, title, theme.on_card(theme.accent_alt).cell);
            },
            .entry => |index| {
                const entry = self.entries[index];
                const chosen = self.scroll + i == self.cursor;
                const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;

                if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

                const in_use = std.mem.eql(u8, entry.name, self.current);
                if (in_use) {
                    _ = w.writeText(surface, pad, y, "●", base.withFg(theme.success).cell);
                }

                const x = w.writeText(surface, pad + 2, y, entry.name, base.withFg(theme.fg).cell);
                _ = w.writeText(surface, x + 1, y, entry.provider, base.withFg(theme.fg_dim).cell);
            },
        }
    }

    const hint_row = height - 2;
    var hint = w.writeText(surface, pad, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " select   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, hint, hint_row, " switch", theme.on_card(theme.fg_dim).cell);

    return .{
        .surface = surface,
        .origin = .{ .row = origin_row, .col = origin_col },
        .cursor = cursor,
    };
}

test "the list groups by provider and lifts what was used before" {
    var picker: Picker = .init(std.testing.allocator);
    defer picker.deinit();

    try picker.show(&.{
        .{ .name = "qwen3:8b", .provider = "Ollama" },
        .{ .name = "llama3:70b", .provider = "Ollama" },
        .{ .name = "gpt-oss", .provider = "Ollama Cloud" },
    }, &.{"llama3:70b"}, "qwen3:8b");

    try std.testing.expectEqualStrings("Recent", picker.rows.items[0].heading);
    try std.testing.expectEqualStrings("llama3:70b", picker.entries[picker.rows.items[1].entry].name);
    try std.testing.expectEqualStrings("Ollama", picker.rows.items[2].heading);
    try std.testing.expectEqualStrings("Ollama Cloud", picker.rows.items[5].heading);

    try std.testing.expectEqualStrings("llama3:70b", picker.selected().?.name);
}

test "a model remembers which provider offers it" {
    var picker: Picker = .init(std.testing.allocator);
    defer picker.deinit();

    try picker.show(&.{
        .{ .name = "qwen3:8b", .provider = "Ollama", .provider_id = "ollama" },
        .{ .name = "gpt-oss", .provider = "Ollama Cloud", .provider_id = "ollama-cloud" },
    }, &.{}, "qwen3:8b");

    try std.testing.expectEqualStrings("ollama", picker.selected().?.provider_id);

    try picker.search.insertText("gpt");
    try picker.filter();
    try std.testing.expectEqualStrings("gpt-oss", picker.selected().?.name);
    try std.testing.expectEqualStrings("ollama-cloud", picker.selected().?.provider_id);
}

test "typing filters on the model and the provider" {
    var picker: Picker = .init(std.testing.allocator);
    defer picker.deinit();

    try picker.show(&.{
        .{ .name = "qwen3:8b", .provider = "Ollama" },
        .{ .name = "llama3:70b", .provider = "Ollama" },
        .{ .name = "gpt-oss", .provider = "Ollama Cloud" },
    }, &.{}, "");

    try picker.search.insertText("llama");
    try picker.filter();
    try std.testing.expectEqual(@as(usize, 1), picker.matches.items.len);
    try std.testing.expectEqualStrings("llama3:70b", picker.selected().?.name);

    picker.search.clear();
    try picker.search.insertText("cloud");
    try picker.filter();
    try std.testing.expectEqual(@as(usize, 1), picker.matches.items.len);
    try std.testing.expectEqualStrings("gpt-oss", picker.selected().?.name);

    picker.search.clear();
    try picker.search.insertText("ollama");
    try picker.filter();
    try std.testing.expectEqual(@as(usize, 3), picker.matches.items.len);

    picker.search.clear();
    try picker.search.insertText("nope");
    try picker.filter();
    try std.testing.expect(picker.selected() == null);

    // A catalog arriving after the picker opens must keep the user's query.
    try picker.show(&.{
        .{ .name = "unrelated", .provider = "Ollama" },
        .{ .name = "nope-new-model", .provider = "Ollama" },
    }, &.{}, "");
    try std.testing.expectEqualStrings("nope", picker.search.text.items);
    try std.testing.expectEqual(@as(usize, 1), picker.matches.items.len);
    try std.testing.expectEqualStrings("nope-new-model", picker.selected().?.name);
}

test "the cursor steps over headings and stops at the ends" {
    var picker: Picker = .init(std.testing.allocator);
    defer picker.deinit();

    try picker.show(&.{
        .{ .name = "a", .provider = "One" },
        .{ .name = "b", .provider = "Two" },
    }, &.{}, "");

    try std.testing.expectEqualStrings("a", picker.selected().?.name);
    picker.move(-1);
    try std.testing.expectEqualStrings("a", picker.selected().?.name);

    picker.move(1);
    try std.testing.expectEqualStrings("b", picker.selected().?.name);
    picker.move(1);
    try std.testing.expectEqualStrings("b", picker.selected().?.name);
}

test "the box draws at every size, however long the list" {
    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    var names: [40][16]u8 = undefined;
    var entries: [40]Entry = undefined;
    for (&entries, &names, 0..) |*entry, *buffer, i| {
        entry.* = .{
            .name = try std.fmt.bufPrint(buffer, "model-{d}", .{i}),
            .provider = "Ollama",
        };
    }

    for ([_]usize{ 0, 1, 7, 8, 11, 12, 13, 40 }) |count| {
        var picker: Picker = .init(std.testing.allocator);
        defer picker.deinit();
        try picker.show(entries[0..count], &.{}, "model-0");

        var height: u16 = 0;
        while (height <= 40) : (height += 3) {
            var width: u16 = 0;
            while (width <= 120) : (width += 9) {
                var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
                defer arena_state.deinit();

                const ctx: vxfw.DrawContext = .{
                    .arena = arena_state.allocator(),
                    .min = .{},
                    .max = .{ .width = width, .height = height },
                    .cell_size = .{ .width = 10, .height = 20 },
                };
                const drawn = try picker.draw(ctx, widget, .{ .width = width, .height = height });
                if (drawn) |box| {
                    try std.testing.expect(box.surface.size.width <= width);
                    try std.testing.expect(box.surface.size.height <= height);
                }
            }
        }
    }
}

test "the box is drawn without overflowing its own arithmetic" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var picker: Picker = .init(std.testing.allocator);
    defer picker.deinit();

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
        .max = .{ .width = 100, .height = 40 },
        .cell_size = .{ .width = 10, .height = 20 },
    };

    try picker.show(&.{
        .{ .name = "qwen3:8b", .provider = "Ollama" },
        .{ .name = "llama3:70b", .provider = "Ollama" },
    }, &.{"llama3:70b"}, "qwen3:8b");

    const drawn = (try picker.draw(ctx, widget, .{ .width = 100, .height = 40 })).?;
    try std.testing.expectEqual(
        @as(usize, drawn.surface.size.width) * drawn.surface.size.height,
        drawn.surface.buffer.len,
    );

    try std.testing.expect(try picker.draw(ctx, widget, .{ .width = 20, .height = 40 }) == null);
    try std.testing.expect(try picker.draw(ctx, widget, .{ .width = 100, .height = 4 }) == null);
}
