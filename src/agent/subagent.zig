//! Running one nested agent for the `task` tool.
//!
//! A subagent is an ordinary `Loop` with its own transcript, driven to a stop
//! on the worker thread that is already blocked inside the tool call. Nothing
//! about it is special-cased in the parent: it borrows the provider, the
//! registry and the project, and everything it may do comes from the agent
//! record it runs as.
//!
//! This file imports the loop; the loop does not import this file. The parent
//! is handed a `tool.Delegate` from outside, which is what keeps the dependency
//! pointing one way.

const std = @import("std");
const testing = std.testing;

const Conversation = @import("../core/conversation.zig");
const tool = @import("../tools/tool.zig");
const agents = @import("agent.zig");
const Loop = @import("loop.zig");

/// How often the runner looks at a subagent that is still working. The work is
/// on other threads, so this is a sleep rather than a spin.
const poll_interval_ms: u64 = 2;

/// Wall-clock ceiling on one subagent, whatever its step count says. A model
/// that stalls mid-turn would otherwise hold the parent's tool call open for as
/// long as it liked.
const deadline_ms: i128 = tool.subagent_deadline_ms;

pub const Runner = struct {
    /// The loop the subagent borrows its provider, registry and project from.
    /// Blocked inside a tool call for as long as the subagent runs, which is
    /// what makes sharing the provider safe.
    parent: *Loop,

    pub fn delegate(self: *Runner) tool.Delegate {
        return .{ .userdata = self, .run = erasedRun };
    }
};

fn erasedRun(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    task: tool.Delegate.Task,
) anyerror![]const u8 {
    const self: *Runner = @ptrCast(@alignCast(ptr));
    return run(self.parent, allocator, task);
}

/// Run `task` to completion and return what the subagent finished with.
pub fn run(
    parent: *Loop,
    allocator: std.mem.Allocator,
    task: tool.Delegate.Task,
) ![]const u8 {
    var convo: Conversation = .init(parent.allocator);
    defer convo.deinit();

    // A ReadLog of its own: a file the subagent read is not a file the parent
    // may edit, because the parent never saw the contents it would be editing.
    var reads: tool.ReadLog = .init(parent.allocator);
    defer reads.deinit();

    var child: Loop = .init(
        parent.allocator,
        parent.io,
        parent.provider,
        parent.registry,
        &convo,
        &reads,
        parent.project_root,
    );
    defer child.deinit();

    child.project = parent.project;
    child.skills = parent.skills;
    child.system_prompt = parent.system_prompt;
    // Nothing it may call needs a decision, so nothing may auto-approve one.
    child.auto_approve_safe = false;
    child.max_turn_ms = parent.max_turn_ms;
    child.max_turn_tokens = parent.max_turn_tokens;
    child.max_stall_ms = parent.max_stall_ms;
    // No database: a subagent's steps are not a session, and persisting them
    // would put in the transcript exactly what delegating keeps out of it.
    try child.useAgent(task.agent);

    try child.submit(task.prompt, .{});
    const outcome = try drive(&child, task);

    return report(&child, allocator, outcome);
}

const Outcome = enum {
    answered,
    /// The parent gave up, so the subagent was asked to stop.
    cancelled,
    /// Its own wall clock ran out.
    timed_out,
    /// The loop called it: the step ceiling, a budget, or a repeat loop.
    halted,
    /// The turn failed outright, so there may be nothing above at all.
    failed,
};

/// Poll the child until it stops, the parent gives up, or time runs out.
fn drive(child: *Loop, task: tool.Delegate.Task) !Outcome {
    const started = std.Io.Timestamp.now(child.io, .awake);

    while (child.isBusy()) {
        if (task.progress) |channel| {
            var line: [tool.max_progress_bytes]u8 = undefined;
            channel.report(channel.userdata, describe(child, task.label, &line));
        }

        if (task.cancelled) |flag| {
            if (flag.load(.acquire)) {
                child.requestStop();
                return .cancelled;
            }
        }

        const now = std.Io.Timestamp.now(child.io, .awake);
        if (started.durationTo(now).toMilliseconds() > deadline_ms) {
            child.requestStop();
            return .timed_out;
        }

        _ = try child.poll();
        if (!child.isBusy()) break;

        // A subagent that stopped for a decision is a bug in its agent record,
        // not something to wait on: nothing it may call needs one.
        if (child.state == .awaiting_approval) {
            child.requestStop();
            return .halted;
        }

        try std.Io.sleep(child.io, .fromMilliseconds(poll_interval_ms), .real);
    }

    // A step count read back afterwards cannot tell a last step from one too many.
    return switch (child.outcome orelse .done) {
        .done => .answered,
        .cancelled => .cancelled,
        .halted => .halted,
        .failed => .failed,
    };
}

