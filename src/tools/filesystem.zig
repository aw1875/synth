//! File tools: read, write, edit, list, glob, grep.

const std = @import("std");
const testing = std.testing;

const files = @import("../core/files.zig");
const glob = @import("../core/glob.zig");
const regex = @import("../core/regex.zig");
const tool = @import("tool.zig");
const Context = tool.Context;
const Input = tool.Input;
const Output = tool.Output;

/// Largest file a tool will pull into memory.
const max_file_bytes: std.Io.Limit = .limited(1024 * 1024);
/// Cap on `list`, `glob` and `grep` results, so a big tree cannot flood the
/// context.
const max_results: usize = 200;
/// Most context lines either side of a grep match. A larger window is a
/// request to read the file, which `read` does better.
const max_context: usize = 20;
/// Lines `read` returns when the model does not say. A 5000-line file answered
/// whole is most of a context window spent on one call.
const default_read_lines: usize = 2000;
/// Longest line handed to the matcher, and the longest reported back. A
/// minified bundle is one line of half a megabyte, which is neither worth
/// searching nor worth printing.
const max_line_bytes: usize = 4096;
/// Bytes examined when deciding whether a file is binary.
const binary_sniff_bytes: usize = 8192;

pub const all: []const tool.Tool = &.{
    .{
        .name = "read",
        .description = "Read a file from the project. Returns its contents with line numbers. Use offset and limit to page through a large file.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the project root"},"offset":{"type":"integer","description":"First line to return, 1-based; defaults to 1"},"limit":{"type":"integer","description":"How many lines to return; defaults to 2000"}},"required":["path"]}
        ,
        .handler = read,
        .read_only = true,
    },
    .{
        .name = "list",
        .description = "List files and directories at a path in the project.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Directory relative to the project root; defaults to the root"}}}
        ,
        .handler = list,
        .read_only = true,
    },
    .{
        .name = "glob",
        .description = "Find files by path pattern. Supports *, **, ?, [abc] and {a,b}. Ignored files are never returned.",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"e.g. src/**/*.zig or *.{json,zon}"},"path":{"type":"string","description":"Directory to search under; defaults to the project root"}},"required":["pattern"]}
        ,
        .handler = globTool,
        .read_only = true,
    },
    .{
        .name = "grep",
        .description = "Search file contents with a regular expression. Returns matching file:line pairs. Ignored files are never searched.",
        .schema =
        \\{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression: . [] () | * + ? {n,m} ^ $ \\b \\d \\w \\s"},"path":{"type":"string","description":"File or directory to search; defaults to the project root"},"glob":{"type":"string","description":"Only search paths matching this glob, e.g. **/*.zig"},"ignore_case":{"type":"boolean"},"literal":{"type":"boolean","description":"Match the pattern as plain text rather than a regular expression"},"context":{"type":"integer","description":"Lines of context on both sides of each match"},"before":{"type":"integer","description":"Lines of context before each match; overrides context"},"after":{"type":"integer","description":"Lines of context after each match; overrides context"}},"required":["pattern"]}
        ,
        .handler = grep,
        .read_only = true,
    },
    .{
        .name = "write",
        .description = "Create or overwrite a file with the given contents.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        ,
        .handler = write,
    },
    .{
        .name = "edit",
        .description = "Replace an exact string in a file. The file must have been read first.",
        .schema =
        \\{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string","description":"Exact text to replace; must appear exactly once"},"new":{"type":"string"},"edits":{"type":"array","description":"Several replacements in one file, applied in order. Use instead of old/new.","items":{"type":"object","properties":{"old":{"type":"string"},"new":{"type":"string"}},"required":["old","new"]}}},"required":["path"]}
        ,
        .handler = edit,
    },
};

fn read(ctx: Context, input: Input) !Output {
    const path = input.string("path") orelse
        return Output.err(try ctx.allocator.dupe(u8, "read: 'path' is required"));

    const offset: usize = @max(1, input.integer("offset") orelse 1);
    const limit: usize = blk: {
        const asked = input.integer("limit") orelse break :blk default_read_lines;
        if (asked <= 0) break :blk default_read_lines;
        break :blk @intCast(asked);
    };

    const resolved = resolve(ctx, path) catch |err| return pathError(ctx, path, err);
    defer ctx.allocator.free(resolved);

    const source = std.Io.Dir.cwd().readFileAlloc(ctx.io, resolved, ctx.allocator, max_file_bytes) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "read {s}: {s}", .{ path, @errorName(err) }));
    };
    defer ctx.allocator.free(source);

    if (std.Io.Dir.cwd().statFile(ctx.io, resolved, .{})) |stat| {
        try ctx.reads.record(resolved, stat.mtime.nanoseconds);
    } else |_| {}

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 1;
    var shown: usize = 0;
    var total: usize = 0;

    while (lines.next()) |line| : (number += 1) {
        total += 1;
        if (number < offset) continue;
        if (shown == limit) continue;
        try out.writer.print("{d:>5}  {s}\n", .{ number, clip(line) });
        shown += 1;
    }

    if (shown == 0) {
        return Output.ok(try std.fmt.allocPrint(
            ctx.allocator,
            "{s} has {d} line(s); offset {d} is past the end",
            .{ path, total, offset },
        ));
    }

    const last = offset + shown - 1;
    if (last < total) {
        try out.writer.print(
            "\n... {d} more line(s). Read on with offset {d}.\n",
            .{ total - last, last + 1 },
        );
    }

    return Output.ok(try out.toOwnedSlice());
}

/// A line as it should appear in output: long enough to be useful, short
/// enough that one generated file cannot fill the context window.
const Replacement = struct { old: []const u8, new: []const u8 };

/// The replacements a call asked for: an `edits` array, or the single
/// `old`/`new` pair. Both shapes exist because one edit is the common case and
/// spelling it as a one-element array reads badly.
fn collectEdits(arena: std.mem.Allocator, input: Input) ![]const Replacement {
    if (input.get("edits")) |value| {
        const items = switch (value) {
            .array => |array| array.items,
            else => return error.EditsMustBeAnArray,
        };

        const out = try arena.alloc(Replacement, items.len);
        for (items, out) |item, *slot| {
            const fields = switch (item) {
                .object => |object| object,
                else => return error.EditNeedsOldAndNew,
            };
            const from = fields.get("old") orelse return error.EditNeedsOldAndNew;
            const to = fields.get("new") orelse return error.EditNeedsOldAndNew;
            if (from != .string or to != .string) return error.EditNeedsOldAndNew;
            slot.* = .{ .old = from.string, .new = to.string };
        }
        return out;
    }

    const from = input.string("old") orelse return &.{};
    const to = input.string("new") orelse return &.{};
    const out = try arena.alloc(Replacement, 1);
    out[0] = .{ .old = from, .new = to };
    return out;
}

/// A context window, clamped to what is useful and never negative.
fn window(asked: i64) usize {
    if (asked <= 0) return 0;
    return @min(@as(usize, @intCast(asked)), max_context);
}

fn clip(line: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    if (trimmed.len <= max_line_bytes) return trimmed;
    return trimmed[0..max_line_bytes];
}

fn list(ctx: Context, input: Input) !Output {
    const path = input.string("path") orelse ".";

    const resolved = resolve(ctx, path) catch |err| return pathError(ctx, path, err);
    defer ctx.allocator.free(resolved);

    var dir = std.Io.Dir.cwd().openDir(ctx.io, resolved, .{ .iterate = true }) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "list {s}: {s}", .{ path, @errorName(err) }));
    };
    defer dir.close(ctx.io);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var it = dir.iterate();
    var count: usize = 0;
    while (it.next(ctx.io) catch null) |entry| {
        if (count >= max_results) {
            try out.writer.writeAll("... truncated\n");
            break;
        }
        if (entry.kind == .directory) {
            try out.writer.print("{s}/\n", .{entry.name});
        } else {
            try out.writer.print("{s}\n", .{entry.name});
        }
        count += 1;
    }

    return Output.ok(try out.toOwnedSlice());
}

/// Every project file under `scope`, with ignored files already gone. The
/// listing is git's where there is a repository, which is why this is asked for
/// the whole project and filtered afterwards: `git ls-files` only answers at
/// the work-tree root.
fn candidates(ctx: Context, scope: []const u8) ![]const []const u8 {
    const everything = try files.list(ctx.allocator, ctx.io, ctx.project_root, .{});
    if (scope.len == 0) return everything;
    defer files.free(ctx.allocator, everything);

    var kept: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (kept.items) |path| ctx.allocator.free(path);
        kept.deinit(ctx.allocator);
    }

    for (everything) |path| {
        if (!under(path, scope)) continue;
        try kept.append(ctx.allocator, try ctx.allocator.dupe(u8, path));
    }
    return kept.toOwnedSlice(ctx.allocator);
}

/// Whether `path` is `scope` itself or something inside it. Compared segment by
/// segment so `src` does not claim `srcfoo/x.zig`.
fn under(path: []const u8, scope: []const u8) bool {
    if (!std.mem.startsWith(u8, path, scope)) return false;
    if (path.len == scope.len) return true;
    return path[scope.len] == '/';
}

/// `path` as the project sees it: relative to the root, with "." meaning all of
/// it. Errors the same way every other tool does when it escapes the project.
fn scopeOf(ctx: Context, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return "";

    const resolved = try resolve(ctx, path);
    defer ctx.allocator.free(resolved);

    if (resolved.len <= ctx.project_root.len) return "";
    return ctx.allocator.dupe(u8, resolved[ctx.project_root.len + 1 ..]);
}

fn globTool(ctx: Context, input: Input) !Output {
    const pattern = input.string("pattern") orelse
        return Output.err(try ctx.allocator.dupe(u8, "glob: 'pattern' is required"));
    const path = input.string("path") orelse ".";

    const scope = scopeOf(ctx, path) catch |err| return pathError(ctx, path, err);
    defer if (scope.len > 0) ctx.allocator.free(scope);

    var set: glob.Set = glob.Set.init(ctx.allocator, pattern) catch |err| {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "glob: '{s}' expands to too many alternatives ({s})",
            .{ pattern, @errorName(err) },
        ));
    };
    defer set.deinit();

    const paths = candidates(ctx, scope) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "glob: {s}", .{@errorName(err)}));
    };
    defer files.free(ctx.allocator, paths);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var count: usize = 0;
    for (paths) |candidate| {
        if (ctx.shouldStop()) return stopped(ctx);
        if (!set.matches(candidate)) continue;
        if (count == max_results) {
            try out.writer.print("... more than {d} matches; narrow the pattern\n", .{max_results});
            break;
        }
        try out.writer.print("{s}\n", .{candidate});
        count += 1;
    }

    if (count == 0) {
        return Output.ok(try std.fmt.allocPrint(
            ctx.allocator,
            "no files match '{s}'",
            .{pattern},
        ));
    }
    return Output.ok(try out.toOwnedSlice());
}

/// What a line is tested against. A literal search is its own case rather than
/// an escaped pattern: escaping a whole pasted function would compile to
/// thousands of instructions to do what a substring search does in one pass.
const Matcher = union(enum) {
    pattern: regex.Regex,
    literal: struct { needle: []const u8, ignore_case: bool },

    fn init(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        literal: bool,
        ignore_case: bool,
    ) !Matcher {
        if (literal) return .{ .literal = .{ .needle = pattern, .ignore_case = ignore_case } };
        return .{ .pattern = try regex.compile(allocator, pattern, .{ .ignore_case = ignore_case }) };
    }

    fn deinit(self: *Matcher) void {
        switch (self.*) {
            .pattern => |*compiled| compiled.deinit(),
            .literal => {},
        }
    }

    fn matches(self: *Matcher, line: []const u8) bool {
        return switch (self.*) {
            .pattern => |*compiled| compiled.matches(line),
            .literal => |plain| if (plain.ignore_case)
                containsIgnoreCase(line, plain.needle)
            else
                std.mem.indexOf(u8, line, plain.needle) != null,
        };
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var at: usize = 0;
    while (at + needle.len <= haystack.len) : (at += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[at..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Whether a file is binary, decided the way every search tool decides it: a
/// NUL byte near the start.
/// What a search that was given up on reports. Says which of the two it was,
/// because a timeout and a cancelled turn call for different things from the
/// reader.
fn stopped(ctx: tool.Context) !Output {
    const why = if (ctx.givenUp()) "cancelled" else "timed out";
    return Output.err(try std.fmt.allocPrint(ctx.allocator, "search {s}", .{why}));
}

fn isBinary(source: []const u8) bool {
    const head = source[0..@min(source.len, binary_sniff_bytes)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

fn grep(ctx: Context, input: Input) !Output {
    const pattern = input.string("pattern") orelse
        return Output.err(try ctx.allocator.dupe(u8, "grep: 'pattern' is required"));
    const path = input.string("path") orelse ".";
    const ignore_case = input.boolean("ignore_case") orelse false;
    const literal = input.boolean("literal") orelse false;

    const shared = @max(input.integer("context") orelse 0, 0);
    const before = window(input.integer("before") orelse shared);
    const after = window(input.integer("after") orelse shared);

    const scope = scopeOf(ctx, path) catch |err| return pathError(ctx, path, err);
    defer if (scope.len > 0) ctx.allocator.free(scope);

    var matcher = Matcher.init(ctx.allocator, pattern, literal, ignore_case) catch |err| {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "grep: '{s}' is not a valid regular expression ({s}). Pass literal:true to search for it as plain text.",
            .{ pattern, @errorName(err) },
        ));
    };
    defer matcher.deinit();

    var filter: ?glob.Set = if (input.string("glob")) |expression|
        glob.Set.init(ctx.allocator, expression) catch |err| {
            return Output.err(try std.fmt.allocPrint(
                ctx.allocator,
                "grep: glob '{s}' is not usable ({s})",
                .{ expression, @errorName(err) },
            ));
        }
    else
        null;
    defer if (filter) |*set| set.deinit();

    const paths = candidates(ctx, scope) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "grep: {s}", .{@errorName(err)}));
    };
    defer files.free(ctx.allocator, paths);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer out.deinit();

    var count: usize = 0;
    var searched: usize = 0;

    for (paths) |candidate| {
        if (count >= max_results) break;
        if (ctx.shouldStop()) return stopped(ctx);
        if (filter) |*set| {
            if (!set.matches(candidate)) continue;
        }

        const full = try std.fs.path.join(ctx.allocator, &.{ ctx.project_root, candidate });
        defer ctx.allocator.free(full);

        const source = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, ctx.allocator, max_file_bytes) catch continue;
        defer ctx.allocator.free(source);
        if (isBinary(source)) continue;
        searched += 1;

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(ctx.allocator);

        var split = std.mem.splitScalar(u8, source, '\n');
        while (split.next()) |line| try lines.append(ctx.allocator, line);

        var printed: ?usize = null;
        for (lines.items, 0..) |line, i| {
            if (!matcher.matches(clip(line))) continue;

            const from = i -| before;
            const to = @min(i + after, lines.items.len -| 1);

            if (printed) |last| {
                if (from > last + 1) try out.writer.writeAll("--\n");
            }

            const start = if (printed) |last| @max(from, last + 1) else from;
            for (lines.items[start .. to + 1], start..) |shown, at| {
                try out.writer.print("{s}:{d}{s} {s}\n", .{
                    candidate,
                    at + 1,
                    if (at == i) ":" else "-",
                    std.mem.trim(u8, clip(shown), " \t"),
                });
            }
            printed = to;

            count += 1;
            if (count >= max_results) break;
        }
    }

    if (count == 0) {
        return Output.ok(try std.fmt.allocPrint(
            ctx.allocator,
            "no matches for '{s}' in {d} file(s)",
            .{ pattern, searched },
        ));
    }
    if (count >= max_results) {
        try out.writer.print("... stopped at {d} matches; narrow the search\n", .{max_results});
    }
    return Output.ok(try out.toOwnedSlice());
}

fn write(ctx: Context, input: Input) !Output {
    const path = input.string("path") orelse
        return Output.err(try ctx.allocator.dupe(u8, "write: 'path' is required"));
    const content = input.string("content") orelse
        return Output.err(try ctx.allocator.dupe(u8, "write: 'content' is required"));

    const resolved = resolve(ctx, path) catch |err| return pathError(ctx, path, err);
    defer ctx.allocator.free(resolved);

    if (std.fs.path.dirname(resolved)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }

    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = resolved, .data = content }) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "write {s}: {s}", .{ path, @errorName(err) }));
    };

    return Output.ok(try std.fmt.allocPrint(ctx.allocator, "wrote {d} bytes to {s}", .{ content.len, path }));
}

fn edit(ctx: Context, input: Input) !Output {
    const path = input.string("path") orelse
        return Output.err(try ctx.allocator.dupe(u8, "edit: 'path' is required"));
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();

    const edits = collectEdits(arena_state.allocator(), input) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "edit: {s}", .{@errorName(err)}));
    };
    if (edits.len == 0) {
        return Output.err(try ctx.allocator.dupe(
            u8,
            "edit: give 'old' and 'new', or an 'edits' array of them",
        ));
    }

    const resolved = resolve(ctx, path) catch |err| return pathError(ctx, path, err);
    defer ctx.allocator.free(resolved);

    const stat = std.Io.Dir.cwd().statFile(ctx.io, resolved, .{}) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "edit {s}: {s}", .{ path, @errorName(err) }));
    };
    const last_read = ctx.reads.lastRead(resolved) orelse {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "edit {s}: read the file before editing it",
            .{path},
        ));
    };
    if (stat.mtime.nanoseconds > last_read) {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "edit {s}: file changed since it was read; read it again",
            .{path},
        ));
    }

    const source = std.Io.Dir.cwd().readFileAlloc(ctx.io, resolved, ctx.allocator, max_file_bytes) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "edit {s}: {s}", .{ path, @errorName(err) }));
    };
    defer ctx.allocator.free(source);

    // Applied to a copy, and only written once every edit has landed: half a
    // change is worse than none, and the model cannot see which half.
    var current: []const u8 = source;
    var first_line: usize = 0;

    for (edits, 0..) |change, index| {
        const at = std.mem.indexOf(u8, current, change.old) orelse {
            return Output.err(try std.fmt.allocPrint(
                ctx.allocator,
                "edit {s}: edit {d} of {d}: 'old' not found",
                .{ path, index + 1, edits.len },
            ));
        };
        if (std.mem.indexOfPos(u8, current, at + change.old.len, change.old) != null) {
            return Output.err(try std.fmt.allocPrint(
                ctx.allocator,
                "edit {s}: edit {d} of {d}: 'old' appears more than once; include more context",
                .{ path, index + 1, edits.len },
            ));
        }

        if (index == 0) first_line = std.mem.count(u8, current[0..at], "\n") + 1;

        var next: std.Io.Writer.Allocating = .init(arena_state.allocator());
        try next.writer.writeAll(current[0..at]);
        try next.writer.writeAll(change.new);
        try next.writer.writeAll(current[at + change.old.len ..]);
        current = next.written();
    }

    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = resolved, .data = current }) catch |err| {
        return Output.err(try std.fmt.allocPrint(ctx.allocator, "edit {s}: {s}", .{ path, @errorName(err) }));
    };

    if (std.Io.Dir.cwd().statFile(ctx.io, resolved, .{})) |updated| {
        try ctx.reads.record(resolved, updated.mtime.nanoseconds);
    } else |_| {}

    if (edits.len == 1) {
        return Output.ok(try std.fmt.allocPrint(
            ctx.allocator,
            "edited {s} at line {d}",
            .{ path, first_line },
        ));
    }
    return Output.ok(try std.fmt.allocPrint(
        ctx.allocator,
        "edited {s}: {d} replacements",
        .{ path, edits.len },
    ));
}

fn resolve(ctx: Context, path: []const u8) ![]u8 {
    return tool.resolvePath(ctx, path);
}

fn pathError(ctx: Context, path: []const u8, err: anyerror) !Output {
    if (err == error.PathOutsideProject) {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "{s} is outside the project root",
            .{path},
        ));
    }
    return err;
}

/// A temp directory plus the context pointing at it, so each test gets a
/// throwaway project root.
const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    reads: tool.ReadLog,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        return .{ .tmp = tmp, .root = root, .reads = .init(testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.reads.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn context(self: *Fixture) Context {
        return .{
            .allocator = testing.allocator,
            .io = testing.io,
            .project_root = self.root,
            .reads = &self.reads,
        };
    }

    /// Put a file in the fixture without going through a tool, for a test that
    /// is about reading rather than writing.
    fn writeFile(self: *Fixture, path: []const u8, content: []const u8) !void {
        const full = try std.fs.path.join(testing.allocator, &.{ self.root, path });
        defer testing.allocator.free(full);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = full, .data = content });
    }

    fn call(self: *Fixture, handler: tool.Handler, args: []const u8) !Output {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args, .{});
        defer parsed.deinit();
        return handler(self.context(), .{ .arguments = parsed.value });
    }
};

test "write then read round-trips" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"a/b.txt\",\"content\":\"hello\"}");
    defer testing.allocator.free(written.content);
    try testing.expect(!written.is_error);

    const got = try fixture.call(read, "{\"path\":\"a/b.txt\"}");
    defer testing.allocator.free(got.content);
    try testing.expect(std.mem.indexOf(u8, got.content, "hello") != null);
}

test "edit requires the file to have been read" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"x.txt\",\"content\":\"one two\"}");
    testing.allocator.free(written.content);

    const unread = try fixture.call(edit, "{\"path\":\"x.txt\",\"old\":\"one\",\"new\":\"1\"}");
    defer testing.allocator.free(unread.content);
    try testing.expect(unread.is_error);
    try testing.expect(std.mem.indexOf(u8, unread.content, "read the file") != null);

    const seen = try fixture.call(read, "{\"path\":\"x.txt\"}");
    testing.allocator.free(seen.content);

    const edited = try fixture.call(edit, "{\"path\":\"x.txt\",\"old\":\"one\",\"new\":\"1\"}");
    defer testing.allocator.free(edited.content);
    try testing.expect(!edited.is_error);

    const after = try fixture.call(read, "{\"path\":\"x.txt\"}");
    defer testing.allocator.free(after.content);
    try testing.expect(std.mem.indexOf(u8, after.content, "1 two") != null);
}

test "edit refuses ambiguous matches" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"y.txt\",\"content\":\"dup dup\"}");
    testing.allocator.free(written.content);
    const seen = try fixture.call(read, "{\"path\":\"y.txt\"}");
    testing.allocator.free(seen.content);

    const result = try fixture.call(edit, "{\"path\":\"y.txt\",\"old\":\"dup\",\"new\":\"x\"}");
    defer testing.allocator.free(result.content);
    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "more than once") != null);
}

test "tools refuse paths outside the project" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const result = try fixture.call(read, "{\"path\":\"../../../etc/passwd\"}");
    defer testing.allocator.free(result.content);
    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.content, "outside the project") != null);
}

test "grep finds matches and reports misses" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"src/m.zig\",\"content\":\"const needle = 1;\"}");
    testing.allocator.free(written.content);

    const hit = try fixture.call(grep, "{\"pattern\":\"needle\"}");
    defer testing.allocator.free(hit.content);
    try testing.expect(std.mem.indexOf(u8, hit.content, "m.zig") != null);

    const miss = try fixture.call(grep, "{\"pattern\":\"haystack\"}");
    defer testing.allocator.free(miss.content);
    try testing.expect(std.mem.indexOf(u8, miss.content, "no matches") != null);
}

test "a scope is compared segment by segment" {
    try testing.expect(under("src/main.zig", "src"));
    try testing.expect(under("src", "src"));
    try testing.expect(!under("srcfoo/main.zig", "src"));
    try testing.expect(!under("other/src/main.zig", "src"));
}

test "read pages through a file with offset and limit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    for (1..51) |n| try body.writer.print("line {d}\n", .{n});

    const args = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"path\":\"big.txt\",\"content\":{f}}}",
        .{std.json.fmt(body.written(), .{})},
    );
    defer testing.allocator.free(args);

    const written = try fixture.call(write, args);
    testing.allocator.free(written.content);

    const page = try fixture.call(read, "{\"path\":\"big.txt\",\"offset\":10,\"limit\":3}");
    defer testing.allocator.free(page.content);

    try testing.expect(std.mem.indexOf(u8, page.content, "line 10") != null);
    try testing.expect(std.mem.indexOf(u8, page.content, "line 12") != null);
    try testing.expect(std.mem.indexOf(u8, page.content, "line 13") == null);
    try testing.expect(std.mem.indexOf(u8, page.content, "line 9") == null);
    try testing.expect(std.mem.indexOf(u8, page.content, "Read on with offset 13") != null);

    const past = try fixture.call(read, "{\"path\":\"big.txt\",\"offset\":9000}");
    defer testing.allocator.free(past.content);
    try testing.expect(std.mem.indexOf(u8, past.content, "past the end") != null);
}

test "glob finds files by pattern and stays inside the path given" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    for ([_][]const u8{
        "{\"path\":\"src/main.zig\",\"content\":\"a\"}",
        "{\"path\":\"src/tui/app.zig\",\"content\":\"b\"}",
        "{\"path\":\"src/notes.md\",\"content\":\"c\"}",
        "{\"path\":\"docs/guide.zig\",\"content\":\"d\"}",
    }) |args| {
        const written = try fixture.call(write, args);
        testing.allocator.free(written.content);
    }

    const zig = try fixture.call(globTool, "{\"pattern\":\"**/*.zig\"}");
    defer testing.allocator.free(zig.content);
    try testing.expect(std.mem.indexOf(u8, zig.content, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, zig.content, "src/tui/app.zig") != null);
    try testing.expect(std.mem.indexOf(u8, zig.content, "docs/guide.zig") != null);
    try testing.expect(std.mem.indexOf(u8, zig.content, "notes.md") == null);

    const scoped = try fixture.call(globTool, "{\"pattern\":\"**/*.zig\",\"path\":\"src\"}");
    defer testing.allocator.free(scoped.content);
    try testing.expect(std.mem.indexOf(u8, scoped.content, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, scoped.content, "docs/guide.zig") == null);

    const braces = try fixture.call(globTool, "{\"pattern\":\"src/*.{zig,md}\"}");
    defer testing.allocator.free(braces.content);
    try testing.expect(std.mem.indexOf(u8, braces.content, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, braces.content, "src/notes.md") != null);

    const nothing = try fixture.call(globTool, "{\"pattern\":\"**/*.rs\"}");
    defer testing.allocator.free(nothing.content);
    try testing.expect(std.mem.indexOf(u8, nothing.content, "no files match") != null);
}

