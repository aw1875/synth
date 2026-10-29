//! The schema, one file per version.
//!
//! Each migration is a `.sql` file next to this one, embedded at build time
//! rather than read at run time: `synth` ships as a binary, and a migration
//! directory it expected to find on disk would be a directory it could not
//! find. `@embedFile` keeps the SQL where SQL belongs - its own file, with
//! syntax highlighting and a diff that reads like a schema change - while
//! staying part of the executable.
//!
//! There are no down migrations. Rolling a schema back on a user's machine is
//! not a thing this app can do halfway: the version that wrote the data is
//! gone, and the way back is a backup.

const std = @import("std");
const testing = std.testing;

const zqlite = @import("zqlite");

/// One migration. `version` is the `user_version` the database is left at
/// after `sql` runs.
pub const Migration = struct {
    version: i32,
    sql: [:0]const u8,
};

/// Every migration, in order. Append; never edit one that has shipped, because
/// a database out there has already run it.
pub const all = [_]Migration{
    .{ .version = 1, .sql = @embedFile("migrations/001_initial.sql") },
    .{ .version = 2, .sql = @embedFile("migrations/002_session_agent.sql") },
    .{ .version = 3, .sql = @embedFile("migrations/003_attachment.sql") },
    .{ .version = 4, .sql = @embedFile("migrations/004_todo.sql") },
    .{ .version = 5, .sql = @embedFile("migrations/005_subagent_session.sql") },
    .{ .version = 6, .sql = @embedFile("migrations/006_tool_call_elapsed.sql") },
    .{ .version = 7, .sql = @embedFile("migrations/007_lease.sql") },
    .{ .version = 8, .sql = @embedFile("migrations/008_mcp_auth.sql") },
};

/// The version this build writes. Derived, so adding a migration is one edit.
pub const current: i32 = all[all.len - 1].version;

/// Bring the schema up to `current`. Each migration runs in its own
/// transaction; a failure rolls that one back and leaves the version where it
/// was, so the next start retries it rather than skipping it.
/// Each step takes the write lock before it reads the version, so a second
/// process opening the database at the same moment waits for the first and
/// then finds the step done. A deferred `begin` would let both read the old
/// version, and fail the second as busy when it went to write.
pub fn run(conn: *zqlite.Conn) !void {
    if (try userVersion(conn) >= current) return;
    while (true) {
        try conn.execNoArgs("begin immediate");
        errdefer conn.rollback();

        const version = try userVersion(conn);
        if (version >= current) return conn.commit();
        const migration = for (all) |m| {
            if (m.version == version + 1) break m;
        } else return error.UnknownMigration;

        try conn.execNoArgs(migration.sql);
        try setUserVersion(conn, migration.version);
        try conn.commit();
    }
}

pub fn userVersion(conn: *zqlite.Conn) !i32 {
    const row = try conn.row("PRAGMA user_version", .{}) orelse return 0;
    defer row.deinit();
    return @intCast(row.int(0));
}

pub fn setUserVersion(conn: *zqlite.Conn, version: i32) !void {
    var buf: [64]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{version});
    try conn.execNoArgs(sql.ptr);
}

test "versions start at one and have no gaps" {
    try testing.expectEqual(@as(i32, 1), all[0].version);
    for (all, 1..) |migration, expected| {
        try testing.expectEqual(@as(i32, @intCast(expected)), migration.version);
        try testing.expect(migration.sql.len > 0);
    }
    try testing.expectEqual(all[all.len - 1].version, current);
}
