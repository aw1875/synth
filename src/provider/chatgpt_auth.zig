//! Sign in with ChatGPT, for using a ChatGPT plan as the model backend.
//!
//! The open-source flow: https://developers.openai.com/siwc/token-sharing-open-source
//! The first sign-in registers synth as its own OAuth client on the user's
//! account; later sign-ins reuse the client it was issued.

const std = @import("std");
const builtin = @import("builtin");

const mcp = @import("mcp");
const pkg = @import("pkg");

const Callback = mcp.Callback;

pub const issuer = "https://auth.openai.com";
pub const resource = "https://api.openai.com/v1";
pub const usage_url = "https://chatgpt.com/settings/usage";
pub const plan_scope = "chatgpt.tokens.use.direct";

const authorize_url = issuer ++ "/api/accounts/authorize";
const token_url = issuer ++ "/api/accounts/oauth/token";
const revoke_url = issuer ++ "/api/accounts/oauth/revoke";
const jwks_url = issuer ++ "/.well-known/jwks.json";
const requested_scopes = "openid profile email offline_access resource.invoke " ++ plan_scope;
const registration_client_id = "dynamic_agent_client";
const callback_port: u16 = 1455;
const callback_path = "/auth/callback";
const callback_poll_ns: u64 = 250 * std.time.ns_per_ms;
pub const sign_in_timeout_ns: u64 = 10 * std.time.ns_per_min;
/// Renew this long before the access token runs out, so a turn never starts
/// on one that dies mid-stream.
const expiry_skew_seconds: i64 = 120;
const max_body_bytes: usize = 256 * 1024;
const max_file_bytes: usize = 64 * 1024;

const owner_only: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    .fromMode(0o600)
else
    .default_file;

pub const Error = error{
    NotSignedIn,
    PlanUsageNotGranted,
    AuthorizationDenied,
    SignInCanceled,
    SignInTimedOut,
    RegistrationIncomplete,
    ClientMismatch,
    AccountMismatch,
    TokenExchangeFailed,
    SessionExpired,
    InvalidIdToken,
};

/// What one signed-in ChatGPT account leaves on disk. The client id and host
/// id outlive a sign-out: signing in again reuses both.
pub const Credentials = struct {
    client_id: []const u8 = "",
    ext_agent_host_id: []const u8 = "",
    subject: []const u8 = "",
    email: []const u8 = "",
    id_token: []const u8 = "",
    access_token: []const u8 = "",
    refresh_token: []const u8 = "",
    scope: []const u8 = "",
    expires_at: i64 = 0,

    pub fn signedIn(self: Credentials) bool {
        return self.refresh_token.len > 0 or self.access_token.len > 0;
    }

    pub fn grantsPlanUsage(self: Credentials) bool {
        var scopes = std.mem.tokenizeScalar(u8, self.scope, ' ');
        while (scopes.next()) |scope| {
            if (std.mem.eql(u8, scope, plan_scope)) return true;
        }
        return false;
    }
};

