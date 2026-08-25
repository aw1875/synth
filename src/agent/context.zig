//! Builds the system prompt: the base instructions plus everything the model
//! needs to know about where it is running.
//!
//! Ordered stable-first. The base instructions never change, the project's
//! instruction file rarely does, and the file listing changes whenever the model
//! writes something - so the listing goes last, where a rebuild invalidates the
//! least of a provider's prefix cache.

const std = @import("std");

const files = @import("../core/files.zig");
const Project = @import("../core/project.zig");
const skills = @import("../core/skill.zig");

/// Directory entries listed before the tree is truncated.
const max_entries: usize = 60;
/// Largest instruction file read into the prompt.
const max_instruction_bytes: std.Io.Limit = .limited(32 * 1024);
/// How long a built prompt is reused. A turn runs the model once per tool call,
/// and rebuilding means a `git ls-files` each time; the tree does not change
/// often enough to pay that.
const cache_ms: i64 = 15_000;

/// Project instruction files, in priority order. The first one found wins.
const instruction_files: []const []const u8 = &.{ "AGENTS.md", "CLAUDE.md" };

/// A built prompt, held so the steps of one turn share it. Owned by the
/// provider, which is the only thing that knows when a request starts.
pub const Cache = struct {
    text: ?[]const u8 = null,
    built_at: ?std.Io.Timestamp = null,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.invalidate(allocator);
    }

    pub fn invalidate(self: *Cache, allocator: std.mem.Allocator) void {
        if (self.text) |text| allocator.free(text);
        self.text = null;
        self.built_at = null;
    }

    /// The prompt, rebuilding it when the last one has gone stale. The result
    /// belongs to the cache and stays valid until the next `get` or `deinit`.
    pub fn get(
        self: *Cache,
        allocator: std.mem.Allocator,
        io: std.Io,
        base_prompt: []const u8,
        agent_prompt: []const u8,
        project: *const Project,
        available: []const skills.Skill,
    ) ![]const u8 {
        const now: std.Io.Timestamp = .now(io, .awake);
        if (self.text) |text| {
            const age = self.built_at.?.durationTo(now).nanoseconds;
            if (age < cache_ms * std.time.ns_per_ms) return text;
        }

        const built = try buildWithAgent(allocator, io, base_prompt, agent_prompt, project, available);
        self.invalidate(allocator);
        self.text = built;
        self.built_at = now;
        return built;
    }
};

/// `build`, with the agent's instructions folded into the base. They sit
/// directly after it: an agent changes rarely, so the volatile tail stays at
/// the end where a rebuild costs the least cache.
fn buildWithAgent(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    agent_prompt: []const u8,
    project: *const Project,
    available: []const skills.Skill,
) ![]const u8 {
    if (agent_prompt.len == 0) return build(allocator, io, base, project, available);

    const joined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ base, agent_prompt });
    defer allocator.free(joined);
    return build(allocator, io, joined, project, available);
}

/// Assemble the full system prompt. Caller owns the result.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_prompt: []const u8,
    project: *const Project,
    available: []const skills.Skill,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(base_prompt);

    try writeInstructions(w, io, allocator, project.root);
    try writeSkills(w, available);
    try writeEnvironment(w, project);
    try writeTree(w, io, allocator, project.root);

    return out.toOwnedSlice();
}

/// Name the skills this project offers, one line each.
///
/// A skill with no description is left out. The description is the only thing
/// that tells the model when the skill applies, so listing one without it
/// spends context on a name that can never be matched against anything; it
/// stays reachable by hand.
fn writeSkills(w: *std.Io.Writer, available: []const skills.Skill) !void {
    var listed: usize = 0;
    for (available) |entry| {
        if (entry.description.len > 0) listed += 1;
    }
    if (listed == 0) return;

    try w.writeAll(
        \\
        \\<skills>
        \\Instructions kept in this project rather than in this prompt. When one
        \\covers what you are about to do, call `skill` with its name first and
        \\follow what it says.
        \\
    );
    for (available) |entry| {
        if (entry.description.len == 0) continue;
        try w.print("{s}: {s}\n", .{ entry.id, entry.description });
    }
    try w.writeAll("</skills>\n");
}

