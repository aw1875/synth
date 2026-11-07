//! Getting an access token for one MCP server.
//!
//! The whole authorization code flow, start to finish: discover who guards
//! the server, register as a client if this is the first time, put a loopback
//! listener up, send the user to their browser, take the code that comes back,
//! and trade it for tokens. What comes out is stored in `Auth` and reused.
//!
//! A public client throughout - a program on someone's machine cannot keep a
//! secret, so there is none to keep. PKCE is what ties the redirect back to
//! the process that started the flow, and the `state` is what stops a redirect
//! from somewhere else settling it.

const std = @import("std");
const oauth2 = @import("oauth2");

const Auth = @import("auth.zig");
const Browser = @import("browser.zig");
const Callback = @import("callback.zig");
const discovery = @import("discovery.zig");
const registration = @import("registration.zig");

const Provider = oauth2.BaseOAuth2Provider;
const Param = Provider.Param;

pub const Error = error{
    /// The user said no, or the authorization server refused on their behalf.
    AuthorizationDenied,
    /// The code came back stamped with an issuer this flow never asked. A
    /// mix-up attack looks exactly like this, so it is refused rather than
    /// shrugged at.
    IssuerMismatch,
    /// The token endpoint answered, but not with a token.
    TokenRequestFailed,
    /// A refresh was asked for with nothing to refresh.
    NoRefreshToken,
    /// The authorization server no longer honours the stored refresh token, so
    /// the user has to sign in again.
    SignInExpired,
};

/// Treat a token as expired this many seconds early, so one that would have
/// died mid-request is renewed before the request rather than during it.
pub const expiry_skew_seconds: i64 = 60;

/// What a token endpoint sends back. Everything but the access token is
/// optional because, in practice, everything but the access token is.
const TokenResponse = struct {
    access_token: []const u8,
    token_type: ?[]const u8 = null,
    expires_in: ?i64 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

pub const Options = struct {
    /// What this server is called in the config, and the key it is stored
    /// under.
    name: []const u8,
    /// The MCP endpoint being authorized.
    server_url: []const u8,
    /// Shown to the user on the consent screen, so it should name the program.
    client_name: []const u8,
    /// The `WWW-Authenticate` header off the 401 that started this, when there
    /// was one. Empty is fine; discovery falls back to the well-known URL.
    challenge: []const u8 = "",
    scopes: []const []const u8 = &.{},
    /// How the user is sent to the authorization server. A TUI overrides this
    /// to show the URL itself rather than have a browser open over the screen.
    open: Browser.Open = Browser.defaultOpen,
    timeout_ns: u64 = Callback.default_timeout_ns,
};

/// Run the flow and store what it produces. Returns the access token, owned by
/// `store` and valid until the next thing written to it.
///
/// Blocking, and for minutes: the middle of this is a human reading a consent
/// screen.
pub fn authorize(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Auth,
    options: Options,
) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try discovery.discover(gpa, arena, io, options.server_url, options.challenge);
    const cached = store.getForUrl(options.name, options.server_url);

    // A registration is tied to the exact redirect URI it was made with, so
    // the listener asks for the port last time's registration used. Getting it
    // means the client id is still good; missing it means registering again.
    const preferred_port = port: {
        const entry = cached orelse break :port Callback.default_port;
        const uri = entry.redirect_uri orelse break :port Callback.default_port;
        break :port Callback.parseRedirectUri(uri).port;
    };

    const state = try oauth2.createStateNonce(io, arena);
    const verifier = try oauth2.createStateNonce(io, arena);

    var listener = try Callback.Listener.start(gpa, io, .{
        .state = state,
        .port = preferred_port,
    });
    defer listener.deinit();

    const redirect_uri = try listener.redirectUri(arena);

    const scopes = chosenScopes(options.scopes, found.resource.scopes_supported);

    const client_id = try clientId(gpa, arena, io, store, options, found, cached, redirect_uri, scopes);

    var provider = try Provider.init(io, gpa, .{
        .client_id = client_id,
        // Public client: no secret, so `client_id` goes in the body and no
        // Authorization header is sent.
        .client_secret = "",
        .redirect_uri = redirect_uri,
    });
    defer provider.deinit();

    // RFC 8707. The token is minted for this resource and no other, which is
    // what stops a token for one MCP server being replayed against another.
    const resource: []const Param = &.{
        .{ .key = "resource", .value = found.resource.resource },
    };

    const url = try provider.createAuthorizationUrlWithPKCE(
        arena,
        found.server.authorization_endpoint,
        state,
        .S256,
        verifier,
        scopes,
        resource,
    );

    // Written down before the browser opens: if this process dies while the
    // user is still deciding, the flow is resumable rather than lost.
    try store.updateCodeVerifier(options.name, verifier);
    try store.updateOAuthState(options.name, state);

    try options.open(io, url);

    const code = switch (try listener.wait(options.timeout_ns)) {
        .denied => return Error.AuthorizationDenied,
        .code => |code| code,
    };

    if (code.iss) |issuer| {
        if (!std.mem.eql(u8, issuer, found.server.issuer)) return Error.IssuerMismatch;
    }

    var response = try provider.validateAuthorizationCode(
        TokenResponse,
        arena,
        found.server.token_endpoint,
        code.code,
        verifier,
        resource,
    );
    defer response.deinit();

    const tokens = try settle(io, response);

    store.clearCodeVerifier(options.name);
    store.clearOAuthState(options.name);
    try store.updateTokens(options.name, tokens, options.server_url);

    return store.get(options.name).?.tokens.?.access_token;
}

