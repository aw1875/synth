//! What the project contains, minus what nobody wants to see.
//!
//! A hardcoded list of directory names to skip is wrong twice: it misses what a
//! project actually ignores (`.gitignore` is right there, and it is already
//! maintained), and it hides things the project keeps (`build/` is generated in
//! one repo and checked in as source in the next). So when the project is a git
//! repository, git answers - tracked files plus untracked ones it would not
//! ignore, which is exactly what `.gitignore`, nested ignore files,
//! `.git/info/exclude` and the user's global excludes add up to.
//!
//! Without git - or without a `git` on PATH - there is nothing to consult, and
//! the builtin list is the fallback rather than the rule.

const std = @import("std");
const testing = std.testing;

/// Ceiling on entries, so a huge tree cannot stall a caller.
pub const default_limit: usize = 20_000;
/// Largest `git ls-files` output read.
const max_git_output: std.Io.Limit = .limited(4 * 1024 * 1024);

/// Names skipped when git cannot be asked. Deliberately short: this is the
/// guess made in the absence of an answer, not a policy.
const noise: []const []const u8 = &.{
    ".git",         ".hg",     ".svn",
    ".zig-cache",   "zig-out", "zig-pkg",
    "node_modules", ".venv",   "__pycache__",
    "target",       "dist",    ".cache",
};

pub const Options = struct {
    /// Include directories, each with a trailing separator, so a picker can
    /// show them and `@src/` can mean a listing.
    directories: bool = false,
    limit: usize = default_limit,
};

/// Every file in the project, root-relative and sorted. Caller owns the slice
/// and every path in it.
pub fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    options: Options,
) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    fromGit(allocator, io, root, options.limit, &paths) catch {
        for (paths.items) |path| allocator.free(path);
        paths.clearRetainingCapacity();
        try fromWalk(allocator, io, root, options.limit, &paths);
    };

    if (options.directories) try addDirectories(allocator, &paths, options.limit);

    const out = try paths.toOwnedSlice(allocator);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

pub fn free(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// A directory sorts before what it contains, since `/` sorts below every
/// character a name starts with.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Ask git. Tracked files and untracked ones it would not ignore: a file
/// created a second ago shows up, and a build directory never does.
fn fromGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);

    // Anywhere but a work tree root, git answers about the enclosing repository.
    _ = dir.statFile(io, ".git", .{}) catch return error.NotARepository;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var reaped = false;
    defer if (!reaped) child.kill(io);

    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const output = try reader.interface.allocRemaining(allocator, max_git_output);
    defer allocator.free(output);

    const term = try child.wait(io);
    reaped = true;

    switch (term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    // NUL-separated: without `-z` git quotes paths with newlines or quotes in them.
    var entries = std.mem.splitScalar(u8, output, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        if (out.items.len >= limit) return;
        try out.append(allocator, try allocator.dupe(u8, entry));
    }
}

/// No git to ask: walk, and skip what is usually noise.
fn fromWalk(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (out.items.len >= limit) return;
        if (entry.kind != .file) continue;
        if (isNoisy(entry.path)) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }
}

/// Add every directory the files sit in, each with a trailing separator.
/// Derived rather than walked, so a directory holding nothing but ignored files
/// does not show up as an empty one.
fn addDirectories(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), limit: usize) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    var directories: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (directories.items) |path| allocator.free(path);
        directories.deinit(allocator);
    }

    for (paths.items) |path| {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, at, std.fs.path.sep)) |sep| {
            at = sep + 1;
            const prefix = path[0..at];
            if (seen.contains(prefix)) continue;

            const owned = try allocator.dupe(u8, prefix);
            errdefer allocator.free(owned);
            try seen.put(allocator, owned, {});
            try directories.append(allocator, owned);
        }
    }

    for (directories.items) |path| {
        if (paths.items.len >= limit) {
            allocator.free(path);
            continue;
        }
        try paths.append(allocator, path);
    }
    directories.deinit(allocator);
}