/// One line saying where the subagent has got to. Repeats are filtered out by
/// whoever is listening, so this says the same thing until it changes.
fn describe(child: *const Loop, label: []const u8, buffer: *[tool.max_progress_bytes]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (label.len > 0) writer.print("{s} - ", .{label}) catch {};
    writer.print("step {d}/{d}: {s}", .{
        child.steps + 1,
        child.agent.steps,
        doing(child),
    }) catch {};
    return writer.buffered();
}

/// What the subagent is up to right now, in a couple of words.
fn doing(child: *const Loop) []const u8 {
    return switch (child.state) {
        .running_hooks => "running hooks",
        .thinking => "thinking",
        .compacting => "compacting",
        .running_tools => child.runningToolName() orelse "running tools",
        .cancelling => "stopping",
        .awaiting_approval, .awaiting_answer => "waiting",
        .idle => "done",
    };
}

/// The subagent's answer as the parent should read it: its final prose, with a
/// note when it stopped for a reason other than being finished.
fn report(child: *Loop, allocator: std.mem.Allocator, outcome: Outcome) ![]const u8 {
    const halt = haltReason(child);
    const answer = lastAnswer(child, halt.at);

    var buffer: [halt_note_bytes]u8 = undefined;
    const note: []const u8 = switch (outcome) {
        .answered => "",
        .cancelled => "\n\n<note>The subagent was cancelled before it finished.</note>",
        .timed_out => "\n\n<note>The subagent ran out of time before it finished. What is above is partial.</note>",
        .failed => "\n\n<note>The subagent's request failed before it finished. What is above is partial.</note>",
        .halted => haltNote(&buffer, halt.reason),
    };

    if (answer.len == 0 and note.len == 0) return allocator.dupe(u8, "");
    if (answer.len == 0) {
        return std.fmt.allocPrint(allocator, "The subagent produced no answer.{s}", .{note});
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ answer, note });
}

/// Room for the longest reason the loop halts with, and the note around it.
const halt_note_bytes = 256;

/// The note for a halted subagent, naming the limit it hit.
fn haltNote(buffer: *[halt_note_bytes]u8, reason: []const u8) []const u8 {
    const partial = " What is above is partial.</note>";
    if (reason.len == 0) return "\n\n<note>The subagent stopped before it finished." ++ partial;

    const said = if (std.mem.startsWith(u8, reason, Loop.halt_prefix)) reason[Loop.halt_prefix.len..] else reason;
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("\n\n<note>The subagent stopped early: {s}" ++ partial, .{said}) catch {
        return "\n\n<note>The subagent stopped before it finished." ++ partial;
    };
    return writer.buffered();
}

/// The reason a halted loop gave, and where it sits in the transcript.
fn haltReason(child: *Loop) Halt {
    if (child.outcome != .halted) return .{};

    const messages = child.conversation.messages.items;
    var at = messages.len;
    while (at > 0) {
        at -= 1;
        const msg = messages[at];
        if (msg.role != .assistant) continue;

        const text = std.mem.trim(u8, msg.text, " \t\r\n");
        if (!std.mem.startsWith(u8, text, Loop.halt_prefix)) return .{};
        return .{ .reason = text, .at = at };
    }
    return .{};
}

const Halt = struct { reason: []const u8 = "", at: ?usize = null };

/// The last thing the subagent said, rather than the last message: a transcript
/// ending in tool results has the answer further back.
///
/// `skip` is the halt reason's index, which reads as an answer but is not one.
fn lastAnswer(child: *Loop, skip: ?usize) []const u8 {
    const messages = child.conversation.messages.items;
    var at = messages.len;
    while (at > 0) {
        at -= 1;
        if (skip) |halt| if (at == halt) continue;
        const msg = messages[at];
        if (msg.role != .assistant) continue;
        const text = std.mem.trim(u8, msg.text, " \t\r\n");
        if (text.len == 0) continue;
        // The loop's placeholder for a turn that said nothing is not an answer.
        if (std.mem.eql(u8, text, Loop.no_reply)) continue;
        return text;
    }
    return "";
}

test "a subagent loops through its own tools and returns only the answer" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{
        .{ .call = .{ .name = "list", .arguments = "{\"path\":\".\"}" } },
        .{ .text = "the parser is at src/parse.zig:40" },
    };

    const answer = try run(&harness.parent, testing.allocator, .{
        .agent = "task",
        .prompt = "where is the parser",
    });
    defer testing.allocator.free(answer);

    try testing.expectEqualStrings("the parser is at src/parse.zig:40", answer);
    // It took more than one model call to get there.
    try testing.expectEqual(@as(usize, 2), harness.fake.at);
    // And the parent's own transcript saw none of it.
    try testing.expectEqual(@as(usize, 0), harness.convo.messages.items.len);
}

test "a subagent that says nothing returns nothing for the tool to report" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{.{ .text = "" }};

    const answer = try run(&harness.parent, testing.allocator, .{
        .agent = "task",
        .prompt = "find nothing",
    });
    defer testing.allocator.free(answer);

    try testing.expectEqualStrings("", answer);
}

