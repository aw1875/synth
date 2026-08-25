//! Executing a batch of approved tool calls off the event loop.

const std = @import("std");

const Registry = @import("../tools/registry.zig");
const tool = @import("../tools/tool.zig");
const Conversation = @import("../core/conversation.zig");
const Hooks = @import("../core/hooks.zig");

const ToolRun = @This();

/// Most calls that may run together at once, so a batch of twenty reads does
/// not become twenty threads.
const max_parallel: usize = 8;

pub const Result = struct {
    /// Index of the call within the assistant message that requested it.
    index: usize,
    content: []const u8,
    is_error: bool,
};

allocator: std.mem.Allocator,
io: std.Io,
registry: *const Registry,
project_root: []const u8,
reads: *tool.ReadLog,
/// Passed through to every call's context, so a tool that delegates can.
delegate: ?tool.Delegate,
hooks: ?*const Hooks.Runner,

/// Calls to run: name, arguments, and their index in the requesting message.
/// Owned copies, because the conversation may move underneath the worker.
calls: []Call,
results: []Result,

future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
/// How many results are written and safe to read. Published as each group
/// lands - a group being one call, or the run of calls that ran together - so
/// the owner settles cards as they finish rather than all at once at the end.
settled: std.atomic.Value(usize) = .init(0),
/// Set by the owner to ask the worker to give up. Checked as each call starts,
/// so everything after the ones already running is skipped.
stop: std.atomic.Value(bool) = .init(false),

pub const Call = struct {
    index: usize,
    name: []const u8,
    arguments: []const u8,
    /// Whether a person approved this call by hand, and so whether it may
    /// touch anything outside the project.
    allow_outside: bool = false,
};

/// Spawn a worker for every approved call in `message`.
pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *const Registry,
    project_root: []const u8,
    reads: *tool.ReadLog,
    delegate: ?tool.Delegate,
    hook_runner: ?*const Hooks.Runner,
    approved: []const Call,
) !*ToolRun {
    const self = try allocator.create(ToolRun);
    errdefer allocator.destroy(self);

    const calls = try allocator.alloc(Call, approved.len);
    var built: usize = 0;
    errdefer {
        for (calls[0..built]) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments);
        }
        allocator.free(calls);
    }
    for (approved, calls) |src, *dst| {
        dst.* = .{
            .index = src.index,
            .name = try allocator.dupe(u8, src.name),
            .arguments = try allocator.dupe(u8, src.arguments),
            .allow_outside = src.allow_outside,
        };
        built += 1;
    }

    const results = try allocator.alloc(Result, approved.len);
    errdefer allocator.free(results);
    // Not left to the worker: a call cancelled before its handler ran writes
    // nothing, and index 0 would then be adopted as call 0's answer.
    for (results, calls) |*result, call| {
        result.* = .{ .index = call.index, .content = "", .is_error = true };
    }

    self.* = .{
        .allocator = allocator,
        .io = io,
        .registry = registry,
        .project_root = project_root,
        .reads = reads,
        .delegate = delegate,
        .hooks = hook_runner,
        .calls = calls,
        .results = results,
    };

    self.future = try io.concurrent(run, .{self});
    return self;
}

/// Ask the worker to stop before its next call. Non-blocking, and no help to
/// a tool already blocked inside a call. Pair it with `cancel`.
pub fn requestStop(self: *ToolRun) void {
    self.stop.store(true, .release);
}

/// Interrupt the batch and wait for it to unwind. A tool blocked on I/O is
/// unblocked; a child process spawned by one is not, and still has to exit.
pub fn cancel(self: *ToolRun) void {
    self.requestStop();
    self.future.cancel(self.io);
}

pub fn isFinished(self: *ToolRun) bool {
    return self.done.load(.acquire);
}

/// How many entries of `results` are finished. Everything below this index is
/// safe to read; the calls run one after another, so it only ever grows.
pub fn settledCount(self: *ToolRun) usize {
    return self.settled.load(.acquire);
}

