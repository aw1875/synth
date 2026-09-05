//! The tool interface.

const std = @import("std");

/// Everything a handler is allowed to know about its surroundings.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Absolute path every relative path is resolved against, and the boundary
    /// no tool may read or write outside of.
    project_root: []const u8,
    /// Files this session has read, keyed to the mtime seen at read time, so
    /// edits can be refused when the file changed underneath the model.
    reads: *ReadLog,
    /// How a tool starts a nested agent. Null where there is no loop behind the
    /// call - a test, a one-off run - and the tool that needs it says so rather
    /// than pretending to have delegated.
    delegate: ?Delegate = null,
    /// Set when the caller has given up on this batch of calls. A tool that
    /// runs long must check it, or cancelling a turn waits for the tool rather
    /// than the other way round.
    cancelled: ?*const std.atomic.Value(bool) = null,
    /// The `userdata` of the tool being run, filled in by the registry. What
    /// tells a handler shared by many tools which one it is answering for.
    userdata: ?*anyopaque = null,
    /// When this call runs out of time, on the monotonic clock. Filled in by
    /// the registry; null where nothing is enforcing a limit.
    deadline_ms: ?i64 = null,
    /// How a tool that runs long says what it is doing, so the card the person
    /// is watching says something other than "running". Null where nothing is
    /// listening - a test, a one-off run.
    progress: ?Progress = null,
    /// Where this call sits in the message that asked for it, so what a tool
    /// leaves behind can be matched back to the call that produced it.
    call_index: usize = 0,
    /// Whether this call may touch paths outside the project.
    ///
    /// True only for a call a person approved by hand. A call that skipped the
    /// gate - a read-only tool, a safe command, a standing allowance - stays
    /// inside the root, so a path the approval layer did not think to inspect
    /// is refused rather than quietly allowed.
    allow_outside: bool = false,

    /// Whether the caller has given up. Cheap, and false when nothing can
    /// cancel this call at all.
    pub fn givenUp(self: Context) bool {
        const flag = self.cancelled orelse return false;
        return flag.load(.acquire);
    }

    /// Whether this call has run out of time.
    pub fn outOfTime(self: Context) bool {
        const deadline = self.deadline_ms orelse return false;
        return monotonicMilliseconds(self.io) >= deadline;
    }

    /// Whether this call should stop, for either reason. What a tool that
    /// blocks calls between waits.
    pub fn shouldStop(self: Context) bool {
        return self.givenUp() or self.outOfTime();
    }

    /// Say what this call is doing now. A no-op where nothing is watching, so
    /// a tool can call it without asking whether anyone cares.
    pub fn report(self: Context, text: []const u8) void {
        const progress = self.progress orelse return;
        progress.report(progress.userdata, text);
    }

    /// How long a blocking wait may last: whatever is left, capped at `cap_ms`.
    ///
    /// The cap is what makes cancellation work. A tool that waits on the full
    /// remaining time cannot notice it has been cancelled until that time is
    /// up, which for a two-minute default is indistinguishable from ignoring
    /// the request.
    pub fn waitSliceMs(self: Context, cap_ms: u64) u64 {
        const deadline = self.deadline_ms orelse return cap_ms;
        const left = deadline - monotonicMilliseconds(self.io);
        if (left <= 0) return 0;
        return @min(cap_ms, @as(u64, @intCast(left)));
    }
};

/// Cap on one progress line. Fixed so a worker can publish it without
/// allocating, and long enough for "step 3/12: grep".
pub const max_progress_bytes: usize = 96;

/// Where a tool's "what I am doing now" line goes.
pub const Progress = struct {
    userdata: *anyopaque,
    /// Publish one short line, replacing whatever the last one was. The text is
    /// copied, so the caller keeps its own.
    report: *const fn (*anyopaque, []const u8) void,
};

/// How long a tool call may run before the caller gives up on it. Long enough
/// for a build or a test suite, short enough that a command waiting on input
/// nobody is going to type does not hold the turn open forever.
pub const default_timeout_ms: u64 = 120_000;

/// Wall-clock ceiling on one subagent. Named here rather than beside either
/// user so the two stay ordered: a subagent that gives up first reports what it
/// found, where a tool call timing out first reports nothing at all.
pub const subagent_deadline_ms: u64 = 10 * std.time.ms_per_min;

/// Slack between a subagent's own deadline and the tool call wrapping it.
pub const subagent_timeout_ms: u64 = subagent_deadline_ms + 5 * std.time.ms_per_min;

