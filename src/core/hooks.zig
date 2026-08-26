const std = @import("std");
const builtin = @import("builtin");

const stderr_limit: usize = 64 * 1024;
const poll_slice_ms: u64 = 100;
const default_timeout_ms: u64 = 30_000;
const posix_signals = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

pub const Event = enum {
    user_prompt_submit,
    pre_tool_use,
    post_tool_use,

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .user_prompt_submit => "UserPromptSubmit",
            .pre_tool_use => "PreToolUse",
            .post_tool_use => "PostToolUse",
        };
    }
};

pub const Hook = struct {
    matcher: []const u8 = "",
    command: []const u8,
};

pub const Set = struct {
    user_prompt_submit: []const Hook = &.{},
    pre_tool_use: []const Hook = &.{},
    post_tool_use: []const Hook = &.{},

    pub fn forEvent(self: Set, event: Event) []const Hook {
        return switch (event) {
            .user_prompt_submit => self.user_prompt_submit,
            .pre_tool_use => self.pre_tool_use,
            .post_tool_use => self.post_tool_use,
        };
    }
};

pub const File = struct {
    UserPromptSubmit: ?[]const Hook = null,
    PreToolUse: ?[]const Hook = null,
    PostToolUse: ?[]const Hook = null,

    pub fn set(self: File) Set {
        return .{
            .user_prompt_submit = self.UserPromptSubmit orelse &.{},
            .pre_tool_use = self.PreToolUse orelse &.{},
            .post_tool_use = self.PostToolUse orelse &.{},
        };
    }
};

pub const Invocation = struct {
    event: Event,
    prompt: []const u8 = "",
    tool_name: []const u8 = "",
    tool_input: []const u8 = "{}",
    tool_response: []const u8 = "",
};

pub const Runner = struct {
    io: std.Io,
    root: []const u8,
    set: Set,
    timeout_ms: u64 = default_timeout_ms,

    pub fn dispatch(self: Runner, allocator: std.mem.Allocator, invocation: Invocation) !?[]u8 {
        for (self.set.forEvent(invocation.event)) |hook| {
            if (!matches(hook.matcher, invocation.tool_name)) continue;
            const result = try self.runCommand(allocator, hook.command, invocation);
            defer allocator.free(result.stderr);

            if (result.code == 2 and invocation.event != .post_tool_use) {
                const reason = std.mem.trim(u8, result.stderr, " \t\r\n");
                if (reason.len > 0) return @as(?[]u8, try allocator.dupe(u8, reason));
                return @as(?[]u8, try std.fmt.allocPrint(
                    allocator,
                    "{s} hook blocked the operation",
                    .{invocation.event.name()},
                ));
            }
        }
        return null;
    }

    const CommandResult = struct {
        code: u8,
        stderr: []u8,
    };

    fn runCommand(
        self: Runner,
        allocator: std.mem.Allocator,
        command: []const u8,
        invocation: Invocation,
    ) !CommandResult {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{});
        defer dir.close(self.io);

        var payload_writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer payload_writer.deinit();
        try writeJson(allocator, &payload_writer.writer, self.root, invocation);
        try payload_writer.writer.writeByte('\n');
        const payload = try payload_writer.toOwnedSlice();
        defer allocator.free(payload);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "bash", "-lc", command },
            .cwd = .{ .dir = dir },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .pipe,
            .pgid = if (posix_signals) 0 else null,
        });
        var reaped = false;
        defer if (!reaped) killGroup(self.io, &child);

        var input: InputWrite = .{ .io = self.io, .child = &child, .payload = payload };
        var input_future = try self.io.concurrent(InputWrite.run, .{&input});
        defer input_future.cancel(self.io);

        var buffers: std.Io.File.MultiReader.Buffer(1) = undefined;
        var readers: std.Io.File.MultiReader = undefined;
        readers.init(allocator, self.io, buffers.toStreams(), &.{child.stderr.?});
        defer readers.deinit();

        const stderr_reader = readers.reader(0);
        const deadline = std.Io.Clock.now(.awake, self.io).toMilliseconds() + @as(i64, @intCast(self.timeout_ms));
        var stderr_done = false;

        while (!stderr_done or !input.done.load(.acquire)) {
            const left = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            const slice = @min(poll_slice_ms, @as(u64, @intCast(left)));

            if (stderr_done) {
                try std.Io.sleep(self.io, .fromMilliseconds(@intCast(slice)), .awake);
            } else {
                readers.fill(64, .{ .duration = .{
                    .raw = .fromMilliseconds(@intCast(slice)),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.EndOfStream => stderr_done = true,
                    error.Timeout => {},
                    else => |other| return other,
                };
                if (stderr_reader.buffered().len > stderr_limit) return error.StreamTooLong;
            }
        }

        input_future.await(self.io);
        try readers.checkAnyError();

        const term = try child.wait(self.io);
        reaped = true;
        const stderr = try readers.toOwnedSlice(0);
        errdefer allocator.free(stderr);
        const code: u8 = switch (term) {
            .exited => |value| value,
            else => 1,
        };
        return .{ .code = code, .stderr = stderr };
    }
};

