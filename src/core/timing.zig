//! Where startup time goes.
//!
//! Off unless `SYNTH_TIMING` is set, and writes to stderr rather than the
//! debug log so it is readable while the TUI is taking over the screen. The
//! clock is `.awake`, so a system clock adjustment cannot make a phase look
//! negative.

const std = @import("std");

const Timing = @This();

io: std.Io,
on: bool,
started: i64 = 0,
last: i64 = 0,

pub fn start(io: std.Io, env: *std.process.Environ.Map) Timing {
    const on = env.get("SYNTH_TIMING") != null;
    const now = if (on) milliseconds(io) else 0;
    return .{ .io = io, .on = on, .started = now, .last = now };
}

/// Record how long the phase ending here took.
pub fn mark(self: *Timing, label: []const u8) void {
    if (!self.on) return;

    const now = milliseconds(self.io);
    self.write("{d:>6}ms  {s}\r\n", .{ now - self.last, label });
    self.last = now;
}

/// Record the total, once everything is up.
pub fn total(self: *Timing, label: []const u8) void {
    if (!self.on) return;

    const now = milliseconds(self.io);
    self.write("{d:>6}ms  {s} (total)\r\n", .{ now - self.started, label });
    self.last = now;
}

fn write(self: *Timing, comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var file = std.Io.File.stderr().writer(self.io, &buffer);
    file.interface.print(fmt, args) catch return;
    file.interface.flush() catch {};
}

fn milliseconds(io: std.Io) i64 {
    return std.Io.Clock.now(.awake, io).toMilliseconds();
}