test "grep matches a regular expression, and says so when the pattern is bad" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(
        write,
        "{\"path\":\"src/m.zig\",\"content\":\"const Needle = 1;\\nconcatenate();\\nfn needle() void {}\\n\"}",
    );
    testing.allocator.free(written.content);

    const word = try fixture.call(grep, "{\"pattern\":\"\\\\bneedle\\\\b\"}");
    defer testing.allocator.free(word.content);
    try testing.expect(std.mem.indexOf(u8, word.content, "m.zig:3") != null);
    try testing.expect(std.mem.indexOf(u8, word.content, "m.zig:2") == null);

    const folded = try fixture.call(grep, "{\"pattern\":\"^const needle\",\"ignore_case\":true}");
    defer testing.allocator.free(folded.content);
    try testing.expect(std.mem.indexOf(u8, folded.content, "m.zig:1") != null);

    const bad = try fixture.call(grep, "{\"pattern\":\"foo(bar\"}");
    defer testing.allocator.free(bad.content);
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, bad.content, "literal:true") != null);

    const plain = try fixture.call(grep, "{\"pattern\":\"needle()\",\"literal\":true}");
    defer testing.allocator.free(plain.content);
    try testing.expect(std.mem.indexOf(u8, plain.content, "m.zig:3") != null);
}