/// Trade the stored refresh token for a fresh access token. Returns the new
/// access token, owned by `store`.
pub fn refresh(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Auth,
    options: Options,
) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    store.reload(options.name) catch {};
    const entry = store.getForUrl(options.name, options.server_url) orelse return Error.NoRefreshToken;
    const tokens = entry.tokens orelse return Error.NoRefreshToken;
    const refresh_token = tokens.refresh_token orelse return Error.NoRefreshToken;
    const info = entry.client_info orelse return Error.NoRefreshToken;

    const found = try discovery.discover(gpa, arena, io, options.server_url, options.challenge);

    var provider = try Provider.init(io, gpa, .{
        .client_id = info.client_id,
        .client_secret = info.client_secret orelse "",
        .redirect_uri = entry.redirect_uri orelse "",
    });
    defer provider.deinit();

    const resource: []const Param = &.{
        .{ .key = "resource", .value = found.resource.resource },
    };

    var response = try provider.refreshAccessToken(
        TokenResponse,
        arena,
        found.server.token_endpoint,
        refresh_token,
        null,
        resource,
    );
    defer response.deinit();

    if (response.oauthError()) |refusal| {
        if (std.mem.eql(u8, refusal.code, "invalid_grant")) return afterRefusal(io, store, options, refresh_token);
    }

    var fresh = try settle(io, response);

    // Not every server rotates the refresh token, and one that does not simply
    // omits it. Dropping the old one on that reply would end the session at
    // the next expiry.
    if (fresh.refresh_token == null) fresh.refresh_token = refresh_token;

    try store.updateTokens(options.name, fresh, options.server_url);
    // A server that rotates has already disowned the stored refresh token.
    store.save(options.name) catch {};
    return store.get(options.name).?.tokens.?.access_token;
}

