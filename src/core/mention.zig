//! `@path` mentions in a prompt.

const std = @import("std");

const image = @import("image.zig");

/// Largest file pulled in by a single mention.
const max_attachment_bytes: std.Io.Limit = .limited(256 * 1024);
/// Cap on files attached to one message, so `@a @b @c ...` cannot blow up the
/// request.
const max_attachments: usize = 16;
/// Entries listed for a mentioned directory before the rest is cut.
const max_listing_entries: usize = 200;
/// Images pulled in by one message. Each is megabytes once base64'd, and a
/// model that can see them charges for every one.
const max_images: usize = 4;

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
    /// The file's text, which past `Conversation.preview_bytes` may be only the
    /// first part of it. `content_bytes` holds the full length.
    content: []const u8,
    /// Full length of the file in bytes. Zero where nothing has said otherwise,
    /// which means `content` is all of it.
    content_bytes: u64 = 0,

    /// Whether `content` is only the start of the file.
    pub fn shortened(self: Attachment) bool {
        return self.content_bytes > self.content.len;
    }

    pub fn deinit(self: *Attachment, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

/// Find every `@path` in `text`. Spans borrow from `text`.
pub fn scan(allocator: std.mem.Allocator, text: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    var from: usize = 0;
    while (nextSpan(text, from)) |span| {
        try spans.append(allocator, span);
        from = span.end;
    }

    return spans.toOwnedSlice(allocator);
}

/// The first mention at or after `from`, or null when there are no more.
///
/// A bare mention ends at whitespace, which is what a reader expects and what
/// most filenames allow. A name with a space in it - and screenshots are full
/// of them - is written `@"Pasted image.png"`, and the quotes are not part of
/// the path.
fn nextSpan(text: []const u8, from: usize) ?Span {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (text[i] != '@') continue;
        if (i > 0 and !isBoundary(text[i - 1])) continue;

        if (i + 1 < text.len and text[i + 1] == '"') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 2, '"') orelse continue;
            if (close == i + 2) continue;
            return .{ .start = i, .end = close + 1, .path = text[i + 2 .. close] };
        }

        var end = i + 1;
        while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
        while (end > i + 1 and std.mem.indexOfScalar(u8, trailing_punctuation, text[end - 1]) != null) {
            end -= 1;
        }
        if (end == i + 1) continue;

        return .{ .start = i, .end = end, .path = text[i + 1 .. end] };
    }
    return null;
}

/// Whether `path` has to be quoted to survive being written into a prompt.
pub fn needsQuoting(path: []const u8) bool {
    for (path) |c| {
        if (std.ascii.isWhitespace(c) or c == '"') return true;
    }
    return false;
}

/// Whether `text` mentions something that looks like an image. Allocation-free,
/// because the draw path asks this of the draft on every frame to know whether
/// to warn that the model in use cannot see.
pub fn mentionsImage(text: []const u8) bool {
    var from: usize = 0;
    while (nextSpan(text, from)) |span| {
        if (image.hasImageExtension(span.path)) return true;
        from = span.end;
    }
    return false;
}

fn isBoundary(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '(' or c == '[' or c == '{';
}

/// Read every mentioned file or directory that exists under `root`. A mention
/// that does not
/// resolve is skipped rather than failing the turn: the model still sees the
/// text, and a typo should not block the prompt.
/// What a prompt's mentions came to: files to read, and images to look at. A
/// picture cannot be inlined as text, so the two travel separately all the way
/// to the provider.
pub const Resolved = struct {
    attachments: []Attachment = &.{},
    /// Base64-encoded image bodies, in the order they were mentioned.
    images: [][]const u8 = &.{},

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        for (self.attachments) |*attachment| attachment.deinit(allocator);
        allocator.free(self.attachments);
        for (self.images) |body| allocator.free(body);
        allocator.free(self.images);
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    text: []const u8,
) !Resolved {
    const spans = try scan(allocator, text);
    defer allocator.free(spans);

    var attachments: std.ArrayList(Attachment) = .empty;
    var images: std.ArrayList([]const u8) = .empty;
    var resolved: Resolved = .{};
    errdefer {
        resolved.attachments = attachments.items;
        resolved.images = images.items;
        resolved.deinit(allocator);
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

        if (image.hasImageExtension(span.path)) {
            if (images.items.len >= max_images) continue;
            const encoded = readImage(allocator, io, full) catch continue;
            if (encoded) |body| {
                try images.append(allocator, body);
                continue;
            }
        }

        const content = readEntry(allocator, io, full) catch continue;
        errdefer allocator.free(content);

        try attachments.append(allocator, .{
            .path = try allocator.dupe(u8, span.path),
            .content = content,
        });
    }

    resolved.attachments = try attachments.toOwnedSlice(allocator);
    resolved.images = try images.toOwnedSlice(allocator);
    return resolved;
}

