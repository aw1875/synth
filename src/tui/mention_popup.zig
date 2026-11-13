//! The `@` file picker shown above the prompt.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const fuzzy = @import("../core/fuzzy.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Popup = @This();

/// Rows shown at once.
pub const max_rows: u16 = 8;

allocator: std.mem.Allocator,
/// Project-relative paths, owned, as the session's server listed them. Empty
/// until the first `@`.
files: std.ArrayList([]const u8) = .empty,
/// When the index was last built, in milliseconds. Null means never. An index
/// is a snapshot of a directory that keeps changing underneath it - not least
/// because the agent itself creates files - so it goes stale rather than being
/// built once and believed forever.
indexed_at: ?i64 = null,
/// Indices into `files` matching the current query, best first.
matches: std.ArrayList(usize) = .empty,
selected: usize = 0,
/// Byte offset of the `@` being completed, within the input buffer.
anchor: ?usize = null,

pub fn init(allocator: std.mem.Allocator) Popup {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Popup) void {
    for (self.files.items) |path| self.allocator.free(path);
    self.files.deinit(self.allocator);
    self.matches.deinit(self.allocator);
}

/// Whether the cursor sits in an `@` token, matches or not.
pub fn isCompleting(self: *const Popup) bool {
    return self.anchor != null;
}

/// Open while completing and something matches, or while there is no index
/// yet to match against and the first listing is on its way.
pub fn isOpen(self: *const Popup) bool {
    return self.anchor != null and (self.matches.items.len > 0 or self.indexed_at == null);
}

pub fn close(self: *Popup) void {
    self.anchor = null;
    self.selected = 0;
    self.matches.clearRetainingCapacity();
}

/// Recompute the popup state from the input buffer. Opens when the cursor sits
/// inside an `@token` and something matches, closes otherwise.
pub fn update(self: *Popup, text: []const u8, cursor: usize) !void {
    const anchor = mentionStart(text, cursor) orelse {
        self.close();
        return;
    };

    const query = std.mem.trimStart(u8, text[anchor + 1 .. cursor], "\"");
    self.anchor = anchor;
    try self.filter(query);
    if (self.selected >= self.matches.items.len) self.selected = 0;
}

/// The offset of the `@` the cursor is completing, if any.
fn mentionStart(text: []const u8, cursor: usize) ?usize {
    if (cursor > text.len) return null;

    var i = cursor;
    while (i > 0) {
        i -= 1;
        const c = text[i];
        if (c == '@') {
            if (i == 0 or std.ascii.isWhitespace(text[i - 1])) return i;
            return null;
        }
        if (std.ascii.isWhitespace(c)) return null;
    }
    return null;
}

pub fn moveSelection(self: *Popup, delta: i32) void {
    if (self.matches.items.len == 0) return;
    const len: i32 = @intCast(self.matches.items.len);
    var next = @as(i32, @intCast(self.selected)) + delta;
    while (next < 0) next += len;
    self.selected = @intCast(@mod(next, len));
}

/// The path to insert, or null when nothing is selected.
pub fn selectedPath(self: *const Popup) ?[]const u8 {
    if (self.matches.items.len == 0) return null;
    return self.files.items[self.matches.items[self.selected]];
}

/// Rank every file against the query and keep the best `max_rows`.
fn filter(self: *Popup, query: []const u8) !void {
    self.matches.clearRetainingCapacity();

    if (query.len == 0) {
        for (self.files.items, 0..) |_, i| {
            if (self.matches.items.len >= max_rows) break;
            try self.matches.append(self.allocator, i);
        }
        return;
    }

    var top: fuzzy.Top(max_rows) = .{};
    for (self.files.items, 0..) |path, i| top.consider(i, path, query, .{ .path = true });
    for (top.ranked()) |entry| try self.matches.append(self.allocator, entry.index);
}

/// How long an index is trusted before the next mention rebuilds it. Short
/// enough that a file the agent just wrote can be mentioned straight after,
/// long enough that holding a key down does not start a walk per keystroke.
pub const stale_after_ms: i64 = 3000;

