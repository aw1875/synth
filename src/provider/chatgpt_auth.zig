//! Sign in with ChatGPT, for using a ChatGPT plan as the model backend.
//!
//! The open-source flow: https://developers.openai.com/siwc/token-sharing-open-source
//! The first sign-in registers synth as its own OAuth client on the user's
//! account; later sign-ins reuse the client it was issued.

const std = @import("std");

const mcp = @import("mcp");
const pkg = @import("pkg");

const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");

const Callback = mcp.Callback;

pub const resource = "https://api.openai.com/v1";
pub const usage_url = "https://chatgpt.com/settings/usage";

const issuer = "https://auth.openai.com";
const plan_scope = "chatgpt.tokens.use.direct";
const authorize_url = issuer ++ "/api/accounts/authorize";
const token_url = issuer ++ "/api/accounts/oauth/token";
const revoke_url = issuer ++ "/api/accounts/oauth/revoke";
const jwks_url = issuer ++ "/.well-known/jwks.json";
const requested_scopes = "openid profile email offline_access resource.invoke " ++ plan_scope;
const registration_client_id = "dynamic_agent_client";
const credential_file = "chatgpt.json";
pub const callback_port: u16 = 1455;
const callback_path = "/auth/callback";
const callback_poll_ns: u64 = 250 * std.time.ns_per_ms;
const sign_in_timeout_ns: u64 = 10 * std.time.ns_per_min;
const callback_page =
    \\<h1>ChatGPT sign-in received</h1>
    \\<p>Return to synth to finish. You can close this tab.</p>
;
/// Renew this long before the access token runs out, so a turn never starts
/// on one that dies mid-stream.
const expiry_skew_seconds: i64 = 120;
const max_file_bytes: usize = 64 * 1024;

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
    RefreshUnavailable,
    InvalidIdToken,
    IssuerMismatch,
};

/// What one signed-in ChatGPT account leaves on disk. The host id outlives a
/// sign-out; the rest belongs to the account and goes with it.
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

    pub fn isSignedIn(self: Credentials) bool {
        return self.refresh_token.len > 0 or self.access_token.len > 0;
    }

    pub fn hasPlanUsage(self: Credentials) bool {
        var scopes = std.mem.tokenizeScalar(u8, self.scope, ' ');
        while (scopes.next()) |scope| {
            if (std.mem.eql(u8, scope, plan_scope)) return true;
        }
        return false;
    }

    /// A previous sign-in that came back without the plan permission. Asking
    /// again needs the consent screen, which a returning sign-in otherwise skips.
    fn hasDeclinedPlanUsage(self: Credentials) bool {
        return self.scope.len > 0 and !self.hasPlanUsage();
    }

    /// The same account with its session ended: tokens gone, registration
    /// kept. The ID token stays as the hint that brings the next sign-in back
    /// to this account; an expired one still identifies it.
    fn withoutTokens(self: Credentials) Credentials {
        return .{
            .client_id = self.client_id,
            .ext_agent_host_id = self.ext_agent_host_id,
            .subject = self.subject,
            .email = self.email,
            .scope = self.scope,
            .id_token = self.id_token,
        };
    }
};

