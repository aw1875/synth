//! Running nested agents for the `task` tool.
//!
//! A subagent is an ordinary `Loop` with its own transcript, its own client and
//! its own read log, driven by the same tick that drives the parent. The tool
//! call that asked for it waits on a worker thread; the loop behind it never
//! leaves the thread every other loop is polled on, which is what lets the
//! person read it while it runs.
//!
//! This file imports the loop; the loop does not import this file. The parent
//! is handed a `tool.Delegate` from outside, which is what keeps the dependency
//! pointing one way.

const std = @import("std");
const testing = std.testing;

const Backend = @import("../provider/backend.zig");
const Conversation = @import("../core/conversation.zig");
const tool = @import("../tools/tool.zig");
const agents = @import("agent.zig");
const Loop = @import("loop.zig");

/// How long a waiting tool call sleeps between looks at its subagent.
const wait_slice_ms: u64 = 5;

/// Wall-clock ceiling on one subagent, whatever its step count says. A model
/// that stalls mid-turn would otherwise hold the parent's tool call open for as
/// long as it liked.
const deadline_ms: i64 = @intCast(tool.subagent_deadline_ms);

/// One nested run, from the request to the answer.
///
/// Written by two threads at different times, never at once: the tool worker
/// fills the request and then waits, and the tick that owns `loop` fills the
/// answer and raises `done`. `done` is the handoff.
pub const Child = struct {
    /// What was asked for, owned by this struct.
    agent: []const u8,
    prompt: []const u8,
    label: []const u8,
    /// Which of the parent's tool calls is waiting on it.
    index: usize,
    /// The parent's give-up flag, so cancelling a turn ends this too.
    cancelled: ?*const std.atomic.Value(bool),
    progress: ?tool.Progress,

    /// Built on the first tick that sees this, so everything the loop touches
    /// belongs to the thread that polls it.
    started: bool = false,
    backend: ?*Backend.Spawned = null,
    convo: Conversation,
    reads: tool.ReadLog,
    loop: Loop = undefined,
    started_ms: i64 = 0,

    /// Raised once `answer` or `failed` is set, and nothing writes either after.
    done: std.atomic.Value(bool) = .init(false),
    answer: ?[]const u8 = null,
    failed: ?anyerror = null,

    /// Whether the waiting call has taken the answer and gone. Raised on the
    /// worker, read on the tick.
    collected: std.atomic.Value(bool) = .init(false),

    fn describeTo(self: *Child, buffer: *[tool.max_progress_bytes]u8) []const u8 {
        return describe(&self.loop, self.label, buffer);
    }
};

