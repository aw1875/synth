//! Skills: instructions kept in a directory rather than in the binary.
//!
//! A skill is a folder holding a `SKILL.md`, whose frontmatter names it and
//! says in one line what it is for. Only those two lines ever reach the model
//! unasked; the body is read when something invokes the skill. That is the
//! whole design - a project can carry fifty skills and pay for fifty
//! descriptions, not fifty documents.
//!
//! The folder is the unit, not the file, so a skill can keep a script or a
//! template beside its instructions and point at them by name.

const std = @import("std");

/// What a skill's instructions live in.
pub const file_name = "SKILL.md";

/// Directories searched under a project root, in order. `.agents` is the
/// cross-harness convention; `.claude` is read too, so skills written for
/// Claude Code work here unchanged.
pub const project_dirs: []const []const u8 = &.{
    ".agents/skills",
    ".claude/skills",
};

/// The same pair under `$HOME`, for skills that follow a person between
/// projects.
pub const home_dirs: []const []const u8 = project_dirs;

/// Largest `SKILL.md` read. A skill is instructions, not a corpus.
pub const max_file_bytes: std.Io.Limit = .limited(64 * 1024);

/// How many skills are loaded before the rest are ignored.
pub const max_skills: usize = 256;

/// Longest description kept. One line in the system prompt, so a skill that
/// writes an essay there is trimmed rather than allowed to crowd out the rest.
pub const max_description_bytes: usize = 240;

pub const Skill = struct {
    /// The directory's name. What `/id` and the tool argument use.
    id: []const u8,
    /// `name:` from the frontmatter, or the directory name when it has none.
    name: []const u8,
    /// `description:` from the frontmatter. Empty when it has none, which
    /// leaves the skill invocable by hand but invisible to the model.
    description: []const u8,
    /// Absolute path to the skill's directory, so the body can refer to files
    /// beside it and the model can be told where they are.
    dir: []const u8,
    /// Everything after the frontmatter.
    body: []const u8,
};

/// Every skill found, and the arena holding their strings.
pub const Set = struct {
    arena: std.heap.ArenaAllocator,
    skills: []const Skill = &.{},
    /// Every directory that was looked in, whether or not it existed. Kept so a
    /// skill that did not turn up can be explained rather than guessed at.
    paths: []const []const u8 = &.{},

    pub fn deinit(self: *Set) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Set, id: []const u8) ?Skill {
        return findIn(self.skills, id);
    }

    /// The set as a person reads it: what was found, and where it was looked for.
    /// Written here rather than in the UI because both the TUI and a future command
    /// line listing want the same answer.
    pub fn listText(self: *const Set, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;

        if (self.skills.len == 0) {
            try out.appendSlice(arena, "No skills found.\n");
        } else {
            try out.appendSlice(arena, "**Skills**\n\n");
            for (self.skills) |entry| {
                try out.print(arena, "- `/{s}` - {s}\n", .{
                    entry.id,
                    if (entry.description.len > 0) entry.description else "no description",
                });
                try out.print(arena, "  `{s}`\n", .{entry.dir});
            }
        }

        try out.appendSlice(arena, "\n**Looked in**\n\n");
        for (self.paths) |path| try out.print(arena, "- `{s}`\n", .{path});

        return out.toOwnedSlice(arena);
    }

    /// Whether any skill was found at all. What decides if the prompt gets a
    /// `<skills>` block and if `/` has anything extra to offer.
    pub fn any(self: *const Set) bool {
        return self.skills.len > 0;
    }
};

/// The skill a `SKILL.md` path belongs to, or null for any other file. Borrows
/// from `path`, so the caller does not have to hold a set to label one.
pub fn idFromPath(path: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(path), file_name)) return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    const id = std.fs.path.basename(dir);
    return if (id.len > 0) id else null;
}