pub fn join(self: *ToolRun) void {
    self.future.await(self.io);
}

pub fn destroy(self: *ToolRun) void {
    const allocator = self.allocator;
    for (self.calls) |call| {
        allocator.free(call.name);
        allocator.free(call.arguments);
    }
    allocator.free(self.calls);
    for (self.results) |result| {
        if (result.content.len > 0) allocator.free(result.content);
    }
    allocator.free(self.results);
    allocator.destroy(self);
}

fn run(self: *ToolRun) void {
    defer self.done.store(true, .release);

    var start_index: usize = 0;
    while (start_index < self.calls.len) {
        const group = self.groupAt(start_index);
        if (group == 1) {
            self.runOne(start_index);
        } else {
            self.runGroup(start_index, group);
        }
        // The whole group is written by the time the count is published, and
        // `.release` is what makes it visible.
        _ = self.settled.fetchAdd(group, .release);
        start_index += group;
    }
}

/// How many calls starting at `index` may run together. One unless every call
/// in the run says it is safe beside another, capped so a long batch of reads
/// does not become a thread per call.
fn groupAt(self: *ToolRun, index: usize) usize {
    var count: usize = 0;
    while (index + count < self.calls.len and count < max_parallel) : (count += 1) {
        const call = self.calls[index + count];
        const found = self.registry.get(call.name) orelse break;
        if (!found.parallel) break;
    }
    return @max(count, 1);
}

/// Run `count` calls at once and wait for all of them.
///
/// A `Group` rather than a future each: cancelling the batch cancels this
/// worker, and `Group.await` is what passes that on to the calls inside it.
fn runGroup(self: *ToolRun, index: usize, count: usize) void {
    var group: std.Io.Group = .init;

    var spawned: usize = 0;
    while (spawned < count) : (spawned += 1) {
        group.concurrent(self.io, runOne, .{ self, index + spawned }) catch break;
    }

    // A call that found no thread still runs, here.
    for (index + spawned..index + count) |at| self.runOne(at);

    group.await(self.io) catch {
        self.stop.store(true, .release);
    };
}

/// Run one call and write its result, with a `Context` of its own: the calls
/// in a group differ in what they may touch.
fn runOne(self: *ToolRun, index: usize) void {
    const call = self.calls[index];
    const result = &self.results[index];

    if (self.stop.load(.acquire)) {
        result.* = .{
            .index = call.index,
            .content = self.allocator.dupe(u8, "cancelled") catch "cancelled",
            .is_error = true,
        };
        return;
    }

    const ctx: tool.Context = .{
        .allocator = self.allocator,
        .io = self.io,
        .project_root = self.project_root,
        .reads = self.reads,
        .delegate = self.delegate,
        .cancelled = &self.stop,
        .allow_outside = call.allow_outside,
    };

    if (self.hooks) |runner| {
        const blocked = runner.dispatch(.{
            .event = .pre_tool_use,
            .tool_name = call.name,
            .tool_input = call.arguments,
        }) catch |err| {
            result.* = .{
                .index = call.index,
                .content = std.fmt.allocPrint(self.allocator, "pre-tool hook failed: {s}", .{@errorName(err)}) catch "pre-tool hook failed",
                .is_error = true,
            };
            return;
        };
        if (blocked) |reason| {
            result.* = .{ .index = call.index, .content = reason, .is_error = true };
            return;
        }
    }

    const output = self.registry.executeJson(ctx, call.name, call.arguments) catch |err| {
        result.* = .{
            .index = call.index,
            .content = std.fmt.allocPrint(
                self.allocator,
                "{s} failed: {s}",
                .{ call.name, @errorName(err) },
            ) catch "tool failed",
            .is_error = true,
        };
        return;
    };
    result.* = .{ .index = call.index, .content = output.content, .is_error = output.is_error };
    if (!output.is_error) if (self.hooks) |runner| {
        _ = runner.dispatch(.{
            .event = .post_tool_use,
            .tool_name = call.name,
            .tool_input = call.arguments,
            .tool_response = output.content,
        }) catch {};
    };
}

