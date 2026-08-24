//! Toasts in the top-right of the transcript column: something happened that
//! the transcript itself is the wrong place for.
//!
//! Several can be up at once, stacked oldest at the top. Each owns its text,
//! since most of what a toast says is formatted on the spot, and each takes
//! itself away: dismissal is a deadline rather than a countdown, so a redraw
//! that happens for any other reason retires an expired toast too, and the tick
//! one schedules is only there to guarantee the frame.

const std = @import("std");
const testing = std.testing;

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Notification = @This();

pub const Kind = enum {
    info,
    warn,
    err,

    fn color(self: Kind) theme.Color {
        return switch (self) {
            .info => theme.accent_alt,
            .warn => theme.warning,
            .err => theme.danger,
        };
    }

    fn glyph(self: Kind) []const u8 {
        return switch (self) {
            .info => "●",
            .warn => "▲",
            .err => "✕",
        };
    }
};

/// How long a toast stays up.
pub const visible_ms: i64 = 4_000;
/// How many can be up at once. A fixed set of slots rather than a list, so a
/// toast's address never moves and the one a click lands on is the one that
/// was drawn there.
pub const capacity: usize = 4;
/// Widest a toast gets, before the column makes it narrower.
const box_width: u16 = 46;
/// Column the text starts at, leaving room for the accent bar.
const indent: u16 = 3;
/// Body rows shown before the rest is dropped.
const max_body_rows: usize = 6;
/// Blank row between stacked toasts.
const stack_gap: u16 = 1;

allocator: std.mem.Allocator,
io: std.Io,
toasts: [capacity]Toast,
/// Ordering, so the stack reads oldest-first however the slots were reused.
next_serial: u64 = 1,

/// One toast. Its own widget, so a click dismisses the one under the pointer.
const Toast = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    kind: Kind = .info,
    /// Owned. Empty when the slot is free.
    body: []const u8 = "",
    /// When this stops being drawn. Null when the slot is free.
    expires_at: ?std.Io.Timestamp = null,
    serial: u64 = 0,

    fn isOpen(self: *const Toast) bool {
        const expires_at = self.expires_at orelse return false;
        const now: std.Io.Timestamp = .now(self.io, .awake);
        return now.durationTo(expires_at).nanoseconds > 0;
    }

    fn set(self: *Toast, kind: Kind, body: []const u8, serial: u64) !void {
        const body_copy = try self.allocator.dupe(u8, body);

        self.clear();
        self.kind = kind;
        self.body = body_copy;
        self.serial = serial;

        const now: std.Io.Timestamp = .now(self.io, .awake);
        self.expires_at = now.addDuration(.fromMilliseconds(visible_ms));
    }

    fn clear(self: *Toast) void {
        self.allocator.free(self.body);
        self.body = "";
        self.expires_at = null;
    }

    fn widget(self: *Toast) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Toast = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                switch (mouse.button) {
                    .wheel_up, .wheel_down, .wheel_left, .wheel_right => return,
                    .left => {},
                    else => return ctx.consumeEvent(),
                }
                if (mouse.type == .press) {
                    self.clear();
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
                return ctx.consumeAndRedraw();
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
                ctx.redraw = true;
            },
            .tick => ctx.redraw = true,
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Toast = @ptrCast(@alignCast(ptr));
        return self.render(ctx, ctx.max.width orelse 0);
    }

    fn render(self: *Toast, ctx: vxfw.DrawContext, width: u16) std.mem.Allocator.Error!vxfw.Surface {
        if (width <= indent) return .empty(self.widget());

        const lines = try self.bodyLines(ctx.arena, width - indent - 1);
        const height: u16 = @intCast(2 + lines.len);

        const surface = try w.surfaceClamped(ctx.arena, self.widget(), .{
            .width = width,
            .height = height,
        });
        w.fill(surface, theme.card.cell);

        const accent = self.kind.color();
        for (0..height) |row| {
            _ = w.writeText(surface, 0, @intCast(row), "▌", theme.on_card(accent).cell);
        }

        _ = w.writeText(surface, 2, 1, self.kind.glyph(), theme.on_card(accent).cell);

        for (lines, 0..) |line, i| {
            _ = w.writeText(surface, indent + 1, if (i == 0) 1 else @intCast(i + 1), line, theme.on_card(theme.fg_muted).cell);
        }

        return surface;
    }

    /// Wrap the body to `width`, breaking on spaces and giving up on the rest
    /// once it runs long. A toast that grows without limit is a dialog.
    fn bodyLines(self: *const Toast, arena: std.mem.Allocator, width: u16) ![]const []const u8 {
        if (self.body.len == 0 or width == 0) return &.{};

        var lines: std.ArrayList([]const u8) = .empty;
        var paragraphs = std.mem.splitScalar(u8, self.body, '\n');
        while (paragraphs.next()) |paragraph| {
            var rest = std.mem.trim(u8, paragraph, " \t\r");
            if (rest.len == 0) continue;

            while (rest.len > 0) {
                if (lines.items.len == max_body_rows) return lines.items;
                const cut = breakAt(rest, width);
                try lines.append(arena, rest[0..cut]);
                rest = std.mem.trimStart(u8, rest[cut..], " ");
            }
        }
        return lines.items;
    }
};