const InputWrite = struct {
    io: std.Io,
    child: *std.process.Child,
    payload: []const u8,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *InputWrite) void {
        defer self.done.store(true, .release);
        defer {
            if (self.child.stdin) |stdin| stdin.close(self.io);
            self.child.stdin = null;
        }

        var buffer: [4096]u8 = undefined;
        var writer = self.child.stdin.?.writer(self.io, &buffer);
        writer.interface.writeAll(self.payload) catch return;
        writer.interface.flush() catch return;
    }
};

fn killGroup(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    if (posix_signals) std.posix.kill(-pid, .TERM) catch {};
    child.kill(io);
    if (posix_signals) std.posix.kill(-pid, .KILL) catch {};
}

pub const Dispatch = struct {
    allocator: std.mem.Allocator,
    runner: Runner,
    invocation: Invocation,
    blocked: ?[]u8 = null,
    failed: ?anyerror = null,
    future: std.Io.Future(void) = undefined,
    done: std.atomic.Value(bool) = .init(false),

    pub fn start(allocator: std.mem.Allocator, runner: Runner, invocation: Invocation) !*Dispatch {
        const self = try allocator.create(Dispatch);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .runner = runner,
            .invocation = invocation,
        };
        self.future = try runner.io.concurrent(run, .{self});
        return self;
    }

    pub fn isFinished(self: *Dispatch) bool {
        return self.done.load(.acquire);
    }

    pub fn join(self: *Dispatch) void {
        self.future.await(self.runner.io);
    }

    pub fn cancel(self: *Dispatch) void {
        self.future.cancel(self.runner.io);
    }

    pub fn takeBlocked(self: *Dispatch) ?[]u8 {
        const blocked = self.blocked;
        self.blocked = null;
        return blocked;
    }

    pub fn destroy(self: *Dispatch) void {
        const allocator = self.allocator;
        if (self.blocked) |blocked| allocator.free(blocked);
        allocator.destroy(self);
    }

    fn run(self: *Dispatch) void {
        defer self.done.store(true, .release);
        self.blocked = self.runner.dispatch(self.allocator, self.invocation) catch |err| {
            self.failed = err;
            return;
        };
    }
};

fn matches(matcher: []const u8, tool_name: []const u8) bool {
    if (matcher.len == 0) return true;
    return std.mem.eql(u8, matcher, tool_name);
}

fn writeJson(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    root: []const u8,
    invocation: Invocation,
) !void {
    try w.writeAll("{\"hook_event_name\":");
    try std.json.Stringify.encodeJsonString(invocation.event.name(), .{}, w);
    try w.writeAll(",\"cwd\":");
    try std.json.Stringify.encodeJsonString(root, .{}, w);

    if (invocation.prompt.len > 0) {
        try w.writeAll(",\"prompt\":");
        try std.json.Stringify.encodeJsonString(invocation.prompt, .{}, w);
    }
    if (invocation.tool_name.len > 0) {
        try w.writeAll(",\"tool_name\":");
        try std.json.Stringify.encodeJsonString(invocation.tool_name, .{}, w);
        try w.writeAll(",\"tool_input\":");
        if (try std.json.validate(allocator, invocation.tool_input)) {
            try w.writeAll(invocation.tool_input);
        } else {
            try w.writeAll("{}");
        }
    }
    if (invocation.tool_response.len > 0) {
        try w.writeAll(",\"tool_response\":");
        try std.json.Stringify.encodeJsonString(invocation.tool_response, .{}, w);
    }
    try w.writeByte('}');
}

test "a matching pre-tool hook can block" {
    const testing = std.testing;
    const hook = Hook{ .matcher = "bash", .command = "read payload; echo blocked by policy >&2; exit 2" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };

    const reason = try runner.dispatch(testing.allocator, .{
        .event = .pre_tool_use,
        .tool_name = "bash",
        .tool_input = "{\"command\":\"make\"}",
    });
    defer if (reason) |text| testing.allocator.free(text);
    try testing.expectEqualStrings("blocked by policy", reason.?);
}

test "a matcher leaves other tools alone" {
    const testing = std.testing;
    const hook = Hook{ .matcher = "write", .command = "exit 2" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };
    try testing.expect(try runner.dispatch(testing.allocator, .{ .event = .pre_tool_use, .tool_name = "read" }) == null);
}

test "large input and stderr cannot block each other" {
    const testing = std.testing;
    const prompt = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(prompt);
    @memset(prompt, 'x');

    const hook = Hook{
        .command = "i=0; while [ $i -lt 4096 ]; do printf 12345678 >&2; i=$((i + 1)); done; exit 2",
    };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .user_prompt_submit = &.{hook} },
        .timeout_ms = 2_000,
    };

    const reason = try runner.dispatch(testing.allocator, .{
        .event = .user_prompt_submit,
        .prompt = prompt,
    });
    defer if (reason) |text| testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 32 * 1024), reason.?.len);
}

test "a hook is killed when its deadline passes" {
    const testing = std.testing;
    const hook = Hook{ .command = "sleep 5" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .user_prompt_submit = &.{hook} },
        .timeout_ms = 50,
    };

    try testing.expectError(error.Timeout, runner.dispatch(testing.allocator, .{
        .event = .user_prompt_submit,
        .prompt = "hello",
    }));
}
