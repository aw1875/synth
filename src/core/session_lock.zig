//! Which process hosts a live session: the one holding an exclusive `flock` on
//! the session's file in `<database>-locks/`. The kernel lets go of a lock
//! however its holder ends, so a crashed host frees its session at once, and
//! one too busy to check in keeps it.

const std = @import("std");
const testing = std.testing;

const SessionLock = @This();

/// Null for a session of an in-memory database, which is this process's
/// alone.
file: ?std.Io.File,

/// How long a taker waits before trying once more: someone asking whether
/// the session is held takes the lock for a moment to find out.
const retry_after: std.Io.Duration = .fromMilliseconds(50);

/// The directory beside the database at `db_path` that its locks live in.
/// Null for an in-memory database, which no other process can open.
pub fn dirFor(allocator: std.mem.Allocator, db_path: []const u8) !?[]u8 {
    if (std.mem.eql(u8, db_path, ":memory:")) return null;
    return try std.fmt.allocPrint(allocator, "{s}-locks", .{db_path});
}

/// Host session `handle`, until released. `error.SessionHeld` when someone
/// else does: another process, or another lock in this one.
pub fn take(io: std.Io, dir: []const u8, handle: []const u8) !SessionLock {
    std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.Io.Dir.cwd().createFile(io, try pathOf(&buffer, dir, handle), .{ .truncate = false, .permissions = .fromMode(0o600) });
    errdefer file.close(io);
    if (try file.tryLock(io, .exclusive)) return .{ .file = file };
    try std.Io.sleep(io, retry_after, .awake);
    if (try file.tryLock(io, .exclusive)) return .{ .file = file };
    return error.SessionHeld;
}

pub fn release(self: SessionLock, io: std.Io) void {
    if (self.file) |file| file.close(io);
}

/// Whether some process hosts session `handle` right now.
pub fn isHeld(io: std.Io, dir: []const u8, handle: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathOf(&buffer, dir, handle) catch return false;
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    const free = file.tryLock(io, .shared) catch return false;
    if (free) file.unlock(io);
    return !free;
}

/// Remove session `handle`'s file, once the session itself is gone.
pub fn forget(io: std.Io, dir: []const u8, handle: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathOf(&buffer, dir, handle) catch return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// A handle is a file name here, so one that could climb out of `dir` is
/// refused.
fn pathOf(buffer: []u8, dir: []const u8, handle: []const u8) ![]const u8 {
    if (handle.len == 0 or handle[0] == '.' or std.mem.indexOfAny(u8, handle, "/\\") != null) return error.InvalidHandle;
    return std.fmt.bufPrint(buffer, "{s}/{s}.lock", .{ dir, handle });
}

test "a session is hosted by one holder at a time, and free once it lets go" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root);
    const db_path = try std.fs.path.join(testing.allocator, &.{ root[0..n], "synth.db" });
    defer testing.allocator.free(db_path);
    const dir = (try dirFor(testing.allocator, db_path)).?;
    defer testing.allocator.free(dir);

    try testing.expect(!isHeld(testing.io, dir, "ses_one"));
    const held = try take(testing.io, dir, "ses_one");
    try testing.expect(isHeld(testing.io, dir, "ses_one"));
    try testing.expectError(error.SessionHeld, take(testing.io, dir, "ses_one"));
    const other = try take(testing.io, dir, "ses_two");
    other.release(testing.io);

    held.release(testing.io);
    try testing.expect(!isHeld(testing.io, dir, "ses_one"));
    const again = try take(testing.io, dir, "ses_one");
    again.release(testing.io);
    forget(testing.io, dir, "ses_one");
    try testing.expect(!isHeld(testing.io, dir, "ses_one"));

    try testing.expectError(error.InvalidHandle, take(testing.io, dir, "../escape"));
    try testing.expectEqual(null, try dirFor(testing.allocator, ":memory:"));
}