const testing = std.testing;

/// Shared state for the test tools below. `arrived` counts how many calls have
/// entered a handler; `peak` is the most that were ever inside one at once,
/// which is what tells a batch that overlapped from one that did not.
const Probe = struct {
    arrived: std.atomic.Value(usize) = .init(0),
    inside: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    /// How many calls each one waits for before returning. Zero waits for
    /// nobody, which is what a barrier tool wants.
    rendezvous: usize = 0,
    /// Whether a handler asks the batch to stop once it has met the others.
    stop_run: bool = false,
    /// The batch to ask, set once it has started - which is after the workers
    /// are already going, so the handlers read it atomically rather than
    /// racing the test thread for it.
    run: std.atomic.Value(?*ToolRun) = .init(null),

    fn enter(self: *Probe) usize {
        const now = self.inside.fetchAdd(1, .acq_rel) + 1;
        _ = self.peak.fetchMax(now, .acq_rel);
        return self.arrived.fetchAdd(1, .acq_rel) + 1;
    }

    fn leave(self: *Probe) void {
        _ = self.inside.fetchSub(1, .acq_rel);
    }
};

/// Wait until every call in the group has arrived. A batch that runs one call
/// after another never gets there, so the deadline is the assertion: it fails
/// the test rather than hanging the suite.
fn rendezvousHandler(ctx: tool.Context, _: tool.Input) anyerror!tool.Output {
    const probe: *Probe = @ptrCast(@alignCast(ctx.userdata.?));
    _ = probe.enter();
    defer probe.leave();

    const deadline = tool.monotonicMilliseconds(ctx.io) + 2000;
    while (probe.arrived.load(.acquire) < probe.rendezvous) {
        if (tool.monotonicMilliseconds(ctx.io) >= deadline) {
            return tool.Output.err(try ctx.allocator.dupe(u8, "timed out waiting for the others"));
        }
        std.Io.sleep(ctx.io, .fromMilliseconds(1), .awake) catch break;
    }
    if (probe.stop_run) {
        if (probe.run.load(.acquire)) |run_state| run_state.requestStop();
    }
    return tool.Output.ok(try ctx.allocator.dupe(u8, "together"));
}

/// Record how many calls were running alongside this one, then return.
fn aloneHandler(ctx: tool.Context, _: tool.Input) anyerror!tool.Output {
    const probe: *Probe = @ptrCast(@alignCast(ctx.userdata.?));
    _ = probe.enter();
    defer probe.leave();

    std.Io.sleep(ctx.io, .fromMilliseconds(5), .awake) catch {};
    return tool.Output.ok(try ctx.allocator.dupe(u8, "alone"));
}

fn probeRegistry(allocator: std.mem.Allocator, probe: *Probe) !Registry {
    var registry: Registry = .{ .allocator = allocator };
    errdefer registry.deinit();

    try registry.register(.{
        .name = "together",
        .description = "test",
        .schema = "{}",
        .handler = rendezvousHandler,
        .read_only = true,
        .parallel = true,
        .userdata = probe,
    });
    try registry.register(.{
        .name = "alone",
        .description = "test",
        .schema = "{}",
        .handler = aloneHandler,
        .read_only = true,
        .userdata = probe,
    });
    return registry;
}

fn drain(
    allocator: std.mem.Allocator,
    io: std.Io,
    registry: *const Registry,
    reads: *tool.ReadLog,
    calls: []const Call,
) !*ToolRun {
    const run_state = try ToolRun.start(allocator, io, registry, ".", reads, null, null, calls);
    run_state.join();
    return run_state;
}