/// The monotonic clock, in milliseconds. `.awake` rather than `.real` because
/// a deadline has to survive the system clock being set backwards.
pub fn monotonicMilliseconds(io: std.Io) i64 {
    return std.Io.Clock.now(.awake, io).toMilliseconds();
}

/// Running a nested agent, from the point of view of a tool.
///
/// The seam exists so `tools/` never has to import the loop: the
/// implementation is installed from outside by whoever assembled the loop, and
/// a tool only ever sees this pair of pointers.
pub const Delegate = struct {
    userdata: *anyopaque,
    /// Run `task` to completion and return the agent's final answer. Blocks the
    /// calling thread, which is a worker, and allocates the result with the
    /// allocator it is given.
    run: *const fn (*anyopaque, std.mem.Allocator, Task) anyerror![]const u8,

    pub const Task = struct {
        /// Which agent record configures the nested run.
        agent: []const u8,
        /// What it is being asked to do, as its first user message.
        prompt: []const u8,
        /// A few words naming the task, for the line the person watches.
        label: []const u8 = "",
        /// The parent call's index, which is how the transcript this leaves
        /// behind is matched back to the card that started it.
        index: usize = 0,
        /// The parent's give-up flag, so cancelling a turn also ends the
        /// subagent rather than waiting for it.
        cancelled: ?*const std.atomic.Value(bool) = null,
        /// Where the nested run says what it is doing, so the card the person
        /// is watching is not stuck on "running" for minutes.
        progress: ?Progress = null,
    };
};

/// Arguments as the model produced them.
pub const Input = struct {
    arguments: std.json.Value,

    pub fn string(self: Input, name: []const u8) ?[]const u8 {
        const value = self.get(name) orelse return null;
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn integer(self: Input, name: []const u8) ?i64 {
        const value = self.get(name) orelse return null;
        return switch (value) {
            .integer => |i| i,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            else => null,
        };
    }

    pub fn boolean(self: Input, name: []const u8) ?bool {
        const value = self.get(name) orelse return null;
        return switch (value) {
            .bool => |b| b,
            .string => |s| std.mem.eql(u8, s, "true"),
            else => null,
        };
    }

    /// The raw value for `name`, for an argument whose shape the typed
    /// accessors do not cover - an array of objects, say.
    pub fn get(self: Input, name: []const u8) ?std.json.Value {
        return switch (self.arguments) {
            .object => |obj| obj.get(name),
            else => null,
        };
    }
};

/// What the model gets back. `content` is allocated with the context allocator
/// and owned by the caller.
pub const Output = struct {
    content: []const u8,
    is_error: bool = false,

    pub fn ok(content: []const u8) Output {
        return .{ .content = content };
    }

    pub fn err(content: []const u8) Output {
        return .{ .content = content, .is_error = true };
    }
};

pub const Handler = *const fn (Context, Input) anyerror!Output;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for the arguments object, embedded verbatim in the request.
    schema: []const u8,
    handler: Handler,
    /// Read-only tools run without prompting. Anything that mutates the working
    /// tree or executes a command must be approved, so it stays false.
    read_only: bool = false,
    /// What the handler is about, for a handler shared by many tools. A built-in
    /// needs none: its handler is written for it. One tool standing for a
    /// function on a particular server does, and this is how it knows which.
    /// Borrowed, and must outlive the registry.
    userdata: ?*anyopaque = null,
    /// Whether the registry owns `name`, `description` and `schema` and must
    /// free them. False for a built-in, whose strings are in the binary; true
    /// for a tool learned at runtime.
    owned: bool = false,
    /// How long this tool may run before the caller gives up on it. Null takes
    /// `default_timeout_ms`. A tool that legitimately runs long - one that
    /// drives a whole nested agent - says so here rather than being killed
    /// halfway.
    timeout_ms: ?u64 = null,
    /// Largest result this tool's output may reach the model as. Null takes the
    /// loop's own ceiling, which is sized for a tool whose output is a summary.
    /// A tool asked for a document is the exception, and says so here rather
    /// than advertising a size the loop then cuts down.
    max_result_bytes: ?usize = null,
    /// Whether this tool may run beside another call in the same batch.
    ///
    /// Deliberately not `read_only`: that says a call needs no approval, which
    /// is a different question. `task` is read-only and still has to run alone,
    /// because a subagent borrows the parent's provider and only the parent
    /// being blocked inside the call keeps that safe.
    parallel: bool = false,

    /// Release the strings a runtime-registered tool brought with it. A no-op
    /// for a built-in.
    pub fn deinit(self: Tool, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.schema);
    }
};