/// Whether the index is old enough to be worth rebuilding.
pub fn stale(self: *const Popup, io: std.Io) bool {
    const built = self.indexed_at orelse return true;
    return nowMilliseconds(io) - built >= stale_after_ms;
}

fn nowMilliseconds(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

/// Drop the index outright, so the next mention rebuilds it rather than
/// waiting out `stale_after_ms`. For when something is known to have changed -
/// a tool that just created a file, say.
pub fn invalidate(self: *Popup) void {
    self.indexed_at = null;
}

/// Take the project's files as the session's server listed them, which the
/// popup owns from here on. Directories carry a trailing separator, both to
/// mark them in the picker and so `@src/` resolves to a listing, not a read.
pub fn supply(self: *Popup, io: std.Io, paths: []const []const u8) void {
    for (self.files.items) |path| self.allocator.free(path);
    self.files.deinit(self.allocator);
    self.files = .fromOwnedSlice(@constCast(paths));
    self.indexed_at = nowMilliseconds(io);
}

/// Render the match list. The caller positions it above the prompt.
pub fn draw(self: *Popup, ctx: vxfw.DrawContext, widget: vxfw.Widget, width: u16) !vxfw.Surface {
    const rows: u16 = @intCast(@min(self.matches.items.len, max_rows));

    if (rows == 0) {
        const waiting = try w.surfaceClamped(ctx.arena, widget, .{ .width = width, .height = 1 });
        w.fill(waiting, theme.card.cell);
        _ = w.writeText(waiting, 2, 0, "indexing project...", theme.on_card(theme.fg_dim).cell);
        return waiting;
    }

    const surface = try w.surfaceClamped(ctx.arena, widget, .{ .width = width, .height = rows });
    w.fill(surface, theme.card.cell);

    for (self.matches.items[0..rows], 0..) |file_index, row| {
        const path = self.files.items[file_index];
        const chosen = row == self.selected;

        const style = if (chosen)
            theme.on_card(theme.fg).cell
        else
            theme.on_card(theme.fg_muted).cell;

        if (chosen) {
            var col: u16 = 0;
            while (col < width) : (col += 1) {
                surface.writeCell(col, @intCast(row), .{ .style = theme.on_card(theme.fg).cell });
            }
            _ = w.writeText(surface, 0, @intCast(row), "▌", theme.on_card(theme.accent).cell);
        }

        _ = w.writeText(surface, 2, @intCast(row), path, style);
    }

    return surface;
}

test "a supplied index is searched as the mention is typed" {
    const testing = std.testing;
    var popup: Popup = .init(testing.allocator);
    defer popup.deinit();

    try popup.update("@ma", 3);
    try testing.expect(popup.isOpen());
    try testing.expectEqual(@as(usize, 0), popup.matches.items.len);

    const paths = try testing.allocator.alloc([]const u8, 2);
    paths[0] = try testing.allocator.dupe(u8, "src/");
    paths[1] = try testing.allocator.dupe(u8, "src/main.zig");
    popup.supply(testing.io, paths);
    try testing.expect(!popup.stale(testing.io));

    try popup.update("@ma", 3);
    try testing.expect(popup.isOpen());
    try testing.expectEqualStrings("src/main.zig", popup.selectedPath().?);

    try popup.update("@zzz", 4);
    try testing.expect(!popup.isOpen());
    try popup.update("done ", 5);
    try testing.expect(!popup.isCompleting());
}

test "mentionStart only fires at a word boundary" {
    try std.testing.expectEqual(@as(?usize, 0), mentionStart("@fla", 4));
    try std.testing.expectEqual(@as(?usize, 4), mentionStart("see @fla", 8));
    try std.testing.expectEqual(@as(?usize, null), mentionStart("me@example", 10));
    try std.testing.expectEqual(@as(?usize, null), mentionStart("@flake.nix ", 11));
}

/// Build a popup over a fixed file list, the way an indexed project looks.
fn fixture(paths: []const []const u8) !Popup {
    var popup: Popup = .init(std.testing.allocator);
    errdefer popup.deinit();
    for (paths) |path| {
        try popup.files.append(std.testing.allocator, try std.testing.allocator.dupe(u8, path));
    }
    return popup;
}

fn ranked(popup: *const Popup, at: usize) []const u8 {
    return popup.files.items[popup.matches.items[at]];
}

test "a query can run two path segments together" {
    var popup = try fixture(&.{
        "src/tui/app.zig",
        "src/provider/ollama.zig",
        "src/core/config.zig",
    });
    defer popup.deinit();

    try popup.filter("srcollama");
    try std.testing.expectEqual(@as(usize, 1), popup.matches.items.len);
    try std.testing.expectEqualStrings("src/provider/ollama.zig", ranked(&popup, 0));

    try popup.filter("ollama");
    try std.testing.expectEqualStrings("src/provider/ollama.zig", ranked(&popup, 0));
}

test "a typo is still a match, and the right one wins" {
    var popup = try fixture(&.{
        "src/tui/mention_popup.zig",
        "src/tui/model_picker.zig",
        "src/core/project.zig",
    });
    defer popup.deinit();

    try popup.filter("mentionpop");
    try std.testing.expectEqualStrings("src/tui/mention_popup.zig", ranked(&popup, 0));

    try popup.filter("mentionzig");
    try std.testing.expectEqualStrings("src/tui/mention_popup.zig", ranked(&popup, 0));
}

test "contiguous beats scattered" {
    var popup = try fixture(&.{
        "src/agent/conversation.zig",
        "src/core/config.zig",
    });
    defer popup.deinit();

    try popup.filter("config");
    try std.testing.expectEqualStrings("src/core/config.zig", ranked(&popup, 0));
}

test "nothing matching lists nothing" {
    var popup = try fixture(&.{ "src/tui/app.zig", "build.zig" });
    defer popup.deinit();

    try popup.filter("gizpa");
    try std.testing.expectEqual(@as(usize, 0), popup.matches.items.len);

    try popup.filter("zzz");
    try std.testing.expectEqual(@as(usize, 0), popup.matches.items.len);
}

test "the list is capped at what it can show" {
    var popup: Popup = .init(std.testing.allocator);
    defer popup.deinit();

    var buffer: [32]u8 = undefined;
    for (0..100) |i| {
        const path = try std.fmt.bufPrint(&buffer, "src/thing{d}/app.zig", .{i});
        try popup.files.append(std.testing.allocator, try std.testing.allocator.dupe(u8, path));
    }

    try popup.filter("app");
    try std.testing.expectEqual(@as(usize, max_rows), popup.matches.items.len);

    try popup.filter("");
    try std.testing.expectEqual(@as(usize, max_rows), popup.matches.items.len);
}

test "filter prefers basename matches" {
    var popup: Popup = .init(std.testing.allocator);
    defer popup.deinit();

    try popup.files.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "src/app/other.zig"));
    try popup.files.append(std.testing.allocator, try std.testing.allocator.dupe(u8, "src/tui/app.zig"));

    try popup.filter("app");

    try std.testing.expectEqual(@as(usize, 2), popup.matches.items.len);
    try std.testing.expectEqualStrings("src/tui/app.zig", popup.files.items[popup.matches.items[0]]);
}

test "an index that has been invalidated is stale at once" {
    const testing = std.testing;
    var popup: Popup = .init(testing.allocator);
    defer popup.deinit();

    popup.supply(testing.io, try testing.allocator.alloc([]const u8, 0));
    try testing.expect(!popup.stale(testing.io));
    popup.invalidate();
    try testing.expect(popup.stale(testing.io));
}

test "an index with no build time behind it is stale" {
    const testing = std.testing;

    var popup: Popup = .init(testing.allocator);
    defer popup.deinit();

    try testing.expect(popup.stale(testing.io));

    popup.indexed_at = nowMilliseconds(testing.io);
    try testing.expect(!popup.stale(testing.io));

    popup.indexed_at = nowMilliseconds(testing.io) - stale_after_ms - 1;
    try testing.expect(popup.stale(testing.io));
}

test "typing the opening quote does not break the search" {
    var popup = try fixture(&.{"Pasted image.png"});
    defer popup.deinit();

    try popup.update("@\"Pas", 5);
    try std.testing.expectEqualStrings("Pasted image.png", popup.selectedPath().?);
}