/// The credential file and the one account it holds. Shared between the UI
/// thread, which signs in and out, and the worker running a turn, which
/// refreshes; every access goes through `mutex`.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    credentials: Credentials = .{},

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .path = try allocator.dupe(u8, path),
            .arena = .init(allocator),
        };
        errdefer allocator.free(self.path);
        self.credentials = readFile(self.arena.allocator(), io, path) catch .{};
        return self;
    }

    pub fn destroy(self: *Store) void {
        self.arena.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// A copy of what is held now, allocated in `arena`.
    pub fn snapshot(self: *Store, arena: std.mem.Allocator) !Credentials {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return dupeCredentials(arena, self.credentials);
    }

    pub fn signedIn(self: *Store) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.credentials.signedIn();
    }

    /// An access token good for at least the next request, renewed first when
    /// the held one is about to run out. Allocated in `arena`.
    pub fn accessToken(self: *Store, arena: std.mem.Allocator) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!self.credentials.signedIn()) return Error.NotSignedIn;
        if (!expiresSoon(self.io, self.credentials.expires_at)) return arena.dupe(u8, self.credentials.access_token);

        try self.refreshLocked();
        return arena.dupe(u8, self.credentials.access_token);
    }

    /// Renew now, whatever the held token's expiry says. For a request the
    /// server refused as unauthorized.
    pub fn forceRefresh(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.credentials.signedIn()) return Error.NotSignedIn;
        try self.refreshLocked();
    }

    /// Another process may have renewed first, in which case its rotated token
    /// is adopted rather than spending ours, which would revoke the session.
    fn refreshLocked(self: *Store) !void {
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);

        var scratch_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        const on_disk = readFile(scratch, self.io, self.path) catch Credentials{};
        const renewed_elsewhere = on_disk.refresh_token.len > 0 and
            !std.mem.eql(u8, on_disk.refresh_token, self.credentials.refresh_token) and
            !expiresSoon(self.io, on_disk.expires_at);
        if (renewed_elsewhere) return self.replace(on_disk);

        if (self.credentials.refresh_token.len == 0) return Error.SessionExpired;

        const tokens = try requestRefresh(scratch, self.io, self.credentials.client_id, self.credentials.refresh_token);
        var renewed = self.credentials;
        renewed.access_token = tokens.access_token;
        renewed.refresh_token = if (tokens.refresh_token.len > 0) tokens.refresh_token else self.credentials.refresh_token;
        renewed.expires_at = unixSeconds(self.io) + tokens.expires_in;
        if (tokens.scope.len > 0) renewed.scope = tokens.scope;
        if (tokens.id_token.len > 0) renewed.id_token = tokens.id_token;

        try writeFile(self.io, self.path, renewed);
        try self.replace(renewed);
    }

    /// Hold `fresh` in place of what was held. Copied into a new arena so the
    /// old strings can be released in one go.
    fn replace(self: *Store, fresh: Credentials) !void {
        var next: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer next.deinit();
        const copied = try dupeCredentials(next.allocator(), fresh);
        self.arena.deinit();
        self.arena = next;
        self.credentials = copied;
    }

    /// Record a completed sign-in.
    fn adopt(self: *Store, fresh: Credentials) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);
        try writeFile(self.io, self.path, fresh);
        try self.replace(fresh);
    }

    /// The host id, minted and saved on first use. Never a credential: it says
    /// which installation is asking, not who.
    fn hostId(self: *Store, arena: std.mem.Allocator) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.credentials.ext_agent_host_id.len > 0) return arena.dupe(u8, self.credentials.ext_agent_host_id);

        var minted = self.credentials;
        minted.ext_agent_host_id = try newHostId(arena, self.io);
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);
        try writeFile(self.io, self.path, minted);
        try self.replace(minted);
        return arena.dupe(u8, self.credentials.ext_agent_host_id);
    }

    /// End the session at OpenAI and forget its tokens, keeping the client and
    /// host ids for the next sign-in. Returns whether OpenAI confirmed it.
    pub fn signOut(self: *Store) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const revoked = revoke(self.allocator, self.io, self.credentials.client_id, self.credentials.refresh_token);

        const cleared: Credentials = .{
            .client_id = self.credentials.client_id,
            .ext_agent_host_id = self.credentials.ext_agent_host_id,
            .subject = self.credentials.subject,
            .email = self.credentials.email,
        };
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);
        try writeFile(self.io, self.path, cleared);
        try self.replace(cleared);
        return revoked;
    }
};

/// `chatgpt.json`, beside `auth.json`. A file of its own because its refresh
/// token rotates: a store that rewrites every provider's key at once would
/// eventually write a spent one back.
pub fn defaultPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (builtin.mode == .Debug) return allocator.dupe(u8, "chatgpt.json");
    const base = env.get("XDG_DATA_HOME") orelse blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    };
    defer if (env.get("XDG_DATA_HOME") == null) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, pkg.name, "chatgpt.json" });
}