pub fn init(allocator: std.mem.Allocator, io: std.Io) Notification {
    return .{
        .allocator = allocator,
        .io = io,
        .toasts = @splat(.{ .allocator = allocator, .io = io }),
    };
}

pub fn deinit(self: *Notification) void {
    self.close();
}

/// Whether anything is showing.
pub fn isOpen(self: *const Notification) bool {
    for (&self.toasts) |*toast| {
        if (toast.isOpen()) return true;
    }
    return false;
}

/// Put a toast up and ask for the frame that takes it down again.
pub fn show(
    self: *Notification,
    ctx: *vxfw.EventContext,
    kind: Kind,
    body: []const u8,
) !void {
    const slot = try self.push(kind, body);
    try ctx.tick(@intCast(visible_ms), slot.widget());
    ctx.redraw = true;
}

/// `show`, with the body formatted.
pub fn showFmt(
    self: *Notification,
    ctx: *vxfw.EventContext,
    kind: Kind,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const body = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(body);
    try self.show(ctx, kind, body);
}

/// Take a slot and fill it, without scheduling anything. A free slot first,
/// then the oldest one still up: with everything showing, the newest matters
/// more than the one that was about to go anyway.
fn push(self: *Notification, kind: Kind, body: []const u8) !*Toast {
    var chosen: *Toast = &self.toasts[0];
    for (&self.toasts) |*toast| {
        if (!toast.isOpen()) {
            chosen = toast;
            break;
        }
        if (toast.serial < chosen.serial) chosen = toast;
    }

    try chosen.set(kind, body, self.next_serial);
    self.next_serial += 1;
    return chosen;
}

/// Take every toast down at once.
pub fn close(self: *Notification) void {
    for (&self.toasts) |*toast| toast.clear();
}

pub const Drawn = struct {
    surface: vxfw.Surface,
    origin: struct { row: u16, col: u16 },
};

/// Every toast that is up, with where it goes inside `area`: stacked down from
/// the top-right corner, oldest first. Empty when nothing is showing.
pub fn draw(self: *Notification, ctx: vxfw.DrawContext, area: vxfw.Size) ![]const Drawn {
    if (area.width < indent + 8 or area.height < 3) return &.{};

    var order: [capacity]*Toast = undefined;
    const up = self.showing(&order);
    if (up.len == 0) return &.{};

    const width = @min(box_width, area.width);
    var drawn: std.ArrayList(Drawn) = .empty;
    var row: u16 = 1;

    for (up) |toast| {
        const surface = try toast.render(ctx, width);
        if (surface.size.height == 0) continue;
        if (row + surface.size.height > area.height) break;

        try drawn.append(ctx.arena, .{
            .surface = surface,
            .origin = .{ .row = row, .col = area.width - width },
        });
        row += surface.size.height + stack_gap;
    }

    return drawn.items;
}