test "grep can be narrowed by glob, and skips binaries" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    for ([_][]const u8{
        "{\"path\":\"src/a.zig\",\"content\":\"target here\"}",
        "{\"path\":\"src/b.md\",\"content\":\"target here too\"}",
        "{\"path\":\"src/c.bin\",\"content\":\"target\\u0000here\"}",
    }) |args| {
        const written = try fixture.call(write, args);
        testing.allocator.free(written.content);
    }

    const zig_only = try fixture.call(grep, "{\"pattern\":\"target\",\"glob\":\"**/*.zig\"}");
    defer testing.allocator.free(zig_only.content);
    try testing.expect(std.mem.indexOf(u8, zig_only.content, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, zig_only.content, "b.md") == null);

    const everywhere = try fixture.call(grep, "{\"pattern\":\"target\"}");
    defer testing.allocator.free(everywhere.content);
    try testing.expect(std.mem.indexOf(u8, everywhere.content, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, everywhere.content, "b.md") != null);
    try testing.expect(std.mem.indexOf(u8, everywhere.content, "c.bin") == null);
}

test "grep never searches what the project ignores" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    // No `.git` here on purpose. Creating one would make this a work tree root
    // in git's eyes but not a valid repository, so git would walk up to the
    // enclosing one and answer about that instead. A real `.git` is excluded by
    // git itself; the fallback below excludes it as a dotfile, which is the
    // path `.hidden` exercises.
    for ([_][]const u8{
        "{\"path\":\"src/real.zig\",\"content\":\"secret\"}",
        "{\"path\":\".hidden/notes.txt\",\"content\":\"secret\"}",
        "{\"path\":\".zig-cache/o/deadbeef/thing.o\",\"content\":\"secret\"}",
        "{\"path\":\"zig-out/bin/synth\",\"content\":\"secret\"}",
        "{\"path\":\"node_modules/left-pad/index.js\",\"content\":\"secret\"}",
    }) |args| {
        const written = try fixture.call(write, args);
        testing.allocator.free(written.content);
    }

    const found = try fixture.call(grep, "{\"pattern\":\"secret\"}");
    defer testing.allocator.free(found.content);

    try testing.expect(std.mem.indexOf(u8, found.content, "src/real.zig") != null);
    for ([_][]const u8{ ".hidden", ".zig-cache", "zig-out", "node_modules" }) |ignored| {
        try testing.expect(std.mem.indexOf(u8, found.content, ignored) == null);
    }
}