/// What is left once the server has refused `spent`. Another process sharing
/// the storage may have rotated it a moment before, and a server refuses the
/// old token then, so what that process saved is kept. Otherwise the sign-in
/// is over; the client registration outlives it.
fn afterRefusal(io: std.Io, store: *Auth, options: Options, spent: []const u8) ![]const u8 {
    store.reload(options.name) catch {};
    const entry = store.getForUrl(options.name, options.server_url) orelse return Error.SignInExpired;
    const tokens = entry.tokens orelse return Error.SignInExpired;

    if (std.mem.eql(u8, tokens.refresh_token orelse "", spent)) {
        store.forgetTokens(options.name);
        store.save(options.name) catch {};
        return Error.SignInExpired;
    }
    if (expired(io, tokens.expires_at)) return Error.SignInExpired;
    return tokens.access_token;
}

/// A usable access token for `name`, refreshed if the stored one has run out.
///
/// Null means there is nothing to work with and the user has to authorize
/// interactively - which opens a browser, so it is the caller's decision to
/// make, not this function's.
pub fn accessToken(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Auth,
    options: Options,
) !?[]const u8 {
    store.reload(options.name) catch {};
    const entry = store.getForUrl(options.name, options.server_url) orelse return null;
    const tokens = entry.tokens orelse return null;

    if (!expired(io, tokens.expires_at)) return tokens.access_token;
    if (tokens.refresh_token == null) return null;

    return try refresh(gpa, io, store, options);
}

/// Whether a token whose lifetime ends at `expires_at` should be treated as
/// spent. A token with no stated expiry is taken at face value: the server
/// will say so with a 401 if it disagrees.
pub fn expired(io: std.Io, expires_at: ?i64) bool {
    const deadline = expires_at orelse return false;
    return unixSeconds(io) + expiry_skew_seconds >= deadline;
}

/// What to ask the authorization server for: what the caller configured, or
/// failing that whatever the resource says it offers.
///
/// A server that publishes `scopes_supported` has already answered the
/// question, and sending no `scope` at all is not the same as asking for the
/// default - some authorization servers refuse the request outright.
fn chosenScopes(configured: []const []const u8, offered: []const []const u8) []const []const u8 {
    return if (configured.len > 0) configured else offered;
}

/// The client id to authorize with: the one from last time when its
/// registration still matches, or a fresh registration.
fn clientId(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    store: *Auth,
    options: Options,
    found: discovery.Found,
    cached: ?Auth.Entry,
    redirect_uri: []const u8,
    scopes: []const []const u8,
) ![]const u8 {
    if (cached) |entry| {
        if (entry.client_info) |info| {
            const registered_uri = entry.redirect_uri orelse "";
            if (std.mem.eql(u8, registered_uri, redirect_uri)) return info.client_id;
        }
    }

    const registered = try registration.register(gpa, arena, io, found.server.registration_endpoint, .{
        .client_name = options.client_name,
        .redirect_uris = &.{redirect_uri},
        .scope = if (scopes.len > 0) try std.mem.join(arena, " ", scopes) else null,
    }, null);

    try store.updateClientInfo(options.name, .{
        .client_id = registered.client_id,
        .client_secret = registered.client_secret,
        .client_id_issued_at = registered.client_id_issued_at,
        .client_secret_expires_at = registered.client_secret_expires_at,
    }, options.server_url);
    try store.updateRedirectUri(options.name, redirect_uri);

    // Saved before the flow finishes: an attempt abandoned at the consent
    // screen would otherwise register a fresh client on every try.
    store.save(options.name) catch {};

    return registered.client_id;
}

/// Turn a token endpoint's answer into something storable, or say why not.
///
/// The slices point into `response` and are copied by `Auth` when stored, so
/// they only have to outlive the call.
fn settle(io: std.Io, response: oauth2.Response(TokenResponse)) !Auth.Tokens {
    if (response.oauthError()) |_| return Error.TokenRequestFailed;

    const parsed = response.parsed orelse return Error.TokenRequestFailed;
    const body = parsed.value;
    if (body.access_token.len == 0) return Error.TokenRequestFailed;

    return .{
        .access_token = body.access_token,
        .refresh_token = body.refresh_token,
        // Stored as a moment rather than a duration: a lifetime is only
        // meaningful next to the time it was issued, and that is now.
        .expires_at = if (body.expires_in) |seconds| unixSeconds(io) + seconds else null,
        .scope = body.scope,
    };
}