/// A browser sign-in that has been started and not yet settled. Built on one
/// thread, waited on by another, and canceled from either.
pub const SignIn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    arena: std.heap.ArenaAllocator,
    listener: *Callback.Listener,
    /// The page to open. Printed as well as opened: over SSH there is no
    /// browser to open it in.
    url: []const u8,
    redirect_uri: []const u8,
    verifier: []const u8,
    nonce: []const u8,
    /// The issued client being reauthorized, or empty for a first sign-in.
    saved_client_id: []const u8,
    previous_subject: []const u8,
    host_id: []const u8,
    canceled: std.atomic.Value(bool) = .init(false),

    pub fn begin(allocator: std.mem.Allocator, io: std.Io, store: *Store) !*SignIn {
        const self = try allocator.create(SignIn);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .arena = .init(allocator),
            .listener = undefined,
            .url = "",
            .redirect_uri = "",
            .verifier = "",
            .nonce = "",
            .saved_client_id = "",
            .previous_subject = "",
            .host_id = "",
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();

        const saved = try store.snapshot(arena);
        self.saved_client_id = saved.client_id;
        self.previous_subject = saved.subject;
        self.host_id = try store.hostId(arena);

        const state = try randomToken(arena, io);
        self.nonce = try randomToken(arena, io);
        self.verifier = try randomToken(arena, io);

        self.listener = try Callback.Listener.start(allocator, io, .{
            .state = state,
            .port = callback_port,
            .path = callback_path,
        });
        errdefer self.listener.deinit();
        self.redirect_uri = try self.listener.redirectUri(arena);

        self.url = try authorizationUrl(arena, .{
            .client_id = if (saved.client_id.len > 0) saved.client_id else registration_client_id,
            .registering = saved.client_id.len == 0,
            .host_id = self.host_id,
            .redirect_uri = self.redirect_uri,
            .state = state,
            .nonce = self.nonce,
            .challenge = try pkceChallenge(arena, self.verifier),
            .id_token_hint = saved.id_token,
            .login_hint = saved.email,
        });
        return self;
    }

    pub fn cancel(self: *SignIn) void {
        self.canceled.store(true, .release);
    }

    /// Wait for the browser, then trade the code for tokens and store them.
    /// Blocks for as long as the person takes, up to `timeout_ns`.
    pub fn finish(self: *SignIn, timeout_ns: u64) !Credentials {
        const outcome = try self.waitForCallback(timeout_ns);
        const code = switch (outcome) {
            .denied => return Error.AuthorizationDenied,
            .code => |code| code,
        };

        const arena = self.arena.allocator();
        const client_id = try self.issuedClientId(code.client_id);

        const tokens = try exchangeCode(arena, self.io, .{
            .client_id = client_id,
            .code = code.code,
            .verifier = self.verifier,
            .redirect_uri = self.redirect_uri,
        });
        const identity = try verifyIdToken(arena, self.io, tokens.id_token, client_id, self.nonce);

        const switched_account = self.previous_subject.len > 0 and !std.mem.eql(u8, identity.subject, self.previous_subject);
        if (switched_account and self.saved_client_id.len > 0) return Error.AccountMismatch;

        const fresh: Credentials = .{
            .client_id = client_id,
            .ext_agent_host_id = self.host_id,
            .subject = identity.subject,
            .email = identity.email,
            .id_token = tokens.id_token,
            .access_token = tokens.access_token,
            .refresh_token = tokens.refresh_token,
            .scope = tokens.scope,
            .expires_at = unixSeconds(self.io) + tokens.expires_in,
        };
        try self.store.adopt(fresh);
        if (!fresh.grantsPlanUsage()) return Error.PlanUsageNotGranted;
        return fresh;
    }

    fn waitForCallback(self: *SignIn, timeout_ns: u64) !Callback.Outcome {
        var waited: u64 = 0;
        while (waited < timeout_ns) : (waited += callback_poll_ns) {
            if (self.canceled.load(.acquire)) return Error.SignInCanceled;
            return self.listener.wait(callback_poll_ns) catch |err| switch (err) {
                error.Timeout => continue,
                else => |other| return other,
            };
        }
        return Error.SignInTimedOut;
    }

    /// A first registration names its new client in the redirect; a returning
    /// one may omit it, and must not name a different one.
    fn issuedClientId(self: *SignIn, returned: ?[]const u8) ![]const u8 {
        if (self.saved_client_id.len == 0) {
            const issued = returned orelse return Error.RegistrationIncomplete;
            if (issued.len == 0 or std.mem.eql(u8, issued, registration_client_id)) return Error.RegistrationIncomplete;
            return self.arena.allocator().dupe(u8, issued);
        }
        const named = returned orelse return self.saved_client_id;
        if (!std.mem.eql(u8, named, self.saved_client_id)) return Error.ClientMismatch;
        return self.saved_client_id;
    }

    pub fn destroy(self: *SignIn) void {
        self.listener.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

const AuthorizationRequest = struct {
    client_id: []const u8,
    registering: bool,
    host_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    nonce: []const u8,
    challenge: []const u8,
    id_token_hint: []const u8,
    login_hint: []const u8,
};

fn authorizationUrl(arena: std.mem.Allocator, request: AuthorizationRequest) ![]const u8 {
    var url: std.Io.Writer.Allocating = .init(arena);
    const w = &url.writer;
    try w.writeAll(authorize_url);
    var first = true;
    try queryParam(w, &first, "client_id", request.client_id);
    try queryParam(w, &first, "ext_agent_host_id", request.host_id);
    if (request.registering) try queryParam(w, &first, "agent_name_hint", pkg.name);
    try queryParam(w, &first, "response_type", "code");
    try queryParam(w, &first, "redirect_uri", request.redirect_uri);
    try queryParam(w, &first, "scope", requested_scopes);
    try queryParam(w, &first, "resource", resource);
    try queryParam(w, &first, "state", request.state);
    try queryParam(w, &first, "nonce", request.nonce);
    try queryParam(w, &first, "code_challenge_method", "S256");
    try queryParam(w, &first, "code_challenge", request.challenge);
    if (!request.registering and request.id_token_hint.len > 0) try queryParam(w, &first, "id_token_hint", request.id_token_hint);
    if (!request.registering and request.login_hint.len > 0) try queryParam(w, &first, "login_hint", request.login_hint);
    return url.toOwnedSlice();
}

fn queryParam(w: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8) !void {
    try w.writeByte(if (first.*) '?' else '&');
    first.* = false;
    try w.writeAll(name);
    try w.writeByte('=');
    try percentEncode(w, value);
}

fn percentEncode(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (unreserved) {
            try w.writeByte(byte);
        } else {
            try w.print("%{X:0>2}", .{byte});
        }
    }
}

