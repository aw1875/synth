//! SQLite persistence for sessions, messages, tool calls, read logs and
//! remembered approvals.

const std = @import("std");

const zqlite = @import("zqlite");

const Conversation = @import("conversation.zig");
const Config = @import("config.zig");
const migrations = @import("migrations.zig");

const Database = @This();

conn: zqlite.Conn,
io: std.Io,

/// Length of the random part of a session handle.
const public_id_chars: usize = 8;
/// Crockford-style base32: no letters that read as digits, so a handle can be
/// copied off a terminal by eye.
const public_id_alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

pub fn init(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !Database {
    const path = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path);

    try Config.ensureDir(io, db_path);

    // NoMutex: this connection is the UI thread's. A worker opens its own.
    var conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.NoMutex);
    errdefer conn.close();

    var db = Database{ .conn = conn, .io = io };
    errdefer db.deinit();

    conn.execNoArgs("PRAGMA journal_mode = WAL") catch {};
    conn.execNoArgs("PRAGMA synchronous = NORMAL") catch {};
    conn.execNoArgs("PRAGMA busy_timeout = 2000") catch {};
    conn.execNoArgs("PRAGMA foreign_keys = ON") catch {};

    try db.migrate();

    return db;
}

pub fn deinit(self: *Database) void {
    self.conn.close();
}

fn migrate(self: *Database) !void {
    return migrations.run(&self.conn);
}

fn userVersion(self: *Database) !i32 {
    return migrations.userVersion(&self.conn);
}

fn setUserVersion(self: *Database, version: i32) !void {
    return migrations.setUserVersion(&self.conn, version);
}

/// Wall-clock time in milliseconds since the Unix epoch, for `created_at` and
/// friends. Stored as INTEGER.
fn nowMs(self: *Database) i64 {
    return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
}

/// Find the project row for `root`, creating it if absent. Returns its id and
/// bumps `last_used_at` either way.
pub fn resolveProject(
    self: *Database,
    root: []const u8,
    vcs: ?[]const u8,
    name: []const u8,
) !i64 {
    const now = self.nowMs();
    try self.conn.exec(
        \\INSERT INTO project (root, vcs, name, created_at, last_used_at)
        \\VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(root) DO UPDATE SET last_used_at = excluded.last_used_at
    , .{ root, vcs, name, now, now });

    const row = try self.conn.row("SELECT id FROM project WHERE root = ?", .{root}) orelse
        return error.ProjectNotFound;
    defer row.deinit();
    return row.int(0);
}

/// Create a session row and return its id.
pub fn createSession(
    self: *Database,
    project_id: i64,
    cwd: []const u8,
    model: []const u8,
) !i64 {
    const now = self.nowMs();
    var buffer: [public_id_chars + 4]u8 = undefined;
    const public_id = self.newPublicId(&buffer);

    try self.conn.exec(
        \\INSERT INTO session (project_id, created_at, updated_at, cwd, model, public_id)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , .{ project_id, now, now, cwd, model, public_id });
    return self.conn.lastInsertedRowId();
}

/// A fresh `ses_xxxxxxxx` handle, written into `buffer`. Randomness comes from
/// `Io` in 0.16, which is also what makes it testable.
fn newPublicId(self: *Database, buffer: []u8) []const u8 {
    @memcpy(buffer[0..4], "ses_");

    const body = buffer[4 .. 4 + public_id_chars];
    self.io.random(body);
    for (body) |*c| c.* = public_id_alphabet[c.* % public_id_alphabet.len];

    return buffer[0 .. 4 + public_id_chars];
}

/// The handle for a session, or "" when it predates handles.
pub fn sessionPublicId(self: *Database, session_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    const row = try self.conn.row("SELECT public_id FROM session WHERE id = ?", .{session_id}) orelse
        return allocator.dupe(u8, "");
    defer row.deinit();
    return allocator.dupe(u8, row.text(0));
}

/// One row of `session list`.
pub const SessionInfo = struct {
    id: i64,
    public_id: []const u8,
    title: []const u8,
    updated_at: i64,
    messages: u64,

    pub fn deinit(self: *const SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.public_id);
        allocator.free(self.title);
    }
};