fn unixSeconds(io: std.Io) i64 {
    return @divTrunc(std.Io.Clock.now(.real, io).toMilliseconds(), 1000);
}

const testing = std.testing;

test "a token with no stated expiry is taken at face value" {
    try testing.expect(!expired(testing.io, null));
}

test "a token is spent once it is inside the skew" {
    const now = unixSeconds(testing.io);

    try testing.expect(expired(testing.io, now - 1));
    try testing.expect(expired(testing.io, now + expiry_skew_seconds - 1));
    try testing.expect(!expired(testing.io, now + expiry_skew_seconds + 60));
}

test "accessToken is null for a server nothing is stored for" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    try testing.expect(try accessToken(testing.allocator, testing.io, &store, .{
        .name = "files",
        .server_url = "https://mcp.example/mcp",
        .client_name = "test",
    }) == null);
}

test "accessToken hands back a token that is still good" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    try store.updateTokens("files", .{
        .access_token = "still-good",
        .expires_at = unixSeconds(testing.io) + 3600,
    }, "https://mcp.example/mcp");

    const token = try accessToken(testing.allocator, testing.io, &store, .{
        .name = "files",
        .server_url = "https://mcp.example/mcp",
        .client_name = "test",
    });
    try testing.expectEqualStrings("still-good", token.?);
}

test "an expired token with nothing to refresh with is null, not an error" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    try store.updateTokens("files", .{
        .access_token = "spent",
        .expires_at = unixSeconds(testing.io) - 3600,
    }, "https://mcp.example/mcp");

    try testing.expect(try accessToken(testing.allocator, testing.io, &store, .{
        .name = "files",
        .server_url = "https://mcp.example/mcp",
        .client_name = "test",
    }) == null);
}

test "a token stored for a different url is not reused" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    try store.updateTokens("files", .{ .access_token = "old" }, "https://old.example/mcp");

    try testing.expect(try accessToken(testing.allocator, testing.io, &store, .{
        .name = "files",
        .server_url = "https://new.example/mcp",
        .client_name = "test",
    }) == null);
}

test "refreshing without a refresh token says so" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    try store.updateTokens("files", .{ .access_token = "spent" }, "https://mcp.example/mcp");

    try testing.expectError(Error.NoRefreshToken, refresh(testing.allocator, testing.io, &store, .{
        .name = "files",
        .server_url = "https://mcp.example/mcp",
        .client_name = "test",
    }));
}

/// One server's entry kept the way a database would keep it, apart from any
/// `Auth` reading it.
const OneEntry = struct {
    encoded: ?[]u8 = null,

    fn deinit(self: *OneEntry) void {
        if (self.encoded) |old| testing.allocator.free(old);
    }

    fn storage(self: *OneEntry) Auth.Storage {
        return .{ .context = self, .readAll = readAll, .read = read, .write = write };
    }

    fn put(self: *OneEntry, encoded: []const u8) !void {
        self.deinit();
        self.encoded = try testing.allocator.dupe(u8, encoded);
    }

    fn readAll(context: *anyopaque, arena: std.mem.Allocator) anyerror![]const Auth.Storage.Stored {
        const self: *OneEntry = @ptrCast(@alignCast(context));
        const encoded = self.encoded orelse return &.{};
        const out = try arena.alloc(Auth.Storage.Stored, 1);
        out[0] = .{ .name = "files", .encoded = try arena.dupe(u8, encoded) };
        return out;
    }

    fn read(context: *anyopaque, arena: std.mem.Allocator, _: []const u8) anyerror!?[]const u8 {
        const self: *OneEntry = @ptrCast(@alignCast(context));
        return try arena.dupe(u8, self.encoded orelse return null);
    }

    fn write(context: *anyopaque, _: []const u8, encoded: ?[]const u8) anyerror!void {
        const self: *OneEntry = @ptrCast(@alignCast(context));
        try self.put(encoded orelse return error.TestUnexpectedResult);
    }
};