const TokenResponse = struct {
    access_token: []const u8 = "",
    refresh_token: []const u8 = "",
    id_token: []const u8 = "",
    scope: []const u8 = "",
    expires_in: i64 = 3600,
};

const CodeExchange = struct {
    client_id: []const u8,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
};

fn exchangeCode(arena: std.mem.Allocator, io: std.Io, exchange: CodeExchange) !TokenResponse {
    var form: std.Io.Writer.Allocating = .init(arena);
    var first = true;
    try formParam(&form.writer, &first, "grant_type", "authorization_code");
    try formParam(&form.writer, &first, "client_id", exchange.client_id);
    try formParam(&form.writer, &first, "code", exchange.code);
    try formParam(&form.writer, &first, "code_verifier", exchange.verifier);
    try formParam(&form.writer, &first, "redirect_uri", exchange.redirect_uri);
    try formParam(&form.writer, &first, "resource", resource);

    const reply = try postForm(arena, io, token_url, form.written());
    if (reply.status.class() != .success) return Error.TokenExchangeFailed;
    const tokens = std.json.parseFromSliceLeaky(TokenResponse, arena, reply.body, .{ .ignore_unknown_fields = true }) catch
        return Error.TokenExchangeFailed;
    if (tokens.access_token.len == 0 or tokens.id_token.len == 0) return Error.TokenExchangeFailed;
    return tokens;
}