/// The credential file and the one account it holds, shared by the UI thread
/// and every worker running a turn.
///
/// The file is the source of truth: another synth process may rotate the
/// refresh token or sign out at any moment. `state_mutex` guards the copy in
/// memory and is never held across network I/O, so the UI can always read it;
/// `session_mutex` serializes the refresh and sign-out round trips.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    state_mutex: std.Io.Mutex = .init,
    session_mutex: std.Io.Mutex = .init,
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

    /// The store at its usual place. The one way in, matching `Auth.open`.
    pub fn openDefault(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !*Store {
        const path = try defaultPath(allocator, env);
        defer allocator.free(path);
        return open(allocator, io, path);
    }

    pub fn destroy(self: *Store) void {
        self.arena.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn snapshot(self: *Store, arena: std.mem.Allocator) !Credentials {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return dupeCredentials(arena, self.credentials);
    }

    pub fn isSignedIn(self: *Store) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.credentials.isSignedIn();
    }

    /// Signed in, with permission to spend the plan. Anything less needs the
    /// browser again.
    pub fn isUsable(self: *Store) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.credentials.isSignedIn() and self.credentials.hasPlanUsage();
    }

    /// An access token good for at least the next request, renewed first when
    /// the held one is about to run out. Allocated in `arena`.
    pub fn accessToken(self: *Store, arena: std.mem.Allocator) ![]const u8 {
        try self.adoptFile();
        if (try self.freshToken(arena)) |token| return token;
        try self.renew(.when_expiring);
        return (try self.freshToken(arena)) orelse Error.SessionExpired;
    }

    /// Take up whatever another process left in the file: a sign-out, or a
    /// token it renewed. The file is written by rename, so a read never sees
    /// half of a save.
    fn adoptFile(self: *Store) !void {
        var scratch_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const on_disk = readFile(scratch, self.io, self.path) catch return;
        const held = try self.snapshot(scratch);
        const is_same = std.mem.eql(u8, on_disk.access_token, held.access_token) and
            std.mem.eql(u8, on_disk.refresh_token, held.refresh_token);
        if (!is_same) try self.hold(on_disk);
    }

    /// Renew now, whatever the held token's expiry says. For a request the
    /// server refused as unauthorized.
    pub fn forceRefresh(self: *Store) !void {
        try self.renew(.always);
    }

    fn freshToken(self: *Store, arena: std.mem.Allocator) !?[]const u8 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (!self.credentials.isSignedIn()) return Error.NotSignedIn;
        if (!self.credentials.hasPlanUsage()) return Error.PlanUsageNotGranted;
        if (isExpiringSoon(self.io, self.credentials.expires_at)) return null;
        return try arena.dupe(u8, self.credentials.access_token);
    }

    const Renewal = enum { when_expiring, always };

    fn renew(self: *Store, renewal: Renewal) !void {
        self.session_mutex.lockUncancelable(self.io);
        defer self.session_mutex.unlock(self.io);
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);

        var scratch_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        const held = try self.snapshot(scratch);
        const on_disk = readFile(scratch, self.io, self.path) catch held;
        if (!on_disk.isSignedIn()) {
            try self.hold(on_disk);
            return Error.NotSignedIn;
        }

        const rotated_elsewhere = !std.mem.eql(u8, on_disk.refresh_token, held.refresh_token);
        if (rotated_elsewhere) try self.hold(on_disk);
        const needs_renewal = renewal == .always and !rotated_elsewhere;
        if (!needs_renewal and !isExpiringSoon(self.io, on_disk.expires_at)) return;

        const tokens = requestRefresh(scratch, self.io, on_disk.client_id, on_disk.refresh_token) catch |err| {
            if (err == Error.SessionExpired) try self.save(on_disk.withoutTokens());
            return err;
        };
        var renewed = on_disk;
        renewed.access_token = tokens.access_token;
        if (tokens.refresh_token.len > 0) renewed.refresh_token = tokens.refresh_token;
        renewed.expires_at = unixSeconds(self.io) + tokens.expires_in;
        if (tokens.scope.len > 0) renewed.scope = tokens.scope;
        try self.save(renewed);
    }

    /// Write to the file and hold the result. Caller holds the file lock.
    fn save(self: *Store, fresh: Credentials) !void {
        try writeFile(self.io, self.path, fresh);
        try self.hold(fresh);
    }

    /// Copied into a new arena so the old strings are released in one go.
    fn hold(self: *Store, fresh: Credentials) !void {
        var next: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer next.deinit();
        const copied = try dupeCredentials(next.allocator(), fresh);

        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        self.arena.deinit();
        self.arena = next;
        self.credentials = copied;
    }

    fn adopt(self: *Store, fresh: Credentials) !void {
        self.session_mutex.lockUncancelable(self.io);
        defer self.session_mutex.unlock(self.io);
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);
        try self.save(fresh);
    }

    /// What a new sign-in starts from: the file as it is now, with a host id
    /// minted and saved if this installation never had one. The host id is
    /// never a credential: it says which installation is asking, not who.
    fn prepareSignIn(self: *Store, arena: std.mem.Allocator) !Credentials {
        self.session_mutex.lockUncancelable(self.io);
        defer self.session_mutex.unlock(self.io);
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);

        var current = readFile(arena, self.io, self.path) catch try self.snapshot(arena);
        if (current.ext_agent_host_id.len == 0) {
            current.ext_agent_host_id = try newHostId(arena, self.io);
            try self.save(current);
        } else {
            try self.hold(current);
        }
        return current;
    }

    /// End the session at OpenAI and forget the account, keeping only the host
    /// id, so the next sign-in may be anyone. Returns whether OpenAI confirmed
    /// the revocation. Network I/O: never call it from the thread that draws.
    pub fn signOut(self: *Store) !bool {
        self.session_mutex.lockUncancelable(self.io);
        defer self.session_mutex.unlock(self.io);
        var lock = try FileLock.acquire(self.io, self.path);
        defer lock.release(self.io);

        var scratch_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        const current = readFile(scratch, self.io, self.path) catch try self.snapshot(scratch);
        const revoked = revoke(scratch, self.io, current.client_id, current.refresh_token);
        try self.save(.{ .ext_agent_host_id = current.ext_agent_host_id });
        return revoked;
    }
};