/// Models this project has actually used, most recently first.
pub fn recentModels(
    self: *Database,
    allocator: std.mem.Allocator,
    project_id: i64,
    limit: usize,
) ![][]const u8 {
    var rows = try self.conn.rows(
        \\SELECT model, MAX(updated_at) AS used
        \\FROM session
        \\WHERE project_id = ? AND model IS NOT NULL AND model != ''
        \\GROUP BY model
        \\ORDER BY used DESC
        \\LIMIT ?
    , .{ project_id, @as(i64, @intCast(limit)) });
    defer rows.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |name| allocator.free(name);
        list.deinit(allocator);
    }
    while (rows.next()) |row| {
        try list.append(allocator, try allocator.dupe(u8, row.text(0)));
    }
    return list.toOwnedSlice(allocator);
}

/// Sessions for a project, newest first. Empty ones are skipped: every launch
/// creates a row, and a list of blank sessions is noise.
pub fn listSessions(
    self: *Database,
    allocator: std.mem.Allocator,
    project_id: i64,
    limit: usize,
) ![]SessionInfo {
    var rows = try self.conn.rows(
        \\SELECT s.id, s.public_id, s.title, s.updated_at, COUNT(m.id) AS messages
        \\FROM session s
        \\LEFT JOIN message m ON m.session_id = s.id
        \\WHERE s.project_id = ?
        \\GROUP BY s.id
        \\HAVING messages > 0
        \\ORDER BY s.updated_at DESC
        \\LIMIT ?
    , .{ project_id, @as(i64, @intCast(limit)) });
    defer rows.deinit();

    var list: std.ArrayList(SessionInfo) = .empty;
    errdefer {
        for (list.items) |info| info.deinit(allocator);
        list.deinit(allocator);
    }

    while (rows.next()) |row| {
        const public_id = try allocator.dupe(u8, row.text(1));
        errdefer allocator.free(public_id);
        try list.append(allocator, .{
            .id = row.int(0),
            .public_id = public_id,
            .title = try allocator.dupe(u8, row.text(2)),
            .updated_at = row.int(3),
            .messages = @intCast(row.int(4)),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// The session a `--session` handle names, within this project.
pub fn findSession(self: *Database, project_id: i64, public_id: []const u8) !?i64 {
    const row = try self.conn.row(
        "SELECT id FROM session WHERE project_id = ? AND public_id = ?",
        .{ project_id, public_id },
    ) orelse return null;
    defer row.deinit();
    return row.int(0);
}

/// The most recently touched session with anything in it, for `--continue`.
pub fn latestSession(self: *Database, project_id: i64) !?i64 {
    const row = try self.conn.row(
        \\SELECT s.id FROM session s
        \\WHERE s.project_id = ? AND EXISTS (SELECT 1 FROM message m WHERE m.session_id = s.id)
        \\ORDER BY s.updated_at DESC
        \\LIMIT 1
    , .{project_id}) orelse return null;
    defer row.deinit();
    return row.int(0);
}

/// How many messages a session holds.
pub fn countMessages(self: *Database, session_id: i64) !u64 {
    const row = try self.conn.row(
        "SELECT COUNT(*) FROM message WHERE session_id = ?",
        .{session_id},
    ) orelse return 0;
    defer row.deinit();
    return @intCast(row.int(0));
}

/// Delete a session and everything hanging off it.
pub fn deleteSession(self: *Database, session_id: i64) !void {
    try self.conn.exec("DELETE FROM session WHERE id = ?", .{session_id});
}

/// Append a message row and return its id. Heavy bodies (reasoning, tool
/// results) are written separately via `appendBlob` so a transcript load never
/// drags them in.
pub fn appendMessage(
    self: *Database,
    session_id: i64,
    seq: i64,
    role: []const u8,
    text: []const u8,
    thinking_ms: ?i64,
    thinking_bytes: i64,
) !i64 {
    try self.conn.exec(
        \\INSERT INTO message (session_id, seq, role, created_at, text, thinking_ms, thinking_bytes)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    , .{ session_id, seq, role, self.nowMs(), text, thinking_ms, thinking_bytes });
    return self.conn.lastInsertedRowId();
}

/// Append a heavy body (reasoning or tool result) to a message.
pub fn appendBlob(
    self: *Database,
    message_id: i64,
    seq: i64,
    kind: []const u8,
    body: []const u8,
) !void {
    try self.conn.exec(
        \\INSERT INTO blob (message_id, seq, kind, body) VALUES (?, ?, ?, ?)
    , .{ message_id, seq, kind, body });
}

/// Append a tool call row.
pub fn appendToolCall(
    self: *Database,
    message_id: i64,
    seq: i64,
    call_id: []const u8,
    name: []const u8,
    arguments: []const u8,
    status: []const u8,
    result: ?[]const u8,
    result_bytes: i64,
) !void {
    try self.conn.exec(
        \\INSERT INTO tool_call (message_id, seq, call_id, name, arguments, status, result, result_bytes)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    , .{ message_id, seq, call_id, name, arguments, status, result, result_bytes });
}

/// Record that a file was read at `read_at` (mtime nanoseconds), for the
/// staleness guard on `edit`.
pub fn recordRead(self: *Database, session_id: i64, path: []const u8, read_at: i64) !void {
    try self.conn.exec(
        \\INSERT INTO read_file (session_id, path, read_at) VALUES (?, ?, ?)
        \\ON CONFLICT(session_id, path) DO UPDATE SET read_at = excluded.read_at
    , .{ session_id, path, read_at });
}

/// The mtime (nanoseconds) recorded for the last read of `path`, if any.
pub fn lastRead(self: *Database, session_id: i64, path: []const u8) !?i64 {
    const row = try self.conn.row(
        "SELECT read_at FROM read_file WHERE session_id = ? AND path = ?",
        .{ session_id, path },
    ) orelse return null;
    defer row.deinit();
    return row.int(0);
}

/// Rename a session. An empty title means the session goes back to being shown
/// by its start time.
pub fn setSessionTitle(self: *Database, session_id: i64, title: []const u8) !void {
    try self.conn.exec(
        "UPDATE session SET title = ?, updated_at = ? WHERE id = ?",
        .{ title, self.nowMs(), session_id },
    );
}

/// Record the model a session is running under. Called on a switch, so
/// `recentModels` reflects what was actually used rather than what it started
/// with.
pub fn setSessionModel(self: *Database, session_id: i64, model: []const u8) !void {
    try self.conn.exec(
        "UPDATE session SET model = ?, updated_at = ? WHERE id = ?",
        .{ model, self.nowMs(), session_id },
    );
}

/// The model a session is recorded as running under, or "" when it has none.
pub fn sessionModel(self: *Database, session_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    const row = try self.conn.row("SELECT model FROM session WHERE id = ?", .{session_id}) orelse
        return allocator.dupe(u8, "");
    defer row.deinit();
    return allocator.dupe(u8, row.text(0));
}

/// Record the agent a session is running under, so resuming it comes back in
/// the same mode rather than in the default one.
pub fn setSessionAgent(self: *Database, session_id: i64, agent: []const u8) !void {
    try self.conn.exec(
        "UPDATE session SET agent = ? WHERE id = ?",
        .{ agent, session_id },
    );
}

/// The agent a session is recorded as running under, or "" when it has none.
pub fn sessionAgent(self: *Database, session_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    const row = try self.conn.row("SELECT agent FROM session WHERE id = ?", .{session_id}) orelse
        return allocator.dupe(u8, "");
    defer row.deinit();
    return allocator.dupe(u8, row.text(0));
}

/// The session's title, or "" when it has none.
pub fn sessionTitle(self: *Database, session_id: i64, allocator: std.mem.Allocator) ![]const u8 {
    const row = try self.conn.row("SELECT title FROM session WHERE id = ?", .{session_id}) orelse
        return allocator.dupe(u8, "");
    defer row.deinit();
    return allocator.dupe(u8, row.text(0));
}

/// Remember an "always allow" approval, scoped to the project.
/// The provider in use, or "" when none has been chosen. Caller owns the
/// result.
pub fn activeProvider(self: *Database, allocator: std.mem.Allocator) ![]const u8 {
    return self.setting(allocator, "provider");
}

pub fn setActiveProvider(self: *Database, id: []const u8) !void {
    try self.setSetting("provider", id);
}

/// The host a provider was last reached at, or "" when it has never been
/// connected - in which case the catalog's own host stands. Caller owns the
/// result.
pub fn providerHost(self: *Database, allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    const row = try self.conn.row("SELECT host FROM provider WHERE id = ?", .{id}) orelse
        return allocator.dupe(u8, "");
    defer row.deinit();
    return allocator.dupe(u8, row.text(0));
}

/// Remember where a provider was reached. Credentials are not here: they live
/// in `auth.json`, owner-only, because a database is a thing people copy about.
pub fn setProviderHost(self: *Database, id: []const u8, host: []const u8) !void {
    try self.conn.exec(
        \\INSERT INTO provider (id, host, updated_at) VALUES (?, ?, ?)
        \\ON CONFLICT(id) DO UPDATE SET host = excluded.host, updated_at = excluded.updated_at
    ,
        .{ id, host, self.nowMs() },
    );
}

/// A stored setting, or "" when unset. Caller owns the result.
pub fn setting(self: *Database, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const row = try self.conn.row("SELECT value FROM setting WHERE key = ?", .{key}) orelse
        return allocator.dupe(u8, "");
    defer row.deinit();
    return allocator.dupe(u8, row.text(0));
}

pub fn setSetting(self: *Database, key: []const u8, value: []const u8) !void {
    try self.conn.exec(
        \\INSERT INTO setting (key, value) VALUES (?, ?)
        \\ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ,
        .{ key, value },
    );
}

pub fn addApproval(self: *Database, project_id: i64, tool: []const u8, pattern: []const u8) !void {
    try self.conn.exec(
        \\INSERT INTO approval (project_id, tool, pattern) VALUES (?, ?, ?)
        \\ON CONFLICT(project_id, tool, pattern) DO NOTHING
    , .{ project_id, tool, pattern });
}

/// Whether `tool` is approved for `pattern` (or `*`) in this project.
pub fn isApproved(self: *Database, project_id: i64, tool: []const u8, pattern: []const u8) !bool {
    const row = try self.conn.row(
        \\SELECT 1 FROM approval
        \\WHERE project_id = ? AND tool = ?
        \\  AND (pattern = ?
        \\       OR pattern = '*'
        \\       OR (substr(pattern, length(pattern) - 1) = ' *'
        \\           AND substr(pattern, 1, length(pattern) - 2) = ?))
    , .{ project_id, tool, pattern, pattern });
    if (row) |r| {
        defer r.deinit();
        return true;
    }
    return false;
}

/// Base64 image bodies attached to a message, in the order they were pasted.
/// Caller owns the result and each body.
pub fn loadImages(self: *Database, allocator: std.mem.Allocator, message_id: i64) ![][]const u8 {
    var rows = try self.conn.rows(
        "SELECT body FROM blob WHERE message_id = ? AND kind = 'image' ORDER BY seq",
        .{message_id},
    );
    defer rows.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |body| allocator.free(body);
        list.deinit(allocator);
    }
    while (rows.next()) |row| {
        try list.append(allocator, try allocator.dupe(u8, row.text(0)));
    }
    return list.toOwnedSlice(allocator);
}

/// One remembered approval: a tool and the pattern it was approved for.
pub const Approval = struct {
    tool: []const u8,
    pattern: []const u8,

    pub fn deinit(self: *const Approval, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        allocator.free(self.pattern);
    }
};

/// Every approval remembered for this project. Used to seed the loop's
/// in-memory "always allow" list at session start.
pub fn approvals(self: *Database, project_id: i64, allocator: std.mem.Allocator) ![]Approval {
    var rows = try self.conn.rows(
        "SELECT tool, pattern FROM approval WHERE project_id = ?",
        .{project_id},
    );
    defer rows.deinit();

    var list: std.ArrayList(Approval) = .empty;
    errdefer {
        for (list.items) |approval| approval.deinit(allocator);
        list.deinit(allocator);
    }
    while (rows.next()) |row| {
        const tool = try allocator.dupe(u8, row.text(0));
        errdefer allocator.free(tool);
        try list.append(allocator, .{ .tool = tool, .pattern = try allocator.dupe(u8, row.text(1)) });
    }
    return list.toOwnedSlice(allocator);
}

/// Update a tool call's settled status and result.
pub fn updateToolCall(
    self: *Database,
    message_id: i64,
    seq: i64,
    status: []const u8,
    result: ?[]const u8,
    result_bytes: i64,
) !void {
    try self.conn.exec(
        "UPDATE tool_call SET status = ?, result = ?, result_bytes = ? WHERE message_id = ? AND seq = ?",
        .{ status, result, result_bytes, message_id, seq },
    );
}

/// Load up to `limit` messages with `seq < before_seq`, in descending order
/// (newest first), along with their tool calls and reasoning previews. The
/// caller reverses them before prepending. Owned by the caller; free each
/// message with `Conversation.Message.deinit`.
pub fn loadMessages(
    self: *Database,
    allocator: std.mem.Allocator,
    session_id: i64,
    before_seq: i64,
    limit: usize,
) ![]Conversation.Message {
    var rows = try self.conn.rows(
        \\SELECT id, seq, role, text, thinking_ms, thinking_bytes
        \\FROM message
        \\WHERE session_id = ? AND seq < ?
        \\ORDER BY seq DESC
        \\LIMIT ?
    , .{ session_id, before_seq, @as(i64, @intCast(limit)) });
    defer rows.deinit();

    var messages: std.ArrayList(Conversation.Message) = .empty;
    errdefer {
        for (messages.items) |*msg| msg.deinit(allocator);
        messages.deinit(allocator);
    }

    var loaded_images = false;

    while (rows.next()) |row| {
        const id = row.int(0);
        const seq = row.int(1);
        const role = try parseRole(row.text(2));
        const text = try allocator.dupe(u8, row.text(3));
        const thinking_ms: ?u64 = if (row.nullableInt(4)) |ms| @intCast(ms) else null;
        const thinking_bytes: u64 = @intCast(row.int(5));

        var msg: Conversation.Message = .{
            .seq = @intCast(seq),
            .role = role,
            .text = text,
            .thinking_ms = thinking_ms,
            .thinking_bytes = thinking_bytes,
        };
        errdefer msg.deinit(allocator);

        if (try self.loadBlob(allocator, id, 0, "reasoning")) |full| {
            const preview = try Conversation.preview(allocator, full);
            if (preview.ptr == full.ptr) {
                msg.thinking = full;
            } else {
                allocator.free(full);
                msg.thinking = preview;
            }
        }

        msg.tool_calls = try self.loadToolCalls(allocator, id);

        if (!loaded_images) {
            const images = try self.loadImages(allocator, id);
            if (images.len > 0) {
                msg.images = images;
                loaded_images = true;
            } else {
                allocator.free(images);
            }
        }

        try messages.append(allocator, msg);
    }

    return messages.toOwnedSlice(allocator);
}

/// Load the full reasoning body for a message, from the blob table. Returns
/// null when the message has no reasoning.
pub fn loadThinking(
    self: *Database,
    allocator: std.mem.Allocator,
    session_id: i64,
    seq: i64,
) !?[]const u8 {
    const row = try self.conn.row(
        \\SELECT b.body FROM blob b JOIN message m ON b.message_id = m.id
        \\WHERE m.session_id = ? AND m.seq = ? AND b.kind = 'reasoning' AND b.seq = 0
    , .{ session_id, seq }) orelse return null;
    defer row.deinit();
    return try allocator.dupe(u8, row.text(0));
}

/// Load the full result body for a tool call, from the blob table. Returns
/// null when the result was short enough to be stored inline (no blob).
pub fn loadToolResult(
    self: *Database,
    allocator: std.mem.Allocator,
    session_id: i64,
    seq: i64,
    call_seq: i64,
) !?[]const u8 {
    const row = try self.conn.row(
        \\SELECT b.body FROM blob b JOIN message m ON b.message_id = m.id
        \\WHERE m.session_id = ? AND m.seq = ? AND b.kind = 'tool_result' AND b.seq = ?
    , .{ session_id, seq, call_seq }) orelse return null;
    defer row.deinit();
    return try allocator.dupe(u8, row.text(0));
}

fn loadBlob(self: *Database, allocator: std.mem.Allocator, message_id: i64, seq: i64, kind: []const u8) !?[]const u8 {
    const row = try self.conn.row(
        "SELECT body FROM blob WHERE message_id = ? AND seq = ? AND kind = ?",
        .{ message_id, seq, kind },
    ) orelse return null;
    defer row.deinit();
    return try allocator.dupe(u8, row.text(0));
}

fn loadToolCalls(self: *Database, allocator: std.mem.Allocator, message_id: i64) ![]Conversation.ToolCall {
    var rows = try self.conn.rows(
        \\SELECT seq, call_id, name, arguments, status, result, result_bytes
        \\FROM tool_call WHERE message_id = ? ORDER BY seq
    , .{message_id});
    defer rows.deinit();

    var calls: std.ArrayList(Conversation.ToolCall) = .empty;
    errdefer {
        for (calls.items) |*call| call.deinit(allocator);
        calls.deinit(allocator);
    }

    while (rows.next()) |row| {
        const result_full = if (row.nullableText(5)) |r| try allocator.dupe(u8, r) else null;
        const result_bytes: u64 = @intCast(row.int(6));

        var result: ?[]const u8 = null;
        if (result_full) |full| {
            const preview = try Conversation.preview(allocator, full);
            if (preview.ptr == full.ptr) {
                result = full;
            } else {
                allocator.free(full);
                result = preview;
            }
        }

        try calls.append(allocator, .{
            .id = try allocator.dupe(u8, row.text(1)),
            .name = try allocator.dupe(u8, row.text(2)),
            .arguments = try allocator.dupe(u8, row.text(3)),
            .status = parseStatus(row.text(4)),
            .result = result,
            .result_bytes = result_bytes,
        });
    }

    return calls.toOwnedSlice(allocator);
}

fn parseRole(text: []const u8) !Conversation.Role {
    return std.meta.stringToEnum(Conversation.Role, text) orelse error.BadRole;
}

fn parseStatus(text: []const u8) Conversation.ToolCall.Status {
    return std.meta.stringToEnum(Conversation.ToolCall.Status, text) orelse .failed;
}

test "migrations bring a fresh database to the current version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ buf[0..n], "test.db" });
    defer std.testing.allocator.free(db_path);

    var db = try init(std.testing.allocator, std.testing.io, db_path);
    defer db.deinit();

    try std.testing.expectEqual(migrations.current, try db.userVersion());

    try db.conn.execNoArgs("SELECT 1 FROM project LIMIT 0");
    try db.conn.execNoArgs("SELECT 1 FROM session LIMIT 0");
    try db.conn.execNoArgs("SELECT 1 FROM message LIMIT 0");
    try db.conn.execNoArgs("SELECT 1 FROM blob LIMIT 0");
    try db.conn.execNoArgs("SELECT 1 FROM tool_call LIMIT 0");
    try db.conn.execNoArgs("SELECT 1 FROM read_file LIMIT 0");
    try db.conn.execNoArgs("SELECT 1 FROM approval LIMIT 0");
}

test "an older database is brought forward, keeping what it held" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const db_path = try std.fs.path.joinZ(testing.allocator, &.{ buf[0..n], "old.db" });
    defer testing.allocator.free(db_path);

    var session_id: i64 = undefined;
    {
        // A version 1 database: everything except the migration under test.
        var db: Database = .{
            .conn = try zqlite.open(db_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.NoMutex),
            .io = testing.io,
        };
        defer db.deinit();

        try db.conn.execNoArgs(migrations.all[0].sql);
        try db.setUserVersion(1);

        const project_id = try db.resolveProject("/repo", "git", "repo");
        session_id = try db.createSession(project_id, "/repo/src", "a-model");
    }

    var db = try init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    try testing.expectEqual(migrations.current, try db.userVersion());

    // The row written before the migration is still there, and reads back with
    // the new column at its default.
    const agent = try db.sessionAgent(session_id, testing.allocator);
    defer testing.allocator.free(agent);
    try testing.expectEqualStrings("", agent);

    const model = try db.sessionModel(session_id, testing.allocator);
    defer testing.allocator.free(model);
    try testing.expectEqualStrings("a-model", model);

    try db.setSessionAgent(session_id, "review");
    const after = try db.sessionAgent(session_id, testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("review", after);
}

test "reopening an existing database does not re-run migrations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ buf[0..n], "test.db" });
    defer std.testing.allocator.free(db_path);

    {
        var db = try init(std.testing.allocator, std.testing.io, db_path);
        defer db.deinit();
        try std.testing.expectEqual(migrations.current, try db.userVersion());
    }
    {
        var db = try init(std.testing.allocator, std.testing.io, db_path);
        defer db.deinit();
        try std.testing.expectEqual(migrations.current, try db.userVersion());
    }
}

test "project, session, message and approval round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ buf[0..n], "test.db" });
    defer std.testing.allocator.free(db_path);

    var db = try init(std.testing.allocator, std.testing.io, db_path);
    defer db.deinit();

    const project_id = try db.resolveProject("/repo", "git", "repo");
    try std.testing.expectEqual(project_id, try db.resolveProject("/repo", "git", "repo"));

    const session_id = try db.createSession(project_id, "/repo/src", "qwen3");

    const msg_id = try db.appendMessage(session_id, 0, "user", "hello", null, 0);
    try db.appendBlob(msg_id, 0, "reasoning", "thinking hard");
    try db.appendToolCall(msg_id, 0, "call_1", "read", "{\"path\":\"x\"}", "ok", "contents", 8);

    try db.recordRead(session_id, "/repo/x", 12345);
    try std.testing.expectEqual(@as(?i64, 12345), try db.lastRead(session_id, "/repo/x"));
    try std.testing.expectEqual(@as(?i64, null), try db.lastRead(session_id, "/repo/y"));

    try db.addApproval(project_id, "bash", "git status");
    try std.testing.expect(try db.isApproved(project_id, "bash", "git status"));
    try std.testing.expect(!try db.isApproved(project_id, "bash", "rm -rf"));
    try std.testing.expect(!try db.isApproved(project_id, "read", "git status"));

    try db.addApproval(project_id, "bash", "grep *");
    try std.testing.expect(try db.isApproved(project_id, "bash", "grep"));
    try std.testing.expect(!try db.isApproved(project_id, "bash", "rm -rf"));
    try db.addApproval(project_id, "bash", "xargs*");
    try std.testing.expect(!try db.isApproved(project_id, "bash", "xargs"));
    try std.testing.expect(try db.isApproved(project_id, "bash", "xargs*"));

    const other = try db.resolveProject("/other", "git", "other");
    try std.testing.expect(!try db.isApproved(other, "bash", "git status"));
}

