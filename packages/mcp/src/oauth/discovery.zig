//! Finding out who authorizes an MCP server.
//!
//! Three documents, in order:
//!
//! 1. The `WWW-Authenticate` header on the `401`, which per RFC 9728 names the
//!    protected resource metadata URL.
//! 2. That metadata, which names one or more authorization servers.
//! 3. The authorization server's own metadata (RFC 8414), which names the
//!    endpoints to actually talk to.
//!
//! Every step has a fallback, because deployed servers skip steps. A `401`
//! with no header falls back to the well-known URL derived from the MCP
//! endpoint; an authorization server with no metadata document falls back to
//! the pre-8414 conventional paths. Only a server that publishes nothing and
//! answers nothing is a failure.

const std = @import("std");

const fetch = @import("fetch.zig");

pub const Error = error{
    /// No authorization server could be found for the resource.
    NoAuthorizationServer,
    /// A metadata document parsed but was missing something required.
    MalformedMetadata,
};

/// RFC 9728 protected resource metadata: what the MCP endpoint says about who
/// guards it.
pub const ProtectedResource = struct {
    /// The canonical resource identifier, which is what goes in the RFC 8707
    /// `resource` parameter. Falls back to the URL it was fetched for.
    resource: []const u8,
    authorization_servers: []const []const u8,
    scopes_supported: []const []const u8 = &.{},
};

/// RFC 8414 authorization server metadata, trimmed to the fields this client
/// acts on.
pub const Server = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    /// Absent on a server that does not accept dynamic client registration,
    /// which for MCP means the user has to supply a client id by hand.
    registration_endpoint: ?[]const u8 = null,
    revocation_endpoint: ?[]const u8 = null,
    scopes_supported: []const []const u8 = &.{},
    code_challenge_methods_supported: []const []const u8 = &.{},

    /// Whether the server advertises PKCE with S256. A server that publishes
    /// metadata without saying so is taken at its word and treated as not
    /// supporting it; one that publishes no metadata at all never reaches
    /// here, because `conventional` fills the field in.
    pub fn supportsS256(self: Server) bool {
        for (self.code_challenge_methods_supported) |method| {
            if (std.mem.eql(u8, method, "S256")) return true;
        }
        return false;
    }
};

/// Pull `resource_metadata="..."` out of a `WWW-Authenticate` header. Null
/// when the header is absent, is not a Bearer challenge, or carries no such
/// parameter - all of which are ordinary, and all of which mean "derive the
/// URL from the endpoint instead".
pub fn resourceMetadataUrl(header: []const u8) ?[]const u8 {
    const key = "resource_metadata";
    var rest = header;
    while (std.mem.indexOf(u8, rest, key)) |at| {
        rest = rest[at + key.len ..];
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (trimmed.len == 0 or trimmed[0] != '=') continue;

        const value = std.mem.trimStart(u8, trimmed[1..], " \t");
        if (value.len == 0) continue;

        if (value[0] == '"') {
            const end = std.mem.indexOfScalar(u8, value[1..], '"') orelse continue;
            return value[1 .. 1 + end];
        }

        const end = std.mem.indexOfAny(u8, value, ", \t") orelse value.len;
        return value[0..end];
    }
    return null;
}

/// The RFC 9728 well-known URL for a resource. The well-known segment goes
/// between the host and the resource's path, not at the end of it:
/// `https://host/a/b` becomes
/// `https://host/.well-known/oauth-protected-resource/a/b`.
pub fn protectedResourceUrl(arena: std.mem.Allocator, resource_url: []const u8) ![]const u8 {
    const split = try origin(resource_url);
    return std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource{s}", .{ split.origin, split.path });
}

/// Where an issuer's metadata might be, in the order to try. RFC 8414 puts
/// the well-known segment before the issuer's path; OpenID Connect Discovery
/// puts it after. Servers in the wild do both.
pub fn serverMetadataUrls(arena: std.mem.Allocator, issuer: []const u8) ![]const []const u8 {
    const split = try origin(issuer);

    var urls: std.ArrayList([]const u8) = .empty;
    try urls.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server{s}", .{ split.origin, split.path }));
    try urls.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration{s}", .{ split.origin, split.path }));
    if (split.path.len > 0) {
        try urls.append(arena, try std.fmt.allocPrint(arena, "{s}{s}/.well-known/openid-configuration", .{ split.origin, split.path }));
    }
    return urls.toOwnedSlice(arena);
}

/// The endpoints a pre-RFC-8414 server is assumed to have. Used when an
/// issuer publishes no metadata document at all, which was the norm before
/// discovery existed and is still true of some deployments.
pub fn conventional(arena: std.mem.Allocator, issuer: []const u8) !Server {
    const trimmed = std.mem.trimEnd(u8, issuer, "/");
    return .{
        .issuer = try arena.dupe(u8, trimmed),
        .authorization_endpoint = try std.fmt.allocPrint(arena, "{s}/authorize", .{trimmed}),
        .token_endpoint = try std.fmt.allocPrint(arena, "{s}/token", .{trimmed}),
        .registration_endpoint = try std.fmt.allocPrint(arena, "{s}/register", .{trimmed}),
        // Assumed rather than advertised: PKCE is mandatory for MCP, and a
        // server that does not support it will reject the request anyway.
        .code_challenge_methods_supported = try dupeStrings(arena, &.{"S256"}),
    };
}

