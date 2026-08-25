//! Lifecycle hooks: typed events inside synth, optionally handled by commands.
//!
//! Commands run from the project root and receive one JSON object on stdin.
//! An exit status of 2 blocks events that can still be stopped; every other
//! status is advisory. This deliberately leaves richer JSON decisions for a
//! later version without baking shell concerns into the agent loop.

const std = @import("std");

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

    pub fn parse(text: []const u8) ?Event {
        inline for (std.meta.tags(Event)) |event| {
            if (std.mem.eql(u8, text, event.name())) return event;
        }
        return null;
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
    /// Raw JSON arguments produced by the model.
    tool_input: []const u8 = "{}",
    tool_response: []const u8 = "",
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    set: Set,

    /// Run every matching command. Returns an owned block reason when a hook
    /// exits 2, otherwise null. The caller owns the returned string.
    pub fn dispatch(self: Runner, invocation: Invocation) !?[]u8 {
        for (self.set.forEvent(invocation.event)) |hook| {
            if (!matches(hook.matcher, invocation.tool_name)) continue;
            const result = try self.runCommand(hook.command, invocation);
            defer self.allocator.free(result.stderr);

            if (result.code == 2 and invocation.event != .post_tool_use) {
                const reason = std.mem.trim(u8, result.stderr, " \t\r\n");
                if (reason.len > 0) return @as(?[]u8, try self.allocator.dupe(u8, reason));
                return @as(?[]u8, try std.fmt.allocPrint(
                    self.allocator,
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

    fn runCommand(self: Runner, command: []const u8, invocation: Invocation) !CommandResult {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{});
        defer dir.close(self.io);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "bash", "-lc", command },
            .cwd = .{ .dir = dir },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        errdefer child.kill(self.io);

        var input_buffer: [4096]u8 = undefined;
        var input = child.stdin.?.writer(self.io, &input_buffer);
        try writeJson(&input.interface, self.root, invocation);
        try input.interface.writeByte('\n');
        try input.interface.flush();
        child.stdin.?.close(self.io);
        child.stdin = null;

        var stderr_buffer: [4096]u8 = undefined;
        var stderr_reader = child.stderr.?.reader(self.io, &stderr_buffer);
        const stderr = try stderr_reader.interface.allocRemaining(self.allocator, .limited(64 * 1024));
        errdefer self.allocator.free(stderr);

        const term = try child.wait(self.io);
        const code: u8 = switch (term) {
            .exited => |value| value,
            else => 1,
        };
        return .{ .code = code, .stderr = stderr };
    }
};

fn matches(matcher: []const u8, tool_name: []const u8) bool {
    if (matcher.len == 0) return true;
    return std.mem.eql(u8, matcher, tool_name);
}

fn writeJson(w: *std.Io.Writer, root: []const u8, invocation: Invocation) !void {
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
        // Model-produced arguments have already been parsed by the registry.
        // Keep malformed input valid JSON for hooks that only inspect metadata.
        if (try std.json.validate(std.heap.page_allocator, invocation.tool_input)) {
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
        .allocator = testing.allocator,
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };

    const reason = try runner.dispatch(.{
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
        .allocator = testing.allocator,
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };
    try testing.expect(try runner.dispatch(.{ .event = .pre_tool_use, .tool_name = "read" }) == null);
}