/// The skill with this id, from a plain slice. What the parts holding skills
/// without the set they came from - the loop, the slash picker - look through.
pub fn findIn(available: []const Skill, id: []const u8) ?Skill {
    for (available) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// Search paths for `root`, in precedence order: the project first, then
/// whatever the config named, then the person's own. Caller owns the result and
/// each path in it.
pub fn searchPaths(
    allocator: std.mem.Allocator,
    root: []const u8,
    configured: []const []const u8,
    home: ?[]const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freePaths(allocator, out.items);
    errdefer out.deinit(allocator);

    for (project_dirs) |dir| {
        try out.append(allocator, try std.fs.path.join(allocator, &.{ root, dir }));
    }
    for (configured) |dir| {
        try out.append(allocator, try allocator.dupe(u8, dir));
    }
    if (home) |base| {
        for (home_dirs) |dir| {
            try out.append(allocator, try std.fs.path.join(allocator, &.{ base, dir }));
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Every skill visible from `root`, in one call: the project's own, then the
/// configured directories, then the person's.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    configured: []const []const u8,
    home: ?[]const u8,
) !Set {
    const paths = try searchPaths(allocator, root, configured, home);
    defer freePaths(allocator, paths);
    return discover(allocator, io, paths);
}

pub fn freePaths(allocator: std.mem.Allocator, paths: []const []const u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

/// Load every skill under `paths`. A path that does not exist is not an error:
/// most projects have none of these directories, and a missing one is the
/// normal case rather than a broken setup.
///
/// The first path to offer an id wins, so a project can shadow a personal skill
/// with its own. The result is sorted by id, which keeps the block written into
/// the system prompt stable between runs.
pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
) !Set {
    var set: Set = .{ .arena = .init(allocator) };
    errdefer set.deinit();
    const arena = set.arena.allocator();

    var found: std.ArrayList(Skill) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    const kept = try arena.alloc([]const u8, paths.len);
    for (paths, kept) |path, *out| out.* = try arena.dupe(u8, path);
    set.paths = kept;

    for (paths) |path| {
        if (found.items.len >= max_skills) break;
        try collect(arena, io, path, &found, &seen);
    }

    const skills = try found.toOwnedSlice(arena);
    std.mem.sort(Skill, skills, {}, byId);
    set.skills = skills;
    return set;
}

fn byId(_: void, a: Skill, b: Skill) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

/// Every skill directly under `path`. Not recursive: a skill's own folder is
/// its to organise, and descending into it would find its templates.
fn collect(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    found: *std.ArrayList(Skill),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (found.items.len >= max_skills) return;
        if (entry.kind != .directory) continue;
        if (!usableId(entry.name)) continue;
        if (seen.contains(entry.name)) continue;

        const skill_dir = try std.fs.path.join(arena, &.{ path, entry.name });
        const skill = read(arena, io, skill_dir) catch continue orelse continue;

        try seen.put(arena, skill.id, {});
        try found.append(arena, skill);
    }
}

/// One skill, from the directory holding it. Null when there is no `SKILL.md`,
/// which is how an unrelated folder in the search path is passed over.
fn read(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !?Skill {
    const path = try std.fs.path.join(arena, &.{ dir, file_name });
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, max_file_bytes) catch
        return null;

    const id = std.fs.path.basename(dir);
    const parsed = parse(source);

    return .{
        .id = id,
        .name = if (parsed.name.len > 0) parsed.name else id,
        .description = parsed.description,
        .dir = dir,
        .body = parsed.body,
    };
}

/// A directory name a person can type and a model can quote. Rules out the
/// dotfiles a search path picks up, and anything that would need escaping.
fn usableId(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// What the frontmatter said, plus what follows it. Every field borrows from
/// the source.
pub const Front = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    body: []const u8 = "",
};

/// Split a `SKILL.md` into its frontmatter and its instructions.
///
/// Deliberately not a YAML parser. The frontmatter of a skill is a handful of
/// single-line scalars, and treating it as more than that would mean carrying a
/// parser for the sake of syntax nothing writes. A file with no frontmatter at
/// all is all body, which is the sensible reading of a plain Markdown file.
pub fn parse(source: []const u8) Front {
    const text = std.mem.trimStart(u8, source, "\xef\xbb\xbf");
    if (!std.mem.startsWith(u8, text, "---")) return .{ .body = std.mem.trim(u8, text, " \t\r\n") };

    const after_open = std.mem.indexOfScalar(u8, text, '\n') orelse return .{};
    const rest = text[after_open + 1 ..];

    const close = findClose(rest) orelse return .{ .body = std.mem.trim(u8, text, " \t\r\n") };

    var front: Front = .{ .body = std.mem.trim(u8, rest[close.end..], " \t\r\n") };

    var lines = std.mem.splitScalar(u8, rest[0..close.start], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = unquote(std.mem.trim(u8, line[colon + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "name")) front.name = value;
        if (std.mem.eql(u8, key, "description")) {
            front.description = value[0..@min(value.len, max_description_bytes)];
        }
    }

    return front;
}

/// Where the closing `---` starts, and where the text after it begins.
fn findClose(rest: []const u8) ?struct { start: usize, end: usize } {
    var offset: usize = 0;
    while (offset < rest.len) {
        const line_end = std.mem.indexOfScalarPos(u8, rest, offset, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[offset..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            return .{ .start = offset, .end = @min(line_end + 1, rest.len) };
        }
        offset = line_end + 1;
    }
    return null;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    const first = value[0];
    if ((first == '"' or first == '\'') and value[value.len - 1] == first) {
        return value[1 .. value.len - 1];
    }
    return value;
}

const testing = std.testing;

test "frontmatter gives up its name and description, and the body starts after it" {
    const front = parse(
        \\---
        \\name: Release
        \\description: how a release is cut here
        \\---
        \\Run the tests, then tag.
        \\
    );

    try testing.expectEqualStrings("Release", front.name);
    try testing.expectEqualStrings("how a release is cut here", front.description);
    try testing.expectEqualStrings("Run the tests, then tag.", front.body);
}

test "a file without frontmatter is all instructions" {
    const front = parse("Just do the thing.\n");
    try testing.expectEqualStrings("", front.name);
    try testing.expectEqualStrings("", front.description);
    try testing.expectEqualStrings("Just do the thing.", front.body);

    const unclosed = parse("---\nname: nope\nstill going\n");
    try testing.expectEqualStrings("", unclosed.name);
    try testing.expect(unclosed.body.len > 0);
}

test "quoting, spacing and colons in the value survive" {
    const front = parse(
        \\---
        \\name:   "Commit style"
        \\description: 'use: a prefix, then a summary'
        \\unknown: ignored
        \\---
        \\body
    );

    try testing.expectEqualStrings("Commit style", front.name);
    try testing.expectEqualStrings("use: a prefix, then a summary", front.description);
}

test "a description cannot crowd out the rest of the prompt" {
    var buffer: [max_description_bytes * 2]u8 = undefined;
    const long = buffer[0..];
    @memset(long, 'x');

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "---\ndescription: ");
    try source.appendSlice(testing.allocator, long);
    try source.appendSlice(testing.allocator, "\n---\nbody");

    const front = parse(source.items);
    try testing.expectEqual(max_description_bytes, front.description.len);
}

test "an id has to be typeable" {
    try testing.expect(usableId("release"));
    try testing.expect(usableId("commit-style"));
    try testing.expect(usableId("v1.2_notes"));
    try testing.expect(!usableId(""));
    try testing.expect(!usableId(".git"));
    try testing.expect(!usableId("has space"));
    try testing.expect(!usableId("has/slash"));
}

/// Write `SKILL.md` for `id` under `dir`, for the tests below.
fn writeSkill(tmp: *std.testing.TmpDir, dir: []const u8, id: []const u8, source: []const u8) !void {
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(testing.allocator);
    try path.print(testing.allocator, "{s}/{s}", .{ dir, id });
    try tmp.dir.createDirPath(testing.io, path.items);
    try path.print(testing.allocator, "/{s}", .{file_name});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = path.items, .data = source });
}

test "skills are found under every search path, project first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkill(&tmp, "project/.agents/skills", "release", "---\ndescription: project one\n---\nproject body");
    try writeSkill(&tmp, "project/.claude/skills", "release", "---\ndescription: shadowed\n---\nshadowed body");
    try writeSkill(&tmp, "project/.claude/skills", "commit", "---\nname: Commit\ndescription: from claude\n---\nbody");
    try writeSkill(&tmp, "home/.agents/skills", "notes", "no frontmatter here");
    try tmp.dir.createDirPath(testing.io, "project/.agents/skills/.hidden");

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];

    const root = try std.fs.path.join(testing.allocator, &.{ base, "project" });
    defer testing.allocator.free(root);
    const home = try std.fs.path.join(testing.allocator, &.{ base, "home" });
    defer testing.allocator.free(home);

    const paths = try searchPaths(testing.allocator, root, &.{}, home);
    defer freePaths(testing.allocator, paths);

    var set = try discover(testing.allocator, testing.io, paths);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 3), set.skills.len);

    const release = set.find("release").?;
    try testing.expectEqualStrings("project one", release.description);
    try testing.expectEqualStrings("project body", release.body);
    try testing.expectEqualStrings("release", release.name);

    const commit = set.find("commit").?;
    try testing.expectEqualStrings("Commit", commit.name);
    try testing.expect(std.mem.endsWith(u8, commit.dir, ".claude/skills/commit"));

    const notes = set.find("notes").?;
    try testing.expectEqualStrings("", notes.description);
    try testing.expectEqualStrings("no frontmatter here", notes.body);

    try testing.expectEqualStrings("commit", set.skills[0].id);
    try testing.expectEqualStrings("notes", set.skills[1].id);
    try testing.expectEqualStrings("release", set.skills[2].id);
}