pub const Runner = struct {
    /// The loop a subagent takes its registry, project and settings from.
    parent: *Loop,
    /// Where a child's own client comes from. Null leaves subagents sharing the
    /// parent's, which is only safe while nothing else is using it.
    backend: ?*Backend = null,
    /// Where a tool worker leaves a request. Guarded, and drained by the tick
    /// into `active`, which nothing but the tick ever touches.
    mutex: std.Io.Mutex = .init,
    inbox: std.ArrayList(*Child) = .empty,
    active: std.ArrayList(*Child) = .empty,

    pub fn delegate(self: *Runner) tool.Delegate {
        return .{ .userdata = self, .run = erasedRun };
    }

    pub fn deinit(self: *Runner) void {
        self.mutex.lockUncancelable(self.parent.io);
        defer self.mutex.unlock(self.parent.io);

        for (self.inbox.items) |child| destroy(self.parent.allocator, child);
        self.inbox.deinit(self.parent.allocator);
        for (self.active.items) |child| destroy(self.parent.allocator, child);
        self.active.deinit(self.parent.allocator);
    }

    /// Drive every subagent one step, on the thread that owns them.
    ///
    /// Returns true if anything moved, so the caller knows to redraw.
    pub fn poll(self: *Runner) !bool {
        var moved = try self.collect();

        var at: usize = 0;
        while (at < self.active.items.len) {
            const child = self.active.items[at];
            if (child.collected.load(.acquire)) {
                _ = self.active.orderedRemove(at);
                destroy(self.parent.allocator, child);
                moved = true;
                continue;
            }
            moved = try self.step(child) or moved;
            at += 1;
        }
        return moved;
    }

    /// Take whatever the workers left, so the rest of a poll needs no lock.
    fn collect(self: *Runner) !bool {
        self.mutex.lockUncancelable(self.parent.io);
        defer self.mutex.unlock(self.parent.io);
        if (self.inbox.items.len == 0) return false;

        try self.active.appendSlice(self.parent.allocator, self.inbox.items);
        self.inbox.clearRetainingCapacity();
        return true;
    }

    /// The transcripts a person can read right now, newest last. Tick only.
    pub fn live(self: *Runner) []const *Child {
        return self.active.items;
    }

    /// The subagent a parent tool call is waiting on, if it is still running.
    pub fn running(self: *Runner, index: usize) ?*Child {
        for (self.active.items) |child| {
            if (child.index == index and !child.done.load(.acquire)) return child;
        }
        return null;
    }

    fn step(self: *Runner, child: *Child) !bool {
        if (child.done.load(.acquire)) return false;

        if (!child.started) {
            self.begin(child) catch |err| {
                child.failed = err;
                child.done.store(true, .release);
                return true;
            };
            return true;
        }

        if (child.progress) |channel| {
            var line: [tool.max_progress_bytes]u8 = undefined;
            channel.report(channel.userdata, child.describeTo(&line));
        }

        if (self.givenUp(child)) {
            child.loop.requestStop();
            try self.finish(child, .cancelled);
            return true;
        }

        if (tool.monotonicMilliseconds(self.parent.io) - child.started_ms > deadline_ms) {
            child.loop.requestStop();
            try self.finish(child, .timed_out);
            return true;
        }

        const moved = try child.loop.poll();
        if (child.loop.isBusy()) {
            // Nobody can see a subagent's approval prompt, so an agent record
            // that can reach one has nowhere to go. Today none can.
            if (child.loop.state != .awaiting_approval) return moved;
            child.loop.requestStop();
            try self.finish(child, .halted);
            return true;
        }

        try self.finish(child, outcomeOf(&child.loop));
        return true;
    }

    /// Build the loop, on the tick, so nothing it owns is touched by two
    /// threads.
    fn begin(self: *Runner, child: *Child) !void {
        const parent = self.parent;

        var provider = parent.provider;
        if (self.backend) |backend| {
            child.backend = try backend.spawn(parent.allocator);
            provider = child.backend.?.provider();
        }

        child.loop = .init(
            parent.allocator,
            parent.io,
            provider,
            parent.registry,
            &child.convo,
            &child.reads,
            parent.project_root,
        );
        child.loop.project = parent.project;
        child.loop.skills = parent.skills;
        child.loop.system_prompt = parent.system_prompt;
        child.loop.delegate = null;
        // A standing allowance is the person's, not something to inherit.
        child.loop.auto_approve_safe = false;
        child.loop.max_turn_ms = parent.max_turn_ms;
        child.loop.max_turn_tokens = parent.max_turn_tokens;
        child.loop.max_stall_ms = parent.max_stall_ms;

        try child.loop.useAgent(child.agent);
        child.started_ms = tool.monotonicMilliseconds(parent.io);
        child.started = true;
        try child.loop.submit(child.prompt, .{});
    }

    fn finish(self: *Runner, child: *Child, outcome: Outcome) !void {
        const allocator = self.parent.allocator;
        child.answer = report(&child.loop, allocator, outcome) catch |err| {
            child.failed = err;
            child.done.store(true, .release);
            return;
        };
        self.parent.storeSubagent(child.index, &child.convo) catch {};
        child.done.store(true, .release);
    }

    fn givenUp(_: *Runner, child: *Child) bool {
        const flag = child.cancelled orelse return false;
        return flag.load(.acquire);
    }

    fn add(self: *Runner, child: *Child) !void {
        self.mutex.lockUncancelable(self.parent.io);
        defer self.mutex.unlock(self.parent.io);
        try self.inbox.append(self.parent.allocator, child);
    }
};

/// Free a child and everything it built.
fn destroy(allocator: std.mem.Allocator, child: *Child) void {
    if (child.started) child.loop.deinit();
    if (child.backend) |spawned| spawned.deinit();
    child.convo.deinit();
    child.reads.deinit();
    if (child.answer) |answer| allocator.free(answer);
    allocator.free(child.agent);
    allocator.free(child.prompt);
    allocator.free(child.label);
    allocator.destroy(child);
}

fn erasedRun(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    task: tool.Delegate.Task,
) anyerror![]const u8 {
    const self: *Runner = @ptrCast(@alignCast(ptr));
    return run(self, allocator, task);
}