fn requestRefresh(arena: std.mem.Allocator, io: std.Io, client_id: []const u8, refresh_token: []const u8) !TokenResponse {
    var form: std.Io.Writer.Allocating = .init(arena);
    var first = true;
    try formParam(&form.writer, &first, "grant_type", "refresh_token");
    try formParam(&form.writer, &first, "client_id", client_id);
    try formParam(&form.writer, &first, "refresh_token", refresh_token);
    try formParam(&form.writer, &first, "resource", resource);

    const reply = try postForm(arena, io, token_url, form.written());
    if (reply.status.class() == .server_error) return error.RefreshUnavailable;
    if (reply.status.class() != .success) return Error.SessionExpired;
    const tokens = std.json.parseFromSliceLeaky(TokenResponse, arena, reply.body, .{ .ignore_unknown_fields = true }) catch
        return error.RefreshUnavailable;
    if (tokens.access_token.len == 0) return error.RefreshUnavailable;
    return tokens;
}

/// An empty 200 is success, including for a token that was already dead.
fn revoke(allocator: std.mem.Allocator, io: std.Io, client_id: []const u8, refresh_token: []const u8) bool {
    if (refresh_token.len == 0 or client_id.len == 0) return true;
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var form: std.Io.Writer.Allocating = .init(arena);
    var first = true;
    formParam(&form.writer, &first, "token", refresh_token) catch return false;
    formParam(&form.writer, &first, "token_type_hint", "refresh_token") catch return false;
    formParam(&form.writer, &first, "client_id", client_id) catch return false;

    const reply = postForm(arena, io, revoke_url, form.written()) catch return false;
    return reply.status == .ok;
}

fn formParam(w: *std.Io.Writer, first: *bool, name: []const u8, value: []const u8) !void {
    if (!first.*) try w.writeByte('&');
    first.* = false;
    try w.writeAll(name);
    try w.writeByte('=');
    try percentEncode(w, value);
}

const HttpReply = struct { status: std.http.Status, body: []const u8 };

fn postForm(arena: std.mem.Allocator, io: std.Io, url: []const u8, form: []const u8) !HttpReply {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = form,
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .response_writer = &body.writer,
    });
    return .{ .status = result.status, .body = body.written() };
}

fn getBody(arena: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .response_writer = &body.writer,
    });
    if (result.status.class() != .success) return error.HttpError;
    return body.written();
}

const Identity = struct { subject: []const u8, email: []const u8 };

const IdTokenHeader = struct { alg: []const u8 = "", kid: []const u8 = "" };

const IdTokenClaims = struct {
    iss: []const u8 = "",
    sub: []const u8 = "",
    aud: std.json.Value = .null,
    exp: i64 = 0,
    nonce: []const u8 = "",
    email: []const u8 = "",
};

/// Check the ID token's signature against OpenAI's published keys, then its
/// issuer, audience, expiry and nonce.
fn verifyIdToken(arena: std.mem.Allocator, io: std.Io, id_token: []const u8, client_id: []const u8, nonce: []const u8) !Identity {
    const parts = try splitJwt(id_token);
    const header = std.json.parseFromSliceLeaky(IdTokenHeader, arena, try decodeSegment(arena, parts.header), .{ .ignore_unknown_fields = true }) catch
        return Error.InvalidIdToken;
    if (!std.mem.eql(u8, header.alg, "RS256")) return Error.InvalidIdToken;

    const jwks = try getBody(arena, io, jwks_url);
    const key = try findSigningKey(arena, jwks, header.kid);
    const signature = try decodeSegment(arena, parts.signature);
    try verifyRs256(key, parts.signed, signature);

    const claims = std.json.parseFromSliceLeaky(IdTokenClaims, arena, try decodeSegment(arena, parts.payload), .{ .ignore_unknown_fields = true }) catch
        return Error.InvalidIdToken;
    try checkClaims(claims, client_id, nonce, unixSeconds(io));
    return .{ .subject = claims.sub, .email = claims.email };
}