test "calls that may run together do" {
    const allocator = testing.allocator;

    var probe: Probe = .{ .rendezvous = 4 };
    var registry = try probeRegistry(allocator, &probe);
    defer registry.deinit();

    const calls: []const Call = &.{
        .{ .index = 0, .name = "together", .arguments = "{}" },
        .{ .index = 1, .name = "together", .arguments = "{}" },
        .{ .index = 2, .name = "together", .arguments = "{}" },
        .{ .index = 3, .name = "together", .arguments = "{}" },
    };

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    const run_state = try drain(allocator, testing.io, &registry, &reads, calls);
    defer run_state.destroy();

    try testing.expectEqual(@as(usize, 4), run_state.settledCount());
    for (run_state.results) |result| {
        try testing.expect(!result.is_error);
        try testing.expectEqualStrings("together", result.content);
    }
    try testing.expectEqual(@as(usize, 4), probe.peak.load(.acquire));
}

test "a call that cannot run beside another never does" {
    const allocator = testing.allocator;

    var probe: Probe = .{ .rendezvous = 2 };
    var registry = try probeRegistry(allocator, &probe);
    defer registry.deinit();

    // The pair rendezvous, proving they grouped; the barrier must still be alone.
    const calls: []const Call = &.{
        .{ .index = 0, .name = "together", .arguments = "{}" },
        .{ .index = 1, .name = "together", .arguments = "{}" },
        .{ .index = 2, .name = "alone", .arguments = "{}" },
    };

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    const run_state = try drain(allocator, testing.io, &registry, &reads, calls);
    defer run_state.destroy();

    try testing.expectEqual(@as(usize, 3), run_state.settledCount());
    try testing.expectEqualStrings("alone", run_state.results[2].content);
    try testing.expectEqual(@as(usize, 2), probe.peak.load(.acquire));
}

test "results land in the slot their call asked for" {
    const allocator = testing.allocator;

    var probe: Probe = .{ .rendezvous = 0 };
    var registry = try probeRegistry(allocator, &probe);
    defer registry.deinit();

    const calls: []const Call = &.{
        .{ .index = 7, .name = "together", .arguments = "{}" },
        .{ .index = 3, .name = "alone", .arguments = "{}" },
        .{ .index = 5, .name = "together", .arguments = "{}" },
    };

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    const run_state = try drain(allocator, testing.io, &registry, &reads, calls);
    defer run_state.destroy();

    try testing.expectEqual(@as(usize, 7), run_state.results[0].index);
    try testing.expectEqual(@as(usize, 3), run_state.results[1].index);
    try testing.expectEqual(@as(usize, 5), run_state.results[2].index);
}

test "a batch wider than the cap runs in several groups" {
    const allocator = testing.allocator;

    var probe: Probe = .{ .rendezvous = 0 };
    var registry = try probeRegistry(allocator, &probe);
    defer registry.deinit();

    var many: [max_parallel + 3]Call = undefined;
    for (&many, 0..) |*call, i| {
        call.* = .{ .index = i, .name = "together", .arguments = "{}" };
    }

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    const run_state = try ToolRun.start(allocator, testing.io, &registry, ".", &reads, null, null, &many);
    defer run_state.destroy();
    run_state.join();

    try testing.expectEqual(max_parallel, run_state.groupAt(0));
    try testing.expectEqual(@as(usize, 3), run_state.groupAt(max_parallel));
    try testing.expectEqual(many.len, run_state.settledCount());
}

test "giving up inside a group stops the calls after it" {
    const allocator = testing.allocator;

    var probe: Probe = .{ .rendezvous = 2, .stop_run = true };
    var registry = try probeRegistry(allocator, &probe);
    defer registry.deinit();

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    // The pair stop the batch; the barrier starts after them and must see it.
    const calls: []const Call = &.{
        .{ .index = 0, .name = "together", .arguments = "{}" },
        .{ .index = 1, .name = "together", .arguments = "{}" },
        .{ .index = 2, .name = "alone", .arguments = "{}" },
    };

    const run_state = try ToolRun.start(allocator, testing.io, &registry, ".", &reads, null, null, calls);
    defer run_state.destroy();
    probe.run.store(run_state, .release);
    run_state.join();

    try testing.expect(run_state.results[2].is_error);
    try testing.expectEqualStrings("cancelled", run_state.results[2].content);
    try testing.expectEqual(@as(usize, 2), probe.peak.load(.acquire));
}
