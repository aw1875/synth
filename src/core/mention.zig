//! `@path` mentions in a prompt.

const std = @import("std");

/// Largest file pulled in by a single mention.
const max_attachment_bytes: std.Io.Limit = .limited(256 * 1024);
/// Cap on files attached to one message, so `@a @b @c ...` cannot blow up the
/// request.
const max_attachments: usize = 16;
/// Entries listed for a mentioned directory before the rest is cut.
const max_listing_entries: usize = 200;

/// Trailing characters that are almost certainly punctuation rather than part
/// of a filename. A trailing `.` is left alone: `@flake.nix` is common and
/// `@file.` is not.
const trailing_punctuation = ",;:)]}!?\"'";

pub const Span = struct {
    /// Byte offsets of the mention within the source text, including the `@`.
    start: usize,
    end: usize,
    /// The path as typed, without the `@`.
    path: []const u8,
};

/// A resolved mention: the file's contents, ready to hand to the model.
pub const Attachment = struct {
    /// Path as written in the prompt.
    path: []const u8,
    content: []const u8,

    pub fn deinit(self: *Attachment, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

/// Find every `@path` in `text`. Spans borrow from `text`.
pub fn scan(allocator: std.mem.Allocator, text: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '@') continue;
        if (i > 0 and !isBoundary(text[i - 1])) continue;

        var end = i + 1;
        while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
        while (end > i + 1 and std.mem.indexOfScalar(u8, trailing_punctuation, text[end - 1]) != null) {
            end -= 1;
        }
        if (end == i + 1) continue;

        try spans.append(allocator, .{ .start = i, .end = end, .path = text[i + 1 .. end] });
        i = end - 1;
    }

    return spans.toOwnedSlice(allocator);
}

fn isBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '(' or c == '[' or c == '{';
}

/// Read every mentioned file or directory that exists under `root`. A mention
/// that does not
/// resolve is skipped rather than failing the turn: the model still sees the
/// text, and a typo should not block the prompt.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    text: []const u8,
) ![]Attachment {
    const spans = try scan(allocator, text);
    defer allocator.free(spans);

    var attachments: std.ArrayList(Attachment) = .empty;
    errdefer {
        for (attachments.items) |*a| a.deinit(allocator);
        attachments.deinit(allocator);
    }

    for (spans) |span| {
        if (attachments.items.len >= max_attachments) break;

        var seen = false;
        for (attachments.items) |a| {
            if (std.mem.eql(u8, a.path, span.path)) seen = true;
        }
        if (seen) continue;

        const full = resolveInRoot(allocator, root, span.path) catch continue;
        defer allocator.free(full);

        const content = readEntry(allocator, io, full) catch continue;
        errdefer allocator.free(content);

        try attachments.append(allocator, .{
            .path = try allocator.dupe(u8, span.path),
            .content = content,
        });
    }

    return attachments.toOwnedSlice(allocator);
}

/// A file's contents, or a directory's listing. Mentioning a folder is a way to
/// show the model what is in it - reading every file under it would blow the
/// context on one `@`.
fn readEntry(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        var count: usize = 0;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (count >= max_listing_entries) {
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
        if (count == 0) try out.writer.writeAll("(empty directory)\n");
        return out.toOwnedSlice();
    } else |_| {}

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, max_attachment_bytes);
}

/// Same containment rule as the tools: a mention cannot reach outside the
/// project.
fn resolveInRoot(allocator: std.mem.Allocator, root: []const u8, path: []const u8) ![]u8 {
    const joined = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ root, path });
    defer allocator.free(joined);

    const resolved = try std.fs.path.resolve(allocator, &.{joined});
    errdefer allocator.free(resolved);

    if (!std.mem.startsWith(u8, resolved, root)) return error.PathOutsideProject;
    if (resolved.len > root.len and resolved[root.len] != std.fs.path.sep) {
        return error.PathOutsideProject;
    }
    return resolved;
}

test "scan finds mentions at word boundaries" {
    const allocator = std.testing.allocator;

    const spans = try scan(allocator, "look at @flake.nix and @src/main.zig, please");
    defer allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("flake.nix", spans[0].path);
    try std.testing.expectEqualStrings("src/main.zig", spans[1].path);
}

test "scan ignores email addresses and bare @" {
    const allocator = std.testing.allocator;

    const spans = try scan(allocator, "mail me@example.com or just @ nothing");
    defer allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

test "resolve reads mentioned files and skips misses" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real.txt", .data = "contents" });

    const attachments = try resolve(
        allocator,
        std.testing.io,
        root,
        "see @real.txt and @missing.txt and @../escape.txt",
    );
    defer {
        for (attachments) |*a| a.deinit(allocator);
        allocator.free(attachments);
    }

    try std.testing.expectEqual(@as(usize, 1), attachments.len);
    try std.testing.expectEqualStrings("real.txt", attachments[0].path);
    try std.testing.expectEqualStrings("contents", attachments[0].content);
}

test "a mentioned folder resolves to its listing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];

    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "x" });

    const attachments = try resolve(allocator, std.testing.io, root, "look at @src/");
    defer {
        for (attachments) |*a| a.deinit(allocator);
        allocator.free(attachments);
    }

    try std.testing.expectEqual(@as(usize, 1), attachments.len);
    try std.testing.expect(std.mem.indexOf(u8, attachments[0].content, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, attachments[0].content, "nested/") != null);
    try std.testing.expect(std.mem.indexOf(u8, attachments[0].content, "x") == null);
}