/// The toasts still up, oldest first, written into `into`. Insertion sort over
/// four slots: the order comes from the serial, not from where a toast landed.
fn showing(self: *Notification, into: *[capacity]*Toast) []*Toast {
    var len: usize = 0;
    for (&self.toasts) |*toast| {
        if (!toast.isOpen()) continue;
        var at = len;
        while (at > 0 and into[at - 1].serial > toast.serial) : (at -= 1) {
            into[at] = into[at - 1];
        }
        into[at] = toast;
        len += 1;
    }
    return into[0..len];
}

/// How much of `text` fits in `width`: the last space that fits, or a hard cut
/// when a single word is wider than the box.
fn breakAt(text: []const u8, width: u16) usize {
    if (w.textWidth(text) <= width) return text.len;

    var used: u16 = 0;
    var last_space: ?usize = null;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const gw: u16 = vaxis.gwidth.gwidth(bytes, .unicode);
        if (used + gw > width) break;
        if (bytes.len == 1 and bytes[0] == ' ') last_space = g.start;
        used += gw;
        if (g.start + g.len >= text.len) return text.len;
    }
    return last_space orelse @max(usedBytes(text, width), 1);
}

/// Bytes of `text` that fit in `width`, for the word that has to be split.
fn usedBytes(text: []const u8, width: u16) usize {
    var used: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |g| {
        const bytes = g.bytes(text);
        const gw: u16 = vaxis.gwidth.gwidth(bytes, .unicode);
        if (used + gw > width) return g.start;
        used += gw;
    }
    return text.len;
}

test "a toast owns its text and takes itself down" {
    var toasts: Notification = .init(testing.allocator, testing.io);
    defer toasts.deinit();

    try testing.expect(!toasts.isOpen());

    const slot = try toasts.push(.info, "session 4");

    try testing.expect(toasts.isOpen());
    try testing.expectEqualStrings("session 4", slot.body);

    slot.expires_at = std.Io.Timestamp.now(testing.io, .awake).subDuration(.fromMilliseconds(1));
    try testing.expect(!toasts.isOpen());

    const again = try toasts.push(.err, "no route to host");
    try testing.expectEqual(slot, again);
    try testing.expectEqual(Kind.err, again.kind);

    toasts.close();
    try testing.expect(!toasts.isOpen());
}

test "several stack oldest first, and the newest wins the last slot" {
    var toasts: Notification = .init(testing.allocator, testing.io);
    defer toasts.deinit();

    _ = try toasts.push(.info, "one");
    _ = try toasts.push(.info, "two");
    _ = try toasts.push(.info, "three");

    var order: [capacity]*Toast = undefined;
    const three = toasts.showing(&order);
    try testing.expectEqual(@as(usize, 3), three.len);

    _ = try toasts.push(.info, "four");
    _ = try toasts.push(.info, "five");

    const full = toasts.showing(&order);
    try testing.expectEqual(capacity, full.len);
}

test "the body wraps to the box, and stops" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var toasts: Notification = .init(testing.allocator, testing.io);
    defer toasts.deinit();

    const toast = try toasts.push(.info, "the quick brown fox jumps");
    const lines = try toast.bodyLines(arena, 10);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("the quick", lines[0]);
    try testing.expectEqualStrings("brown fox", lines[1]);
    try testing.expectEqualStrings("jumps", lines[2]);

    try toast.set(.info, "supercalifragilistic", 99);
    const long = try toast.bodyLines(arena, 8);
    try testing.expectEqualStrings("supercal", long[0]);
    try testing.expectEqualStrings("ifragili", long[1]);

    try toast.set(.info, "one\n\ntwo", 100);
    const split = try toast.bodyLines(arena, 20);
    try testing.expectEqual(@as(usize, 2), split.len);
    try testing.expectEqualStrings("two", split[1]);

    try toast.set(.info, "", 101);
    try testing.expectEqual(@as(usize, 0), (try toast.bodyLines(arena, 20)).len);
}
