//! Telling the terminal how a session is doing: the bell when a turn finishes
//! and nobody is watching, and an OSC 7501 status report on every change.

const builtin = @import("builtin");
const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Config = @import("../core/config.zig");

/// BEL. What a terminal turns into a sound, a flash, or an urgency hint on the
/// window, depending on how it is configured.
const bel = "\x07";

/// Focus reporting, which vaxis does not enable on its own. A terminal that
/// does not know the mode ignores it, and never reports focus either way.
pub const focus_set = "\x1b[?1004h";
const focus_reset = "\x1b[?1004l";

/// Whether a turn that just ended should ring, given what the terminal has said
/// about focus. `focused` is null when it has said nothing.
pub fn shouldRing(when: Config.Bell, focused: ?bool) bool {
    return switch (when) {
        .never => false,
        .always => true,
        .unfocused => focused == false,
    };
}

/// Say a turn has ended, by whatever the terminal actually carries.
///
/// Both, because neither lands everywhere: the notification needs a terminal
/// that turns OSC 777 into one, and BEL needs a terminal with a bell to ring.
pub fn ring(app: *vxfw.App, environ: ?*std.process.Environ.Map, said: []const u8) void {
    if (builtin.os.tag == .windows or builtin.is_test) return;
    const writer = app.tty.writer();

    writer.writeAll(notification(said, underTmux(environ))) catch {};
    writer.writeAll(bel) catch {};
    writer.flush() catch {};
}

/// Whether output is going through tmux, which eats an OSC it does not know
/// unless it arrives wrapped.
pub fn underTmux(environ: ?*std.process.Environ.Map) bool {
    const env = environ orelse return false;
    const value = env.get("TMUX") orelse return false;
    return value.len > 0;
}

/// An OSC 777 desktop notification for `said`.
///
/// The outcome goes in the summary rather than the body: the app-name slot is
/// the terminal's to fill, and a notification daemon may be set up to show no
/// body at all.
///
/// tmux forwards an unknown sequence only inside its own DCS wrapper, and only
/// with `allow-passthrough on`; every ESC in the payload is doubled there.
fn notification(said: []const u8, wrapped: bool) []const u8 {
    const bare = comptime std.StaticStringMap([]const u8).initComptime(.{
        .{ "done", "\x1b]777;notify;synth: done;the turn finished\x1b\\" },
        .{ "cancelled", "\x1b]777;notify;synth: cancelled;the turn was cancelled\x1b\\" },
        .{ "failed", "\x1b]777;notify;synth: failed;the turn failed\x1b\\" },
        .{ "stopped", "\x1b]777;notify;synth: stopped;the turn ran out of room\x1b\\" },
    });
    const in_tmux = comptime std.StaticStringMap([]const u8).initComptime(.{
        .{ "done", "\x1bPtmux;\x1b\x1b]777;notify;synth: done;the turn finished\x1b\x1b\\\x1b\\" },
        .{ "cancelled", "\x1bPtmux;\x1b\x1b]777;notify;synth: cancelled;the turn was cancelled\x1b\x1b\\\x1b\\" },
        .{ "failed", "\x1bPtmux;\x1b\x1b]777;notify;synth: failed;the turn failed\x1b\x1b\\\x1b\\" },
        .{ "stopped", "\x1bPtmux;\x1b\x1b]777;notify;synth: stopped;the turn ran out of room\x1b\x1b\\\x1b\\" },
    });

    const table = if (wrapped) in_tmux else bare;
    return table.get(said) orelse table.get("done").?;
}

/// What a session is up to, as OSC 7501 reports it to a terminal that shows
/// programs' progress: a spinner while working, a badge while blocked, a mark
/// once done that stays until seen.
pub const Status = struct {
    state: State,
    kind: ?Kind = null,
    /// Shown beside the mark. One line, no control characters.
    msg: []const u8 = "",

    pub const State = enum { idle, working, blocked, done, @"error" };
    pub const Kind = enum { permission, question };

    pub fn eql(a: Status, b: Status) bool {
        return a.state == b.state and a.kind == b.kind and std.mem.eql(u8, a.msg, b.msg);
    }
};

/// Tell the terminal what the session is doing. Sent whatever focus says: the
/// terminal decides what to show, and a terminal that does not know the
/// sequence ignores it.
pub fn report(app: *vxfw.App, environ: ?*std.process.Environ.Map, status: Status) void {
    if (builtin.os.tag == .windows or builtin.is_test) return;
    const writer = app.tty.writer();
    writeStatus(writer, status, underTmux(environ)) catch {};
    writer.flush() catch {};
}