test "grep reports context on both sides, marking the match" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.txt", "one\ntwo\nthree\nfour\nfive\n");

    const out = try fixture.call(grep, "{\"pattern\":\"three\",\"context\":1}");
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "a.txt:2- two") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "a.txt:3: three") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "a.txt:4- four") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "one") == null);
}

test "before and after override the shared context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.txt", "one\ntwo\nthree\nfour\nfive\n");

    const out = try fixture.call(grep, "{\"pattern\":\"three\",\"context\":2,\"after\":0}");
    defer testing.allocator.free(out.content);

    try testing.expect(std.mem.indexOf(u8, out.content, "a.txt:1- one") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "a.txt:3: three") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "four") == null);
}

test "context is not printed twice where two matches overlap" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.txt", "hit\nmiddle\nhit\n");

    const out = try fixture.call(grep, "{\"pattern\":\"hit\",\"context\":1}");
    defer testing.allocator.free(out.content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.content, "a.txt:2- middle"));
    try testing.expect(std.mem.indexOf(u8, out.content, "--") == null);
}

test "a gap between matches is marked" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.txt", "hit\n1\n2\n3\n4\n5\nhit\n");

    const out = try fixture.call(grep, "{\"pattern\":\"hit\",\"context\":1}");
    defer testing.allocator.free(out.content);

    try testing.expect(std.mem.indexOf(u8, out.content, "--") != null);
}

