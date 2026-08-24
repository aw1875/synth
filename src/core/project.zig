//! Working out what project we are in.

const std = @import("std");

const pkg = @import("pkg");

const Project = @This();

/// How far up the tree to look for a repository root before giving up.
const max_walk_up = 64;

pub const Vcs = enum { none, git };

/// Absolute path of the repository root, or of the working directory when
/// there is no repository. Owned.
root: []const u8,
/// Directory the harness was launched from. Owned.
cwd: []const u8,
vcs: Vcs = .none,
/// Current branch, when it can be read cheaply. Owned.
branch: ?[]const u8 = null,

pub fn deinit(self: *Project, allocator: std.mem.Allocator) void {
    allocator.free(self.root);
    allocator.free(self.cwd);
    if (self.branch) |branch| allocator.free(branch);
}

/// Display name for the project: the last path component of its root.
pub fn name(self: *const Project) []const u8 {
    if (self.root.len == 0) return pkg.name;
    return std.fs.path.basename(self.root);
}

/// `cwd` relative to the project root, or "" when they are the same. Borrowed
/// from `cwd`.
pub fn relativeCwd(self: *const Project) []const u8 {
    if (self.cwd.len <= self.root.len) return "";
    if (!std.mem.startsWith(u8, self.cwd, self.root)) return "";
    return std.mem.trimStart(u8, self.cwd[self.root.len..], "/");
}

/// Walk up from `cwd` looking for a `.git` entry. Matches a file as well as a
/// directory, because a linked worktree's `.git` is a file pointing elsewhere.
pub fn detect(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !Project {
    var self: Project = .{
        .root = try allocator.dupe(u8, cwd),
        .cwd = try allocator.dupe(u8, cwd),
    };
    errdefer self.deinit(allocator);

    var dir = cwd;
    var steps: usize = 0;
    while (steps < max_walk_up) : (steps += 1) {
        if (dir.len == 0) break;

        const git_path = try std.fs.path.join(allocator, &.{ dir, ".git" });
        defer allocator.free(git_path);

        if (std.Io.Dir.cwd().statFile(io, git_path, .{})) |_| {
            allocator.free(self.root);
            self.root = try allocator.dupe(u8, dir);
            self.vcs = .git;
            self.branch = readBranch(allocator, io, git_path) catch null;
            break;
        } else |_| {}

        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len == dir.len) break;
        dir = parent;
    }

    return self;
}

/// Read the checked-out branch straight out of `.git/HEAD`, rather than
/// shelling out to git. Returns null for a detached HEAD.
fn readBranch(allocator: std.mem.Allocator, io: std.Io, git_path: []const u8) !?[]const u8 {
    var buffer: [4096]u8 = undefined;

    const stat = try std.Io.Dir.cwd().statFile(io, git_path, .{});
    const head_path = if (stat.kind == .directory)
        try std.fs.path.join(allocator, &.{ git_path, "HEAD" })
    else blk: {
        const pointer = try std.Io.Dir.cwd().readFile(io, git_path, &buffer);
        const prefix = "gitdir:";
        if (!std.mem.startsWith(u8, pointer, prefix)) return null;
        const git_dir = std.mem.trim(u8, pointer[prefix.len..], " \t\r\n");
        break :blk try std.fs.path.join(allocator, &.{ git_dir, "HEAD" });
    };
    defer allocator.free(head_path);

    const head = std.Io.Dir.cwd().readFile(io, head_path, &buffer) catch return null;
    const trimmed = std.mem.trim(u8, head, " \t\r\n");

    const ref_prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, ref_prefix)) return null;
    return try allocator.dupe(u8, trimmed[ref_prefix.len..]);
}

test "relativeCwd" {
    var project: Project = .{
        .root = try std.testing.allocator.dupe(u8, "/repo"),
        .cwd = try std.testing.allocator.dupe(u8, "/repo/src/tui"),
    };
    defer project.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("src/tui", project.relativeCwd());
    try std.testing.expectEqualStrings("repo", project.name());
}