pub fn parseProtectedResource(
    arena: std.mem.Allocator,
    source: []const u8,
    fallback_resource: []const u8,
) !ProtectedResource {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch return Error.MalformedMetadata;
    const fields = switch (root) {
        .object => |object| object,
        else => return Error.MalformedMetadata,
    };

    const servers = try stringArray(arena, fields, "authorization_servers");
    if (servers.len == 0) return Error.NoAuthorizationServer;

    return .{
        .resource = try string(arena, fields, "resource") orelse try arena.dupe(u8, fallback_resource),
        .authorization_servers = servers,
        .scopes_supported = try stringArray(arena, fields, "scopes_supported"),
    };
}

pub fn parseServer(arena: std.mem.Allocator, source: []const u8) !Server {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch return Error.MalformedMetadata;
    const fields = switch (root) {
        .object => |object| object,
        else => return Error.MalformedMetadata,
    };

    return .{
        .issuer = try string(arena, fields, "issuer") orelse return Error.MalformedMetadata,
        .authorization_endpoint = try string(arena, fields, "authorization_endpoint") orelse return Error.MalformedMetadata,
        .token_endpoint = try string(arena, fields, "token_endpoint") orelse return Error.MalformedMetadata,
        .registration_endpoint = try string(arena, fields, "registration_endpoint"),
        .revocation_endpoint = try string(arena, fields, "revocation_endpoint"),
        .scopes_supported = try stringArray(arena, fields, "scopes_supported"),
        .code_challenge_methods_supported = try stringArray(arena, fields, "code_challenge_methods_supported"),
    };
}

/// What a full discovery run produced.
pub const Found = struct {
    resource: ProtectedResource,
    server: Server,
};

/// Walk the whole chain: header (or endpoint) to resource metadata to
/// authorization server metadata. Everything is allocated in `arena`.
pub fn discover(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    resource_url: []const u8,
    challenge: []const u8,
) !Found {
    const metadata_url = resourceMetadataUrl(challenge) orelse
        try protectedResourceUrl(arena, resource_url);

    const resource = resolved: {
        const response = fetch.get(gpa, arena, io, metadata_url) catch break :resolved try assumed(arena, resource_url);
        if (!response.ok()) break :resolved try assumed(arena, resource_url);
        break :resolved parseProtectedResource(arena, response.body, resource_url) catch
            try assumed(arena, resource_url);
    };

    for (resource.authorization_servers) |issuer| {
        for (try serverMetadataUrls(arena, issuer)) |url| {
            const response = fetch.get(gpa, arena, io, url) catch continue;
            if (!response.ok()) continue;
            const server = parseServer(arena, response.body) catch continue;
            return .{ .resource = resource, .server = server };
        }
    }

    // Every issuer answered nothing usable. The first one gets the benefit of
    // the doubt with conventional endpoints rather than failing outright.
    return .{
        .resource = resource,
        .server = try conventional(arena, resource.authorization_servers[0]),
    };
}

/// What to assume when the resource publishes no metadata: it authorizes
/// itself, which is what a single-tenant deployment looks like.
fn assumed(arena: std.mem.Allocator, resource_url: []const u8) !ProtectedResource {
    const split = try origin(resource_url);
    return .{
        .resource = try arena.dupe(u8, resource_url),
        .authorization_servers = try dupeStrings(arena, &.{split.origin}),
    };
}

/// Split a URL into scheme+authority and path. Query and fragment are dropped:
/// neither belongs in a well-known URL.
fn origin(url: []const u8) !struct { origin: []const u8, path: []const u8 } {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return Error.MalformedMetadata;
    const after_scheme = scheme_end + "://".len;
    if (after_scheme >= url.len) return Error.MalformedMetadata;

    const cut = std.mem.indexOfAny(u8, url[after_scheme..], "?#") orelse url.len - after_scheme;
    const without_query = url[0 .. after_scheme + cut];

    const slash = std.mem.indexOfScalar(u8, without_query[after_scheme..], '/') orelse
        return .{ .origin = without_query, .path = "" };

    const path = std.mem.trimEnd(u8, without_query[after_scheme + slash ..], "/");
    return .{ .origin = without_query[0 .. after_scheme + slash], .path = path };
}

fn string(arena: std.mem.Allocator, fields: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = fields.get(name) orelse return null;
    if (value != .string) return null;
    return try arena.dupe(u8, value.string);
}

fn stringArray(arena: std.mem.Allocator, fields: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    const value = fields.get(name) orelse return &.{};
    const items = switch (value) {
        .array => |array| array.items,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item != .string) continue;
        try out.append(arena, try arena.dupe(u8, item.string));
    }
    return out.toOwnedSlice(arena);
}