test "a cancelled parent ends the subagent" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{.{ .text = "working on it" }};

    var stop: std.atomic.Value(bool) = .init(true);
    const answer = try run(&harness.parent, testing.allocator, .{
        .agent = "task",
        .prompt = "take your time",
        .cancelled = &stop,
    });
    defer testing.allocator.free(answer);

    try testing.expect(std.mem.indexOf(u8, answer, "cancelled") != null);
}

test "a halted subagent reports its work, not the loop's stop line" {
    const harness = try Harness.init();
    defer harness.deinit();

    // The same call every time, which the loop halts on.
    harness.fake.script = &.{.{ .call = .{
        .name = "list",
        .arguments = "{\"path\":\".\"}",
        .said = "the parser is at src/parse.zig:40",
    } }};

    const answer = try run(&harness.parent, testing.allocator, .{
        .agent = "task",
        .prompt = "keep going forever",
    });
    defer testing.allocator.free(answer);

    try testing.expect(std.mem.indexOf(u8, answer, "src/parse.zig:40") != null);
    try testing.expect(std.mem.indexOf(u8, answer, "partial") != null);

    try testing.expect(std.mem.indexOf(u8, answer, "stopped early: the same tool call") != null);
    try testing.expect(!std.mem.startsWith(u8, answer, Loop.halt_prefix));
}

test "a subagent that answers gets no note, however many steps it spent" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{
        .{ .call = .{ .name = "list", .arguments = "{\"path\":\".\"}" } },
        .{ .text = "done" },
    };

    const answer = try run(&harness.parent, testing.allocator, .{
        .agent = "task",
        .prompt = "be quick",
    });
    defer testing.allocator.free(answer);

    try testing.expectEqualStrings("done", answer);
}

test "a subagent cannot reach a tool its agent record leaves out" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{
        .{ .call = .{ .name = "write", .arguments = "{\"path\":\"x\",\"content\":\"y\"}" } },
        .{ .text = "I could not write anything" },
    };

    const answer = try run(&harness.parent, testing.allocator, .{
        .agent = "task",
        .prompt = "write a file",
    });
    defer testing.allocator.free(answer);

    try testing.expectEqualStrings("I could not write anything", answer);

    // The call was turned down rather than queued for a person, which is what
    // keeps a blocking subagent from deadlocking on an approval nobody sees.
    const messages = harness.parent.conversation.messages.items;
    try testing.expectEqual(@as(usize, 0), messages.len);
}

/// A parent loop backed by a scripted provider, which is all a subagent needs
/// to borrow.
const Harness = struct {
    convo: Conversation,
    registry: @import("../tools/registry.zig"),
    reads: tool.ReadLog,
    fake: Fake,
    parent: Loop,

    /// On the heap, because the loop borrows pointers to these fields and a
    /// value returned from here would leave every one of them dangling.
    fn init() !*Harness {
        const self = try testing.allocator.create(Harness);
        self.* = .{
            .convo = .init(testing.allocator),
            .registry = try .init(testing.allocator),
            .reads = .init(testing.allocator),
            .fake = .{},
            .parent = undefined,
        };
        self.parent = .init(
            testing.allocator,
            testing.io,
            self.fake.provider(),
            &self.registry,
            &self.convo,
            &self.reads,
            ".",
        );
        return self;
    }

    fn deinit(self: *Harness) void {
        self.parent.deinit();
        self.reads.deinit();
        self.registry.deinit();
        self.convo.deinit();
        testing.allocator.destroy(self);
    }
};

/// Answers with the next step of a script, so a nested loop can be driven
/// through several turns without a model.
const Fake = struct {
    script: []const Step = &.{},
    at: usize = 0,

    const Provider = @import("../provider/provider.zig");

    const Step = union(enum) {
        text: []const u8,
        /// `said` rides along with the call, since calls alone end no turn.
        call: struct { name: []const u8, arguments: []const u8, said: []const u8 = "" },
    };

    fn provider(self: *Fake) Provider {
        return .{ .userdata = self, .respond = respond, .name = "fake", .model = "fake" };
    }

    fn respond(
        ptr: *anyopaque,
        _: *Conversation,
        _: Provider.Turn,
        allocator: std.mem.Allocator,
        _: ?Provider.Sink,
    ) anyerror!Provider.Reply {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.script.len == 0) return .{ .text = try allocator.dupe(u8, "") };

        // Past the end the last step repeats, so a script can outlast a limit.
        const step = self.script[@min(self.at, self.script.len - 1)];
        self.at += 1;

        return switch (step) {
            .text => |line| .{ .text = try allocator.dupe(u8, line) },
            .call => |wanted| blk: {
                const calls = try allocator.alloc(Conversation.ToolCall, 1);
                calls[0] = .{
                    .id = try allocator.dupe(u8, "call_0"),
                    .name = try allocator.dupe(u8, wanted.name),
                    .arguments = try allocator.dupe(u8, wanted.arguments),
                };
                break :blk .{ .text = try allocator.dupe(u8, wanted.said), .tool_calls = calls };
            },
        };
    }
};
