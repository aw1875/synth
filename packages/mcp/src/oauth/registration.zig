//! Dynamic client registration, RFC 7591.
//!
//! An MCP client has no client id to start with. There is no developer portal
//! to visit and no secret to paste: the program registers itself with whatever
//! authorization server discovery turned up, gets an id back, and keeps it.
//!
//! It registers as a public client - `token_endpoint_auth_method: "none"` -
//! because a desktop program cannot keep a secret. That is what makes PKCE
//! load-bearing rather than belt-and-braces: the code challenge is the only
//! thing tying the redirect back to the program that started the flow.
//!
//! Registration is a once-per-server event. The id it produces is stored in
//! `mcp-auth.json` and reused; re-registering on every run would litter the
//! authorization server with dead clients.

const std = @import("std");

const fetch = @import("fetch.zig");

pub const Error = error{
    /// The server has no registration endpoint, so a client id has to come
    /// from somewhere else - configuration, or the user.
    RegistrationUnsupported,
    /// The server refused to register this client. `Rejected.detail` has what
    /// it said.
    RegistrationRefused,
    /// The server registered the client but did not say what its id is.
    MalformedRegistration,
};

/// What to ask for.
pub const Request = struct {
    /// Shown to the user on the consent screen, so it should name the program
    /// rather than the library.
    client_name: []const u8,
    /// Every URI the flow might redirect to. The loopback listener picks its
    /// port at run time, so this is filled in once the listener is up.
    redirect_uris: []const []const u8,
    /// Space-separated, or null to accept whatever the server defaults to.
    scope: ?[]const u8 = null,
    /// A URL describing the client, if there is one to point at.
    client_uri: ?[]const u8 = null,
};

/// What came back. The optional fields are the server's choice: a server may
/// issue a secret even to a client that asked to be public, and may put an
/// expiry on it.
pub const Registered = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    client_id_issued_at: ?i64 = null,
    /// Zero means "never expires", per RFC 7591. Kept as sent rather than
    /// normalised, because the distinction between zero and absent is the
    /// server's to make.
    client_secret_expires_at: ?i64 = null,
};

/// Why a registration was refused, for reporting rather than for control flow.
pub const Rejected = struct {
    status: std.http.Status,
    detail: []const u8,
};

/// Build the RFC 7591 request body.
pub fn writeRequest(out: *std.Io.Writer, request: Request) !void {
    var json: std.json.Stringify = .{ .writer = out };

    try json.beginObject();

    try json.objectField("client_name");
    try json.write(request.client_name);

    try json.objectField("redirect_uris");
    try json.beginArray();
    for (request.redirect_uris) |uri| try json.write(uri);
    try json.endArray();

    try json.objectField("grant_types");
    try json.beginArray();
    try json.write("authorization_code");
    try json.write("refresh_token");
    try json.endArray();

    try json.objectField("response_types");
    try json.beginArray();
    try json.write("code");
    try json.endArray();

    // A public client: no secret to authenticate with, PKCE instead.
    try json.objectField("token_endpoint_auth_method");
    try json.write("none");

    if (request.scope) |scope| {
        try json.objectField("scope");
        try json.write(scope);
    }
    if (request.client_uri) |uri| {
        try json.objectField("client_uri");
        try json.write(uri);
    }

    try json.endObject();
}

pub fn parse(arena: std.mem.Allocator, source: []const u8) !Registered {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch return Error.MalformedRegistration;
    const fields = switch (root) {
        .object => |object| object,
        else => return Error.MalformedRegistration,
    };

    return .{
        .client_id = try string(arena, fields, "client_id") orelse return Error.MalformedRegistration,
        .client_secret = try string(arena, fields, "client_secret"),
        .client_id_issued_at = integer(fields, "client_id_issued_at"),
        .client_secret_expires_at = integer(fields, "client_secret_expires_at"),
    };
}

/// Register with `endpoint`, or report why not. `rejected` is filled in when
/// the error is `RegistrationRefused`, so a caller can tell the user what the
/// server actually objected to.
pub fn register(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    endpoint: ?[]const u8,
    request: Request,
    rejected: ?*Rejected,
) !Registered {
    const url = endpoint orelse return Error.RegistrationUnsupported;

    var body: std.Io.Writer.Allocating = .init(arena);
    defer body.deinit();
    try writeRequest(&body.writer, request);

    const response = fetch.postJson(gpa, arena, io, url, body.written()) catch return Error.RegistrationRefused;
    if (!response.ok()) {
        if (rejected) |slot| slot.* = .{ .status = response.status, .detail = response.body };
        return Error.RegistrationRefused;
    }

    return parse(arena, response.body);
}

fn string(arena: std.mem.Allocator, fields: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = fields.get(name) orelse return null;
    if (value != .string) return null;
    return try arena.dupe(u8, value.string);
}

fn integer(fields: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = fields.get(name) orelse return null;
    return switch (value) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

const testing = std.testing;

test "writeRequest asks to be a public client" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeRequest(&out.writer, .{
        .client_name = "synth",
        .redirect_uris = &.{"http://127.0.0.1:19876/mcp/oauth/callback"},
    });

    const body = out.written();
    try testing.expect(std.mem.indexOf(u8, body, "\"token_endpoint_auth_method\":\"none\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"authorization_code\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"refresh_token\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "http://127.0.0.1:19876/mcp/oauth/callback") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"scope\"") == null);
}

test "writeRequest carries an optional scope and client_uri" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeRequest(&out.writer, .{
        .client_name = "synth",
        .redirect_uris = &.{"http://127.0.0.1:19876/cb"},
        .scope = "read write",
        .client_uri = "https://example.invalid/synth",
    });

    const body = out.written();
    try testing.expect(std.mem.indexOf(u8, body, "\"scope\":\"read write\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"client_uri\":\"https://example.invalid/synth\"") != null);
}

test "writeRequest lists every redirect uri" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeRequest(&out.writer, .{
        .client_name = "synth",
        .redirect_uris = &.{ "http://127.0.0.1:19876/cb", "http://127.0.0.1:19877/cb" },
    });

    const body = out.written();
    try testing.expect(std.mem.indexOf(u8, body, "19876") != null);
    try testing.expect(std.mem.indexOf(u8, body, "19877") != null);
}

test "parse reads what the server issued" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const registered = try parse(arena_state.allocator(),
        \\{"client_id":"abc-123","client_id_issued_at":1700000000,"client_secret_expires_at":0}
    );

    try testing.expectEqualStrings("abc-123", registered.client_id);
    try testing.expect(registered.client_secret == null);
    try testing.expectEqual(@as(i64, 1700000000), registered.client_id_issued_at.?);
    try testing.expectEqual(@as(i64, 0), registered.client_secret_expires_at.?);
}

test "parse keeps a secret the server issued anyway" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const registered = try parse(arena_state.allocator(),
        \\{"client_id":"abc","client_secret":"shh"}
    );
    try testing.expectEqualStrings("shh", registered.client_secret.?);
}

test "parse refuses a response with no client id" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(Error.MalformedRegistration, parse(arena,
        \\{"client_secret":"shh"}
    ));
    try testing.expectError(Error.MalformedRegistration, parse(arena, "[]"));
    try testing.expectError(Error.MalformedRegistration, parse(arena, "not json"));
}

test "register without an endpoint is unsupported, not a failure to try" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(Error.RegistrationUnsupported, register(
        testing.allocator,
        arena_state.allocator(),
        testing.io,
        null,
        .{ .client_name = "synth", .redirect_uris = &.{"http://127.0.0.1:1/cb"} },
        null,
    ));
}