fn checkClaims(claims: IdTokenClaims, client_id: []const u8, nonce: []const u8, now: i64) !void {
    if (!std.mem.eql(u8, claims.iss, issuer)) return Error.InvalidIdToken;
    if (!audienceIncludes(claims.aud, client_id)) return Error.InvalidIdToken;
    if (claims.exp <= now) return Error.InvalidIdToken;
    if (!std.mem.eql(u8, claims.nonce, nonce)) return Error.InvalidIdToken;
    if (claims.sub.len == 0) return Error.InvalidIdToken;
}

fn audienceIncludes(aud: std.json.Value, client_id: []const u8) bool {
    return switch (aud) {
        .string => |single| std.mem.eql(u8, single, client_id),
        .array => |list| for (list.items) |entry| {
            if (entry == .string and std.mem.eql(u8, entry.string, client_id)) break true;
        } else false,
        else => false,
    };
}

const JwtParts = struct { header: []const u8, payload: []const u8, signature: []const u8, signed: []const u8 };

fn splitJwt(token: []const u8) !JwtParts {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return Error.InvalidIdToken;
    const second_dot = std.mem.indexOfScalarPos(u8, token, first_dot + 1, '.') orelse return Error.InvalidIdToken;
    return .{
        .header = token[0..first_dot],
        .payload = token[first_dot + 1 .. second_dot],
        .signature = token[second_dot + 1 ..],
        .signed = token[0..second_dot],
    };
}

fn decodeSegment(arena: std.mem.Allocator, segment: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(segment) catch return Error.InvalidIdToken;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, segment) catch return Error.InvalidIdToken;
    return out;
}

const SigningKey = struct { modulus: []const u8, exponent: []const u8 };

fn findSigningKey(arena: std.mem.Allocator, jwks: []const u8, kid: []const u8) !SigningKey {
    const Jwks = struct {
        keys: []const struct { kid: []const u8 = "", kty: []const u8 = "", n: []const u8 = "", e: []const u8 = "" } = &.{},
    };
    const parsed = std.json.parseFromSliceLeaky(Jwks, arena, jwks, .{ .ignore_unknown_fields = true }) catch
        return Error.InvalidIdToken;
    for (parsed.keys) |key| {
        if (!std.mem.eql(u8, key.kid, kid) or !std.mem.eql(u8, key.kty, "RSA")) continue;
        return .{ .modulus = try decodeSegment(arena, key.n), .exponent = try decodeSegment(arena, key.e) };
    }
    return Error.InvalidIdToken;
}

fn verifyRs256(key: SigningKey, signed: []const u8, signature: []const u8) !void {
    const rsa = std.crypto.Certificate.rsa;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const public_key = rsa.PublicKey.fromBytes(key.exponent, key.modulus) catch return Error.InvalidIdToken;
    switch (key.modulus.len) {
        inline 256, 384, 512 => |modulus_len| {
            if (signature.len != modulus_len) return Error.InvalidIdToken;
            rsa.PKCS1v1_5Signature.verify(modulus_len, signature[0..modulus_len].*, signed, public_key, Sha256) catch
                return Error.InvalidIdToken;
        },
        else => return Error.InvalidIdToken,
    }
}

fn pkceChallenge(arena: std.mem.Allocator, verifier: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return base64Url(arena, &digest);
}

fn randomToken(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    return base64Url(arena, &bytes);
}

fn base64Url(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(out, bytes);
}