test "no context asked for is the plain listing it always was" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.txt", "one\ntwo\nthree\n");

    const out = try fixture.call(grep, "{\"pattern\":\"two\"}");
    defer testing.allocator.free(out.content);

    try testing.expectEqualStrings("a.txt:2: two\n", out.content);
}

test "several edits land in one call" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"a.zig\",\"content\":\"const a = 1;\\nconst b = 2;\\nconst c = 3;\\n\"}");
    testing.allocator.free(written.content);

    const seen = try fixture.call(read, "{\"path\":\"a.zig\"}");
    testing.allocator.free(seen.content);

    const out = try fixture.call(edit,
        \\{"path":"a.zig","edits":[{"old":"a = 1","new":"a = 10"},{"old":"c = 3","new":"c = 30"}]}
    );
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "2 replacements") != null);

    const after = try fixture.call(read, "{\"path\":\"a.zig\"}");
    defer testing.allocator.free(after.content);
    try testing.expect(std.mem.indexOf(u8, after.content, "a = 10") != null);
    try testing.expect(std.mem.indexOf(u8, after.content, "b = 2") != null);
    try testing.expect(std.mem.indexOf(u8, after.content, "c = 30") != null);
}

test "one bad edit in a batch writes none of them" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"a.zig\",\"content\":\"const a = 1;\\nconst b = 2;\\n\"}");
    testing.allocator.free(written.content);

    const seen = try fixture.call(read, "{\"path\":\"a.zig\"}");
    testing.allocator.free(seen.content);

    const out = try fixture.call(edit,
        \\{"path":"a.zig","edits":[{"old":"a = 1","new":"a = 10"},{"old":"nowhere","new":"x"}]}
    );
    defer testing.allocator.free(out.content);

    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "edit 2 of 2") != null);

    const after = try fixture.call(read, "{\"path\":\"a.zig\"}");
    defer testing.allocator.free(after.content);
    try testing.expect(std.mem.indexOf(u8, after.content, "a = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, after.content, "a = 10") == null);
}

test "an edit may act on what an earlier one produced" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"a.zig\",\"content\":\"one\\n\"}");
    testing.allocator.free(written.content);

    const seen = try fixture.call(read, "{\"path\":\"a.zig\"}");
    testing.allocator.free(seen.content);

    const out = try fixture.call(edit,
        \\{"path":"a.zig","edits":[{"old":"one","new":"two"},{"old":"two","new":"three"}]}
    );
    defer testing.allocator.free(out.content);
    try testing.expect(!out.is_error);

    const after = try fixture.call(read, "{\"path\":\"a.zig\"}");
    defer testing.allocator.free(after.content);
    try testing.expect(std.mem.indexOf(u8, after.content, "three") != null);
}

