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
/// Opened once and written to as the run goes. A file rather than stderr: the
/// screen belongs to the TUI, and a line written there is a line nobody reads.
file: ?std.Io.File = null,
/// Bytes already in the log, so each write lands after the last.
written: u64 = 0,

/// Where the marks go when `SYNTH_TIMING` is set.
pub const log_path = "synth-timing.log";

pub fn start(io: std.Io, env: *std.process.Environ.Map) Timing {
    const setting = env.get("SYNTH_TIMING");
    const on = setting != null;
    const now = if (on) milliseconds(io) else 0;
    var self: Timing = .{ .io = io, .on = on, .started = now, .last = now };
    if (!on) return self;

    // A value with a separator names the file; anything else takes the default.
    const where = setting.?;
    const path = if (std.mem.indexOfScalar(u8, where, std.fs.path.sep) != null) where else log_path;

    const dir: std.Io.Dir = .cwd();
    self.file = dir.createFile(io, path, .{}) catch null;

    // Written so a log that does not open with it is known to be incomplete.
    self.write("---- start ----\n", .{});
    return self;
}

/// Record how long the phase ending here took.
pub fn mark(self: *Timing, label: []const u8) void {
    if (!self.on) return;

    const now = milliseconds(self.io);
    self.write("{d:>6}ms  {s}\n", .{ now - self.last, label });
    self.last = now;
}

/// Record the total, once everything is up.
pub fn total(self: *Timing, label: []const u8) void {
    if (!self.on) return;

    const now = milliseconds(self.io);
    self.write("{d:>6}ms  {s} (total)\n", .{ now - self.started, label });
    self.last = now;
}

fn write(self: *Timing, comptime fmt: []const u8, args: anytype) void {
    const file = self.file orelse return;
    var buffer: [256]u8 = undefined;
    var writer = file.writer(self.io, &buffer);
    writer.pos = self.written;
    writer.interface.print(fmt, args) catch return;
    writer.interface.flush() catch {};
    self.written = writer.pos + writer.interface.end;
}

fn milliseconds(io: std.Io) i64 {
    return std.Io.Clock.now(.awake, io).toMilliseconds();
}

const testing = std.testing;

test "marks land in the file the environment names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "timing.log" });
    defer testing.allocator.free(path);

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("SYNTH_TIMING", path);

    var timing: Timing = .start(testing.io, &env);
    timing.mark("first");
    timing.mark("second");
    timing.total("whole thing");

    const written = try tmp.dir.readFileAlloc(testing.io, "timing.log", testing.allocator, .limited(4096));
    defer testing.allocator.free(written);

    try testing.expect(std.mem.startsWith(u8, written, "---- start ----"));
    try testing.expect(std.mem.indexOf(u8, written, "first") != null);
    try testing.expect(std.mem.indexOf(u8, written, "second") != null);
    try testing.expect(std.mem.indexOf(u8, written, "whole thing (total)") != null);
}

test "nothing is written when the environment says nothing" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    var timing: Timing = .start(testing.io, &env);
    timing.mark("ignored");
    try testing.expect(timing.file == null);
}