/// An authorization server that publishes no metadata, so discovery settles
/// on `/token` at its origin, and answers that with `reply`. `rotated` lands in
/// `kept` first, as another process's refresh would.
const FakeTokenEndpoint = struct {
    server: std.Io.net.Server,
    thread: std.Thread = undefined,
    status: []const u8,
    reply: []const u8,
    kept: *OneEntry,
    rotated: ?[]const u8 = null,
    url_buffer: [64]u8 = undefined,

    fn start(self: *FakeTokenEndpoint) ![]const u8 {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return std.fmt.bufPrint(&self.url_buffer, "http://127.0.0.1:{d}/mcp", .{self.server.socket.address.getPort()});
    }

    fn stop(self: *FakeTokenEndpoint) void {
        self.thread.join();
        self.server.deinit(testing.io);
    }

    fn serve(self: *FakeTokenEndpoint) !void {
        const io = testing.io;
        while (true) {
            const stream = try self.server.accept(io);
            defer stream.close(io);

            var in_buffer: [4096]u8 = undefined;
            var in = stream.reader(io, &in_buffer);
            const request = (try in.interface.takeDelimiter('\n')).?;
            const wants_token = std.mem.startsWith(u8, request, "POST /token");
            var length: usize = 0;
            while (try in.interface.takeDelimiter('\n')) |line| {
                const header = std.mem.trimEnd(u8, line, "\r");
                if (header.len == 0) break;
                if (std.ascii.startsWithIgnoreCase(header, "content-length: ")) length = try std.fmt.parseInt(usize, header["content-length: ".len..], 10);
            }
            try in.interface.discardAll(length);

            var out_buffer: [1024]u8 = undefined;
            var out = stream.writer(io, &out_buffer);
            if (!wants_token) {
                try out.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                try out.interface.flush();
                continue;
            }
            if (self.rotated) |entry| try self.kept.put(entry);
            try out.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ self.status, self.reply.len, self.reply });
            try out.interface.flush();
            return;
        }
    }
};

fn fakeEndpoint(kept: *OneEntry, status: []const u8, reply: []const u8) !FakeTokenEndpoint {
    const loopback: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    return .{ .server = try loopback.listen(testing.io, .{}), .status = status, .reply = reply, .kept = kept };
}

fn signInWithSpentToken(kept: *OneEntry, url: []const u8) !void {
    var seeding = try Auth.open(testing.allocator, kept.storage());
    defer seeding.deinit();
    try seeding.updateTokens("files", .{ .access_token = "A1", .refresh_token = "R1", .expires_at = 1000 }, url);
    try seeding.updateClientInfo("files", .{ .client_id = "client" }, null);
    try seeding.save("files");
}

test "a refreshed token is saved, so the next run holds the one the server still honours" {
    var kept: OneEntry = .{};
    defer kept.deinit();
    var endpoint = try fakeEndpoint(&kept, "200 OK",
        \\{"access_token":"A2","refresh_token":"R2","expires_in":3600}
    );
    const url = try endpoint.start();
    defer endpoint.stop();
    try signInWithSpentToken(&kept, url);

    var store = try Auth.open(testing.allocator, kept.storage());
    defer store.deinit();
    const token = try accessToken(testing.allocator, testing.io, &store, .{ .name = "files", .server_url = url, .client_name = "test" });
    try testing.expectEqualStrings("A2", token.?);

    var next_run = try Auth.open(testing.allocator, kept.storage());
    defer next_run.deinit();
    try testing.expectEqualStrings("R2", next_run.get("files").?.tokens.?.refresh_token.?);
}