/// Records when each file was last read, so `edit` can refuse to apply changes
/// to a file that moved underneath the model.
pub const ReadLog = struct {
    allocator: std.mem.Allocator,
    seen: std.StringHashMapUnmanaged(i96) = .empty,
    /// Guards `seen`. A batch may run several reads at once, and two of them
    /// growing the map together is corruption rather than a lost entry.
    ///
    /// Taken uncancelable: the hold is one hashmap insert, and a lock that
    /// could return `error.Canceled` would spend the call's cancellation on
    /// bookkeeping instead of on the tool.
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator) ReadLog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReadLog) void {
        self.clearUnlocked();
        self.seen.deinit(self.allocator);
    }

    pub fn clear(self: *ReadLog, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearUnlocked();
    }

    fn clearUnlocked(self: *ReadLog) void {
        var it = self.seen.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.seen.clearRetainingCapacity();
    }

    pub fn record(self: *ReadLog, io: std.Io, path: []const u8, mtime: i96) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const entry = try self.seen.getOrPut(self.allocator, path);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, path);
        }
        entry.value_ptr.* = mtime;
    }

    pub fn lastRead(self: *ReadLog, io: std.Io, path: []const u8) ?i96 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        return self.seen.get(path);
    }

    /// Iterate the recorded reads, for flushing to the `read_file` table on the
    /// UI thread after a tool run. Unguarded: the batch has been joined by the
    /// time anything iterates, so there is nothing left to race with.
    pub fn iterator(self: *ReadLog) std.StringHashMapUnmanaged(i96).Iterator {
        return self.seen.iterator();
    }
};

/// Resolve `path` against the project root, refusing anything that escapes it
/// unless this call was approved by hand.
pub fn resolvePath(ctx: Context, path: []const u8) ![]u8 {
    const joined = if (std.fs.path.isAbsolute(path))
        try ctx.allocator.dupe(u8, path)
    else
        try std.fs.path.join(ctx.allocator, &.{ ctx.project_root, path });
    defer ctx.allocator.free(joined);

    const resolved = try std.fs.path.resolve(ctx.allocator, &.{joined});
    errdefer ctx.allocator.free(resolved);

    if (!ctx.allow_outside and !isInside(ctx.project_root, resolved)) return error.PathOutsideProject;
    return resolved;
}

fn isInside(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == std.fs.path.sep;
}

test "resolvePath keeps paths inside the project" {
    var reads: ReadLog = .init(std.testing.allocator);
    defer reads.deinit();

    const ctx: Context = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .project_root = "/home/user/project",
        .reads = &reads,
    };

    const inside = try resolvePath(ctx, "src/main.zig");
    defer std.testing.allocator.free(inside);
    try std.testing.expectEqualStrings("/home/user/project/src/main.zig", inside);

    try std.testing.expectError(error.PathOutsideProject, resolvePath(ctx, "../../etc/passwd"));
    try std.testing.expectError(error.PathOutsideProject, resolvePath(ctx, "/etc/passwd"));
    try std.testing.expectError(error.PathOutsideProject, resolvePath(ctx, "/home/user/project-other/x"));
}

test "input coerces model-supplied strings" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"a\":\"12\",\"b\":7,\"c\":\"true\"}",
        .{},
    );
    defer parsed.deinit();

    const input: Input = .{ .arguments = parsed.value };
    try std.testing.expectEqual(@as(?i64, 12), input.integer("a"));
    try std.testing.expectEqual(@as(?i64, 7), input.integer("b"));
    try std.testing.expectEqual(@as(?bool, true), input.boolean("c"));
    try std.testing.expectEqual(@as(?[]const u8, null), input.string("missing"));
}

test "an approved call may reach outside the project" {
    var reads: ReadLog = .init(std.testing.allocator);
    defer reads.deinit();

    const ctx: Context = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .project_root = "/home/user/project",
        .reads = &reads,
        .allow_outside = true,
    };

    const outside = try resolvePath(ctx, "/etc/passwd");
    defer std.testing.allocator.free(outside);
    try std.testing.expectEqualStrings("/etc/passwd", outside);

    const up = try resolvePath(ctx, "../sibling/file.zig");
    defer std.testing.allocator.free(up);
    try std.testing.expectEqualStrings("/home/user/sibling/file.zig", up);
}
