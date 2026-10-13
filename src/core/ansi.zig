//! Taking the terminal control sequences back out of captured output.
//!
//! A command run through a pipe is often still asked for colour - `git`, `ls`
//! and `cargo` all read a config rather than the terminal - and what comes back
//! carries escape sequences meant for a terminal that is about to interpret
//! them. Nothing here does: the output is drawn into a cell grid and sent to a
//! model as text, and in both places an escape sequence is noise. So it is
//! removed once, where a tool's result is taken, rather than at each place that
//! goes on to read it.

const std = @import("std");

/// Whether `text` carries anything that has to come out. Newline and tab are
/// the two controls that mean something in a transcript, so text made only of
/// those is handed back untouched rather than copied.
pub fn hasControls(text: []const u8) bool {
    for (text) |byte| {
        if (byte == '\n' or byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

/// `text` with its escape sequences and stray control bytes removed. Caller
/// owns the result.
///
/// A carriage return is not dropped but obeyed: it is what a progress bar uses
/// to write over the line it just wrote, so the line it left behind is the one
/// worth keeping.
pub fn clean(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        switch (byte) {
            0x1b => i += escapeLen(text, i),
            '\r' => {
                // A carriage return that ends a line is half of its ending.
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    i += 1;
                    continue;
                }
                out.shrinkRetainingCapacity(line_start);
                i += 1;
            },
            '\n' => {
                out.appendAssumeCapacity('\n');
                line_start = out.items.len;
                i += 1;
            },
            '\t' => {
                out.appendAssumeCapacity('\t');
                i += 1;
            },
            else => {
                if (byte < 0x20 or byte == 0x7f) {
                    i += 1;
                    continue;
                }
                out.appendAssumeCapacity(byte);
                i += 1;
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

/// How many bytes the escape sequence starting at `at` takes up, including the
/// escape itself. An unterminated sequence runs to the end: whatever follows an
/// escape was written for a terminal, not for a reader.
fn escapeLen(text: []const u8, at: usize) usize {
    if (at + 1 >= text.len) return 1;

    switch (text[at + 1]) {
        // A control sequence runs until a byte in the final range.
        '[' => {
            var i = at + 2;
            while (i < text.len) : (i += 1) {
                if (text[i] >= 0x40 and text[i] <= 0x7e) return i - at + 1;
            }
            return text.len - at;
        },
        // A string sequence runs to a terminator, or to the bell titles still use.
        ']', 'P', '^', '_' => {
            var i = at + 2;
            while (i < text.len) : (i += 1) {
                if (text[i] == 0x07) return i - at + 1;
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i - at + 2;
            }
            return text.len - at;
        },
        else => return 2,
    }
}

const testing = std.testing;

test "text with nothing to strip is left alone" {
    try testing.expect(!hasControls("plain\ttext\nover two lines"));
    try testing.expect(!hasControls(""));
    try testing.expect(hasControls("\x1b[31mred\x1b[0m"));
    try testing.expect(hasControls("progress\r"));
    try testing.expect(hasControls("bell\x07"));
    try testing.expect(hasControls("del\x7f"));
}

test "colour comes out and the words it wrapped stay" {
    const cleaned = try clean(testing.allocator, "\x1b[1;31mfatal\x1b[0m: not a git repository");
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("fatal: not a git repository", cleaned);
}

test "a sequence that never ends takes the rest with it" {
    const cleaned = try clean(testing.allocator, "before\x1b[38;2;255");
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("before", cleaned);
}

test "a window title is dropped, however it is terminated" {
    const bell = try clean(testing.allocator, "a\x1b]0;some title\x07b");
    defer testing.allocator.free(bell);
    try testing.expectEqualStrings("ab", bell);

    const st = try clean(testing.allocator, "a\x1b]0;some title\x1b\\b");
    defer testing.allocator.free(st);
    try testing.expectEqualStrings("ab", st);
}

test "the other string sequences are dropped whole too" {
    // A device control string, and an application one, both ending at ST.
    const dcs = try clean(testing.allocator, "a\x1bP0;1|stuff\x1b\\b");
    defer testing.allocator.free(dcs);
    try testing.expectEqualStrings("ab", dcs);

    const apc = try clean(testing.allocator, "a\x1b_notify\x1b\\b");
    defer testing.allocator.free(apc);
    try testing.expectEqualStrings("ab", apc);
}

test "a two-byte sequence takes its one character" {
    const cleaned = try clean(testing.allocator, "a\x1b=b\x1b>c");
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("abc", cleaned);
}

test "a rewritten line comes back as the line it settled on" {
    const cleaned = try clean(testing.allocator, "10%\r55%\r100%\ndone\n");
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("100%\ndone\n", cleaned);
}

test "a carriage return that ends a line is not a rewrite" {
    const cleaned = try clean(testing.allocator, "one\r\ntwo\r\n");
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("one\ntwo\n", cleaned);
}

test "tabs and newlines are the two controls that survive" {
    const cleaned = try clean(testing.allocator, "a\tb\nc\x00d\x07e\x7f");
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings("a\tb\ncde", cleaned);
}

test "what is not a control is not touched, bytes above ASCII included" {
    const source = "caf\u{e9} \u{2500} \u{1f600}";
    const cleaned = try clean(testing.allocator, source);
    defer testing.allocator.free(cleaned);
    try testing.expectEqualStrings(source, cleaned);
}
