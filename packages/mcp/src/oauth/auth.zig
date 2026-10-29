//! Per-MCP-server OAuth state.
//!
//! Each entry holds the tokens, registered client info, and in-flight OAuth
//! handshake pieces (PKCE verifier, CSRF state) keyed by MCP server name.
//!
//! Where entries are kept between runs is the caller's decision, given as a
//! `Storage`; nothing here knows a path, a database or the program's name.
//! That is what keeps the module `std`-and-`oauth2` only. Entries are written
//! one server at a time, so processes sharing a storage each change only what
//! they touched.
//!
//! An entry is encoded in the shape of opencode's `mcp-auth.json`, and
//! `readFile` reads such a file, to bring one in.

const std = @import("std");

const Auth = @This();

const max_file_bytes: std.Io.Limit = .limited(256 * 1024);

pub const Tokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    /// Unix seconds at which `access_token` stops working.
    expires_at: ?i64 = null,
    scope: ?[]const u8 = null,
};

pub const ClientInfo = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    client_id_issued_at: ?i64 = null,
    client_secret_expires_at: ?i64 = null,
};

pub const Entry = struct {
    /// The URL the cached entry was minted for. Stale entries (a server moved
    /// hosts) are treated as no entry, so a `bind` for the same MCP name
    /// against a new URL re-auths from scratch.
    server_url: ?[]const u8 = null,
    tokens: ?Tokens = null,
    client_info: ?ClientInfo = null,
    /// PKCE verifier for an in-flight authorization request. Cleared once the
    /// exchange completes.
    code_verifier: ?[]const u8 = null,
    /// CSRF state for the in-flight authorization request. Same lifecycle as
    /// `code_verifier`.
    oauth_state: ?[]const u8 = null,
    /// The loopback URI `client_info` was registered against.
    redirect_uri: ?[]const u8 = null,
    /// Whether this server is used at all. Null means nobody has said, which
    /// reads as enabled: a server listed in the config is meant to run unless
    /// it has been turned off on purpose.
    enabled: ?bool = null,
};

/// Where entries outlive the process, a server at a time, each encoded as a
/// JSON object.
pub const Storage = struct {
    context: *anyopaque,
    /// Every server's entry stored, in `arena`.
    readAll: *const fn (context: *anyopaque, arena: std.mem.Allocator) anyerror![]const Stored,
    /// One server's entry, in `arena`, or null when none is stored.
    read: *const fn (context: *anyopaque, arena: std.mem.Allocator, mcp_name: []const u8) anyerror!?[]const u8,
    /// Replace one server's entry, or remove it when `encoded` is null.
    write: *const fn (context: *anyopaque, mcp_name: []const u8, encoded: ?[]const u8) anyerror!void,

    pub const Stored = struct { name: []const u8, encoded: []const u8 };
};

arena: std.heap.ArenaAllocator,
entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
/// Null keeps entries in memory only, and `save` refuses.
storage: ?Storage = null,

pub fn init(allocator: std.mem.Allocator) Auth {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Auth) void {
    self.arena.deinit();
}

/// The store `storage` keeps, holding what it holds now. An entry that will
/// not decode is skipped: it should cost that server, not every other one.
pub fn open(allocator: std.mem.Allocator, storage: Storage) !Auth {
    var self: Auth = .init(allocator);
    errdefer self.deinit();
    self.storage = storage;

    const arena = self.arena.allocator();
    for (try storage.readAll(storage.context, arena)) |stored| {
        const entry = decode(arena, stored.encoded) catch continue;
        (try self.reserve(stored.name)).* = entry;
    }
    return self;
}

/// Write `mcp_name`'s entry to storage as it stands here, or remove it there
/// when it is gone here. Every other server's entry is left as stored.
pub fn save(self: *const Auth, mcp_name: []const u8) !void {
    const storage = self.storage orelse return error.NoStorage;
    const entry = self.entries.get(mcp_name) orelse return storage.write(storage.context, mcp_name, null);
    var out: std.Io.Writer.Allocating = .init(self.arena.child_allocator);
    defer out.deinit();
    try encode(entry, &out.writer);
    try storage.write(storage.context, mcp_name, out.written());
}

/// Take up `mcp_name`'s entry as stored now: another process sharing the
/// storage may have refreshed its tokens since this one read them, and a
/// server that rotates refresh tokens refuses the old one.
pub fn reload(self: *Auth, mcp_name: []const u8) !void {
    const storage = self.storage orelse return;
    const arena = self.arena.allocator();
    const encoded = try storage.read(storage.context, arena, mcp_name) orelse return;
    (try self.reserve(mcp_name)).* = try decode(arena, encoded);
}

