//! What counts as an image, and how one is handed to a provider.
//!
//! In `core/` rather than beside the composer because both ways an image
//! reaches a message need it: the clipboard, which the TUI drives, and an
//! `@path` mention, which the loop resolves whether or not there is a TUI.

const std = @import("std");

/// Ceiling on an image file, before base64 expands it by a third.
pub const max_bytes: usize = 10 << 20;

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

/// Whether a path names an image, by extension. What decides how a file is
/// opened; `isImage` then decides what it turns out to be.
pub fn hasImageExtension(path: []const u8) bool {
    const extensions: []const []const u8 = &.{ ".png", ".jpg", ".jpeg", ".gif", ".webp" };
    for (extensions) |extension| {
        if (std.ascii.endsWithIgnoreCase(path, extension)) return true;
    }
    return false;
}

test "image data is recognised by its signature, not its name" {
    try std.testing.expect(isImage("\x89PNG\r\n\x1a\n\x00\x00\x00\x00"));
    try std.testing.expect(isImage("RIFF\x00\x00\x00\x00WEBP"));
    try std.testing.expect(!isImage("Nothing is copied\n"));
    try std.testing.expect(!isImage("\x89PNG"));
    try std.testing.expect(hasImageExtension("/tmp/Screenshot.PNG"));
    try std.testing.expect(hasImageExtension("a.jpeg"));
    try std.testing.expect(!hasImageExtension("/tmp/notes.txt"));
    try std.testing.expect(!hasImageExtension("png"));
}

test "encoding round trips" {
    const encoded = try encode(std.testing.allocator, "\x89PNG\r\n\x1a\n");
    defer std.testing.allocator.free(encoded);

    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    const out = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(out);
    try decoder.decode(out, encoded);

    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", out);
}