test "a configured path is searched, after the project and before home" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSkill(&tmp, "shared", "audit", "---\ndescription: from the config\n---\nbody");

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const base = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];

    const shared = try std.fs.path.join(testing.allocator, &.{ base, "shared" });
    defer testing.allocator.free(shared);

    const paths = try searchPaths(testing.allocator, base, &.{shared}, null);
    defer freePaths(testing.allocator, paths);

    try testing.expectEqual(project_dirs.len + 1, paths.len);
    try testing.expectEqualStrings(shared, paths[project_dirs.len]);

    var set = try discover(testing.allocator, testing.io, paths);
    defer set.deinit();

    try testing.expect(set.any());
    try testing.expectEqualStrings("from the config", set.find("audit").?.description);
}

test "a directory that holds no skills is not a failure" {
    var set = try discover(testing.allocator, testing.io, &.{"/nowhere/at/all"});
    defer set.deinit();

    try testing.expect(!set.any());
    try testing.expect(set.find("anything") == null);
}

test "a folder without a SKILL.md is passed over" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, ".agents/skills/empty");
    try writeSkill(&tmp, ".agents/skills", "real", "---\ndescription: here\n---\nbody");

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];

    const paths = try searchPaths(testing.allocator, root, &.{}, null);
    defer freePaths(testing.allocator, paths);

    var set = try discover(testing.allocator, testing.io, paths);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 1), set.skills.len);
    try testing.expectEqualStrings("real", set.skills[0].id);
}