fn decode(arena: std.mem.Allocator, encoded: []const u8) !Entry {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{});
    return switch (parsed) {
        .object => |fields| parseEntry(arena, fields),
        else => error.InvalidEntry,
    };
}

fn encode(entry: Entry, out: *std.Io.Writer) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try writeJsonEntry(entry, &json);
}

/// The entries in a JSON file of opencode's `mcp-auth.json` shape, kept in
/// memory: a missing file is an empty store.
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Auth {
    var self: Auth = .init(allocator);
    errdefer self.deinit();

    const arena = self.arena.allocator();
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
        const e = parseEntry(arena, fields) catch continue;
        const result = try self.entries.getOrPut(arena, entry.key_ptr.*);
        if (!result.found_existing) result.key_ptr.* = try arena.dupe(u8, entry.key_ptr.*);
        result.value_ptr.* = e;
    }

    return self;
}

fn parseEntry(arena: std.mem.Allocator, fields: std.json.ObjectMap) !Entry {
    var e: Entry = .{
        .server_url = try optString(arena, fields, "server_url"),
        .code_verifier = try optString(arena, fields, "code_verifier"),
        .oauth_state = try optString(arena, fields, "oauth_state"),
        .redirect_uri = try optString(arena, fields, "redirect_uri"),
        .enabled = switch (fields.get("enabled") orelse std.json.Value{ .null = {} }) {
            .bool => |b| b,
            else => null,
        },
    };
    if (fields.get("tokens")) |v| {
        if (v == .object) e.tokens = try parseTokens(arena, v.object);
    }
    if (fields.get("client_info")) |v| {
        if (v == .object) e.client_info = try parseClientInfo(arena, v.object);
    }
    return e;
}

fn parseTokens(arena: std.mem.Allocator, fields: std.json.ObjectMap) !Tokens {
    return .{
        .access_token = try optString(arena, fields, "access_token") orelse return error.MissingField,
        .refresh_token = try optString(arena, fields, "refresh_token"),
        .expires_at = optInt(fields, "expires_at"),
        .scope = try optString(arena, fields, "scope"),
    };
}

fn parseClientInfo(arena: std.mem.Allocator, fields: std.json.ObjectMap) !ClientInfo {
    return .{
        .client_id = try optString(arena, fields, "client_id") orelse return error.MissingField,
        .client_secret = try optString(arena, fields, "client_secret"),
        .client_id_issued_at = optInt(fields, "client_id_issued_at"),
        .client_secret_expires_at = optInt(fields, "client_secret_expires_at"),
    };
}

/// A string field, copied into `arena`. Anything that is present but not a
/// string reads as absent: a malformed field should cost the one value, not
/// the whole file.
fn optString(arena: std.mem.Allocator, fields: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = fields.get(name) orelse return null;
    if (value != .string) return null;
    return try arena.dupe(u8, value.string);
}

