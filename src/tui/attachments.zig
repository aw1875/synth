//! Things lifted out of the composer and left behind as a token.

const std = @import("std");

const mention = @import("../core/mention.zig");

const Attachments = @This();

/// Ceiling on one pasted body. Past this the paste is truncated rather than
/// held in full: it is going into the model's context either way.
pub const max_paste_bytes: usize = 1 << 20;
/// Ceiling on an image file, before base64 expands it by a third.
pub const max_image_bytes: usize = 10 << 20;

pub const Kind = enum { text, image };

pub const Item = struct {
    kind: Kind,
    /// What the draft shows in place of the body. Owned.
    token: []const u8,
    /// The pasted text, or base64-encoded image bytes. Owned.
    body: []const u8,
    /// How the body is introduced to the model: a file name for an image, or
    /// "pasted text". Owned.
    label: []const u8,

    fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.body);
        allocator.free(self.label);
    }
};

allocator: std.mem.Allocator,
items: std.ArrayList(Item) = .empty,
/// Token slices, in `items` order. Handed to the input widget, which renders
/// them as chips.
token_list: std.ArrayList([]const u8) = .empty,
/// Images are numbered per draft, so the first image of every message is 1.
images_added: usize = 0,

pub fn init(allocator: std.mem.Allocator) Attachments {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Attachments) void {
    self.clear();
    self.items.deinit(self.allocator);
    self.token_list.deinit(self.allocator);
}

pub fn clear(self: *Attachments) void {
    for (self.items.items) |*item| item.deinit(self.allocator);
    self.items.clearRetainingCapacity();
    self.token_list.clearRetainingCapacity();
    self.images_added = 0;
}

/// Tokens currently held, for the input widget to highlight.
pub fn tokens(self: *const Attachments) []const []const u8 {
    return self.token_list.items;
}

/// Hold a pasted block. Returns the token to put in the draft, owned here.
pub fn addText(self: *Attachments, text: []const u8) ![]const u8 {
    const kept = text[0..@min(text.len, max_paste_bytes)];
    const lines = std.mem.count(u8, kept, "\n") + 1;
    const token = try std.fmt.allocPrint(self.allocator, "[Pasted ~{d} lines]", .{lines});
    return self.add(.{
        .kind = .text,
        .token = token,
        .body = try self.allocator.dupe(u8, kept),
        .label = try self.allocator.dupe(u8, token),
    });
}

/// Hold an image, already base64 encoded. `label` is its file name, or "" when
/// it came straight off the clipboard.
pub fn addImage(self: *Attachments, base64: []const u8, label: []const u8) ![]const u8 {
    self.images_added += 1;
    return self.add(.{
        .kind = .image,
        .token = try std.fmt.allocPrint(self.allocator, "[Image {d}]", .{self.images_added}),
        .body = try self.allocator.dupe(u8, base64),
        .label = try self.allocator.dupe(u8, if (label.len > 0) label else "pasted image"),
    });
}

fn add(self: *Attachments, item: Item) ![]const u8 {
    try self.items.append(self.allocator, item);
    try self.token_list.append(self.allocator, item.token);
    return item.token;
}

/// Pasted blocks whose token survives in `text`, as message attachments. The
/// slices borrow from here, so the caller must copy anything it keeps.
/// How many images the draft is holding. Used to warn when the model in use
/// cannot see them.
pub fn imageCount(self: *const Attachments) usize {
    var count: usize = 0;
    for (self.items.items) |item| {
        if (item.kind == .image) count += 1;
    }
    return count;
}

pub fn textAttachments(
    self: *const Attachments,
    arena: std.mem.Allocator,
    text: []const u8,
) ![]const mention.Attachment {
    var out: std.ArrayList(mention.Attachment) = .empty;
    for (self.items.items) |item| {
        if (item.kind != .text) continue;
        if (std.mem.indexOf(u8, text, item.token) == null) continue;
        try out.append(arena, .{ .path = item.label, .content = item.body });
    }
    return out.toOwnedSlice(arena);
}