/// The OSC 7501 report of `status`. Every report replaces the one before, so
/// each names the app.
pub fn writeStatus(writer: *std.Io.Writer, status: Status, wrapped: bool) !void {
    var buffer: [256]u8 = undefined;
    var body: std.Io.Writer = .fixed(&buffer);
    try body.print("\x1b]7501;state={t}:app=synth", .{status.state});
    if (status.kind) |kind| try body.print(":kind={t}", .{kind});
    if (status.msg.len > 0) {
        try body.writeAll(":msg=");
        try std.base64.standard.Encoder.encodeWriter(&body, status.msg);
    }
    try body.writeAll("\x1b\\");

    if (!wrapped) return writer.writeAll(body.buffered());
    try writer.writeAll("\x1bPtmux;");
    for (body.buffered()) |byte| {
        if (byte == '\x1b') try writer.writeByte('\x1b');
        try writer.writeByte(byte);
    }
    try writer.writeAll("\x1b\\");
}

/// Stop the terminal reporting focus, so whatever runs next is not sent events
/// it never asked for.
pub fn stopFocusReports(app: *vxfw.App) void {
    if (builtin.os.tag == .windows or builtin.is_test) return;
    const writer = app.tty.writer();
    writer.writeAll(focus_reset) catch {};
    writer.flush() catch {};
}

/// Ask the terminal to report focus. Sent at startup, and again whenever the
/// screen is handed back after a child process had it.
pub fn askForFocusReports(app: *vxfw.App) void {
    if (builtin.os.tag == .windows or builtin.is_test) return;
    const writer = app.tty.writer();
    writer.writeAll(focus_set) catch {};
    writer.flush() catch {};
}

test "a notification is wrapped for tmux and bare outside it" {
    const testing = std.testing;

    const plain = notification("cancelled", false);
    try testing.expectEqualStrings(
        "\x1b]777;notify;synth: cancelled;the turn was cancelled\x1b\\",
        plain,
    );

    // tmux forwards a payload only inside its DCS wrapper, every ESC doubled.
    const wrapped = notification("cancelled", true);
    try testing.expect(std.mem.startsWith(u8, wrapped, "\x1bPtmux;"));
    try testing.expect(std.mem.endsWith(u8, wrapped, "\x1b\\"));
    try testing.expect(std.mem.indexOf(u8, wrapped, "\x1b\x1b]777;") != null);

    // An outcome with no line of its own still says something.
    try testing.expectEqualStrings(notification("done", false), notification("unknown", false));
}

test "a status report names the app, and only the parts it has" {
    const testing = std.testing;
    const cases = [_]struct { status: Status, want: []const u8 }{
        .{ .status = .{ .state = .working }, .want = "\x1b]7501;state=working:app=synth\x1b\\" },
        .{ .status = .{ .state = .idle }, .want = "\x1b]7501;state=idle:app=synth\x1b\\" },
        .{ .status = .{ .state = .done }, .want = "\x1b]7501;state=done:app=synth\x1b\\" },
        .{ .status = .{ .state = .blocked, .kind = .permission }, .want = "\x1b]7501;state=blocked:app=synth:kind=permission\x1b\\" },
        .{ .status = .{ .state = .blocked, .kind = .question }, .want = "\x1b]7501;state=blocked:app=synth:kind=question\x1b\\" },
        .{ .status = .{ .state = .@"error", .msg = "failed" }, .want = "\x1b]7501;state=error:app=synth:msg=ZmFpbGVk\x1b\\" },
    };
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writeStatus(&out.writer, case.status, false);
        try testing.expectEqualStrings(case.want, out.written());
    }
}

test "a status report is wrapped for tmux with every ESC doubled" {
    const testing = std.testing;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStatus(&out.writer, .{ .state = .blocked, .kind = .question }, true);
    try testing.expectEqualStrings(
        "\x1bPtmux;\x1b\x1b]7501;state=blocked:app=synth:kind=question\x1b\x1b\\\x1b\\",
        out.written(),
    );
}

test "statuses differ by state, kind and message" {
    const testing = std.testing;
    const working: Status = .{ .state = .working };

    try testing.expect(working.eql(.{ .state = .working }));
    try testing.expect(!working.eql(.{ .state = .idle }));
    try testing.expect(!Status.eql(.{ .state = .blocked, .kind = .permission }, .{ .state = .blocked, .kind = .question }));
    try testing.expect(!Status.eql(.{ .state = .@"error", .msg = "failed" }, .{ .state = .@"error", .msg = "stopped" }));
}

test "tmux is noticed by its own variable" {
    const testing = std.testing;

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expect(!underTmux(null));
    try testing.expect(!underTmux(&environ));

    try environ.put("TMUX", "");
    try testing.expect(!underTmux(&environ));

    try environ.put("TMUX", "/tmp/tmux-1000/default,12,0");
    try testing.expect(underTmux(&environ));
}

test "unfocused rings only once the terminal has said it lost focus" {
    const testing = std.testing;

    try testing.expect(!shouldRing(.unfocused, null));
    try testing.expect(!shouldRing(.unfocused, true));
    try testing.expect(shouldRing(.unfocused, false));
}

test "always and never ignore what the terminal reports" {
    const testing = std.testing;

    for ([_]?bool{ null, true, false }) |focused| {
        try testing.expect(shouldRing(.always, focused));
        try testing.expect(!shouldRing(.never, focused));
    }
}