test "loadMessages pages older messages back with tool calls and reasoning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ buf[0..n], "test.db" });
    defer std.testing.allocator.free(db_path);

    var db = try init(std.testing.allocator, std.testing.io, db_path);
    defer db.deinit();

    const project_id = try db.resolveProject("/repo", "git", "repo");
    const session_id = try db.createSession(project_id, "/repo", "qwen3");

    _ = try db.appendMessage(session_id, 0, "user", "hello", null, 0);
    const m1 = try db.appendMessage(session_id, 1, "assistant", "let me look", 42, 8);
    try db.appendBlob(m1, 0, "reasoning", "thinking");
    try db.appendToolCall(m1, 0, "call_1", "list", "{\"path\":\".\"}", "ok", "a\nb", 3);
    _ = try db.appendMessage(session_id, 2, "tool", "a\nb", null, 0);

    const loaded = try db.loadMessages(std.testing.allocator, session_id, 2, 10);
    defer {
        for (loaded) |*msg| msg.deinit(std.testing.allocator);
        std.testing.allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqual(@as(u64, 1), loaded[0].seq);
    try std.testing.expectEqual(Conversation.Role.assistant, loaded[0].role);
    try std.testing.expectEqualStrings("thinking", loaded[0].thinking.?);
    try std.testing.expectEqual(@as(?u64, 42), loaded[0].thinking_ms);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].tool_calls.len);
    try std.testing.expectEqualStrings("list", loaded[0].tool_calls[0].name);
    try std.testing.expectEqualStrings("a\nb", loaded[0].tool_calls[0].result.?);

    try std.testing.expectEqual(@as(u64, 0), loaded[1].seq);
    try std.testing.expectEqualStrings("hello", loaded[1].text);
}

