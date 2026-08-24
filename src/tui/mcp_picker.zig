//! The MCP server list: what is configured, what is up, and what to turn off.
//!
//! Toggling is the point. A server is configured in a file but wanted or not
//! from one session to the next, and editing JSON to stop talking to something
//! is a worse answer than a key press. What the toggle writes lives in
//! `mcp-auth.json` beside the tokens, so the decision survives a restart
//! without touching config a person wrote.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fuzzy = @import("../core/fuzzy.zig");
const mcp_tools = @import("../tools/mcp.zig");
const Input = @import("input.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Picker = @This();

/// Rows visible at once, before the list scrolls.
const max_rows: usize = 10;
/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 62;
/// Left and right padding inside the box.
const pad: u16 = 2;

open: bool = false,
/// Indices into `host.servers` matching the search, in display order.
matches: std.ArrayList(usize) = .empty,
cursor: usize = 0,
scroll: usize = 0,
search: Input,
allocator: std.mem.Allocator,
/// Borrowed for as long as the picker is open, which is inside one frame's
/// event handling and never across a teardown.
host: ?*mcp_tools.Host = null,

pub fn init(allocator: std.mem.Allocator) Picker {
    return .{ .allocator = allocator, .search = .init(allocator) };
}

pub fn deinit(self: *Picker) void {
    self.matches.deinit(self.allocator);
    self.search.deinit();
}

pub fn isOpen(self: *const Picker) bool {
    return self.open;
}

pub fn show(self: *Picker, host: *mcp_tools.Host) !void {
    self.host = host;
    self.search.clear();
    self.cursor = 0;
    self.scroll = 0;
    try self.filter();
    self.open = true;
}

pub fn close(self: *Picker) void {
    self.open = false;
    self.host = null;
    self.search.clear();
    self.matches.clearRetainingCapacity();
}

/// The highlighted server, or null when nothing matches the search.
pub fn selected(self: *const Picker) ?mcp_tools.Server {
    const host = self.host orelse return null;
    if (self.cursor >= self.matches.items.len) return null;
    return host.servers[self.matches.items[self.cursor]];
}

pub const Action = enum { none, cancel, toggle };

pub fn handleKey(self: *Picker, ctx: *vxfw.EventContext, key: vaxis.Key) !Action {
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.space, .{})) return .toggle;

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

/// Rebuild the visible list, keeping the cursor where it was so a toggle does
/// not move the selection out from under the next key press.
pub fn filter(self: *Picker) !void {
    const host = self.host orelse return;
    const query = std.mem.trim(u8, self.search.text.items, " \t");
    const was = self.cursor;

    self.matches.clearRetainingCapacity();

    if (query.len == 0) {
        for (host.servers, 0..) |_, i| try self.matches.append(self.allocator, i);
    } else {
        var top: fuzzy.Top(max_rows) = .{};
        for (host.servers, 0..) |server, i| top.consider(i, server.name, query, .{});
        for (top.ranked()) |ranked| try self.matches.append(self.allocator, ranked.index);
    }

    self.cursor = if (was < self.matches.items.len) was else 0;
    if (self.cursor < self.scroll) self.scroll = self.cursor;
}

fn move(self: *Picker, delta: i32) void {
    if (self.matches.items.len == 0) return;

    var at: i32 = @intCast(self.cursor);
    at += delta;
    if (at < 0 or at >= @as(i32, @intCast(self.matches.items.len))) return;

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
    const host = self.host orelse return null;

    const chrome: u16 = 8;
    const visible: u16 = @intCast(@min(self.matches.items.len, max_rows));
    const height: u16 = chrome + @max(visible, 1);
    if (size.width < 36 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    var surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "MCP servers", theme.on_card(theme.fg).bold().cell);
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
    if (self.matches.items.len == 0) {
        const empty = if (host.servers.len == 0) "no servers configured" else "no matches";
        _ = w.writeText(surface, pad, first_row, empty, theme.on_card(theme.fg_dim).cell);
    }

    for (self.matches.items[self.scroll..][0..visible], 0..) |index, i| {
        const server = host.servers[index];
        const y: u16 = @intCast(first_row + i);
        const chosen = self.scroll + i == self.cursor;
        const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;

        if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

        const state = describe(host, server);
        _ = w.writeText(surface, pad, y, state.mark, base.withFg(state.color).cell);

        const name_style = if (state.on) base.withFg(theme.fg) else base.withFg(theme.fg_dim);
        const x = w.writeText(surface, pad + 2, y, server.name, name_style.cell);
        _ = w.writeText(surface, x + 1, y, state.detail, base.withFg(theme.fg_muted).cell);
    }

    const hint_row = height - 2;
    var hint = w.writeText(surface, pad, hint_row, "space", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " toggle   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, hint, hint_row, " move", theme.on_card(theme.fg_dim).cell);

    return .{
        .surface = surface,
        .origin = .{ .row = origin_row, .col = origin_col },
        .cursor = cursor,
    };
}

const State = struct {
    on: bool,
    mark: []const u8,
    color: theme.Color,
    detail: []const u8,
};

/// What to say about one server: whether it is wanted, and what came of it.
fn describe(host: *mcp_tools.Host, server: mcp_tools.Server) State {
    const wanted = server.enabled and if (host.auth) |store| store.isEnabled(server.name) else true;
    if (!wanted) return .{ .on = false, .mark = "○", .color = theme.fg_dim, .detail = "off" };

    if (host.find(server.name)) |connection| {
        return .{
            .on = true,
            .mark = "●",
            .color = theme.success,
            .detail = if (connection.installed) "connected" else "connecting",
        };
    }

    for (host.failures.items) |failure| {
        if (std.mem.eql(u8, failure.server, server.name)) {
            return .{ .on = true, .mark = "✕", .color = theme.danger, .detail = failure.reason };
        }
    }

    return .{ .on = true, .mark = "◌", .color = theme.fg_muted, .detail = "connecting" };
}

test "an empty search lists every configured server" {
    var picker: Picker = .init(testing.allocator);
    defer picker.deinit();

    var host: mcp_tools.Host = .init(testing.allocator, testing.io);
    defer host.deinit();
    host.servers = &.{
        .{ .name = "files", .transport = .{ .stdio = .{ .command = "npx" } } },
        .{ .name = "linear", .transport = .{ .http = .{ .url = "https://x/mcp" } } },
    };

    try picker.show(&host);
    try testing.expectEqual(@as(usize, 2), picker.matches.items.len);
    try testing.expectEqualStrings("files", picker.selected().?.name);
}

test "a server nobody has turned off reads as wanted" {
    var host: mcp_tools.Host = .init(testing.allocator, testing.io);
    defer host.deinit();

    const server: mcp_tools.Server = .{
        .name = "files",
        .transport = .{ .stdio = .{ .command = "npx" } },
    };

    try testing.expect(describe(&host, server).on);

    const off: mcp_tools.Server = .{
        .name = "off",
        .transport = .{ .stdio = .{ .command = "npx" } },
        .enabled = false,
    };
    try testing.expect(!describe(&host, off).on);
}

test "a failure is what the row says, not a bare dot" {
    var host: mcp_tools.Host = .init(testing.allocator, testing.io);
    defer host.deinit();

    try host.failures.append(testing.allocator, .{ .server = "linear", .reason = "not signed in" });

    const state = describe(&host, .{
        .name = "linear",
        .transport = .{ .http = .{ .url = "https://x/mcp" } },
    });
    try testing.expectEqualStrings("not signed in", state.detail);
}
