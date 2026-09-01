//! Handing the draft to `$EDITOR` and taking back what comes out.
//!
//! A long prompt is miserable to compose in a one-line composer, and every
//! terminal program that asks for prose solves it the same way: write what is
//! there to a file, run the editor the user already knows, read it back.

const builtin = @import("builtin");
const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const bell = @import("bell.zig");

/// Ceiling on what comes back, so a stray `$EDITOR` pointed at something huge
/// cannot be pasted into a prompt whole.
const max_draft_bytes: std.Io.Limit = .limited(1 << 20);

/// Longest name `draftName` writes.
const draft_name_bytes = 64;

pub const Error = error{ NoEditor, EditorFailed };

/// What the user typed, or null when they left the file empty. Caller owns it.
///
/// `app` is borrowed for the length of the call: the terminal is handed back
/// before the editor starts and taken again once it exits.
pub fn edit(
    allocator: std.mem.Allocator,
    io: std.Io,
    app: ?*vxfw.App,
    environ: *std.process.Environ.Map,
    draft: []const u8,
) ![]u8 {
    const command = editorFor(environ) orelse return Error.NoEditor;

    var dir = try std.Io.Dir.openDirAbsolute(io, tempRoot(environ), .{});
    defer dir.close(io);

    var name_buffer: [draft_name_bytes]u8 = undefined;
    const name = draftName(io, &name_buffer);

    // Exclusive: an existing name is an error, not a write through a symlink.
    {
        var file = try dir.createFile(io, name, .{ .exclusive = true });
        defer file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        try writer.interface.writeAll(draft);
        try writer.interface.flush();
    }
    defer dir.deleteFile(io, name) catch {};

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try dir.realPathFile(io, name, &path_buffer)];

    {
        var handed = HandOver.take(app);
        defer handed.give();
        try run(allocator, io, command, path);
    }

    const edited = try dir.readFileAlloc(io, name, allocator, max_draft_bytes);
    errdefer allocator.free(edited);

    // A trailing newline is right for a file and wrong for a prompt.
    const trimmed = std.mem.trimEnd(u8, edited, " \t\r\n");
    if (trimmed.len == edited.len) return edited;

    defer allocator.free(edited);
    return allocator.dupe(u8, trimmed);
}

/// A name no other synth is writing at the same moment. `.md`-suffixed so an
/// editor picks a markdown mode: a prompt is prose, and soft wrapping is what
/// makes it readable.
fn draftName(io: std.Io, buffer: *[draft_name_bytes]u8) []const u8 {
    var salt: [4]u8 = undefined;
    io.random(&salt);

    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("synth-draft-{x}.md", .{std.mem.readInt(u32, &salt, .little)}) catch unreachable;
    return writer.buffered();
}

/// `$VISUAL` first: it is the one meant for a full-screen editor, which is what
/// this is. Falls back to `$EDITOR`, then to whatever is likely installed.
fn editorFor(environ: *std.process.Environ.Map) ?[]const u8 {
    if (environ.get("VISUAL")) |value| {
        if (value.len > 0) return value;
    }
    if (environ.get("EDITOR")) |value| {
        if (value.len > 0) return value;
    }
    return null;
}

fn tempRoot(environ: *std.process.Environ.Map) []const u8 {
    if (environ.get("TMPDIR")) |value| {
        if (value.len > 0) return std.mem.trimEnd(u8, value, "/");
    }
    return "/tmp";
}

/// Run the editor through a shell, so `EDITOR="code -w"` and the like work.
fn run(allocator: std.mem.Allocator, io: std.Io, command: []const u8, path: []const u8) !void {
    const line = try std.fmt.allocPrint(allocator, "{s} \"$1\"", .{command});
    defer allocator.free(line);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", line, "sh", path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return Error.EditorFailed,
        else => return Error.EditorFailed,
    }
}

/// The terminal, lent to a child process and taken back afterwards. Same dance
/// as suspending: leave the alternate screen and raw mode on the way out, and
/// put every mode back on the way in.
const HandOver = struct {
    app: ?*vxfw.App,
    in_band_resize: bool = false,

    fn take(maybe: ?*vxfw.App) HandOver {
        if (builtin.os.tag == .windows or builtin.is_test) return .{ .app = null };

        const app = maybe orelse return .{ .app = null };
        const writer = app.tty.writer();
        const self: HandOver = .{ .app = app, .in_band_resize = app.vx.state.in_band_resize };

        app.vx.resetState(writer) catch {};
        std.posix.tcsetattr(app.tty.fd.handle, .FLUSH, app.tty.termios) catch {};
        return self;
    }

    fn give(self: *HandOver) void {
        if (builtin.os.tag == .windows or builtin.is_test) return;
        const app = self.app orelse return;
        const writer = app.tty.writer();

        _ = vaxis.Tty.makeRaw(app.tty.fd.handle) catch {};
        app.vx.enterAltScreen(writer) catch {};
        app.vx.enableDetectedFeatures(writer) catch {};
        app.vx.setMouseMode(writer, true) catch {};
        app.vx.setBracketedPaste(writer, true) catch {};
        app.vx.subscribeToColorSchemeUpdates(writer) catch {};
        writer.writeAll(bell.focus_set) catch {};
        if (self.in_band_resize) {
            writer.writeAll(vaxis.ctlseqs.in_band_resize_set) catch {};
            app.vx.state.in_band_resize = true;
        }
        writer.flush() catch {};

        app.vx.queueRefresh();
    }
};

test "the draft goes out to the editor and what it wrote comes back" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];

    // Stands in for an editor, leaving the trailing newline a real one would.
    try tmp.dir.writeFile(io, .{
        .sub_path = "fake-editor.sh",
        .data = "#!/bin/sh\nprintf '%s and more\\n\\n' \"$(cat \"$1\")\" > \"$1\"\n",
    });
    var script_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const script = script_buffer[0..try tmp.dir.realPathFile(io, "fake-editor.sh", &script_buffer)];

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    try environ.put("TMPDIR", root);
    const command = try std.fmt.allocPrint(testing.allocator, "sh {s}", .{script});
    defer testing.allocator.free(command);
    try environ.put("EDITOR", command);

    const out = try edit(testing.allocator, io, null, &environ, "the draft");
    defer testing.allocator.free(out);

    // Trimmed, so the prompt is what was written rather than what was saved.
    try testing.expectEqualStrings("the draft and more", out);

    // The draft file is gone: only the editor script it ran is left behind.
    var left: usize = 0;
    var walk = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer walk.close(io);
    var it = walk.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "synth-draft-")) left += 1;
    }
    try testing.expectEqual(@as(usize, 0), left);
}

test "no editor configured is reported rather than guessed at" {
    const testing = std.testing;

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expectError(
        Error.NoEditor,
        edit(testing.allocator, testing.io, null, &environ, "draft"),
    );
}

test "an editor is taken from VISUAL first, then EDITOR" {
    const testing = std.testing;

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expect(editorFor(&environ) == null);

    try environ.put("EDITOR", "vi");
    try testing.expectEqualStrings("vi", editorFor(&environ).?);

    try environ.put("VISUAL", "hx");
    try testing.expectEqualStrings("hx", editorFor(&environ).?);

    // Set but empty is unset: never run the empty string.
    try environ.put("VISUAL", "");
    try testing.expectEqualStrings("vi", editorFor(&environ).?);
}

test "a temp root comes from TMPDIR when it is set" {
    const testing = std.testing;

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expectEqualStrings("/tmp", tempRoot(&environ));

    try environ.put("TMPDIR", "/run/user/1000/");
    try testing.expectEqualStrings("/run/user/1000", tempRoot(&environ));
}