fn newHostId(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(arena, "urn:uuid:{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
}

fn expiresSoon(io: std.Io, expires_at: i64) bool {
    return unixSeconds(io) + expiry_skew_seconds >= expires_at;
}

fn unixSeconds(io: std.Io) i64 {
    return @divTrunc(std.Io.Timestamp.now(io, .real).toMilliseconds(), std.time.ms_per_s);
}

fn dupeCredentials(arena: std.mem.Allocator, source: Credentials) !Credentials {
    var copy = source;
    inline for (std.meta.fields(Credentials)) |field| {
        if (field.type == []const u8) @field(copy, field.name) = try arena.dupe(u8, @field(source, field.name));
    }
    return copy;
}

fn readFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Credentials {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Credentials, arena, source, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Atomic and owner-only, through a temporary file of this process's own so
/// two instances saving at once cannot interleave into one.
fn writeFile(io: std.Io, path: []const u8, credentials: Credentials) !void {
    const Config = @import("../core/config.zig");
    try Config.ensureDir(io, path);

    var suffix_bytes: [8]u8 = undefined;
    io.random(&suffix_bytes);
    const suffix = std.fmt.bytesToHex(suffix_bytes, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = std.fmt.bufPrint(&temp_buffer, "{s}.{s}.tmp", .{ path, suffix }) catch return error.NameTooLong;

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .permissions = owner_only });
        errdefer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
        defer file.close(io);

        var buffer: [1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try std.json.Stringify.value(credentials, .{ .whitespace = .indent_2 }, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        try file.sync(io);
    }
    errdefer std.Io.Dir.cwd().deleteFile(io, temp_path) catch {};
    try std.Io.Dir.cwd().rename(temp_path, std.Io.Dir.cwd(), path, io);
}

/// Serializes refreshes across synth processes sharing one credential file.
const FileLock = struct {
    file: std.Io.File,

    fn acquire(io: std.Io, credential_path: []const u8) !FileLock {
        const Config = @import("../core/config.zig");
        try Config.ensureDir(io, credential_path);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&buffer, "{s}.lock", .{credential_path}) catch return error.NameTooLong;
        const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .permissions = owner_only, .truncate = false });
        errdefer file.close(io);
        try file.lock(io, .exclusive);
        return .{ .file = file };
    }

    fn release(self: *FileLock, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
    }
};

const testing = std.testing;

test "a first sign-in registers synth by name, a returning one reuses its client" {
    const first = try authorizationUrl(testing.allocator, .{
        .client_id = registration_client_id,
        .registering = true,
        .host_id = "urn:uuid:1234",
        .redirect_uri = "http://127.0.0.1:1455/auth/callback",
        .state = "s",
        .nonce = "n",
        .challenge = "c",
        .id_token_hint = "",
        .login_hint = "",
    });
    defer testing.allocator.free(first);
    try testing.expect(std.mem.startsWith(u8, first, authorize_url ++ "?client_id=dynamic_agent_client&"));
    try testing.expect(std.mem.indexOf(u8, first, "agent_name_hint=" ++ pkg.name) != null);
    try testing.expect(std.mem.indexOf(u8, first, "redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback") != null);
    try testing.expect(std.mem.indexOf(u8, first, "scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct") != null);
    try testing.expect(std.mem.indexOf(u8, first, "id_token_hint") == null);

    const again = try authorizationUrl(testing.allocator, .{
        .client_id = "oaiapp_abc",
        .registering = false,
        .host_id = "urn:uuid:1234",
        .redirect_uri = "http://127.0.0.1:1455/auth/callback",
        .state = "s",
        .nonce = "n",
        .challenge = "c",
        .id_token_hint = "hint",
        .login_hint = "a@b.c",
    });
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "client_id=oaiapp_abc") != null);
    try testing.expect(std.mem.indexOf(u8, again, "agent_name_hint") == null);
    try testing.expect(std.mem.indexOf(u8, again, "id_token_hint=hint") != null);
    try testing.expect(std.mem.indexOf(u8, again, "login_hint=a%40b.c") != null);
}

test "only the plan scope makes a sign-in usable for inference" {
    const identity_only: Credentials = .{ .access_token = "a", .scope = "openid email profile" };
    const with_plan: Credentials = .{ .access_token = "a", .scope = "openid " ++ plan_scope ++ " email" };
    try testing.expect(!identity_only.grantsPlanUsage());
    try testing.expect(with_plan.grantsPlanUsage());
    try testing.expect(!(Credentials{}).signedIn());
}

test "the PKCE challenge is the RFC 7636 example" {
    const challenge = try pkceChallenge(testing.allocator, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    defer testing.allocator.free(challenge);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge);
}