/// A unix-seconds field. Servers have been seen sending these as JSON numbers
/// and as strings, so both are read.
fn optInt(fields: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = fields.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

pub fn get(self: *const Auth, mcp_name: []const u8) ?Entry {
    return self.entries.get(mcp_name);
}

pub fn getForUrl(self: *const Auth, mcp_name: []const u8, server_url: []const u8) ?Entry {
    const entry = self.entries.get(mcp_name) orelse return null;
    if (entry.server_url) |cached| {
        if (!std.mem.eql(u8, cached, server_url)) return null;
    }
    return entry;
}

pub fn set(self: *Auth, mcp_name: []const u8, entry: Entry, server_url: ?[]const u8) !void {
    const arena = self.arena.allocator();
    const result = try self.entries.getOrPut(arena, mcp_name);
    if (!result.found_existing) result.key_ptr.* = try arena.dupe(u8, mcp_name);
    var stored = entry;
    if (server_url) |u| stored.server_url = try arena.dupe(u8, u);
    result.value_ptr.* = stored;
}

/// Whether `mcp_name` should be connected. Unknown servers are enabled: the
/// config listing one is the decision, and this file only records departures
/// from it.
pub fn isEnabled(self: *const Auth, mcp_name: []const u8) bool {
    const entry = self.entries.get(mcp_name) orelse return true;
    return entry.enabled orelse true;
}

pub fn setEnabled(self: *Auth, mcp_name: []const u8, enabled: bool) !void {
    const entry = try self.reserve(mcp_name);
    entry.enabled = enabled;
}

/// Drop everything about being signed in, keeping the entry itself. Used by a
/// logout: the tokens go, the decision about whether the server is used at all
/// stays, because they are answers to different questions.
pub fn forget(self: *Auth, mcp_name: []const u8) void {
    const entry = self.entries.getPtr(mcp_name) orelse return;
    entry.tokens = null;
    entry.client_info = null;
    entry.redirect_uri = null;
    entry.code_verifier = null;
    entry.oauth_state = null;
}

pub fn remove(self: *Auth, mcp_name: []const u8) bool {
    return self.entries.orderedRemove(mcp_name);
}

pub fn updateTokens(self: *Auth, mcp_name: []const u8, tokens: Tokens, server_url: ?[]const u8) !void {
    const arena = self.arena.allocator();
    const entry = try self.reserve(mcp_name);
    entry.tokens = .{
        .access_token = try arena.dupe(u8, tokens.access_token),
        .refresh_token = if (tokens.refresh_token) |t| try arena.dupe(u8, t) else null,
        .expires_at = tokens.expires_at,
        .scope = if (tokens.scope) |s| try arena.dupe(u8, s) else null,
    };
    if (server_url) |u| entry.server_url = try arena.dupe(u8, u);
}

pub fn updateClientInfo(self: *Auth, mcp_name: []const u8, info: ClientInfo, server_url: ?[]const u8) !void {
    const arena = self.arena.allocator();
    const entry = try self.reserve(mcp_name);
    entry.client_info = .{
        .client_id = try arena.dupe(u8, info.client_id),
        .client_secret = if (info.client_secret) |s| try arena.dupe(u8, s) else null,
        .client_id_issued_at = info.client_id_issued_at,
        .client_secret_expires_at = info.client_secret_expires_at,
    };
    if (server_url) |u| entry.server_url = try arena.dupe(u8, u);
}

/// Remember which loopback URI a client was registered against, so a later
/// flow can ask for the same port and reuse the registration instead of
/// leaving a fresh dead client behind on the authorization server.
pub fn updateRedirectUri(self: *Auth, mcp_name: []const u8, redirect_uri: []const u8) !void {
    const entry = try self.reserve(mcp_name);
    entry.redirect_uri = try self.arena.allocator().dupe(u8, redirect_uri);
}

/// The entry for `mcp_name`, created empty if this is the first thing known
/// about that server. Every `update*` goes through here so that none of them
/// can silently do nothing for a server that has not been seen before, which
/// is the normal case at the start of an authorization flow.
fn reserve(self: *Auth, mcp_name: []const u8) !*Entry {
    const arena = self.arena.allocator();
    const result = try self.entries.getOrPut(arena, mcp_name);
    if (!result.found_existing) {
        result.key_ptr.* = try arena.dupe(u8, mcp_name);
        result.value_ptr.* = .{};
    }
    return result.value_ptr;
}

pub fn updateCodeVerifier(self: *Auth, mcp_name: []const u8, verifier: []const u8) !void {
    const entry = try self.reserve(mcp_name);
    entry.code_verifier = try self.arena.allocator().dupe(u8, verifier);
}

pub fn clearCodeVerifier(self: *Auth, mcp_name: []const u8) void {
    if (self.entries.getPtr(mcp_name)) |e| e.code_verifier = null;
}

pub fn updateOAuthState(self: *Auth, mcp_name: []const u8, state: []const u8) !void {
    const entry = try self.reserve(mcp_name);
    entry.oauth_state = try self.arena.allocator().dupe(u8, state);
}

pub fn clearOAuthState(self: *Auth, mcp_name: []const u8) void {
    if (self.entries.getPtr(mcp_name)) |e| e.oauth_state = null;
}

fn writeJsonEntry(entry: Entry, json: *std.json.Stringify) !void {
    try json.beginObject();
    if (entry.server_url) |u| {
        try json.objectField("server_url");
        try json.write(u);
    }
    if (entry.tokens) |t| {
        try json.objectField("tokens");
        try writeJsonTokens(t, json);
    }
    if (entry.client_info) |ci| {
        try json.objectField("client_info");
        try writeJsonClientInfo(ci, json);
    }
    if (entry.code_verifier) |v| {
        try json.objectField("code_verifier");
        try json.write(v);
    }
    if (entry.oauth_state) |s| {
        try json.objectField("oauth_state");
        try json.write(s);
    }
    if (entry.redirect_uri) |u| {
        try json.objectField("redirect_uri");
        try json.write(u);
    }
    if (entry.enabled) |on| {
        try json.objectField("enabled");
        try json.write(on);
    }
    try json.endObject();
}

fn writeJsonTokens(tokens: Tokens, json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("access_token");
    try json.write(tokens.access_token);
    if (tokens.refresh_token) |r| {
        try json.objectField("refresh_token");
        try json.write(r);
    }
    if (tokens.expires_at) |e| {
        try json.objectField("expires_at");
        try json.write(e);
    }
    if (tokens.scope) |s| {
        try json.objectField("scope");
        try json.write(s);
    }
    try json.endObject();
}

fn writeJsonClientInfo(info: ClientInfo, json: *std.json.Stringify) !void {
    try json.beginObject();
    try json.objectField("client_id");
    try json.write(info.client_id);
    if (info.client_secret) |s| {
        try json.objectField("client_secret");
        try json.write(s);
    }
    if (info.client_id_issued_at) |t| {
        try json.objectField("client_id_issued_at");
        try json.write(t);
    }
    if (info.client_secret_expires_at) |t| {
        try json.objectField("client_secret_expires_at");
        try json.write(t);
    }
    try json.endObject();
}

const testing = std.testing;

/// A storage in memory, standing in for a database two processes share.
const Shared = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn deinit(self: *Shared) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit(testing.allocator);
    }

    fn storage(self: *Shared) Storage {
        return .{ .context = self, .readAll = readAll, .read = read, .write = write };
    }

    fn readAll(context: *anyopaque, arena: std.mem.Allocator) anyerror![]const Storage.Stored {
        const self: *Shared = @ptrCast(@alignCast(context));
        const out = try arena.alloc(Storage.Stored, self.entries.count());
        for (self.entries.keys(), self.entries.values(), out) |name, encoded, *stored| {
            stored.* = .{ .name = try arena.dupe(u8, name), .encoded = try arena.dupe(u8, encoded) };
        }
        return out;
    }

    fn read(context: *anyopaque, arena: std.mem.Allocator, mcp_name: []const u8) anyerror!?[]const u8 {
        const self: *Shared = @ptrCast(@alignCast(context));
        return try arena.dupe(u8, self.entries.get(mcp_name) orelse return null);
    }

    fn write(context: *anyopaque, mcp_name: []const u8, encoded: ?[]const u8) anyerror!void {
        const self: *Shared = @ptrCast(@alignCast(context));
        if (self.entries.fetchOrderedRemove(mcp_name)) |gone| {
            testing.allocator.free(gone.key);
            testing.allocator.free(gone.value);
        }
        const kept = encoded orelse return;
        try self.entries.put(testing.allocator, try testing.allocator.dupe(u8, mcp_name), try testing.allocator.dupe(u8, kept));
    }
};