fn dupeStrings(arena: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try arena.dupe(u8, value);
    return out;
}

const testing = std.testing;

test "resourceMetadataUrl reads a quoted parameter" {
    const header = "Bearer error=\"invalid_token\", resource_metadata=\"https://mcp.example/.well-known/oauth-protected-resource\"";
    try testing.expectEqualStrings(
        "https://mcp.example/.well-known/oauth-protected-resource",
        resourceMetadataUrl(header).?,
    );
}

test "resourceMetadataUrl reads an unquoted parameter" {
    const header = "Bearer resource_metadata=https://mcp.example/meta, realm=x";
    try testing.expectEqualStrings("https://mcp.example/meta", resourceMetadataUrl(header).?);
}

test "resourceMetadataUrl is null when the parameter is absent" {
    try testing.expect(resourceMetadataUrl("") == null);
    try testing.expect(resourceMetadataUrl("Bearer realm=\"mcp\"") == null);
}

test "protectedResourceUrl puts the well-known segment before the path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "https://host.example/.well-known/oauth-protected-resource/mcp/trading",
        try protectedResourceUrl(arena, "https://host.example/mcp/trading"),
    );
    try testing.expectEqualStrings(
        "https://host.example/.well-known/oauth-protected-resource",
        try protectedResourceUrl(arena, "https://host.example"),
    );
    try testing.expectEqualStrings(
        "https://host.example/.well-known/oauth-protected-resource",
        try protectedResourceUrl(arena, "https://host.example/"),
    );
}

test "protectedResourceUrl drops a query string" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectEqualStrings(
        "https://host.example/.well-known/oauth-protected-resource/mcp",
        try protectedResourceUrl(arena_state.allocator(), "https://host.example/mcp?x=1#f"),
    );
}

test "serverMetadataUrls covers both well-known layouts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const urls = try serverMetadataUrls(arena, "https://auth.example/tenant");
    try testing.expectEqual(@as(usize, 3), urls.len);
    try testing.expectEqualStrings("https://auth.example/.well-known/oauth-authorization-server/tenant", urls[0]);
    try testing.expectEqualStrings("https://auth.example/.well-known/openid-configuration/tenant", urls[1]);
    try testing.expectEqualStrings("https://auth.example/tenant/.well-known/openid-configuration", urls[2]);

    const rootless = try serverMetadataUrls(arena, "https://auth.example");
    try testing.expectEqual(@as(usize, 2), rootless.len);
    try testing.expectEqualStrings("https://auth.example/.well-known/oauth-authorization-server", rootless[0]);
}

test "parseProtectedResource reads the servers and falls back for the resource" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseProtectedResource(arena,
        \\{"authorization_servers":["https://auth.example"],"scopes_supported":["read","write"]}
    , "https://mcp.example/mcp");

    try testing.expectEqualStrings("https://mcp.example/mcp", parsed.resource);
    try testing.expectEqualStrings("https://auth.example", parsed.authorization_servers[0]);
    try testing.expectEqual(@as(usize, 2), parsed.scopes_supported.len);
}

test "parseProtectedResource refuses a document with no authorization server" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(Error.NoAuthorizationServer, parseProtectedResource(arena_state.allocator(),
        \\{"resource":"https://mcp.example/mcp"}
    , "https://mcp.example/mcp"));
}

test "parseServer requires the three endpoints it cannot invent" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseServer(arena,
        \\{"issuer":"https://auth.example",
        \\ "authorization_endpoint":"https://auth.example/authorize",
        \\ "token_endpoint":"https://auth.example/token",
        \\ "registration_endpoint":"https://auth.example/register",
        \\ "code_challenge_methods_supported":["S256","plain"]}
    );

    try testing.expectEqualStrings("https://auth.example/authorize", parsed.authorization_endpoint);
    try testing.expectEqualStrings("https://auth.example/register", parsed.registration_endpoint.?);
    try testing.expect(parsed.supportsS256());

    try testing.expectError(Error.MalformedMetadata, parseServer(arena,
        \\{"issuer":"https://auth.example"}
    ));
}

test "supportsS256 is false when the server advertises only plain" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const parsed = try parseServer(arena_state.allocator(),
        \\{"issuer":"https://a","authorization_endpoint":"https://a/x","token_endpoint":"https://a/t",
        \\ "code_challenge_methods_supported":["plain"]}
    );
    try testing.expect(!parsed.supportsS256());
}

test "conventional fills in the pre-discovery endpoints" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const server = try conventional(arena_state.allocator(), "https://auth.example/");
    try testing.expectEqualStrings("https://auth.example", server.issuer);
    try testing.expectEqualStrings("https://auth.example/authorize", server.authorization_endpoint);
    try testing.expectEqualStrings("https://auth.example/token", server.token_endpoint);
    try testing.expectEqualStrings("https://auth.example/register", server.registration_endpoint.?);
    try testing.expect(server.supportsS256());
}
