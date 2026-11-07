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
/// Rows of the sign-in link shown before it is cut short. Every row links to
/// the whole of it, and `c` copies all of it.
const max_url_rows: usize = 8;

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
pub const Stage = enum { closed, choosing, host, key, signing_in };

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
/// The page a browser sign-in is waiting on, while one is. Owned.
sign_in_url: []const u8 = "",
/// The loopback port the sign-in listener actually bound.
sign_in_port: u16 = 0,
/// Whether to tell the person how to reach the callback from another machine.
sign_in_over_ssh: bool = false,

pub fn init(allocator: std.mem.Allocator) Connect {
    return .{
        .allocator = allocator,
        .host = .init(allocator),
        .key = .init(allocator),
    };
}

pub fn deinit(self: *Connect) void {
    self.forgetSignIn();
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

/// Whether the list showed provider `id` as having what it needs.
pub fn isConnected(self: *const Connect, id: []const u8) bool {
    for (self.rows.items) |row| {
        if (std.mem.eql(u8, row.entry.id, id)) return row.connected;
    }
    return false;
}

pub fn isSigningIn(self: *const Connect) bool {
    return self.stage == .signing_in;
}

/// Open on the provider list. `states` is borrowed for the length of the call;
/// the hosts are duped, since they come from a config that a reconnect will
/// replace out from under this.
pub fn show(self: *Connect, states: []const State) !void {
    self.release();

    for (catalog.all, 0..) |entry, i| {
        const state = find(states, entry.id);
        try self.rows.append(self.allocator, .{
            .entry = entry,
            .host = try self.allocator.dupe(u8, if (state) |s| s.host else entry.host),
            .connected = if (state) |s| s.connected else false,
            .active = if (state) |s| s.active else false,
        });
        if (state) |s| {
            if (s.active) self.cursor = i;
        }
    }

    self.stage = .choosing;
    self.host.clear();
    self.key.clear();
}

fn find(states: []const State, id: []const u8) ?State {
    for (states) |state| {
        if (std.mem.eql(u8, state.id, id)) return state;
    }
    return null;
}

pub fn close(self: *Connect) void {
    self.forgetSignIn();
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
    /// The user finished: connect this provider and store what came back.
    connect: Result,
    /// The user gave up waiting on the browser.
    cancel_sign_in,
    reopen_sign_in,
    /// Put the sign-in link on the clipboard, for a browser elsewhere.
    copy_sign_in,
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
        .choosing => self.chooseKey(key_press),
        .host, .key => self.editKey(ctx, key_press),
        .signing_in => signInKey(key_press),
    };
}

fn signInKey(key_press: vaxis.Key) Action {
    if (key_press.matches(vaxis.Key.escape, .{}) or key_press.matches('c', .{ .ctrl = true })) return .cancel_sign_in;
    if (key_press.matches('o', .{})) return .reopen_sign_in;
    if (key_press.matches('c', .{})) return .copy_sign_in;
    return .none;
}

pub fn showSignIn(self: *Connect, url: []const u8, port: u16, over_ssh: bool) !void {
    self.forgetSignIn();
    self.sign_in_url = try self.allocator.dupe(u8, url);
    self.sign_in_port = port;
    self.sign_in_over_ssh = over_ssh;
    self.stage = .signing_in;
}

fn forgetSignIn(self: *Connect) void {
    if (self.sign_in_url.len > 0) self.allocator.free(self.sign_in_url);
    self.sign_in_url = "";
    self.sign_in_port = 0;
}

fn chooseKey(self: *Connect, key_press: vaxis.Key) Action {
    if (key_press.matches(vaxis.Key.escape, .{})) return .cancel;

    if (key_press.matches(vaxis.Key.up, .{}) or key_press.matches('p', .{ .ctrl = true })) {
        if (self.cursor > 0) self.cursor -= 1;
        return .none;
    }
    if (key_press.matches(vaxis.Key.down, .{}) or key_press.matches('n', .{ .ctrl = true })) {
        if (self.cursor + 1 < self.rows.items.len) self.cursor += 1;
        return .none;
    }
    if (key_press.matches(vaxis.Key.enter, .{})) {
        self.chosen = self.cursor;
        const row = self.rows.items[self.chosen];
        if (row.entry.key == .oauth) return .{ .connect = .{ .id = row.entry.id, .host = row.entry.host, .key = null } };
        self.openFields() catch return .none;
        return .none;
    }
    return .none;
}

