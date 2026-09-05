//! Connecting a provider: pick one, then give it what it needs.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const catalog = @import("../provider/catalog.zig");
const Input = @import("input.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Connect = @This();

/// Box width, clamped to the terminal when it is smaller.
const box_width: u16 = 64;
/// Left and right padding inside the box.
const pad: u16 = 2;
/// Ceiling on what can be typed into either field. A key is around a hundred
/// characters; a URL is shorter. Anything past this is a paste that went wrong.
pub const max_value_bytes: usize = 512;

/// What the caller knows about one provider, for the list to show.
pub const State = struct {
    /// Catalog id.
    id: []const u8,
    /// The host in use, or the catalog default when nothing is configured.
    host: []const u8,
    /// Whether a credential is already stored for it.
    connected: bool,
    /// Whether this is the provider in use right now.
    active: bool,
};

/// Which step is on screen.
pub const Stage = enum { closed, choosing, host, key };

/// A provider row: the catalog entry, plus what the caller knows about it.
const Row = struct {
    entry: catalog.Entry,
    host: []const u8,
    connected: bool,
    active: bool,
};

allocator: std.mem.Allocator,
stage: Stage = .closed,
rows: std.ArrayList(Row) = .empty,
cursor: usize = 0,
/// The row being connected, once one has been chosen.
chosen: usize = 0,
host: Input,
key: Input,

pub fn init(allocator: std.mem.Allocator) Connect {
    return .{
        .allocator = allocator,
        .host = .init(allocator),
        .key = .init(allocator),
    };
}

pub fn deinit(self: *Connect) void {
    self.release();
    self.rows.deinit(self.allocator);
    self.host.deinit();
    self.key.deinit();
}

fn release(self: *Connect) void {
    for (self.rows.items) |row| self.allocator.free(row.host);
    self.rows.clearRetainingCapacity();
}

pub fn isOpen(self: *const Connect) bool {
    return self.stage != .closed;
}

/// Open on the provider list. `states` is borrowed for the length of the call;
/// the hosts are duped, since they come from a config that a reconnect will
/// replace out from under this.
pub fn show(self: *Connect, states: []const State) !void {
    self.release();

    for (catalog.all, 0..) |entry, i| {
        const known_state = findProviderState(states, entry.id);
        const host = if (known_state) |state| state.host else entry.host;
        const is_connected = if (known_state) |state| state.connected else false;
        const is_active = if (known_state) |state| state.active else false;
        try self.rows.append(self.allocator, .{
            .entry = entry,
            .host = try self.allocator.dupe(u8, host),
            .connected = is_connected,
            .active = is_active,
        });
        if (is_active) self.cursor = i;
    }

    self.stage = .choosing;
    self.host.clear();
    self.key.clear();
}

fn findProviderState(states: []const State, id: []const u8) ?State {
    for (states) |state| {
        if (std.mem.eql(u8, state.id, id)) return state;
    }
    return null;
}

pub fn close(self: *Connect) void {
    self.stage = .closed;
    self.release();
    self.host.clear();
    self.key.clear();
    self.cursor = 0;
    self.chosen = 0;
}

/// What the caller should do with the dialog after a key.
pub const Action = union(enum) {
    none,
    cancel,
    disconnect: []const u8,
    /// The user finished: connect this provider and store what came back.
    connect: Result,
};

pub const Result = struct {
    id: []const u8,
    host: []const u8,
    /// Null when the provider takes no key, or the field was left empty.
    key: ?[]const u8,
};

pub fn handleKey(self: *Connect, ctx: *vxfw.EventContext, key_press: vaxis.Key) !Action {
    return switch (self.stage) {
        .closed => .none,
        .choosing => self.handleProviderListKey(key_press),
        .host, .key => self.handleConnectionFieldKey(ctx, key_press),
    };
}

fn handleProviderListKey(self: *Connect, key_press: vaxis.Key) Action {
    const pressed_escape = key_press.matches(vaxis.Key.escape, .{});
    if (pressed_escape) return .cancel;

    const row = self.rows.items[self.cursor];
    const pressed_disconnect = key_press.matches('d', .{});
    const can_disconnect = row.connected and row.entry.key == .oauth;
    const requested_disconnect = pressed_disconnect and can_disconnect;
    if (requested_disconnect) {
        return .{ .disconnect = row.entry.id };
    }

    const requested_previous_row = key_press.matches(vaxis.Key.up, .{}) or key_press.matches('p', .{ .ctrl = true });
    if (requested_previous_row) {
        const has_previous_row = self.cursor > 0;
        if (has_previous_row) self.cursor -= 1;
        return .none;
    }
    const requested_next_row = key_press.matches(vaxis.Key.down, .{}) or key_press.matches('n', .{ .ctrl = true });
    if (requested_next_row) {
        const has_next_row = self.cursor + 1 < self.rows.items.len;
        if (has_next_row) self.cursor += 1;
        return .none;
    }
    const pressed_enter = key_press.matches(vaxis.Key.enter, .{});
    if (pressed_enter) {
        self.chosen = self.cursor;
        const uses_browser_sign_in = self.rows.items[self.chosen].entry.key == .oauth;
        if (uses_browser_sign_in) return self.submitSelection();
        self.openConnectionFields() catch return .none;
        return .none;
    }
    return .none;
}

/// Move on to whatever the chosen provider has to be asked. A host that is not
/// the user's to set is skipped; so is a key for a provider that has one
/// already, which is what makes reconnecting a stored provider a single Enter.
fn openConnectionFields(self: *Connect) !void {
    const row = self.rows.items[self.chosen];

    self.host.clear();
    self.key.clear();
    if (row.entry.host_editable) {
        try self.host.insertText(row.host);
        self.stage = .host;
        return;
    }
    self.stage = .key;
}

fn handleConnectionFieldKey(self: *Connect, ctx: *vxfw.EventContext, key_press: vaxis.Key) !Action {
    if (key_press.matches(vaxis.Key.escape, .{})) {
        const editing_key = self.stage == .key;
        const host_is_editable = self.rows.items[self.chosen].entry.host_editable;
        const should_return_to_host = editing_key and host_is_editable;
        self.stage = if (should_return_to_host) .host else .choosing;
        return .none;
    }

    if (key_press.matches(vaxis.Key.enter, .{})) {
        if (self.stage == .host) {
            self.stage = .key;
            return .none;
        }
        return self.submitSelection();
    }

    const editing = self.focus().?;
    if (editing.text.items.len >= max_value_bytes and key_press.text != null) return .none;
    try editing.handleEvent(ctx, .{ .key_press = key_press });
    return .none;
}

/// The result, or a refusal to finish. A hosted provider with no key would be
/// a connection that fails on its first turn, so the dialog stays open on the
/// field that is missing.
fn submitSelection(self: *Connect) Action {
    const row = self.rows.items[self.chosen];
    const typed_key = trimmed(&self.key);

    const requires_api_key = row.entry.key == .required;
    const key_was_omitted = typed_key.len == 0;
    const needs_new_credential = !row.connected;
    const required_key_is_missing = requires_api_key and key_was_omitted and needs_new_credential;
    if (required_key_is_missing) return .none;

    const host = if (row.entry.host_editable) blk: {
        const typed_host = trimmed(&self.host);
        const has_typed_host = typed_host.len > 0;
        break :blk if (has_typed_host) typed_host else row.entry.host;
    } else row.entry.host;
    const accepts_api_key = row.entry.key != .oauth;
    const has_typed_key = typed_key.len > 0;
    const should_use_typed_key = accepts_api_key and has_typed_key;
    const api_key = if (should_use_typed_key) typed_key else null;

    return .{
        .connect = .{
            .id = row.entry.id,
            .host = host,
            .key = api_key,
        },
    };
}

/// The field the keyboard is in, or null on a step that has none. Also what a
/// paste lands in: the app routes one to whatever owns the keyboard.
pub fn focus(self: *Connect) ?*Input {
    return switch (self.stage) {
        .closed, .choosing => null,
        .host => &self.host,
        .key => &self.key,
    };
}

fn trimmed(input: *const Input) []const u8 {
    return std.mem.trim(u8, input.text.items, " \t\r\n");
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
    cursor: ?vxfw.CursorState = null,
};

pub fn draw(self: *Connect, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    return switch (self.stage) {
        .closed => null,
        .choosing => self.drawList(ctx, parent, size),
        .host, .key => self.drawField(ctx, parent, size),
    };
}

fn drawList(self: *Connect, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    const chrome: u16 = 6;
    const visible: u16 = @intCast(@min(self.rows.items.len, 16));
    const height: u16 = chrome + @max(visible, 1);
    if (size.width < 32 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    const surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "Connect a provider", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    for (self.rows.items[0..visible], 0..) |row, i| {
        const y: u16 = @intCast(3 + i);
        const chosen = i == self.cursor;
        const base = if (chosen) theme.card.withBg(theme.surface_alt) else theme.card;
        if (chosen) w.fillRow(surface, y, 1, width - 2, base.cell);

        if (row.active) {
            _ = w.writeText(surface, pad, y, "●", base.withFg(theme.success).cell);
        } else if (row.connected) {
            _ = w.writeText(surface, pad, y, "✓", base.withFg(theme.fg_muted).cell);
        }

        var x = w.writeText(surface, pad + 2, y, row.entry.label, base.withFg(theme.fg).cell);
        x = w.writeText(surface, x + 1, y, row.entry.summary, base.withFg(theme.fg_dim).cell);

        const needs_connection = !row.connected;
        if (needs_connection) {
            const requirement_label = switch (row.entry.key) {
                .optional => "",
                .required => "needs a key",
                .oauth => "needs sign-in",
            };
            const shows_requirement = requirement_label.len > 0;
            if (shows_requirement) _ = w.writeText(surface, x + 1, y, requirement_label, base.withFg(theme.warning).cell);
        }
    }

    const hint_row = height - 2;
    const selected = self.rows.items[self.cursor];
    var hint = w.writeText(surface, pad, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " select   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    const primary_action_label = if (selected.connected) " use" else " connect";
    hint = w.writeText(surface, hint, hint_row, primary_action_label, theme.on_card(theme.fg_dim).cell);
    const can_disconnect = selected.connected and selected.entry.key == .oauth;
    if (can_disconnect) {
        hint = w.writeText(surface, hint, hint_row, "   d", theme.on_card(theme.fg_muted).bold().cell);
        _ = w.writeText(surface, hint, hint_row, " disconnect", theme.on_card(theme.fg_dim).cell);
    }

    return .{ .surface = surface, .origin = .{ .row = origin_row, .col = origin_col } };
}

fn drawField(self: *Connect, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    const height: u16 = 7;
    if (size.width < 32 or size.height < height) return null;

    const width = @min(box_width, size.width -| 4);
    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    var surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    const row = self.rows.items[self.chosen];
    const title = if (self.stage == .host) "Server URL" else "API key";
    var x = w.writeText(surface, pad, 1, title, theme.on_card(theme.fg).bold().cell);
    _ = w.writeText(surface, x + 1, 1, row.entry.label, theme.on_card(theme.fg_dim).cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);

    var cursor: ?vxfw.CursorState = null;
    const field_row: u16 = 3;
    const inner = width -| (pad * 2);
    if (inner > 0) {
        const active = self.focus().?;
        active.style = theme.card.cell;
        active.placeholder = if (self.stage == .host)
            row.entry.host
        else if (row.connected)
            "leave empty to keep the stored key"
        else switch (row.entry.key) {
            .optional => "optional",
            .required => "required",
            .oauth => unreachable,
        };
        active.placeholder_style = theme.on_card(theme.fg_dim).cell;
        active.height = 1;
        const drawn = try active.draw(ctx.withConstraints(
            .{ .width = inner, .height = 1 },
            .{ .width = inner, .height = 1 },
        ));
        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = field_row, .col = pad }, .surface = drawn };
        surface.children = children;

        if (drawn.cursor) |position| {
            cursor = .{
                .row = origin_row + field_row + position.row,
                .col = origin_col + pad + position.col,
                .shape = .block,
            };
        }
    }

    const hint_row = height - 2;
    x = w.writeText(surface, pad, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    const next = if (self.stage == .host) " continue   " else " connect   ";
    x = w.writeText(surface, x, hint_row, next, theme.on_card(theme.fg_dim).cell);
    x = w.writeText(surface, x, hint_row, "esc", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, x, hint_row, " back", theme.on_card(theme.fg_dim).cell);

    return .{
        .surface = surface,
        .origin = .{ .row = origin_row, .col = origin_col },
        .cursor = cursor,
    };
}

/// Drive the dialog with a key, the way the app does.
fn press(self: *Connect, key_press: vaxis.Key) !Action {
    var ctx: vxfw.EventContext = .{
        .phase = .at_target,
        .io = testing.io,
        .alloc = testing.allocator,
        .cmds = .empty,
    };
    defer ctx.cmds.deinit(testing.allocator);
    return self.handleKey(&ctx, key_press);
}

fn typeText(self: *Connect, text: []const u8) !void {
    for (text) |byte| {
        const buffer = [_]u8{byte};
        _ = try self.press(.{ .codepoint = byte, .text = &buffer });
    }
}

test "connecting the hosted provider asks for a key and nothing else" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.show(&.{
        .{ .id = "ollama", .host = "http://localhost:11434", .connected = false, .active = true },
        .{ .id = "ollama-cloud", .host = "https://ollama.com", .connected = false, .active = false },
    });

    try testing.expectEqual(Stage.choosing, connect.stage);
    try testing.expectEqual(@as(usize, 0), connect.cursor);

    _ = try connect.press(.{ .codepoint = vaxis.Key.down });
    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });

    try testing.expectEqual(Stage.key, connect.stage);

    try testing.expectEqual(Action.none, try connect.press(.{ .codepoint = vaxis.Key.enter }));
    try testing.expectEqual(Stage.key, connect.stage);

    try connect.typeText("sk-secret");
    const action = try connect.press(.{ .codepoint = vaxis.Key.enter });

    try testing.expectEqualStrings("ollama-cloud", action.connect.id);
    try testing.expectEqualStrings("https://ollama.com", action.connect.host);
    try testing.expectEqualStrings("sk-secret", action.connect.key.?);
}