test "a refused refresh token ends the sign-in, and keeps the registration" {
    var kept: OneEntry = .{};
    defer kept.deinit();
    var endpoint = try fakeEndpoint(&kept, "400 Bad Request",
        \\{"error":"invalid_grant"}
    );
    const url = try endpoint.start();
    defer endpoint.stop();
    try signInWithSpentToken(&kept, url);

    var store = try Auth.open(testing.allocator, kept.storage());
    defer store.deinit();
    try testing.expectError(Error.SignInExpired, accessToken(testing.allocator, testing.io, &store, .{ .name = "files", .server_url = url, .client_name = "test" }));

    var next_run = try Auth.open(testing.allocator, kept.storage());
    defer next_run.deinit();
    try testing.expect(next_run.get("files").?.tokens == null);
    try testing.expectEqualStrings("client", next_run.get("files").?.client_info.?.client_id);
}

test "a refusal after another process rotated the token keeps what that process saved" {
    var kept: OneEntry = .{};
    defer kept.deinit();
    var endpoint = try fakeEndpoint(&kept, "400 Bad Request",
        \\{"error":"invalid_grant"}
    );
    const url = try endpoint.start();
    defer endpoint.stop();
    try signInWithSpentToken(&kept, url);

    var encoded: [256]u8 = undefined;
    endpoint.rotated = try std.fmt.bufPrint(&encoded, "{{\"server_url\":\"{s}\",\"tokens\":{{\"access_token\":\"A2\",\"refresh_token\":\"R2\"}},\"client_info\":{{\"client_id\":\"client\"}}}}", .{url});

    var store = try Auth.open(testing.allocator, kept.storage());
    defer store.deinit();
    const token = try accessToken(testing.allocator, testing.io, &store, .{ .name = "files", .server_url = url, .client_name = "test" });
    try testing.expectEqualStrings("A2", token.?);

    var next_run = try Auth.open(testing.allocator, kept.storage());
    defer next_run.deinit();
    try testing.expectEqualStrings("R2", next_run.get("files").?.tokens.?.refresh_token.?);
}

test "a token endpoint that fails for its own reasons leaves the sign-in alone" {
    var kept: OneEntry = .{};
    defer kept.deinit();
    var endpoint = try fakeEndpoint(&kept, "500 Internal Server Error",
        \\{"error":"server_error"}
    );
    const url = try endpoint.start();
    defer endpoint.stop();
    try signInWithSpentToken(&kept, url);

    var store = try Auth.open(testing.allocator, kept.storage());
    defer store.deinit();
    try testing.expectError(Error.TokenRequestFailed, accessToken(testing.allocator, testing.io, &store, .{ .name = "files", .server_url = url, .client_name = "test" }));

    var next_run = try Auth.open(testing.allocator, kept.storage());
    defer next_run.deinit();
    try testing.expectEqualStrings("R1", next_run.get("files").?.tokens.?.refresh_token.?);
}

test "stored tokens are copied, not borrowed" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    {
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();

        try store.updateTokens("files", .{
            .access_token = try scratch.allocator().dupe(u8, "from-scratch"),
            .refresh_token = try scratch.allocator().dupe(u8, "refresh-me"),
        }, try scratch.allocator().dupe(u8, "https://mcp.example/mcp"));
    }

    const entry = store.getForUrl("files", "https://mcp.example/mcp").?;
    try testing.expectEqualStrings("from-scratch", entry.tokens.?.access_token);
    try testing.expectEqualStrings("refresh-me", entry.tokens.?.refresh_token.?);
}

test "configured scopes win, and the metadata fills in for silence" {
    const configured: []const []const u8 = &.{"read"};
    const offered: []const []const u8 = &.{"internal"};

    try testing.expectEqualStrings("read", chosenScopes(configured, offered)[0]);
    try testing.expectEqualStrings("internal", chosenScopes(&.{}, offered)[0]);
    try testing.expectEqual(@as(usize, 0), chosenScopes(&.{}, &.{}).len);
}
