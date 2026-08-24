//! Running commands.

const std = @import("std");
const builtin = @import("builtin");

const tool = @import("tool.zig");
const Context = tool.Context;
const Input = tool.Input;
const Output = tool.Output;

/// Cap on captured output, so a runaway command cannot flood the context.
const output_limit: std.Io.Limit = .limited(64 * 1024);

/// How long one wait for output lasts before the loop looks up to see whether
/// it has been cancelled or run out of time.
///
/// A command that produces nothing - the common shape of a hung one - would
/// otherwise leave this blocked in `fill` with nothing checking anything, which
/// is what made cancelling a turn wait for the command rather than end it.
const poll_slice_ms: u64 = 100;

pub const all: []const tool.Tool = &.{
    .{
        .name = "bash",
        .description = "Run a shell command from the project root and return its output.",
        .schema =
        \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
        ,
        .handler = bash,
    },
};

fn bash(ctx: Context, input: Input) !Output {
    const command = input.string("command") orelse
        return Output.err(try ctx.allocator.dupe(u8, "bash: 'command' is required"));

    var dir = std.Io.Dir.cwd().openDir(ctx.io, ctx.project_root, .{}) catch |err| {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "bash: cannot open project root: {s}",
            .{@errorName(err)},
        ));
    };
    defer dir.close(ctx.io);

    const result = run(ctx, dir, command) catch |err| switch (err) {
        error.Timeout => return Output.err(try ctx.allocator.dupe(
            u8,
            "bash: timed out and was killed, along with anything it started. " ++
                "Long-running work belongs in the background, or split into steps that finish.",
        )),
        error.Canceled => return Output.err(try ctx.allocator.dupe(
            u8,
            "bash: cancelled, and the command was killed",
        )),
        else => return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "bash: {s}",
            .{@errorName(err)},
        )),
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    if (result.stdout.len > 0) try out.writer.writeAll(result.stdout);
    if (result.stderr.len > 0) {
        if (result.stdout.len > 0) try out.writer.writeAll("\n");
        try out.writer.writeAll(result.stderr);
    }

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (code != 0) {
        try out.writer.print("\n(exit code {d})", .{code});
    }
    if (out.written().len == 0) {
        try out.writer.writeAll("(no output)");
    }

    return .{ .content = try out.toOwnedSlice(), .is_error = code != 0 };
}

/// Run `command` and collect its output.
fn run(ctx: Context, dir: std.Io.Dir, command: []const u8) !Result {
    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ "bash", "-lc", command },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (posix_signals) 0 else null,
    });

    var reaped = false;
    defer if (!reaped) killGroup(ctx.io, &child);

    var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(ctx.allocator, ctx.io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer readers.deinit();

    const out_reader = readers.reader(0);
    const err_reader = readers.reader(1);

    while (true) {
        const slice = ctx.waitSliceMs(poll_slice_ms);
        if (slice == 0) return error.Timeout;

        readers.fill(64, .{ .duration = .{
            .raw = .fromMilliseconds(@intCast(slice)),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => |e| return e,
        };

        if (out_reader.buffered().len > output_limit.toInt().?) return error.StreamTooLong;
        if (err_reader.buffered().len > output_limit.toInt().?) return error.StreamTooLong;
        if (ctx.givenUp()) return error.Canceled;
        if (ctx.outOfTime()) return error.Timeout;
    }
    try readers.checkAnyError();

    const term = try child.wait(ctx.io);
    reaped = true;

    const stdout = try readers.toOwnedSlice(0);
    errdefer ctx.allocator.free(stdout);
    const stderr = try readers.toOwnedSlice(1);

    return .{ .stdout = stdout, .stderr = stderr, .term = term };
}

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

/// Whether the target has POSIX process groups. Windows has job objects
/// instead, which `Child.kill` does not use either, so there the direct child
/// is all that can be reached.
const posix_signals = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

/// Kill the child and everything it spawned, then reap it.
fn killGroup(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;

    if (posix_signals) std.posix.kill(-pid, .TERM) catch {};
    child.kill(io);
    if (posix_signals) std.posix.kill(-pid, .KILL) catch {};
}

test "cancelling a command kills what it spawned, not just bash" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "bash", "-lc", "( sleep 30 ) & sleep 30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const pgid = child.id.?;
    errdefer killGroup(io, &child);

    var members: usize = 0;
    for (0..200) |_| {
        members = countGroup(pgid);
        if (members >= 2) break;
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(members >= 2);

    killGroup(io, &child);

    for (0..200) |_| {
        if (countGroup(pgid) == 0) break;
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), countGroup(pgid));
}

/// Processes currently in `pgid`, counted out of `/proc`. Test-only, and
/// deliberately forgiving: a process that exits mid-scan is simply not counted.
fn countGroup(pgid: std.posix.pid_t) usize {
    const io = std.testing.io;

    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return 0;
    defer proc.close(io);

    var found: usize = 0;
    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;

        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "/proc/{s}/stat", .{entry.name}) catch continue;

        var stat_buffer: [1024]u8 = undefined;
        const stat = readSmallFile(io, path, &stat_buffer) orelse continue;

        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        _ = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const pgrp_text = fields.next() orelse continue;

        const pgrp = std.fmt.parseInt(std.posix.pid_t, pgrp_text, 10) catch continue;
        if (pgrp == pgid) found += 1;
    }
    return found;
}

fn readSmallFile(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buffer) catch return null;
    return buffer[0..n];
}

/// A throwaway project root plus the context pointing at it, for driving
/// `bash` the way the registry would.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    reads: tool.ReadLog,
    cancelled: std.atomic.Value(bool) = .init(false),

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(std.testing.io, &buffer);
        return .{
            .tmp = tmp,
            .root = try std.testing.allocator.dupe(u8, buffer[0..n]),
            .reads = .init(std.testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.reads.deinit();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn run(self: *Fixture, command: []const u8, deadline_ms: ?i64) !Output {
        const arguments = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"command\":{f}}}",
            .{std.json.fmt(command, .{})},
        );
        defer std.testing.allocator.free(arguments);

        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, arguments, .{});
        defer parsed.deinit();

        return bash(.{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .project_root = self.root,
            .reads = &self.reads,
            .cancelled = &self.cancelled,
            .deadline_ms = deadline_ms,
        }, .{ .arguments = parsed.value });
    }
};

test "a command that finishes inside its deadline is unaffected" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const out = try fixture.run("echo hello", tool.monotonicMilliseconds(std.testing.io) + 30_000);
    defer std.testing.allocator.free(out.content);

    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("hello\n", out.content);
}

test "a command that outlives its deadline is killed rather than waited on" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const started = tool.monotonicMilliseconds(std.testing.io);
    const out = try fixture.run("sleep 30", started + 300);
    defer std.testing.allocator.free(out.content);

    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.content, "timed out") != null);
    try std.testing.expect(tool.monotonicMilliseconds(std.testing.io) - started < 10_000);
}

test "a cancelled command stops without waiting for its output" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    fixture.cancelled.store(true, .release);

    const started = tool.monotonicMilliseconds(std.testing.io);
    const out = try fixture.run("sleep 30", null);
    defer std.testing.allocator.free(out.content);

    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.content, "cancelled") != null);
    try std.testing.expect(tool.monotonicMilliseconds(std.testing.io) - started < 10_000);
}

test "a deadline already past stops before anything is waited for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    const out = try fixture.run("sleep 30", tool.monotonicMilliseconds(std.testing.io) - 1);
    defer std.testing.allocator.free(out.content);

    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.content, "timed out") != null);
}