test "a SKILL.md path names the skill it belongs to" {
    try testing.expectEqualStrings("caveman", idFromPath("/home/a/.agents/skills/caveman/SKILL.md").?);
    try testing.expectEqualStrings("release", idFromPath("release/SKILL.md").?);
    try testing.expect(idFromPath("/home/a/src/main.zig") == null);
    try testing.expect(idFromPath("SKILL.md") == null);
    try testing.expect(idFromPath("") == null);
}

test "the listing names what was found and where it looked" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var set: Set = .{ .arena = .init(testing.allocator) };
    defer set.deinit();
    set.skills = &.{
        .{ .id = "release", .name = "Release", .description = "cut a release", .dir = "/p/release", .body = "b" },
        .{ .id = "quiet", .name = "quiet", .description = "", .dir = "/p/quiet", .body = "b" },
    };
    set.paths = &.{ "/p/.agents/skills", "/home/a/.claude/skills" };

    const text = try set.listText(arena);
    try testing.expect(std.mem.indexOf(u8, text, "/release") != null);
    try testing.expect(std.mem.indexOf(u8, text, "cut a release") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no description") != null);
    try testing.expect(std.mem.indexOf(u8, text, "/home/a/.claude/skills") != null);

    var empty: Set = .{ .arena = .init(testing.allocator) };
    defer empty.deinit();
    empty.paths = &.{"/nowhere"};
    const none = try empty.listText(arena);
    try testing.expect(std.mem.indexOf(u8, none, "No skills found") != null);
    try testing.expect(std.mem.indexOf(u8, none, "/nowhere") != null);
}
