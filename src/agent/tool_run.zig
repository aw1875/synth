//! Executing a batch of approved tool calls off the event loop.

const std = @import("std");

const Registry = @import("../tools/registry.zig");
const tool = @import("../tools/tool.zig");
const Conversation = @import("../core/conversation.zig");

const ToolRun = @This();

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

/// Calls to run: name, arguments, and their index in the requesting message.
/// Owned copies, because the conversation may move underneath the worker.
calls: []Call,
results: []Result,

future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
/// How many results are written and safe to read. Published as each call
/// lands so the owner can settle one card at a time instead of the whole
/// batch at once when the last call finishes.
settled: std.atomic.Value(usize) = .init(0),
/// Set by the owner to ask the worker to give up. Checked between calls, so
/// the tools after the current one are skipped.
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
    @memset(results, .{ .index = 0, .content = "", .is_error = false });

    self.* = .{
        .allocator = allocator,
        .io = io,
        .registry = registry,
        .project_root = project_root,
        .reads = reads,
        .delegate = delegate,
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

    var ctx: tool.Context = .{
        .allocator = self.allocator,
        .io = self.io,
        .project_root = self.project_root,
        .reads = self.reads,
        .delegate = self.delegate,
        .cancelled = &self.stop,
    };

    for (self.calls, self.results) |call, *result| {
        ctx.allow_outside = call.allow_outside;
        // Whatever this iteration decides, the result is written by the time
        // the count is published, and `.release` is what makes it visible.
        defer _ = self.settled.fetchAdd(1, .release);

        result.index = call.index;
        if (self.stop.load(.acquire)) {
            result.* = .{
                .index = call.index,
                .content = self.allocator.dupe(u8, "cancelled") catch "cancelled",
                .is_error = true,
            };
            continue;
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
            continue;
        };
        result.* = .{ .index = call.index, .content = output.content, .is_error = output.is_error };
    }
}
