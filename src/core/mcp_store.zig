//! MCP sign-ins and on/off choices, kept in `synth.db` a server at a time.
//!
//! On a connection of its own, behind a lock: a server is signed in to from
//! the worker that connects it as well as from the session's thread, and the
//! session's connection is that thread's alone.

const std = @import("std");

const mcp = @import("mcp");

const Database = @import("database.zig");

const McpStore = @This();

allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
db: Database,

/// Bring in `legacy_file` if it has not been already: where sign-ins were
/// kept before.
pub fn open(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, legacy_file: ?[]const u8) !*McpStore {
    const self = try allocator.create(McpStore);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .db = try Database.init(allocator, io, db_path) };
    errdefer self.db.deinit();
    if (legacy_file) |path| try self.importFile(path);
    return self;
}

pub fn close(self: *McpStore) void {
    self.db.deinit();
    self.allocator.destroy(self);
}

/// Every server's entry as stored now, for a session to work from.
pub fn load(self: *McpStore) !mcp.Auth {
    return mcp.Auth.open(self.allocator, self.storage());
}

pub fn storage(self: *McpStore) mcp.Auth.Storage {
    return .{ .context = self, .readAll = readAll, .read = read, .write = write };
}

const imported_setting = "mcp_auth_file_imported";

/// Copy the file's entries in, once. The file is left where it is, for an
/// older build to go on reading. One that will not parse is as good as
/// empty: an older build could not use it either.
fn importFile(self: *McpStore, path: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    const done = self.db.setting(self.allocator, imported_setting);
    self.mutex.unlock(self.io);
    const flag = try done;
    defer self.allocator.free(flag);
    if (flag.len > 0) return;

    var file = mcp.Auth.readFile(self.allocator, self.io, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => mcp.Auth.init(self.allocator),
    };
    defer file.deinit();
    file.storage = self.storage();
    for (file.entries.keys()) |name| try file.save(name);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.db.setSetting(imported_setting, "1");
}

fn readAll(context: *anyopaque, arena: std.mem.Allocator) anyerror![]const mcp.Auth.Storage.Stored {
    const self: *McpStore = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const rows = try self.db.mcpAuthEntries(arena);
    const out = try arena.alloc(mcp.Auth.Storage.Stored, rows.len);
    for (rows, out) |row, *stored| stored.* = .{ .name = row.name, .encoded = row.entry };
    return out;
}

fn read(context: *anyopaque, arena: std.mem.Allocator, mcp_name: []const u8) anyerror!?[]const u8 {
    const self: *McpStore = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.db.mcpAuthEntry(arena, mcp_name);
}

fn write(context: *anyopaque, mcp_name: []const u8, encoded: ?[]const u8) anyerror!void {
    const self: *McpStore = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.db.setMcpAuthEntry(mcp_name, encoded);
}

const testing = std.testing;

test "sign-ins come in from the old file once, and each server is stored alone" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mcp-auth.json", .data =
        \\{"linear":{"tokens":{"access_token":"from-file"}},"files":{"enabled":false}}
    });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const db_path = try std.fs.path.join(testing.allocator, &.{ root, "synth.db" });
    defer testing.allocator.free(db_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ root, "mcp-auth.json" });
    defer testing.allocator.free(file_path);

    const first = try McpStore.open(testing.allocator, io, db_path, file_path);
    defer first.close();
    var mine = try first.load();
    defer mine.deinit();
    try testing.expectEqualStrings("from-file", mine.get("linear").?.tokens.?.access_token);
    try testing.expect(!mine.isEnabled("files"));

    try tmp.dir.writeFile(io, .{ .sub_path = "mcp-auth.json", .data = "{\"late\":{\"tokens\":{\"access_token\":\"x\"}}}" });
    const second = try McpStore.open(testing.allocator, io, db_path, file_path);
    defer second.close();
    var theirs = try second.load();
    defer theirs.deinit();
    try testing.expect(theirs.get("late") == null);

    try theirs.setEnabled("files", true);
    try theirs.save("files");
    try mine.updateTokens("linear", .{ .access_token = "refreshed" }, null);
    try mine.save("linear");

    var after = try first.load();
    defer after.deinit();
    try testing.expectEqualStrings("refreshed", after.get("linear").?.tokens.?.access_token);
    try testing.expect(after.isEnabled("files"));
}