test "the single old/new pair still works, and still reports its line" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const written = try fixture.call(write, "{\"path\":\"a.zig\",\"content\":\"one\\ntwo\\n\"}");
    testing.allocator.free(written.content);

    const seen = try fixture.call(read, "{\"path\":\"a.zig\"}");
    testing.allocator.free(seen.content);

    const out = try fixture.call(edit, "{\"path\":\"a.zig\",\"old\":\"two\",\"new\":\"2\"}");
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "at line 2") != null);
}

test "an edit with neither shape says what it wanted" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const out = try fixture.call(edit, "{\"path\":\"a.zig\"}");
    defer testing.allocator.free(out.content);

    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "'edits' array") != null);
}

/// Run a handler against a context the caller has adjusted, which
/// `Fixture.call` cannot do because it builds its own.
fn invoke(ctx: Context, handler: tool.Handler, args: []const u8) !Output {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args, .{});
    defer parsed.deinit();
    return handler(ctx, .{ .arguments = parsed.value });
}

test "a search that has been given up on stops rather than finishing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.zig", "needle\n");
    try fixture.writeFile("b.zig", "needle\n");

    var stop: std.atomic.Value(bool) = .init(true);
    var ctx = fixture.context();
    ctx.cancelled = &stop;

    const searched = try invoke(ctx, grep, "{\"pattern\":\"needle\"}");
    defer testing.allocator.free(searched.content);
    try testing.expect(searched.is_error);
    try testing.expectEqualStrings("search cancelled", searched.content);

    const globbed = try invoke(ctx, globTool, "{\"pattern\":\"**/*.zig\"}");
    defer testing.allocator.free(globbed.content);
    try testing.expect(globbed.is_error);
    try testing.expectEqualStrings("search cancelled", globbed.content);
}

test "a search that ran out of time says so rather than saying cancelled" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.writeFile("a.zig", "needle\n");

    var ctx = fixture.context();
    ctx.deadline_ms = tool.monotonicMilliseconds(ctx.io) - 1;

    const searched = try invoke(ctx, grep, "{\"pattern\":\"needle\"}");
    defer testing.allocator.free(searched.content);
    try testing.expect(searched.is_error);
    try testing.expectEqualStrings("search timed out", searched.content);
}