test "selecting signed-out Codex starts sign-in without credential fields" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();
    try connect.show(&.{
        .{ .id = "codex", .host = "https://chatgpt.com/backend-api/codex", .connected = false, .active = true },
    });
    const connect_action = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqualStrings("codex", connect_action.connect.id);
    try testing.expect(connect_action.connect.key == null);
}

test "a connected Codex account can be disconnected" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();
    try connect.show(&.{.{ .id = "codex", .host = "https://chatgpt.com/backend-api/codex", .connected = true, .active = true }});
    const disconnect_action = try connect.press(.{ .codepoint = 'd', .text = "d" });
    try testing.expectEqualStrings("codex", disconnect_action.disconnect);
}

test "connecting the local provider asks for a URL first, and a key second" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.show(&.{
        .{ .id = "ollama", .host = "http://box:11434", .connected = false, .active = false },
    });

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });

    try testing.expectEqual(Stage.host, connect.stage);
    try testing.expectEqualStrings("http://box:11434", connect.host.text.items);

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(Stage.key, connect.stage);

    const action = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqualStrings("ollama", action.connect.id);
    try testing.expectEqualStrings("http://box:11434", action.connect.host);
    try testing.expect(action.connect.key == null);
}

test "an empty URL falls back to the provider's own" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.show(&.{
        .{ .id = "ollama", .host = "http://box:11434", .connected = false, .active = false },
    });

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    connect.host.clear();
    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    const action = try connect.press(.{ .codepoint = vaxis.Key.enter });

    try testing.expectEqualStrings("http://localhost:11434", action.connect.host);
}