test "a missing mcp-auth file is an empty store" {
    var auth = try readFile(testing.allocator, testing.io, "definitely-not-a-real-mcp-auth.json");
    defer auth.deinit();

    try testing.expectEqual(@as(usize, 0), auth.entries.count());
    try testing.expect(auth.get("files") == null);
}

test "a file of opencode's shape is read, and a malformed entry costs only itself" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mcp-auth.json", .data =
        \\{"rh-trading":{"server_url":"https://api.example/mcp","tokens":{"access_token":"sk-token","expires_at":"1234567890"},"enabled":false},
        \\ "broken":{"tokens":{"refresh_token":"no access token"}}}
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "mcp-auth.json" });
    defer testing.allocator.free(path);

    var auth = try readFile(testing.allocator, io, path);
    defer auth.deinit();
    const e = auth.getForUrl("rh-trading", "https://api.example/mcp").?;
    try testing.expectEqualStrings("sk-token", e.tokens.?.access_token);
    try testing.expectEqual(@as(i64, 1234567890), e.tokens.?.expires_at.?);
    try testing.expect(!auth.isEnabled("rh-trading"));
    try testing.expect(auth.get("broken") == null);
}

test "tokens survive a save and an open" {
    var shared: Shared = .{};
    defer shared.deinit();

    {
        var auth = try open(testing.allocator, shared.storage());
        defer auth.deinit();
        try auth.updateTokens("rh-trading", .{
            .access_token = "sk-token",
            .refresh_token = "sk-refresh",
            .expires_at = 1234567890,
            .scope = "read write",
        }, "https://api.example/mcp");
        try auth.updateClientInfo("rh-trading", .{ .client_id = "client-123", .client_id_issued_at = 1000 }, null);
        try auth.setEnabled("linear", false);
        try auth.save("rh-trading");
        try auth.save("linear");
    }

    var reopened = try open(testing.allocator, shared.storage());
    defer reopened.deinit();
    const e = reopened.getForUrl("rh-trading", "https://api.example/mcp") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("sk-token", e.tokens.?.access_token);
    try testing.expectEqualStrings("sk-refresh", e.tokens.?.refresh_token.?);
    try testing.expectEqual(@as(i64, 1234567890), e.tokens.?.expires_at.?);
    try testing.expectEqualStrings("client-123", e.client_info.?.client_id);
    try testing.expect(!reopened.isEnabled("linear"));
}