test "a host id is a v4 UUID URN" {
    const id = try newHostId(testing.allocator, testing.io);
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, "urn:uuid:".len + 36), id.len);
    try testing.expect(std.mem.startsWith(u8, id, "urn:uuid:"));
    try testing.expectEqual(@as(u8, '4'), id["urn:uuid:".len + 14]);
}

test "claims must name this client, this nonce, and OpenAI" {
    var audience_list = std.json.Array.init(testing.allocator);
    defer audience_list.deinit();
    try audience_list.append(.{ .string = "oaiapp_abc" });
    const good: IdTokenClaims = .{ .iss = issuer, .sub = "user-1", .aud = .{ .array = audience_list }, .exp = 2000, .nonce = "n1" };
    try checkClaims(good, "oaiapp_abc", "n1", 1000);

    var wrong_client = good;
    wrong_client.aud = .{ .string = "oaiapp_other" };
    try testing.expectError(Error.InvalidIdToken, checkClaims(wrong_client, "oaiapp_abc", "n1", 1000));
    try testing.expectError(Error.InvalidIdToken, checkClaims(good, "oaiapp_abc", "other-nonce", 1000));
    try testing.expectError(Error.InvalidIdToken, checkClaims(good, "oaiapp_abc", "n1", 3000));
    var wrong_issuer = good;
    wrong_issuer.iss = "https://evil.example";
    try testing.expectError(Error.InvalidIdToken, checkClaims(wrong_issuer, "oaiapp_abc", "n1", 1000));
}

test "an RS256 signature verifies against its key and nothing else" {
    // RFC 7515 appendix A.2: an RS256 JWS with its published key.
    const modulus_b64 = "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ";
    const exponent_b64 = "AQAB";
    const signed = "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";
    const signature_b64 = "cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw";

    const arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const key: SigningKey = .{
        .modulus = try decodeSegment(arena.allocator(), modulus_b64),
        .exponent = try decodeSegment(arena.allocator(), exponent_b64),
    };
    const signature = try decodeSegment(arena.allocator(), signature_b64);
    try verifyRs256(key, signed, signature);
    try testing.expectError(Error.InvalidIdToken, verifyRs256(key, signed ++ "x", signature));
}

test "credentials survive a save and a load, owner-only" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "chatgpt.json" });
    defer testing.allocator.free(path);

    try writeFile(io, path, .{ .client_id = "oaiapp_abc", .refresh_token = "r", .scope = plan_scope, .expires_at = 42 });

    const store = try Store.open(testing.allocator, io, path);
    defer store.destroy();
    try testing.expect(store.signedIn());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const held = try store.snapshot(arena_state.allocator());
    try testing.expectEqualStrings("oaiapp_abc", held.client_id);
    try testing.expectEqual(@as(i64, 42), held.expires_at);

    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "a token another process already renewed is adopted, not spent again" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "chatgpt.json" });
    defer testing.allocator.free(path);

    try writeFile(io, path, .{ .client_id = "c", .access_token = "old", .refresh_token = "r1", .expires_at = 0 });
    const store = try Store.open(testing.allocator, io, path);
    defer store.destroy();

    const far_future = unixSeconds(io) + 3600;
    try writeFile(io, path, .{ .client_id = "c", .access_token = "new", .refresh_token = "r2", .expires_at = far_future });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("new", try store.accessToken(arena_state.allocator()));
}

test "signing out keeps the client and host so the next sign-in reuses them" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "chatgpt.json" });
    defer testing.allocator.free(path);

    try writeFile(io, path, .{ .client_id = "c", .ext_agent_host_id = "urn:uuid:h", .access_token = "a", .expires_at = 1 });
    const store = try Store.open(testing.allocator, io, path);
    defer store.destroy();

    _ = try store.signOut();
    try testing.expect(!store.signedIn());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const held = try store.snapshot(arena_state.allocator());
    try testing.expectEqualStrings("c", held.client_id);
    try testing.expectEqualStrings("urn:uuid:h", held.ext_agent_host_id);
}
