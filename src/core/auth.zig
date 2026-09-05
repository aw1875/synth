//! Credentials for the providers the harness can talk to.

const std = @import("std");
const builtin = @import("builtin");

const pkg = @import("pkg");

const Auth = @This();

/// How a provider is authenticated. One kind today; the tag is stored so a
/// second one can be told apart from it later.
pub const Kind = enum { api };

pub const Credential = struct {
    kind: Kind = .api,
    /// The secret itself. Empty is a credential that was recorded and then
    /// cleared, which is not the same as never having had one - the entry is
    /// dropped instead, so `get` cannot hand back a blank key.
    key: []const u8 = "",
};

/// Largest auth file we will read. Keys are short; anything this size is not
/// one.
const max_file_bytes: std.Io.Limit = .limited(64 * 1024);

/// Owner-only, since the whole point of this file is that it holds secrets.
/// The Windows `Permissions` is a different enum with no mode to set, so it
/// falls back to the default there.
const owner_only: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    .fromMode(0o600)
else
    .default_file;

/// Backing storage for every id and key below.
arena: std.heap.ArenaAllocator,
entries: std.StringArrayHashMapUnmanaged(Credential) = .empty,
io: std.Io,
mutex: std.Io.Mutex = .init,
/// The file this was read from, and the one `save` writes back to. Empty for a
/// store built in memory.
path: []const u8 = "",

/// Resolve `auth.json`: beside the database, in the data directory, not beside
/// the config. It is state the program writes, not something a person edits.
/// Owned by the caller.
pub fn defaultPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (builtin.mode == .Debug) return allocator.dupe(u8, "auth.json");
    const base = env.get("XDG_DATA_HOME") orelse blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    };
    defer if (env.get("XDG_DATA_HOME") == null) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, pkg.name, "auth.json" });
}

/// Resolve the path and read it. The one way in, matching `Config.open`.
pub fn open(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !Auth {
    const path = try defaultPath(allocator, env);
    defer allocator.free(path);
    return load(allocator, io, path);
}

pub fn init(allocator: std.mem.Allocator, io: std.Io) Auth {
    return .{ .arena = .init(allocator), .io = io };
}

pub fn deinit(self: *Auth) void {
    self.arena.deinit();
}

/// Read `path`. A missing file is an empty store, not an error: a harness that
/// only talks to a local server never has one.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Auth {
    var self: Auth = .init(allocator, io);
    errdefer self.deinit();

    const arena = self.arena.allocator();
    self.path = try arena.dupe(u8, path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return self,
        else => return err,
    };

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    const object = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidAuthFile,
    };

    var it = object.iterator();
    while (it.next()) |entry| {
        const fields = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        const secret = switch (fields.get("key") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (secret.len == 0) continue;

        const kind: Kind = switch (fields.get("type") orelse std.json.Value{ .string = "api" }) {
            .string => |s| std.meta.stringToEnum(Kind, s) orelse continue,
            else => continue,
        };

        try self.entries.put(arena, entry.key_ptr.*, .{ .kind = kind, .key = secret });
    }

    return self;
}

/// The credential for a provider, or null when it has none.
pub fn get(self: *Auth, provider_id: []const u8) ?Credential {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.entries.get(provider_id);
}

/// The key for a provider, or null. What every caller actually wants.
pub fn key(self: *Auth, provider_id: []const u8) ?[]const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const credential = self.entries.get(provider_id) orelse return null;
    return credential.key;
}

/// Record a key, replacing whatever was there. An empty key removes the entry
/// instead: "no credential" is a state worth being able to get back to.
pub fn set(self: *Auth, provider_id: []const u8, secret: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const removes_credential = secret.len == 0;
    if (removes_credential) {
        _ = self.entries.orderedRemove(provider_id);
        return;
    }

    const arena = self.arena.allocator();
    const result = try self.entries.getOrPut(arena, provider_id);
    if (!result.found_existing) result.key_ptr.* = try arena.dupe(u8, provider_id);
    result.value_ptr.* = .{ .kind = .api, .key = try arena.dupe(u8, secret) };
}

