//! A test runner that reports the way a JS runner does: one line per module,
//! failures spelled out beneath the module they came from, and a tally at the
//! end. Wired up in `build.zig` as a `.simple` runner.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

/// For the runner's own clock and terminal checks. The `Io` a test sees is
/// built and torn down around each one, so it cannot be used to time them.
const runner_io: Io = Io.Threaded.global_single_threaded.io();

/// Passing tests slower than this are named anyway: one slow test is usually
/// the whole reason a suite feels slow.
const slow_ms: i64 = 250;

const Style = struct {
    dim: []const u8 = "",
    red: []const u8 = "",
    green: []const u8 = "",
    yellow: []const u8 = "",
    bold: []const u8 = "",
    reset: []const u8 = "",

    /// Colour only where something will render it. CI is not a terminal but
    /// does interpret escapes, so it is asked about separately.
    fn pick(gpa: std.mem.Allocator, environ: std.process.Environ) Style {
        const no_color = environ.containsUnempty(gpa, "NO_COLOR") catch false;
        if (no_color) return .{};

        const tty = Io.File.stderr().isTty(runner_io) catch false;
        const ci = environ.containsUnempty(gpa, "CI") catch false;
        if (!tty and !ci) return .{};

        return .{
            .dim = "\x1b[2m",
            .red = "\x1b[31m",
            .green = "\x1b[32m",
            .yellow = "\x1b[33m",
            .bold = "\x1b[1m",
            .reset = "\x1b[0m",
        };
    }
};

/// A test worth saying something about after its module's line. Names are
/// borrowed from `builtin.test_functions`, which lives in the binary.
const Note = struct {
    name: []const u8,
    err: ?anyerror = null,
    leaked: bool = false,
    ms: i64 = 0,
    /// Only set for the run-wide list, where the module is no longer implied
    /// by which line the note was printed under.
    module: []const u8 = "",
};

const Tally = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn total(self: Tally) usize {
        return self.passed + self.failed + self.skipped;
    }
};

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .ollama, .level = .warn },
        .{ .scope = .zqlite, .level = .warn },
        .{ .scope = .clap, .level = .warn },
        .{ .scope = .oauth2, .level = .warn },
        .{ .scope = .http, .level = .warn },
        .{ .scope = .websocket, .level = .warn },
    },
};

pub fn main(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    const gpa = std.heap.page_allocator;
    const style = Style.pick(gpa, .{ .block = init.environ.block });

    var suite: Tally = .{};
    var modules: Tally = .{};

    var module: []const u8 = "";
    var group: Tally = .{};
    var group_ms: i64 = 0;

    var failures: std.ArrayList(Note) = .empty;
    defer failures.deinit(gpa);

    var all_failures: std.ArrayList(Note) = .empty;
    defer all_failures.deinit(gpa);

    var slow: std.ArrayList(Note) = .empty;
    defer slow.deinit(gpa);

    const began = now();

    for (builtin.test_functions) |t| {
        const owner = moduleOf(t.name) orelse continue;
        if (!std.mem.eql(u8, owner, module)) {
            if (module.len > 0) {
                report(style, module, group, group_ms, failures.items, slow.items);
                if (group.failed > 0) modules.failed += 1 else modules.passed += 1;
            }
            module = owner;
            group = .{};
            group_ms = 0;
            failures.clearRetainingCapacity();
            slow.clearRetainingCapacity();
        }

        std.testing.allocator_instance = .{};
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.environ = init.environ;

        const started = now();
        const result = t.func();
        const took = now() - started;

        std.testing.io_instance.deinit();
        const leaked = std.testing.allocator_instance.deinit() == .leak;

        group_ms += took;
        const name = nameOf(t.name);

        if (result) |_| {
            if (leaked) {
                group.failed += 1;
                suite.failed += 1;
                const note: Note = .{ .name = name, .leaked = true, .ms = took, .module = owner };
                try failures.append(gpa, note);
                try all_failures.append(gpa, note);
            } else {
                group.passed += 1;
                suite.passed += 1;
                if (took >= slow_ms) try slow.append(gpa, .{ .name = name, .ms = took });
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                group.skipped += 1;
                suite.skipped += 1;
            },
            else => {
                group.failed += 1;
                suite.failed += 1;
                const note: Note = .{ .name = name, .err = err, .leaked = leaked, .ms = took, .module = owner };
                try failures.append(gpa, note);
                try all_failures.append(gpa, note);
            },
        }
    }

    if (module.len > 0) {
        report(style, module, group, group_ms, failures.items, slow.items);
        if (group.failed > 0) modules.failed += 1 else modules.passed += 1;
    }

    const elapsed = now() - began;

    if (all_failures.items.len > 0) {
        std.debug.print("\n{s}{s}Failed tests{s}\n", .{ style.bold, style.red, style.reset });
        for (all_failures.items) |note| {
            std.debug.print("  {s}x{s} {s}{s}{s} {s}\n", .{
                style.red,   style.reset,
                style.dim,   note.module,
                style.reset, note.name,
            });
            if (note.err) |err| {
                std.debug.print("    {s}-> {s}{s}\n", .{ style.red, @errorName(err), style.reset });
            }
            if (note.leaked) {
                std.debug.print("    {s}-> leaked memory{s}\n", .{ style.red, style.reset });
            }
        }
    }

    summarize(style, modules, suite, elapsed);

    if (suite.failed > 0) std.process.exit(1);
}

