//! Agents: what the model is allowed to do this turn, and what it is told to do
//! with it.
//!
//! A record, not a branch. Each names the tools it may call and the extra
//! instructions that come with them, and both reach the model through the same
//! two seams - the tool schema in the request, and the approval gate.

const std = @import("std");
const testing = std.testing;

pub const Agent = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    /// Tools this agent may call. Empty means every registered tool.
    tools: []const []const u8 = &.{},
    /// Appended to the base system prompt.
    prompt: []const u8 = "",
    /// Model calls this agent may make in one turn. A backstop, not a budget:
    /// an agent that cannot change anything needs far fewer than one that is
    /// working through a repository.
    steps: usize = 200,

    /// Whether `name` is one of this agent's tools.
    pub fn allows(self: Agent, name: []const u8) bool {
        if (self.tools.len == 0) return true;
        for (self.tools) |tool| {
            if (std.mem.eql(u8, tool, name)) return true;
        }
        return false;
    }
};

pub const default_id = "build";

/// Read-only tools, shared by the agents that may not change anything.
const reading: []const []const u8 = &.{ "read", "list", "glob", "grep", "ask_user" };
/// The same, plus delegating. A subagent can only read, so an agent that may
/// not change anything loses nothing by being allowed to start one - and a
/// multi-round search is exactly what plan and review modes spend their steps
/// on. `task` itself is deliberately absent from `reading`, which is what stops
/// a subagent starting another.
const reading_and_delegating: []const []const u8 = reading ++ &[_][]const u8{"task"};

pub const all: []const Agent = &.{
    .{
        .id = "build",
        .label = "Build",
        .description = "read, write and run - the default",
    },
    .{
        .id = "plan",
        .label = "Plan",
        .description = "read only; produces a plan instead of changes",
        .tools = reading_and_delegating,
        .steps = 40,
        .prompt =
        \\
        \\<mode>
        \\You are in plan mode. `write`, `edit` and `bash` are not available to
        \\you, so nothing you do can change the project.
        \\Read what you need, then answer with a plan: the files to change, what
        \\changes in each, and what could go wrong. Name the files you actually
        \\read.
        \\Do not say work is done. Nothing has been done.
        \\</mode>
        ,
    },
    .{
        .id = "review",
        .label = "Review",
        .description = "read and run commands, but no edits",
        .tools = reading_and_delegating ++ &[_][]const u8{"bash"},
        .steps = 80,
        .prompt =
        \\
        \\<mode>
        \\You are in review mode. You can read files and run commands - tests,
        \\`git diff`, a build - but `write` and `edit` are not available, so you
        \\cannot fix anything you find.
        \\Report findings worst first, each anchored to a `path:line`, each with
        \\the input or state that makes it go wrong. Say plainly when you find
        \\nothing.
        \\</mode>
        ,
    },
};

/// What a subagent runs as.
///
/// Deliberately not in `all`: it is chosen by the `task` tool rather than by a
/// person, so it never appears in the cycle. Its tool list leaves out `task`
/// itself, which is what stops a subagent starting another one.
pub const task: Agent = .{
    .id = "task",
    .label = "Task",
    .description = "a subagent answering one question",
    .tools = reading,
    .steps = 30,
    .prompt =
    \\
    \\<mode>
    \\You are a subagent. You were given one question by the agent you are
    \\working for, and your whole answer is a single tool result it will read.
    \\Nothing you write reaches a person, so write for the agent: no greeting,
    \\no offer to help further.
    \\Search until you can answer, then answer. Lead with the answer, then the
    \\`path:line` references it rests on. Say what you did not find.
    \\You cannot change anything, and you cannot delegate further.
    \\</mode>
    ,
};

/// Every agent, including the ones a person cannot choose.
const every: []const Agent = all ++ &[_]Agent{task};

pub fn find(id: []const u8) ?Agent {
    for (every) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

pub fn findOrDefault(id: []const u8) Agent {
    return find(id) orelse find(default_id).?;
}

/// The agent after `id`, wrapping around. What a single key cycles through.
pub fn next(id: []const u8) Agent {
    for (all, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.id, id)) return all[(i + 1) % all.len];
    }
    return findOrDefault(default_id);
}

test "an agent's tool list is what it may call" {
    const build = findOrDefault("build");
    try testing.expect(build.allows("edit"));
    try testing.expect(build.allows("bash"));
    try testing.expect(build.allows("anything-registered-later"));

    const plan = find("plan").?;
    try testing.expect(plan.allows("read"));
    try testing.expect(plan.allows("task"));
    try testing.expect(!plan.allows("edit"));
    try testing.expect(!plan.allows("write"));
    try testing.expect(!plan.allows("bash"));

    const review = find("review").?;
    try testing.expect(review.allows("bash"));
    try testing.expect(!review.allows("write"));
}

test "reading agents get fewer steps than working ones" {
    const build = findOrDefault("build");
    for (all) |entry| {
        try testing.expect(entry.steps > 0);
        // Nothing needs more room than the agent that can change the project.
        try testing.expect(entry.steps <= build.steps);
    }
    try testing.expect(find("plan").?.steps < build.steps);
}

test "the task agent is reachable but never in the cycle" {
    const subagent = find("task").?;
    try testing.expect(subagent.allows("grep"));
    try testing.expect(subagent.allows("glob"));
    try testing.expect(!subagent.allows("write"));
    try testing.expect(!subagent.allows("bash"));
    // The one that matters: a subagent cannot start a subagent.
    try testing.expect(!subagent.allows("task"));

    for (all) |entry| try testing.expect(!std.mem.eql(u8, entry.id, "task"));

    var id: []const u8 = default_id;
    for (0..all.len * 2) |_| {
        id = next(id).id;
        try testing.expect(!std.mem.eql(u8, id, "task"));
    }
}

test "an unknown id falls back rather than failing" {
    try testing.expect(find("nope") == null);
    try testing.expectEqualStrings(default_id, findOrDefault("nope").id);
    try testing.expectEqualStrings(default_id, findOrDefault("").id);
}

test "cycling visits every agent and comes back" {
    var id: []const u8 = default_id;
    for (0..all.len) |_| id = next(id).id;
    try testing.expectEqualStrings(default_id, id);

    try testing.expectEqualStrings("plan", next("build").id);
    try testing.expectEqualStrings("build", next("nope").id);
}

test "a read-only agent cannot reach a mutating tool" {
    for (all) |entry| {
        if (entry.tools.len == 0) continue;
        for (entry.tools) |tool| {
            try testing.expect(!std.mem.eql(u8, tool, "write"));
            try testing.expect(!std.mem.eql(u8, tool, "edit"));
        }
    }
}