/// `chatgpt.json`, beside `auth.json`. A file of its own because its refresh
/// token rotates: a store that rewrites every provider's key at once would
/// eventually write a spent one back.
fn defaultPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    return Config.privateDataPath(allocator, env, credential_file);
}

/// A browser sign-in that has been started and not yet settled. Built on one
/// thread, waited on by another, and canceled from either.
pub const SignIn = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    arena: std.heap.ArenaAllocator,
    listener: *Callback.Listener,
    /// The page to open. Shown as well as opened: over SSH there is no
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

        const saved = try store.prepareSignIn(arena);
        self.saved_client_id = saved.client_id;
        self.previous_subject = saved.subject;
        self.host_id = saved.ext_agent_host_id;

        const state = try randomToken(arena, io);
        self.nonce = try randomToken(arena, io);
        self.verifier = try randomToken(arena, io);

        self.listener = try Callback.Listener.start(allocator, io, .{
            .state = state,
            .port = callback_port,
            .path = callback_path,
            .success_page = callback_page,
        });
        errdefer self.listener.deinit();
        self.redirect_uri = try self.listener.redirectUri(arena);

        const registering = saved.client_id.len == 0;
        self.url = try authorizationUrl(arena, .{
            .client_id = if (registering) registration_client_id else saved.client_id,
            .registering = registering,
            .host_id = self.host_id,
            .redirect_uri = self.redirect_uri,
            .state = state,
            .nonce = self.nonce,
            .challenge = try pkceChallenge(arena, self.verifier),
            .login_hint = saved.email,
            .id_token_hint = saved.id_token,
            .ask_consent = saved.hasDeclinedPlanUsage(),
        });
        return self;
    }

    pub fn cancel(self: *SignIn) void {
        self.canceled.store(true, .release);
    }

    fn isCanceled(self: *SignIn) bool {
        return self.canceled.load(.acquire);
    }

    /// Wait for the browser, then trade the code for tokens and store them.
    /// Blocks for as long as the person takes, up to the sign-in timeout.
    pub fn finish(self: *SignIn) !void {
        const outcome = try self.waitForCallback();
        const code = switch (outcome) {
            .denied => return Error.AuthorizationDenied,
            .code => |code| code,
        };
        if (code.iss) |named| {
            if (!std.mem.eql(u8, named, issuer)) return Error.IssuerMismatch;
        }

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
        if (switched_account) return Error.AccountMismatch;
        if (self.isCanceled()) return Error.SignInCanceled;

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
        if (!fresh.hasPlanUsage()) return Error.PlanUsageNotGranted;
    }

    fn waitForCallback(self: *SignIn) !Callback.Outcome {
        var waited: u64 = 0;
        while (waited < sign_in_timeout_ns) : (waited += callback_poll_ns) {
            if (self.isCanceled()) return Error.SignInCanceled;
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
    login_hint: []const u8,
    id_token_hint: []const u8 = "",
    ask_consent: bool = false,
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
    if (!request.registering and request.login_hint.len > 0) try queryParam(w, &first, "login_hint", request.login_hint);
    if (!request.registering and request.id_token_hint.len > 0) try queryParam(w, &first, "id_token_hint", request.id_token_hint);
    if (request.ask_consent) try queryParam(w, &first, "prompt", "consent");
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

    const reply = postForm(arena, io, token_url, form.written()) catch return Error.RefreshUnavailable;
    if (reply.status.class() != .success) return refreshFailure(arena, reply);
    const tokens = std.json.parseFromSliceLeaky(TokenResponse, arena, reply.body, .{ .ignore_unknown_fields = true }) catch
        return Error.RefreshUnavailable;
    if (tokens.access_token.len == 0) return Error.RefreshUnavailable;
    return tokens;
}

/// Only a refresh token the server has written off ends the session; anything
/// else (an outage, a throttle) leaves it for the next try.
/// https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery#refresh-errors
fn refreshFailure(arena: std.mem.Allocator, reply: HttpReply) Error {
    const unusable_token_codes = [_][]const u8{
        "invalid_grant",         "invalid_refresh_token",     "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
        "invalid_client",
    };
    const Body = struct { @"error": []const u8 = "" };
    const body = std.json.parseFromSliceLeaky(Body, arena, reply.body, .{ .ignore_unknown_fields = true }) catch Body{};
    for (unusable_token_codes) |code| {
        if (std.mem.eql(u8, body.@"error", code)) return Error.SessionExpired;
    }
    if (reply.status == .unauthorized) return Error.SessionExpired;
    return Error.RefreshUnavailable;
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
    azp: []const u8 = "",
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
    if (!isAudienceOnly(claims.aud, client_id)) return Error.InvalidIdToken;
    if (claims.azp.len > 0 and !std.mem.eql(u8, claims.azp, client_id)) return Error.InvalidIdToken;
    if (claims.exp <= now) return Error.InvalidIdToken;
    if (!std.mem.eql(u8, claims.nonce, nonce)) return Error.InvalidIdToken;
    if (claims.sub.len == 0) return Error.InvalidIdToken;
}

/// A token meant for this client and no other. OIDC Core 3.1.3.7: reject one
/// that also names audiences the client does not trust.
fn isAudienceOnly(aud: std.json.Value, client_id: []const u8) bool {
    return switch (aud) {
        .string => |single| std.mem.eql(u8, single, client_id),
        .array => |list| list.items.len > 0 and for (list.items) |entry| {
            const is_client = entry == .string and std.mem.eql(u8, entry.string, client_id);
            if (!is_client) break false;
        } else true,
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

fn isExpiringSoon(io: std.Io, expires_at: i64) bool {
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
    var suffix_bytes: [8]u8 = undefined;
    io.random(&suffix_bytes);
    const suffix = std.fmt.bytesToHex(suffix_bytes, .lower);
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_path = std.fmt.bufPrint(&temp_buffer, "{s}.{s}.tmp", .{ path, suffix }) catch return error.NameTooLong;

    {
        const file = try std.Io.Dir.cwd().createFile(io, temp_path, .{ .permissions = Auth.owner_only });
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
        try Config.ensureDir(io, credential_path);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&buffer, "{s}.lock", .{credential_path}) catch return error.NameTooLong;
        const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .permissions = Auth.owner_only, .truncate = false });
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
        .login_hint = "",
    });
    defer testing.allocator.free(first);
    try testing.expect(std.mem.startsWith(u8, first, authorize_url ++ "?client_id=dynamic_agent_client&"));
    try testing.expect(std.mem.indexOf(u8, first, "agent_name_hint=" ++ pkg.name) != null);
    try testing.expect(std.mem.indexOf(u8, first, "redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback") != null);
    try testing.expect(std.mem.indexOf(u8, first, "scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct") != null);
    try testing.expect(std.mem.indexOf(u8, first, "prompt=consent") == null);

    const again = try authorizationUrl(testing.allocator, .{
        .client_id = "oaiapp_abc",
        .registering = false,
        .host_id = "urn:uuid:1234",
        .redirect_uri = "http://127.0.0.1:1455/auth/callback",
        .state = "s",
        .nonce = "n",
        .challenge = "c",
        .login_hint = "a@b.c",
        .ask_consent = true,
    });
    defer testing.allocator.free(again);
    try testing.expect(std.mem.indexOf(u8, again, "client_id=oaiapp_abc") != null);
    try testing.expect(std.mem.indexOf(u8, again, "agent_name_hint") == null);
    try testing.expect(std.mem.indexOf(u8, again, "prompt=consent") != null);
    try testing.expect(std.mem.indexOf(u8, again, "login_hint=a%40b.c") != null);
}