/// One line for the module, then anything that needs saying about it.
fn report(
    style: Style,
    module: []const u8,
    group: Tally,
    ms: i64,
    failures: []const Note,
    slow: []const Note,
) void {
    const mark = if (group.failed > 0) "FAIL" else "PASS";
    const colour = if (group.failed > 0) style.red else style.green;

    std.debug.print("{s}{s}{s} {s}{s}{s} {s}({d} {s}", .{
        colour,     mark,          style.reset,
        style.bold, module,        style.reset,
        style.dim,  group.total(), if (group.total() == 1) "test" else "tests",
    });
    if (group.failed > 0) std.debug.print(" | {d} failed", .{group.failed});
    if (group.skipped > 0) std.debug.print(" | {d} skipped", .{group.skipped});
    std.debug.print(") {d}ms{s}\n", .{ ms, style.reset });

    for (failures) |note| {
        std.debug.print("  {s}x{s} {s}\n", .{ style.red, style.reset, note.name });
        if (note.err) |err| {
            std.debug.print("    {s}-> {s}{s}\n", .{ style.red, @errorName(err), style.reset });
        }
        if (note.leaked) {
            std.debug.print("    {s}-> leaked memory{s}\n", .{ style.red, style.reset });
        }
    }
    for (slow) |note| {
        std.debug.print("  {s}slow{s} {s} {s}{d}ms{s}\n", .{
            style.yellow, style.reset, note.name, style.dim, note.ms, style.reset,
        });
    }
}

fn summarize(style: Style, modules: Tally, tests: Tally, elapsed: i64) void {
    std.debug.print("\n{s}Test Modules{s}  ", .{ style.bold, style.reset });
    writeTally(style, modules);
    std.debug.print("       {s}Tests{s}  ", .{ style.bold, style.reset });
    writeTally(style, tests);
    std.debug.print("    {s}Duration{s}  {d}ms\n\n", .{ style.bold, style.reset, elapsed });
}

fn writeTally(style: Style, tally: Tally) void {
    if (tally.failed > 0) {
        std.debug.print("{s}{d} failed{s}, ", .{ style.red, tally.failed, style.reset });
    }
    std.debug.print("{s}{d} passed{s}", .{ style.green, tally.passed, style.reset });
    if (tally.skipped > 0) {
        std.debug.print(", {s}{d} skipped{s}", .{ style.yellow, tally.skipped, style.reset });
    }
    std.debug.print(" {s}({d}){s}\n", .{ style.dim, tally.total(), style.reset });
}

fn now() i64 {
    return Io.Clock.now(.awake, runner_io).toMilliseconds();
}

/// `agent.recap.test.a name with dots in it` -> `agent.recap`.
fn moduleOf(full: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, full, ".test.") orelse return null;
    return full[0..at];
}

/// The part a person actually wrote.
fn nameOf(full: []const u8) []const u8 {
    const marker = ".test.";
    const at = std.mem.indexOf(u8, full, marker) orelse return full;
    return full[at + marker.len ..];
}
