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
};

/// The version this build writes. Derived, so adding a migration is one edit.
pub const current: i32 = all[all.len - 1].version;

/// Bring the schema up to `current`. Each migration runs in its own
/// transaction; a failure rolls that one back and leaves the version where it
/// was, so the next start retries it rather than skipping it.
pub fn run(conn: *zqlite.Conn) !void {
    var version = try userVersion(conn);
    while (version < current) {
        const migration = for (all) |m| {
            if (m.version == version + 1) break m;
        } else return error.UnknownMigration;

        try conn.transaction();
        errdefer conn.rollback();

        try conn.execNoArgs(migration.sql);
        try setUserVersion(conn, migration.version);

        try conn.commit();
        version = migration.version;
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