/// Base64 image bodies whose token survives in `text`.
pub fn images(
    self: *const Attachments,
    arena: std.mem.Allocator,
    text: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (self.items.items) |item| {
        if (item.kind != .image) continue;
        if (std.mem.indexOf(u8, text, item.token) == null) continue;
        try out.append(arena, item.body);
    }
    return out.toOwnedSlice(arena);
}

/// Drop everything whose token appears in `text`, now that it has been sent.
pub fn consume(self: *Attachments, text: []const u8) void {
    var i: usize = 0;
    while (i < self.items.items.len) {
        if (std.mem.indexOf(u8, text, self.items.items[i].token) == null) {
            i += 1;
            continue;
        }
        var item = self.items.orderedRemove(i);
        item.deinit(self.allocator);
    }
    self.rebuildTokens();
}

fn rebuildTokens(self: *Attachments) void {
    self.token_list.clearRetainingCapacity();
    for (self.items.items) |item| {
        self.token_list.append(self.allocator, item.token) catch {};
    }
}

/// Base64-encode `bytes`, for handing an image to a provider.
pub fn encode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

/// Whether `bytes` starts with a PNG, JPEG, GIF, or WebP signature. Clipboard
/// helpers happily return an error message on stdout, so what comes back is
/// checked rather than trusted.
pub fn isImage(bytes: []const u8) bool {
    if (bytes.len < 12) return false;
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return true;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return true;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return true;
    if (std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return true;
    return false;
}

/// Whether a pasted path names an image, by extension.
pub fn hasImageExtension(path: []const u8) bool {
    const extensions: []const []const u8 = &.{ ".png", ".jpg", ".jpeg", ".gif", ".webp" };
    for (extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
    }
    return false;
}

test "a token only counts while it is still in the draft" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var held: Attachments = .init(std.testing.allocator);
    defer held.deinit();

    const pasted = try held.addText("one\ntwo\nthree");
    try std.testing.expectEqualStrings("[Pasted ~3 lines]", pasted);
    const image = try held.addImage("Zm9v", "shot.png");
    try std.testing.expectEqualStrings("[Image 1]", image);
    try std.testing.expectEqual(@as(usize, 2), held.tokens().len);

    const draft = "look at [Pasted ~3 lines] please";
    try std.testing.expectEqual(@as(usize, 1), (try held.textAttachments(arena, draft)).len);
    try std.testing.expectEqual(@as(usize, 0), (try held.images(arena, draft)).len);

    const both = "[Pasted ~3 lines] [Image 1]";
    try std.testing.expectEqual(@as(usize, 1), (try held.images(arena, both)).len);
    const attachments = try held.textAttachments(arena, both);
    try std.testing.expectEqualStrings("[Pasted ~3 lines]", attachments[0].path);
    try std.testing.expectEqualStrings("one\ntwo\nthree", attachments[0].content);
}

test "image data is recognised by its signature, not its name" {
    try std.testing.expect(isImage("\x89PNG\r\n\x1a\n\x00\x00\x00\x00"));
    try std.testing.expect(!isImage("Nothing is copied\n"));
    try std.testing.expect(hasImageExtension("/tmp/Screenshot.PNG"));
    try std.testing.expect(!hasImageExtension("/tmp/notes.txt"));
}

test "held images are counted, pasted text is not" {
    var held: Attachments = .init(std.testing.allocator);
    defer held.deinit();

    try std.testing.expectEqual(@as(usize, 0), held.imageCount());

    _ = try held.addText("one\ntwo\nthree\n" ** 20);
    try std.testing.expectEqual(@as(usize, 0), held.imageCount());

    _ = try held.addImage("aGk=", "shot.png");
    _ = try held.addImage("aGk=", "");
    try std.testing.expectEqual(@as(usize, 2), held.imageCount());
}