test "long reasoning and tool results load as previews then full bodies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ buf[0..n], "test.db" });
    defer std.testing.allocator.free(db_path);

    var db = try init(std.testing.allocator, std.testing.io, db_path);
    defer db.deinit();

    const project_id = try db.resolveProject("/repo", "git", "repo");
    const session_id = try db.createSession(project_id, "/repo", "qwen3");

    const reasoning = "r" ** (Conversation.preview_bytes + 100);
    const result = "x" ** (Conversation.preview_bytes + 200);

    const m = try db.appendMessage(session_id, 0, "assistant", "done", 10, reasoning.len);
    try db.appendBlob(m, 0, "reasoning", reasoning);
    try db.appendToolCall(m, 0, "c", "bash", "{}", "ok", result, result.len);
    try db.appendBlob(m, 0, "tool_result", result);

    const loaded = try db.loadMessages(std.testing.allocator, session_id, 1, 10);
    defer {
        for (loaded) |*msg| msg.deinit(std.testing.allocator);
        std.testing.allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expect(loaded[0].thinking.?.len < reasoning.len);
    try std.testing.expectEqual(@as(u64, reasoning.len), loaded[0].thinking_bytes);
    try std.testing.expect(loaded[0].tool_calls[0].result.?.len < result.len);
    try std.testing.expectEqual(@as(u64, result.len), loaded[0].tool_calls[0].result_bytes);

    const full_thinking = try db.loadThinking(std.testing.allocator, session_id, 0);
    defer std.testing.allocator.free(full_thinking.?);
    try std.testing.expectEqualStrings(reasoning, full_thinking.?);

    const full_result = try db.loadToolResult(std.testing.allocator, session_id, 0, 0);
    defer std.testing.allocator.free(full_result.?);
    try std.testing.expectEqualStrings(result, full_result.?);
}