/// Move on to whatever the chosen provider has to be asked. A host that is not
/// the user's to set is skipped; so is a key for a provider that has one
/// already, which is what makes reconnecting a stored provider a single Enter.
fn openFields(self: *Connect) !void {
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

fn editKey(self: *Connect, ctx: *vxfw.EventContext, key_press: vaxis.Key) !Action {
    if (key_press.matches(vaxis.Key.escape, .{})) {
        self.stage = if (self.stage == .key and self.rows.items[self.chosen].entry.host_editable)
            .host
        else
            .choosing;
        return .none;
    }

    if (key_press.matches(vaxis.Key.enter, .{})) {
        if (self.stage == .host) {
            self.stage = .key;
            return .none;
        }
        return self.finish();
    }

    const editing = self.focus().?;
    if (editing.text.items.len >= max_value_bytes and key_press.text != null) return .none;
    try editing.handleEvent(ctx, .{ .key_press = key_press });
    return .none;
}

/// The result, or a refusal to finish. A hosted provider with no key would be
/// a connection that fails on its first turn, so the dialog stays open on the
/// field that is missing.
fn finish(self: *Connect) Action {
    const row = self.rows.items[self.chosen];
    const typed = trimmed(&self.key);

    if (row.entry.key == .required and typed.len == 0 and !row.connected) return .none;

    const host = if (row.entry.host_editable) blk: {
        const value = trimmed(&self.host);
        break :blk if (value.len > 0) value else row.entry.host;
    } else row.entry.host;

    return .{
        .connect = .{
            .id = row.entry.id,
            .host = host,
            .key = if (typed.len > 0) typed else null,
        },
    };
}

/// The field the keyboard is in, or null on a step that has none. Also what a
/// paste lands in: the app routes one to whatever owns the keyboard.
pub fn focus(self: *Connect) ?*Input {
    return switch (self.stage) {
        .closed, .choosing, .signing_in => null,
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
        .signing_in => self.drawSignIn(ctx, parent, size),
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

        if (row.entry.key == .required and !row.connected) {
            _ = w.writeText(surface, x + 1, y, "needs a key", base.withFg(theme.warning).cell);
        }
        if (row.entry.key == .oauth and !row.connected) {
            _ = w.writeText(surface, x + 1, y, "browser sign-in", base.withFg(theme.fg_muted).cell);
        }
    }

    const hint_row = height - 2;
    var hint = w.writeText(surface, pad, hint_row, "↑↓", theme.on_card(theme.fg_muted).bold().cell);
    hint = w.writeText(surface, hint, hint_row, " select   ", theme.on_card(theme.fg_dim).cell);
    hint = w.writeText(surface, hint, hint_row, "enter", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, hint, hint_row, " connect", theme.on_card(theme.fg_dim).cell);

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
        else if (row.entry.key == .optional)
            "optional"
        else
            "required";
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

fn drawSignIn(self: *Connect, ctx: vxfw.DrawContext, parent: vxfw.Widget, size: vxfw.Size) !?Drawn {
    if (size.width < 32) return null;
    const width = @min(box_width, size.width -| 4);
    const inner: usize = width -| (pad * 2);
    const url_rows: u16 = @intCast(@min(max_url_rows, std.math.divCeil(usize, self.sign_in_url.len, inner) catch 0));
    const ssh_rows: u16 = if (self.sign_in_over_ssh) 3 else 0;
    const fixed_rows: u16 = 10;
    const height: u16 = fixed_rows + url_rows + ssh_rows;
    if (size.height < height) return null;

    const origin_row = (size.height -| height) / 2;
    const origin_col = (size.width -| width) / 2;

    const surface = try w.surfaceClamped(ctx.arena, parent, .{ .width = width, .height = height });
    w.fill(surface, theme.card.cell);

    _ = w.writeText(surface, pad, 1, "Sign in with ChatGPT", theme.on_card(theme.fg).bold().cell);
    w.writeTextRight(surface, 1, pad, "esc", theme.on_card(theme.fg_dim).cell);
    _ = w.writeText(surface, pad, 3, "Finish in your browser. If it did not open, visit:", theme.on_card(theme.fg_muted).cell);

    var remaining = self.sign_in_url;
    var row: u16 = 5;
    const last_url_row = row + url_rows - 1;
    while (remaining.len > 0 and row <= last_url_row) : (row += 1) {
        const is_cut = row == last_url_row and remaining.len > inner;
        const take = if (is_cut) inner -| 1 else @min(remaining.len, inner);
        const shown = if (is_cut) try std.fmt.allocPrint(ctx.arena, "{s}…", .{remaining[0..take]}) else remaining[0..take];
        _ = w.writeLinked(surface, pad, row, shown, theme.on_card(theme.accent_alt).cell, self.sign_in_url);
        remaining = remaining[take..];
    }

    if (self.sign_in_over_ssh) {
        row += 1;
        _ = w.writeText(surface, pad, row, "Over SSH, forward the callback first: press ~C, then", theme.on_card(theme.fg_dim).cell);
        const forward = try std.fmt.allocPrint(ctx.arena, "-L {d}:127.0.0.1:{d}", .{ self.sign_in_port, self.sign_in_port });
        _ = w.writeText(surface, pad, row + 1, forward, theme.on_card(theme.fg_muted).cell);
        row += 2;
    }

    const actions_row = row + 1;
    var action = w.writeText(surface, pad, actions_row, "o", theme.on_card(theme.fg_muted).bold().cell);
    action = w.writeText(surface, action, actions_row, " open it again   ", theme.on_card(theme.fg_dim).cell);
    action = w.writeText(surface, action, actions_row, "c", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, action, actions_row, " copy the link", theme.on_card(theme.fg_dim).cell);

    const hint_row = height - 2;
    var x = w.writeText(surface, pad, hint_row, "waiting for the browser   ", theme.on_card(theme.fg_dim).cell);
    x = w.writeText(surface, x, hint_row, "esc", theme.on_card(theme.fg_muted).bold().cell);
    _ = w.writeText(surface, x, hint_row, " cancel", theme.on_card(theme.fg_dim).cell);

    return .{ .surface = surface, .origin = .{ .row = origin_row, .col = origin_col } };
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

test "a browser sign-in row connects on Enter, whatever was left in the key field" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.show(&.{});
    connect.cursor = connect.rows.items.len - 1;
    try testing.expectEqual(catalog.Key.oauth, connect.rows.items[connect.cursor].entry.key);
    try connect.key.insertText("sk-left-over");

    const action = try connect.press(.{ .codepoint = vaxis.Key.enter });
    try testing.expectEqualStrings(catalog.chatgpt_id, action.connect.id);
    try testing.expect(action.connect.key == null);
}

test "escape while waiting on the browser cancels the sign-in" {
    var connect: Connect = .init(testing.allocator);
    defer connect.deinit();

    try connect.showSignIn("https://auth.openai.com/api/accounts/authorize?x=1", 1462, false);
    try testing.expectEqual(Stage.signing_in, connect.stage);
    try testing.expectEqual(@as(u16, 1462), connect.sign_in_port);
    try testing.expect(connect.focus() == null);
    try testing.expectEqual(Action.none, try connect.press(.{ .codepoint = vaxis.Key.enter }));
    try testing.expectEqual(Action.reopen_sign_in, try connect.press(.{ .codepoint = 'o', .text = "o" }));
    try testing.expectEqual(Action.copy_sign_in, try connect.press(.{ .codepoint = 'c', .text = "c" }));
    try testing.expectEqual(Action.cancel_sign_in, try connect.press(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try testing.expectEqual(Action.cancel_sign_in, try connect.press(.{ .codepoint = vaxis.Key.escape }));
}