test "only the steps that take typing have a field" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try testing.expect(connect.focus() == null);

    try connect.show(&.{
        .{ .id = "ollama", .host = "http://localhost:11434", .connected = false, .active = true },
    });
    try testing.expect(connect.focus() == null);

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(&connect.host, connect.focus().?);

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(&connect.key, connect.focus().?);
}

test "escape walks back a step, and out of the list" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.show(&.{
        .{ .id = "ollama", .host = "http://localhost:11434", .connected = false, .active = true },
        .{ .id = "ollama-cloud", .host = "https://ollama.com", .connected = true, .active = false },
    });

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(Stage.host, connect.stage);

    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(Stage.key, connect.stage);

    _ = try connect.press(.{ .codepoint = vaxis.Key.escape });
    try testing.expectEqual(Stage.host, connect.stage);
    _ = try connect.press(.{ .codepoint = vaxis.Key.escape });
    try testing.expectEqual(Stage.choosing, connect.stage);

    try testing.expectEqual(Action.cancel, try connect.press(.{ .codepoint = vaxis.Key.escape }));
}

test "a provider that already has a key connects on one Enter" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.show(&.{
        .{ .id = "ollama-cloud", .host = "https://ollama.com", .connected = true, .active = false },
    });
    try testing.expectEqual(catalog.all.len, connect.rows.items.len);

    _ = try connect.press(.{ .codepoint = vaxis.Key.down });
    _ = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqual(Stage.key, connect.stage);

    const action = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqualStrings("ollama-cloud", action.connect.id);
    try testing.expect(action.connect.key == null);
}