test "sessions get a handle, and are found by it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/h.db", .{buf[0..n]});
    defer std.testing.allocator.free(db_path);

    var db = try init(std.testing.allocator, std.testing.io, db_path);
    defer db.deinit();

    const project_id = try db.resolveProject("/tmp/project", "git", "project");
    const session_id = try db.createSession(project_id, "/tmp/project", "qwen3");

    const handle = try db.sessionPublicId(session_id, std.testing.allocator);
    defer std.testing.allocator.free(handle);
    try std.testing.expect(std.mem.startsWith(u8, handle, "ses_"));
    try std.testing.expectEqual(@as(usize, 12), handle.len);

    try std.testing.expectEqual(session_id, (try db.findSession(project_id, handle)).?);
    try std.testing.expect(try db.findSession(project_id, "ses_00000000") == null);

    try std.testing.expectEqual(@as(usize, 0), (try db.listSessions(std.testing.allocator, project_id, 10)).len);
    try std.testing.expect(try db.latestSession(project_id) == null);

    _ = try db.appendMessage(session_id, 0, "user", "hello", null, 0);
    try db.setSessionTitle(session_id, "first steps");

    const sessions = try db.listSessions(std.testing.allocator, project_id, 10);
    defer {
        for (sessions) |info| info.deinit(std.testing.allocator);
        std.testing.allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("first steps", sessions[0].title);
    try std.testing.expectEqual(@as(u64, 1), sessions[0].messages);
    try std.testing.expectEqual(session_id, (try db.latestSession(project_id)).?);

    try db.deleteSession(session_id);
    try std.testing.expect(try db.findSession(project_id, handle) == null);
}

