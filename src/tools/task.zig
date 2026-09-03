//! `task`: hand a question to a subagent instead of answering it inline.
//!
//! The tool is a thin front for `Context.delegate`, which is installed by
//! whoever assembled the loop. Keeping the implementation on the other side of
//! that pointer is what lets `tools/` stay ignorant of the loop it runs under.

const std = @import("std");
const testing = std.testing;

const tool = @import("tool.zig");
const Context = tool.Context;
const Input = tool.Input;
const Output = tool.Output;

/// The agent record a subagent runs as. Named here rather than taken from the
/// model, so a prompt cannot talk its way into a more capable agent.
const agent_id = "task";

pub const all: []const tool.Tool = &.{
    .{
        .name = "task",
        .description =
        \\Hand a self-contained search or investigation to a subagent and get back only its answer.
        \\Use it when finding something will take several searches whose output you do not need to keep: the subagent's steps stay out of this conversation.
        \\It can read, list, glob and grep. It cannot change anything, run commands, or ask you a question, so give it everything it needs in one go and tell it what to report.
        ,
        .schema =
        \\{"type":"object","properties":{"prompt":{"type":"string","description":"The whole task: what to find, where to look if you know, and what to report back"},"description":{"type":"string","description":"A few words naming the task, for the transcript"}},"required":["prompt"]}
        ,
        .handler = run,
        // The subagent's own agent record is read-only, so nothing it does
        // needs a decision from the user, and neither does starting it.
        .read_only = true,
        // Read-only but never beside another call: a subagent borrows the
        // parent's provider, and the parent being blocked here is what makes
        // that safe.
        .parallel = false,
        .timeout_ms = tool.subagent_timeout_ms,
    },
};

fn run(ctx: Context, input: Input) !Output {
    const prompt = input.string("prompt") orelse
        return Output.err(try ctx.allocator.dupe(u8, "task: 'prompt' is required"));

    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0) {
        return Output.err(try ctx.allocator.dupe(u8, "task: 'prompt' is empty"));
    }

    const delegate = ctx.delegate orelse return Output.err(try ctx.allocator.dupe(
        u8,
        "task: subagents are not available here. Do the search yourself with glob and grep.",
    ));

    const answer = delegate.run(delegate.userdata, ctx.allocator, .{
        .agent = agent_id,
        .prompt = prompt,
        .label = input.string("description") orelse "",
        .index = ctx.call_index,
        .cancelled = ctx.cancelled,
        .progress = ctx.progress,
    }) catch |err| {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "task: the subagent stopped without answering ({s})",
            .{@errorName(err)},
        ));
    };

    if (answer.len == 0) {
        ctx.allocator.free(answer);
        return Output.err(try ctx.allocator.dupe(u8, "task: the subagent returned nothing"));
    }
    return Output.ok(answer);
}

test "without a delegate the tool says so rather than pretending" {
    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const ctx: Context = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
    };

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"prompt\":\"find the parser\"}",
        .{},
    );
    defer parsed.deinit();

    const output = try run(ctx, .{ .arguments = parsed.value });
    defer testing.allocator.free(output.content);

    try testing.expect(output.is_error);
    try testing.expect(std.mem.indexOf(u8, output.content, "not available") != null);
}

/// A delegate that answers without running anything, so the tool's own
/// behaviour can be tested apart from the loop behind it.
const Echo = struct {
    seen: tool.Delegate.Task = undefined,
    answer: []const u8 = "found it at src/x.zig:12",

    fn delegate(self: *Echo) tool.Delegate {
        return .{ .userdata = self, .run = call };
    }

    fn call(ptr: *anyopaque, allocator: std.mem.Allocator, task: tool.Delegate.Task) anyerror![]const u8 {
        const self: *Echo = @ptrCast(@alignCast(ptr));
        self.seen = task;
        return allocator.dupe(u8, self.answer);
    }
};

test "the prompt reaches the subagent, and its answer is the whole result" {
    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    var echo: Echo = .{};
    const ctx: Context = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
        .delegate = echo.delegate(),
    };

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"prompt\":\"where is the parser\",\"description\":\"find parser\"}",
        .{},
    );
    defer parsed.deinit();

    const output = try run(ctx, .{ .arguments = parsed.value });
    defer testing.allocator.free(output.content);

    try testing.expect(!output.is_error);
    try testing.expectEqualStrings("found it at src/x.zig:12", output.content);
    try testing.expectEqualStrings("where is the parser", echo.seen.prompt);
    try testing.expectEqualStrings("task", echo.seen.agent);
}

test "an empty prompt is refused before anything is started" {
    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    var echo: Echo = .{};
    const ctx: Context = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
        .delegate = echo.delegate(),
    };

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"prompt\":\"   \"}",
        .{},
    );
    defer parsed.deinit();

    const output = try run(ctx, .{ .arguments = parsed.value });
    defer testing.allocator.free(output.content);

    try testing.expect(output.is_error);
    try testing.expect(std.mem.indexOf(u8, output.content, "empty") != null);
}