test "only the plan scope makes a sign-in usable for inference" {
    const identity_only: Credentials = .{ .access_token = "a", .scope = "openid email profile" };
    const with_plan: Credentials = .{ .access_token = "a", .scope = "openid " ++ plan_scope ++ " email" };
    try testing.expect(!identity_only.hasPlanUsage());
    try testing.expect(identity_only.hasDeclinedPlanUsage());
    try testing.expect(with_plan.hasPlanUsage());
    try testing.expect(!with_plan.hasDeclinedPlanUsage());
    try testing.expect(!(Credentials{}).isSignedIn());
    try testing.expect(!(Credentials{}).hasDeclinedPlanUsage());
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

    var shared_list = std.json.Array.init(testing.allocator);
    defer shared_list.deinit();
    try shared_list.append(.{ .string = "oaiapp_abc" });
    try shared_list.append(.{ .string = "oaiapp_other" });
    var shared = good;
    shared.aud = .{ .array = shared_list };
    try testing.expectError(Error.InvalidIdToken, checkClaims(shared, "oaiapp_abc", "n1", 1000));

    var other_party = good;
    other_party.azp = "oaiapp_other";
    try testing.expectError(Error.InvalidIdToken, checkClaims(other_party, "oaiapp_abc", "n1", 1000));
    var this_party = good;
    this_party.azp = "oaiapp_abc";
    try checkClaims(this_party, "oaiapp_abc", "n1", 1000);
}