test "two processes sharing a storage keep each other's sign-ins, and see each other's refreshes" {
    var shared: Shared = .{};
    defer shared.deinit();
    var first = try open(testing.allocator, shared.storage());
    defer first.deinit();
    var second = try open(testing.allocator, shared.storage());
    defer second.deinit();

    try second.updateTokens("linear", .{ .access_token = "linear-token" }, null);
    try second.save("linear");
    try first.updateTokens("github", .{ .access_token = "github-token", .refresh_token = "r1" }, null);
    try first.save("github");

    var reopened = try open(testing.allocator, shared.storage());
    defer reopened.deinit();
    try testing.expectEqualStrings("linear-token", reopened.get("linear").?.tokens.?.access_token);
    try testing.expectEqualStrings("github-token", reopened.get("github").?.tokens.?.access_token);

    try reopened.updateTokens("github", .{ .access_token = "github-fresh", .refresh_token = "r2" }, null);
    try reopened.save("github");
    try first.reload("github");
    try testing.expectEqualStrings("r2", first.get("github").?.tokens.?.refresh_token.?);

    _ = reopened.remove("linear");
    try reopened.save("linear");
    try second.reload("linear");
    try testing.expectEqualStrings("linear-token", second.get("linear").?.tokens.?.access_token);
    var after = try open(testing.allocator, shared.storage());
    defer after.deinit();
    try testing.expect(after.get("linear") == null);
}

test "a store with no storage keeps its entries in memory, and will not save" {
    var auth: Auth = .init(testing.allocator);
    defer auth.deinit();
    try auth.updateTokens("files", .{ .access_token = "x" }, null);
    try auth.reload("files");
    try testing.expectEqualStrings("x", auth.get("files").?.tokens.?.access_token);
    try testing.expectError(error.NoStorage, auth.save("files"));
}

test "getForUrl rejects an entry whose URL changed" {
    var auth = Auth.init(testing.allocator);
    defer auth.deinit();

    try auth.updateTokens("files", .{
        .access_token = "sk-old",
    }, "https://old.example/mcp");

    try testing.expect(auth.getForUrl("files", "https://old.example/mcp") != null);
    try testing.expect(auth.getForUrl("files", "https://new.example/mcp") == null);
}

test "remove drops an entry outright" {
    var auth = Auth.init(testing.allocator);
    defer auth.deinit();

    try auth.updateTokens("files", .{ .access_token = "x" }, null);
    try testing.expect(auth.get("files") != null);

    try testing.expect(auth.remove("files"));
    try testing.expect(auth.get("files") == null);
}

test "code verifier and oauth state round-trip through update/clear" {
    var auth = Auth.init(testing.allocator);
    defer auth.deinit();

    try auth.updateCodeVerifier("files", "verifier-123");
    try auth.updateOAuthState("files", "state-abc");

    const e = auth.get("files").?;
    try testing.expectEqualStrings("verifier-123", e.code_verifier.?);
    try testing.expectEqualStrings("state-abc", e.oauth_state.?);

    auth.clearCodeVerifier("files");
    auth.clearOAuthState("files");
    const e2 = auth.get("files").?;
    try testing.expect(e2.code_verifier == null);
    try testing.expect(e2.oauth_state == null);
}

test "a server nobody has said anything about is enabled" {
    var auth: Auth = .init(testing.allocator);
    defer auth.deinit();

    try testing.expect(auth.isEnabled("never-heard-of-it"));

    try auth.updateTokens("files", .{ .access_token = "x" }, null);
    try testing.expect(auth.isEnabled("files"));
}

test "turning a server off leaves its tokens alone" {
    var auth: Auth = .init(testing.allocator);
    defer auth.deinit();

    try auth.updateTokens("linear", .{ .access_token = "keep-me" }, "https://mcp.example/mcp");
    try auth.setEnabled("linear", false);

    const entry = auth.get("linear").?;
    try testing.expect(!auth.isEnabled("linear"));
    try testing.expectEqualStrings("keep-me", entry.tokens.?.access_token);
}