/// A mentioned image, base64 for the wire. Null when the file is named like an
/// image but is not one, which falls back to reading it as text rather than
/// sending the model something it cannot decode.
fn readImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(image.max_bytes));
    defer allocator.free(bytes);

    if (!image.isImage(bytes)) return null;
    return try image.encode(allocator, bytes);
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

    var resolved = try resolve(
        allocator,
        std.testing.io,
        root,
        "see @real.txt and @missing.txt and @../escape.txt",
    );
    defer resolved.deinit(allocator);
    const attachments = resolved.attachments;

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

    var resolved = try resolve(allocator, std.testing.io, root, "look at @src/");
    defer resolved.deinit(allocator);
    const attachments = resolved.attachments;

    try std.testing.expectEqual(@as(usize, 1), attachments.len);
    try std.testing.expect(std.mem.indexOf(u8, attachments[0].content, "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, attachments[0].content, "nested/") != null);
    try std.testing.expect(std.mem.indexOf(u8, attachments[0].content, "x") == null);
}

test "a mentioned image travels as a picture, not as text" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];

    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shot.png", .data = png });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "words" });

    var resolved = try resolve(allocator, std.testing.io, root, "compare @shot.png with @notes.txt");
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolved.images.len);
    try std.testing.expectEqual(@as(usize, 1), resolved.attachments.len);
    try std.testing.expectEqualStrings("notes.txt", resolved.attachments[0].path);

    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(resolved.images[0]);
    const out = try allocator.alloc(u8, size);
    defer allocator.free(out);
    try decoder.decode(out, resolved.images[0]);
    try std.testing.expectEqualStrings(png, out);
}

test "a file named like an image but holding text is read as text" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-really.png", .data = "just words" });

    var resolved = try resolve(allocator, std.testing.io, root, "look at @not-really.png");
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), resolved.images.len);
    try std.testing.expectEqual(@as(usize, 1), resolved.attachments.len);
    try std.testing.expectEqualStrings("just words", resolved.attachments[0].content);
}

test "only so many images come along at once" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];

    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);

    for (0..max_images + 3) |i| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "s{d}.png", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = png });
        try prompt.print(allocator, "@{s} ", .{path});
    }

    var resolved = try resolve(allocator, std.testing.io, root, prompt.items);
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(max_images, resolved.images.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.attachments.len);
}

test "a draft that mentions an image says so without allocating" {
    try std.testing.expect(mentionsImage("look at @shot.png"));
    try std.testing.expect(mentionsImage("@a.txt and @b.JPEG please"));
    try std.testing.expect(!mentionsImage("look at @notes.txt"));
    try std.testing.expect(!mentionsImage("no mentions here"));
    try std.testing.expect(!mentionsImage("email@png"));
}

test "a name with a space in it survives when it is quoted" {
    const allocator = std.testing.allocator;

    const spans = try scan(allocator, "can you see @\"Pasted image.png\" ?");
    defer allocator.free(spans);

    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("Pasted image.png", spans[0].path);
    try std.testing.expectEqualStrings("@\"Pasted image.png\"", "can you see @\"Pasted image.png\" ?"[spans[0].start..spans[0].end]);

    const bare = try scan(allocator, "can you see @Pasted image.png ?");
    defer allocator.free(bare);
    try std.testing.expectEqual(@as(usize, 1), bare.len);
    try std.testing.expectEqualStrings("Pasted", bare[0].path);
}

test "an unclosed quote is not a mention" {
    const allocator = std.testing.allocator;

    const spans = try scan(allocator, "look at @\"never closed");
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans.len);

    const empty = try scan(allocator, "look at @\"\" please");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "quoted mentions resolve and mix with bare ones" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];

    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Pasted image.png", .data = png });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "words" });

    var resolved = try resolve(
        allocator,
        std.testing.io,
        root,
        "see @\"Pasted image.png\" next to @notes.txt",
    );
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolved.images.len);
    try std.testing.expectEqual(@as(usize, 1), resolved.attachments.len);
    try std.testing.expectEqualStrings("notes.txt", resolved.attachments[0].path);
}

test "a path is quoted only when it has to be" {
    try std.testing.expect(needsQuoting("Pasted image.png"));
    try std.testing.expect(needsQuoting("src/two words/a.zig"));
    try std.testing.expect(!needsQuoting("src/main.zig"));
    try std.testing.expect(!needsQuoting("flake.nix"));
}

test "an image is seen through a quoted mention too" {
    try std.testing.expect(mentionsImage("can you see @\"Pasted image.png\" ?"));
    try std.testing.expect(!mentionsImage("can you see @\"Pasted notes.txt\" ?"));
}