test "a token without the plan permission is never handed to a request" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "chatgpt.json" });
    defer testing.allocator.free(path);

    const far_future = unixSeconds(io) + 3600;
    try writeFile(io, path, .{ .client_id = "c", .access_token = "a", .refresh_token = "r", .scope = "openid email", .expires_at = far_future });
    const store = try Store.open(testing.allocator, io, path);
    defer store.destroy();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(Error.PlanUsageNotGranted, store.accessToken(arena_state.allocator()));
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
    try testing.expect(store.isSignedIn());
    try testing.expect(store.isUsable());
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

    try writeFile(io, path, .{ .client_id = "c", .access_token = "old", .refresh_token = "r1", .scope = plan_scope, .expires_at = 0 });
    const store = try Store.open(testing.allocator, io, path);
    defer store.destroy();

    const far_future = unixSeconds(io) + 3600;
    try writeFile(io, path, .{ .client_id = "c", .access_token = "new", .refresh_token = "r2", .scope = plan_scope, .expires_at = far_future });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("new", try store.accessToken(arena_state.allocator()));
}

test "a sign-out another process made is honored, not written back over" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "chatgpt.json" });
    defer testing.allocator.free(path);

    try writeFile(io, path, .{ .client_id = "c", .access_token = "a", .refresh_token = "r1", .scope = plan_scope, .expires_at = 0 });
    const store = try Store.open(testing.allocator, io, path);
    defer store.destroy();
    try writeFile(io, path, .{ .ext_agent_host_id = "urn:uuid:h" });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(Error.NotSignedIn, store.accessToken(arena_state.allocator()));
    try testing.expect(!store.isSignedIn());
}

test "only a written-off refresh token ends the session" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(Error.SessionExpired, refreshFailure(arena, .{ .status = .bad_request, .body = "{\"error\":\"refresh_token_reused\"}" }));
    try testing.expectEqual(Error.SessionExpired, refreshFailure(arena, .{ .status = .bad_request, .body = "{\"error\":\"invalid_client\"}" }));
    try testing.expectEqual(Error.RefreshUnavailable, refreshFailure(arena, .{ .status = .too_many_requests, .body = "" }));
    try testing.expectEqual(Error.RefreshUnavailable, refreshFailure(arena, .{ .status = .service_unavailable, .body = "<html>" }));
}

test "signing out forgets the account but keeps this installation's host id" {
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
    try testing.expect(!store.isSignedIn());
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const held = try store.snapshot(arena_state.allocator());
    try testing.expectEqualStrings("", held.client_id);
    try testing.expectEqualStrings("urn:uuid:h", held.ext_agent_host_id);
}