/// Whether any component of `path` is a name the fallback skips, or a dotfile.
pub fn isNoisy(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (part[0] == '.') return true;
        for (noise) |name| {
            if (std.mem.eql(u8, part, name)) return true;
        }
    }
    return false;
}

/// The entries directly in the project root: names only, directories marked
/// with a trailing separator. Built from `list`, so it ignores what the project
/// ignores.
pub fn topLevel(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    limit: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |entry| allocator.free(entry);
        out.deinit(allocator);
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (paths) |path| {
        if (out.items.len >= limit) break;

        const sep = std.mem.indexOfScalar(u8, path, std.fs.path.sep);
        const entry = if (sep) |at| path[0 .. at + 1] else path;
        if (seen.contains(entry)) continue;

        const owned = try allocator.dupe(u8, entry);
        errdefer allocator.free(owned);
        try seen.put(allocator, owned, {});
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}

test "git answers for a repository, ignore file included" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];

    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".gitignore", .data = "build/\n*.log\n" });
    try tmp.dir.createDirPath(testing.io, "src");
    try tmp.dir.createDirPath(testing.io, "build");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "build/out.o", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "noisy.log", .data = "" });

    {
        const walked = try list(testing.allocator, testing.io, root, .{});
        defer free(testing.allocator, walked);
        try testing.expect(contains(walked, "build/out.o"));
        try testing.expect(contains(walked, "noisy.log"));
        try testing.expect(!contains(walked, ".gitignore"));
    }

    if (!try initRepo(root)) return error.SkipZigTest;

    const tracked = try list(testing.allocator, testing.io, root, .{});
    defer free(testing.allocator, tracked);

    try testing.expect(contains(tracked, "src/main.zig"));
    try testing.expect(!contains(tracked, "build/out.o"));
    try testing.expect(!contains(tracked, "noisy.log"));
    try testing.expect(contains(tracked, ".gitignore"));
}

test "directories are derived from the files in them" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const root = buf[0..n];

    try tmp.dir.createDirPath(testing.io, "src/tui");
    try tmp.dir.createDirPath(testing.io, "empty");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/tui/app.zig", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "README.md", .data = "" });

    const paths = try list(testing.allocator, testing.io, root, .{ .directories = true });
    defer free(testing.allocator, paths);

    try testing.expect(contains(paths, "src/"));
    try testing.expect(contains(paths, "src/tui/"));
    try testing.expect(contains(paths, "src/tui/app.zig"));
    try testing.expect(!contains(paths, "empty/"));

    const at = indexOf(paths, "src/").?;
    try testing.expectEqualStrings("src/tui/", paths[at + 1]);

    const top = try topLevel(testing.allocator, paths, 10);
    defer free(testing.allocator, top);
    try testing.expectEqual(@as(usize, 2), top.len);
    try testing.expect(contains(top, "src/"));
    try testing.expect(contains(top, "README.md"));
}

test "the fallback skips the usual noise" {
    try testing.expect(isNoisy("node_modules/react/index.js"));
    try testing.expect(isNoisy("zig-out/bin/synth"));
    try testing.expect(isNoisy(".git/HEAD"));
    try testing.expect(isNoisy("src/.hidden"));

    try testing.expect(!isNoisy("src/tui/app.zig"));
    try testing.expect(!isNoisy("build.zig"));
    try testing.expect(!isNoisy("targeting.zig"));
}

fn contains(paths: []const []const u8, wanted: []const u8) bool {
    return indexOf(paths, wanted) != null;
}

fn indexOf(paths: []const []const u8, wanted: []const u8) ?usize {
    for (paths, 0..) |path, i| {
        if (std.mem.eql(u8, path, wanted)) return i;
    }
    return null;
}

/// `git init` plus a commit-less index. Returns false when there is no git to
/// run, which is a skipped test rather than a failed one.
fn initRepo(root: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(testing.io, root, .{}) catch return false;
    defer dir.close(testing.io);

    var child = std.process.spawn(testing.io, .{
        .argv = &.{ "git", "init", "-q" },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;

    const term = try child.wait(testing.io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}