test "deleting a session takes its messages, blobs and tool calls with it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/h.db", .{buf[0..n]});
    defer std.testing.allocator.free(db_path);

    var db = try init(std.testing.allocator, std.testing.io, db_path);
    defer db.deinit();

    const project_id = try db.resolveProject("/tmp/project", "git", "project");
    const session_id = try db.createSession(project_id, "/tmp/project", "qwen3");

    const message_id = try db.appendMessage(session_id, 0, "assistant", "hi", 12, 4);
    try db.appendBlob(message_id, 0, "reasoning", "a long thought");
    try db.appendToolCall(message_id, 0, "1", "bash", "{}", "ok", "output", 6);
    try db.recordRead(session_id, "/tmp/project/a.zig", 1234);

    try db.deleteSession(session_id);

    try std.testing.expectEqual(@as(u64, 0), try db.countMessages(session_id));
    try std.testing.expect(try db.conn.row("SELECT 1 FROM blob WHERE message_id = ?", .{message_id}) == null);
    try std.testing.expect(try db.conn.row("SELECT 1 FROM tool_call WHERE message_id = ?", .{message_id}) == null);
    try std.testing.expect(try db.conn.row("SELECT 1 FROM read_file WHERE session_id = ?", .{session_id}) == null);
}

test "the chosen provider and its host outlive the process" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const db_path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "providers.db" });
    defer testing.allocator.free(db_path);

    {
        var db = try init(testing.allocator, testing.io, db_path);
        defer db.deinit();

        const none = try db.activeProvider(testing.allocator);
        defer testing.allocator.free(none);
        try testing.expectEqualStrings("", none);

        const no_host = try db.providerHost(testing.allocator, "ollama");
        defer testing.allocator.free(no_host);
        try testing.expectEqualStrings("", no_host);

        try db.setProviderHost("ollama", "http://box:11434");
        try db.setActiveProvider("ollama");

        try db.setProviderHost("ollama", "http://other:11434");
    }

    var db = try init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    const active = try db.activeProvider(testing.allocator);
    defer testing.allocator.free(active);
    try testing.expectEqualStrings("ollama", active);

    const host = try db.providerHost(testing.allocator, "ollama");
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("http://other:11434", host);

    try db.setProviderHost("ollama-cloud", "https://ollama.com");
    try db.setActiveProvider("ollama-cloud");

    const kept = try db.providerHost(testing.allocator, "ollama");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("http://other:11434", kept);
}

test "a chosen theme outlives the process" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const db_path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "theme.db" });
    defer testing.allocator.free(db_path);

    {
        var db = try init(testing.allocator, testing.io, db_path);
        defer db.deinit();

        const none = try db.setting(testing.allocator, "theme");
        defer testing.allocator.free(none);
        try testing.expectEqualStrings("", none);

        try db.setSetting("theme", "gruvbox");
        try db.setSetting("theme", "nord");
    }

    var db = try init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    const stored = try db.setting(testing.allocator, "theme");
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings("nord", stored);
}