fn writeEnvironment(w: *std.Io.Writer, project: *const Project) !void {
    try w.writeAll("\n<environment>\n");
    try w.print("Working directory: {s}\n", .{project.cwd});
    try w.print("Project root: {s}\n", .{project.root});
    try w.print("Project name: {s}\n", .{project.name()});
    switch (project.vcs) {
        .git => {
            if (project.branch) |branch| {
                try w.print("Version control: git (branch {s})\n", .{branch});
            } else {
                try w.writeAll("Version control: git (detached HEAD)\n");
            }
        },
        .none => try w.writeAll("Version control: none\n"),
    }
    try w.print("Platform: {s}\n", .{@tagName(@import("builtin").os.tag)});
    try w.writeAll("</environment>\n");
}

/// A shallow listing of the project root. Enough to answer "what is this
/// project" without a filesystem tool. What counts as a file comes from
/// `core/files.zig`, so a git project's own ignore rules decide what the model
/// is shown rather than a list of directory names kept here.
fn writeTree(w: *std.Io.Writer, io: std.Io, allocator: std.mem.Allocator, root: []const u8) !void {
    const paths = files.list(allocator, io, root, .{}) catch return;
    defer files.free(allocator, paths);

    const entries = files.topLevel(allocator, paths, max_entries + 1) catch return;
    defer files.free(allocator, entries);

    try w.writeAll("\n<project_files>\n");
    for (entries[0..@min(entries.len, max_entries)]) |entry| {
        try w.print("{s}\n", .{entry});
    }
    if (entries.len > max_entries) try w.writeAll("... (truncated)\n");
    try w.writeAll("</project_files>\n");
}

/// Inline the project's instruction file, the way AGENTS.md is meant to work.
fn writeInstructions(
    w: *std.Io.Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
) !void {
    for (instruction_files) |file_name| {
        const path = try std.fs.path.join(allocator, &.{ root, file_name });
        defer allocator.free(path);

        const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, max_instruction_bytes) catch continue;
        defer allocator.free(source);

        try w.print("\n<{s}>\n{s}\n</{s}>\n", .{ file_name, source, file_name });
        return;
    }
}

test "build describes the current project, volatile parts last" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);

    var project = try Project.detect(allocator, io, cwd_buf[0..n]);
    defer project.deinit(allocator);

    const prompt = try build(allocator, io, "base instructions", &project, &.{});
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "base instructions"));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Project root:") != null);

    const environment = std.mem.indexOf(u8, prompt, "<environment>").?;
    const listing = std.mem.indexOf(u8, prompt, "<project_files>").?;
    try std.testing.expect(environment < listing);
    if (std.mem.indexOf(u8, prompt, "<AGENTS.md>")) |instructions| {
        try std.testing.expect(instructions < environment);
    }
}

test "a cached prompt is shared by the steps of a turn" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);

    var project = try Project.detect(allocator, io, cwd_buf[0..n]);
    defer project.deinit(allocator);

    var cache: Cache = .{};
    defer cache.deinit(allocator);

    const first = try cache.get(allocator, io, "base", "", &project, &.{});
    const second = try cache.get(allocator, io, "base", "", &project, &.{});
    try std.testing.expectEqual(first.ptr, second.ptr);

    const copy = try allocator.dupe(u8, first);
    defer allocator.free(copy);

    cache.invalidate(allocator);
    const third = try cache.get(allocator, io, "base", "", &project, &.{});
    try std.testing.expectEqualStrings(copy, third);
}

test "skills are named in the prompt, and only the ones a model could pick" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &cwd_buf);

    var project = try Project.detect(allocator, io, cwd_buf[0..n]);
    defer project.deinit(allocator);

    const available: []const skills.Skill = &.{
        .{ .id = "commit", .name = "Commit", .description = "how commits are written", .dir = "/p/commit", .body = "b" },
        .{ .id = "silent", .name = "silent", .description = "", .dir = "/p/silent", .body = "b" },
    };

    const prompt = try build(allocator, io, "base", &project, available);
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "commit: how commits are written") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "silent") == null);

    const block = std.mem.indexOf(u8, prompt, "<skills>").?;
    try std.testing.expect(block < std.mem.indexOf(u8, prompt, "<environment>").?);

    const none = try build(allocator, io, "base", &project, &.{});
    defer allocator.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "<skills>") == null);
}