/// Ask for a subagent and wait for it. Runs on a tool worker; everything the
/// nested loop touches happens on the tick instead.
pub fn run(
    runner: *Runner,
    allocator: std.mem.Allocator,
    task: tool.Delegate.Task,
) ![]const u8 {
    const gpa = runner.parent.allocator;

    const child = try gpa.create(Child);
    child.* = .{
        .agent = try gpa.dupe(u8, task.agent),
        .prompt = try gpa.dupe(u8, task.prompt),
        .label = try gpa.dupe(u8, task.label),
        .index = task.index,
        .cancelled = task.cancelled,
        .progress = task.progress,
        .convo = .init(gpa),
        .reads = .init(gpa),
    };
    errdefer destroy(gpa, child);

    try runner.add(child);

    while (!child.done.load(.acquire)) {
        try std.Io.sleep(runner.parent.io, .fromMilliseconds(wait_slice_ms), .real);
    }

    // Copied before the flag that lets the tick free the child.
    defer child.collected.store(true, .release);
    if (child.failed) |err| return err;
    return allocator.dupe(u8, child.answer orelse "");
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

/// What the loop settled on. A step count read back afterwards cannot tell a
/// last step from one too many.
fn outcomeOf(child: *Loop) Outcome {
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

    const answer = try runTask(harness, .{
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

    const answer = try runTask(harness, .{
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
    const answer = try runTask(harness, .{
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

    const answer = try runTask(harness, .{
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

    const answer = try runTask(harness, .{
        .agent = "task",
        .prompt = "be quick",
    });
    defer testing.allocator.free(answer);

    try testing.expectEqualStrings("done", answer);
}

test "a running subagent is visible before it has answered" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{
        .{ .call = .{ .name = "list", .arguments = "{\"path\":\".\"}" } },
        .{ .text = "found it" },
    };

    var job: Job = .{ .harness = harness, .task = .{
        .agent = "task",
        .prompt = "where is it",
        .index = 3,
    } };
    var future = try testing.io.concurrent(Job.go, .{&job});

    var seen_running = false;
    while (harness.runner.active.items.len == 0 or !job.finished.load(.acquire)) {
        _ = try harness.runner.poll();
        if (harness.runner.running(3) != null) seen_running = true;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }
    future.await(testing.io);

    const answer = try job.result;
    defer testing.allocator.free(answer);

    // Reachable while it worked, which is the whole point of the move.
    try testing.expect(seen_running);
    try testing.expectEqualStrings("found it", answer);

    // And gone once the call collected it.
    _ = try harness.runner.poll();
    try testing.expect(harness.runner.running(3) == null);
}

test "a subagent cannot reach a tool its agent record leaves out" {
    const harness = try Harness.init();
    defer harness.deinit();

    harness.fake.script = &.{
        .{ .call = .{ .name = "write", .arguments = "{\"path\":\"x\",\"content\":\"y\"}" } },
        .{ .text = "I could not write anything" },
    };

    const answer = try runTask(harness, .{
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

/// Runs a task the way the app does: the call waits on a worker while the
/// runner is polled here, which on a real run is the tick's job.
fn runTask(harness: *Harness, task: tool.Delegate.Task) ![]const u8 {
    var job: Job = .{ .harness = harness, .task = task };
    var future = try testing.io.concurrent(Job.go, .{&job});

    while (harness.runner.active.items.len == 0 or !job.finished.load(.acquire)) {
        _ = try harness.runner.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }
    future.await(testing.io);
    return job.result;
}

const Job = struct {
    harness: *Harness,
    task: tool.Delegate.Task,
    result: anyerror![]const u8 = undefined,
    finished: std.atomic.Value(bool) = .init(false),

    fn go(self: *Job) void {
        self.result = run(&self.harness.runner, testing.allocator, self.task);
        self.finished.store(true, .release);
    }
};

/// A parent loop backed by a scripted provider, which is all a subagent needs
/// to borrow.
const Harness = struct {
    convo: Conversation,
    registry: @import("../tools/registry.zig"),
    reads: tool.ReadLog,
    fake: Fake,
    parent: Loop,
    runner: Runner,

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
            .runner = undefined,
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
        self.runner = .{ .parent = &self.parent };
        return self;
    }

    fn deinit(self: *Harness) void {
        self.runner.deinit();
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