pub fn remove(self: *Auth, provider_id: []const u8) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.entries.orderedRemove(provider_id);
}

/// Write the store to `path`, atomically and owner-only.
pub fn save(self: *Auth, io: std.Io, path: []const u8) !void {
    const Config = @import("config.zig");
    try Config.ensureDir(io, path);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const temporary_suffix = std.fmt.bytesToHex(random_bytes, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = std.fmt.bufPrint(&temp_buffer, "{s}.{s}.tmp", .{ path, temporary_suffix }) catch return error.NameTooLong;

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .permissions = owner_only });
        errdefer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        defer file.close(io);

        var buffer: [1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try self.writeJsonUnlocked(&writer.interface);
        try writer.interface.flush();
        try file.sync(io);
    }
    errdefer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};

    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, io);
}

/// Serialize the store. Split out from `save` so a test can read it without
/// touching a filesystem.
fn writeJson(self: *Auth, writer: *std.Io.Writer) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.writeJsonUnlocked(writer);
}

fn writeJsonUnlocked(self: *const Auth, writer: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try json.beginObject();
    var it = self.entries.iterator();
    while (it.next()) |entry| {
        try json.objectField(entry.key_ptr.*);
        try json.beginObject();
        try json.objectField("type");
        try json.write(@tagName(entry.value_ptr.kind));
        try json.objectField("key");
        try json.write(entry.value_ptr.key);
        try json.endObject();
    }
    try json.endObject();
    try writer.writeByte('\n');
}

test "a missing auth file is an empty store" {
    const testing = std.testing;

    var auth = try load(testing.allocator, testing.io, "definitely-not-a-real-auth.json");
    defer auth.deinit();

    try testing.expectEqual(@as(usize, 0), auth.entries.count());
    try testing.expect(auth.key("ollama-cloud") == null);
}

test "credentials survive a save and a load" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "auth.json" });
    defer testing.allocator.free(path);

    {
        var auth: Auth = .init(testing.allocator, testing.io);
        defer auth.deinit();
        try auth.set("ollama-cloud", "sk-secret");
        try auth.save(io, path);
    }

    var auth = try load(testing.allocator, io, path);
    defer auth.deinit();

    try testing.expectEqualStrings("sk-secret", auth.key("ollama-cloud").?);
    try testing.expectEqual(Kind.api, auth.get("ollama-cloud").?.kind);

    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "the file is the shape it says it is" {
    const testing = std.testing;

    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    try auth.set("ollama", "local-key");
    try auth.set("ollama-cloud", "cloud-key");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try auth.writeJson(&out.writer);

    try testing.expectEqualStrings(
        \\{
        \\  "ollama": {
        \\    "type": "api",
        \\    "key": "local-key"
        \\  },
        \\  "ollama-cloud": {
        \\    "type": "api",
        \\    "key": "cloud-key"
        \\  }
        \\}
        \\
    , out.written());
}

test "an empty key clears the entry rather than storing a blank one" {
    const testing = std.testing;

    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    try auth.set("ollama-cloud", "sk-secret");
    try auth.set("ollama-cloud", "");

    try testing.expect(auth.key("ollama-cloud") == null);
    try testing.expectEqual(@as(usize, 0), auth.entries.count());

    try auth.set("ollama-cloud", "one");
    try auth.set("ollama-cloud", "two");
    try testing.expectEqual(@as(usize, 1), auth.entries.count());
    try testing.expectEqualStrings("two", auth.key("ollama-cloud").?);
}

test "a hand-written auth file is read the way it was written" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "auth.json" });
    defer testing.allocator.free(path);

    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data =
        \\{
        \\  "ollama-cloud": {"type": "api", "key": "from-hand"},
        \\  "future-thing": {"type": "oauth", "key": "..."},
        \\  "blank": {"type": "api", "key": ""}
        \\}
        ,
    });

    var auth = try load(testing.allocator, io, path);
    defer auth.deinit();

    try testing.expectEqualStrings("from-hand", auth.key("ollama-cloud").?);
    try testing.expect(auth.key("future-thing") == null);
    try testing.expect(auth.key("blank") == null);
}
