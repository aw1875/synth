//! ChatGPT device sign-in and token refresh for the Codex backend.

const std = @import("std");

const mcp = @import("mcp");
const pkg = @import("pkg");

const Auth = @import("../core/auth.zig");

pub const provider_id = "codex";
pub const backend_url = "https://chatgpt.com/backend-api/codex";
pub const issuer_url = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";

const token_endpoint = issuer_url ++ "/oauth/token";
pub const device_login_url = issuer_url ++ "/codex/device";
const user_code_endpoint = issuer_url ++ "/api/accounts/deviceauth/usercode";
const poll_endpoint = issuer_url ++ "/api/accounts/deviceauth/token";
const device_redirect = issuer_url ++ "/deviceauth/callback";
const max_body_bytes: usize = 256 * 1024;
const refresh_window_seconds: i64 = 5 * 60;
const login_timeout_seconds: u64 = 15 * 60;

pub const Tokens = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    account_id: []const u8,
    expires_at: ?i64 = null,
};

/// One background device-code login. The UI polls it without blocking.
pub const Login = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    auth: *Auth,
    arena: std.heap.ArenaAllocator = undefined,
    login_future: std.Io.Future(void) = undefined,
    cancel_future: ?std.Io.Future(void) = null,
    active: bool = false,
    login_finished: std.atomic.Value(bool) = .init(false),
    cancellation_finished: std.atomic.Value(bool) = .init(false),
    code_received: std.atomic.Value(bool) = .init(false),
    code_announced: bool = false,
    user_code: []const u8 = "",
    login_error: ?anyerror = null,

    pub const Result = union(enum) { success, canceled, failed: anyerror };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, auth: *Auth) Login {
        return .{ .allocator = allocator, .io = io, .auth = auth };
    }

    pub fn start(self: *Login) !void {
        if (self.active) return;
        self.arena = .init(self.allocator);
        errdefer self.arena.deinit();
        self.active = true;
        errdefer self.active = false;
        self.login_finished.store(false, .release);
        self.cancellation_finished.store(false, .release);
        self.code_received.store(false, .release);
        self.code_announced = false;
        self.login_error = null;
        self.login_future = try self.io.concurrent(runLogin, .{self});
    }

    pub fn connecting(self: *const Login) bool {
        return self.active;
    }

    pub fn shouldAnnounceCode(self: *Login) bool {
        const already_announced = self.code_announced;
        const code_is_available = self.code_received.load(.acquire);
        const should_announce_code = !already_announced and code_is_available;
        if (!should_announce_code) return false;
        self.code_announced = true;
        return true;
    }

    pub fn activeCode(self: *const Login) ?[]const u8 {
        const code_is_visible = self.active and self.code_received.load(.acquire);
        if (!code_is_visible) return null;
        return self.user_code;
    }

    pub fn takeResult(self: *Login) ?Result {
        if (!self.active) return null;
        if (self.cancel_future) |*cancel_future| {
            const cancellation_is_done = self.cancellation_finished.load(.acquire);
            if (!cancellation_is_done) return null;
            cancel_future.await(self.io);
            self.cancel_future = null;
        }
        const cancellation_is_done = self.cancellation_finished.load(.acquire);
        const login_is_done = self.login_finished.load(.acquire);
        if (!login_is_done) return null;
        if (!cancellation_is_done) self.login_future.await(self.io);
        // Cancellation can lose the race to a completed token exchange.
        const result: Result = if (self.login_error) |login_error| switch (login_error) {
            error.Canceled => .canceled,
            else => .{ .failed = login_error },
        } else .success;
        return self.finalizeResult(result);
    }

    fn finalizeResult(self: *Login, result: Result) Result {
        self.active = false;
        self.arena.deinit();
        return result;
    }

    /// Begin canceling off the caller's thread; `takeResult` reaps it from a tick.
    pub fn cancel(self: *Login) void {
        const cancellation_already_started = self.cancel_future != null or self.cancellation_finished.load(.acquire);
        const can_start_cancellation = self.active and !cancellation_already_started;
        if (!can_start_cancellation) return;
        self.cancellation_finished.store(false, .release);
        if (self.io.concurrent(cancelLogin, .{self})) |cancel_future| {
            self.cancel_future = cancel_future;
        } else |_| {
            self.cancelLogin();
        }
    }

    fn cancelLogin(self: *Login) void {
        self.login_future.cancel(self.io);
        self.cancellation_finished.store(true, .release);
    }

    pub fn deinit(self: *Login) void {
        if (!self.active) return;
        self.cancel();
        if (self.cancel_future) |*cancel_future| cancel_future.await(self.io);
        self.cancel_future = null;
        _ = self.finalizeResult(.canceled);
    }

    fn runLogin(self: *Login) void {
        defer self.login_finished.store(true, .release);
        runDeviceLogin(self) catch |login_error| {
            self.login_error = login_error;
        };
    }
};

fn runDeviceLogin(login: *Login) !void {
    var client: std.http.Client = .{ .allocator = login.allocator, .io = login.io };
    defer client.deinit();

    var scratch_state: std.heap.ArenaAllocator = .init(login.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const request_body = try std.fmt.allocPrint(scratch, "{{\"client_id\":\"{s}\"}}", .{client_id});
    const device_code_response = try postJson(&client, scratch, user_code_endpoint, request_body);
    const device_code_was_issued = device_code_response.status == .ok;
    if (!device_code_was_issued) return error.DeviceCodeUnavailable;

    const device_code_fields = try parseJsonObject(scratch, device_code_response.body);
    const device_auth_id = jsonStringField(device_code_fields, "device_auth_id") orelse return error.InvalidDeviceCode;
    const user_code = jsonStringField(device_code_fields, "user_code") orelse jsonStringField(device_code_fields, "usercode") orelse return error.InvalidDeviceCode;
    const polling_interval_text = jsonStringField(device_code_fields, "interval") orelse "5";
    const polling_interval_seconds = std.math.clamp(std.fmt.parseInt(u64, polling_interval_text, 10) catch 5, 1, 30);
    const login_arena = login.arena.allocator();
    const owned_device_auth_id = try login_arena.dupe(u8, device_auth_id);
    login.user_code = try login_arena.dupe(u8, user_code);
    login.code_received.store(true, .release);
    mcp.Browser.defaultOpen(login.io, device_login_url) catch {};

    var elapsed_seconds: u64 = 0;
    while (elapsed_seconds < login_timeout_seconds) : (elapsed_seconds += polling_interval_seconds) {
        _ = scratch_state.reset(.retain_capacity);
        const poll_body = try std.fmt.allocPrint(scratch, "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}", .{ owned_device_auth_id, login.user_code });
        const poll_response = try postJson(&client, scratch, poll_endpoint, poll_body);
        const login_was_approved = poll_response.status == .ok;
        if (login_was_approved) {
            const approval_fields = try parseJsonObject(scratch, poll_response.body);
            const authorization_code = jsonStringField(approval_fields, "authorization_code") orelse return error.InvalidDeviceCode;
            const code_verifier = jsonStringField(approval_fields, "code_verifier") orelse return error.InvalidDeviceCode;
            return exchangeAuthorizationCode(login, authorization_code, code_verifier);
        }
        const approval_is_pending = poll_response.status == .forbidden or poll_response.status == .not_found;
        if (!approval_is_pending) return error.DeviceCodeRejected;
        try std.Io.sleep(login.io, .fromSeconds(@intCast(polling_interval_seconds)), .awake);
    }
    return error.DeviceCodeExpired;
}

fn exchangeAuthorizationCode(login: *Login, authorization_code: []const u8, code_verifier: []const u8) !void {
    const Response = struct { id_token: []const u8, access_token: []const u8, refresh_token: []const u8 };
    var form_body: std.Io.Writer.Allocating = .init(login.allocator);
    defer form_body.deinit();
    try writeFormParameter(&form_body.writer, false, "grant_type", "authorization_code");
    try writeFormParameter(&form_body.writer, true, "code", authorization_code);
    try writeFormParameter(&form_body.writer, true, "redirect_uri", device_redirect);
    try writeFormParameter(&form_body.writer, true, "client_id", client_id);
    try writeFormParameter(&form_body.writer, true, "code_verifier", code_verifier);

    var client: std.http.Client = .{ .allocator = login.allocator, .io = login.io };
    defer client.deinit();
    const login_arena = login.arena.allocator();
    const token_response = try postBody(&client, login_arena, token_endpoint, form_body.written(), "application/x-www-form-urlencoded");
    const token_exchange_succeeded = token_response.status.class() == .success;
    if (!token_exchange_succeeded) return error.TokenExchangeFailed;
    const response_tokens = std.json.parseFromSliceLeaky(Response, login_arena, token_response.body, .{ .ignore_unknown_fields = true }) catch return error.TokenExchangeFailed;
    const account_id = try accountIdFromIdToken(login_arena, response_tokens.id_token);
    const expires_at = expirationFromJwt(login_arena, response_tokens.access_token) catch null;
    try saveTokens(login.allocator, login.io, login.auth, .{
        .access_token = response_tokens.access_token,
        .refresh_token = response_tokens.refresh_token,
        .account_id = account_id,
        .expires_at = expires_at,
    });
}

pub fn ensureFreshTokens(allocator: std.mem.Allocator, io: std.Io, auth: *Auth) !Tokens {
    const stored_tokens = try loadTokens(allocator, auth);
    const expires_at = stored_tokens.expires_at orelse return stored_tokens;
    const refresh_deadline = unixTimestamp(io) + refresh_window_seconds;
    const expires_soon = expires_at <= refresh_deadline;
    if (expires_soon) return refreshTokens(allocator, io, auth, stored_tokens);
    return stored_tokens;
}

pub fn refreshTokens(allocator: std.mem.Allocator, io: std.Io, auth: *Auth, previous: Tokens) !Tokens {
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{auth.path});
    defer allocator.free(lock_path);
    const auth_file_lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false, .lock = .exclusive });
    defer auth_file_lock.close(io);

    var persisted_auth = try Auth.load(allocator, io, auth.path);
    defer persisted_auth.deinit();
    const stored_tokens = try loadTokens(allocator, &persisted_auth);
    const tokens_changed = !std.mem.eql(u8, stored_tokens.access_token, previous.access_token) or
        !std.mem.eql(u8, stored_tokens.refresh_token, previous.refresh_token);
    const still_fresh = if (stored_tokens.expires_at) |expires_at| expires_at > unixTimestamp(io) + refresh_window_seconds else true;
    if (tokens_changed and still_fresh) {
        // Another process or subagent refreshed while this request was in flight.
        try auth.set(provider_id, persisted_auth.key(provider_id).?);
        return loadTokens(allocator, auth);
    }
    var request_body: std.Io.Writer.Allocating = .init(allocator);
    defer request_body.deinit();
    try request_body.writer.print("{{\"client_id\":\"{s}\",\"grant_type\":\"refresh_token\",\"refresh_token\":", .{client_id});
    try std.json.Stringify.encodeJsonString(stored_tokens.refresh_token, .{}, &request_body.writer);
    try request_body.writer.writeByte('}');

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const refresh_response = try postJson(&client, allocator, token_endpoint, request_body.written());
    const refresh_succeeded = refresh_response.status.class() == .success;
    if (!refresh_succeeded) {
        const credentials_were_rejected = refresh_response.status == .bad_request or refresh_response.status == .unauthorized;
        if (credentials_were_rejected) {
            _ = persisted_auth.remove(provider_id);
            try persisted_auth.save(io, persisted_auth.path);
            _ = auth.remove(provider_id);
        }
        return error.TokenRefreshFailed;
    }

    const Refresh = struct { access_token: ?[]const u8 = null, refresh_token: ?[]const u8 = null };
    const refreshed_fields = std.json.parseFromSliceLeaky(Refresh, allocator, refresh_response.body, .{ .ignore_unknown_fields = true }) catch return error.TokenRefreshFailed;
    const access_token = refreshed_fields.access_token orelse stored_tokens.access_token;
    const refresh_token = refreshed_fields.refresh_token orelse stored_tokens.refresh_token;
    var expires_at = stored_tokens.expires_at;
    if (refreshed_fields.access_token) |new_access_token| {
        expires_at = expirationFromJwt(allocator, new_access_token) catch stored_tokens.expires_at;
    }
    const refreshed_tokens: Tokens = .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .account_id = stored_tokens.account_id,
        .expires_at = expires_at,
    };
    try saveTokens(allocator, io, &persisted_auth, refreshed_tokens);
    const serialized_tokens = persisted_auth.key(provider_id) orelse return error.TokenRefreshFailed;
    try auth.set(provider_id, serialized_tokens);
    return loadTokens(allocator, auth);
}

/// Forget synth's cached Codex session. The browser's ChatGPT session is
/// separate and remains signed in.
pub fn removeStoredTokens(allocator: std.mem.Allocator, io: std.Io, auth: *Auth) !void {
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{auth.path});
    defer allocator.free(lock_path);
    const auth_file_lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false, .lock = .exclusive });
    defer auth_file_lock.close(io);

    var persisted_auth = try Auth.load(allocator, io, auth.path);
    defer persisted_auth.deinit();
    _ = persisted_auth.remove(provider_id);
    try persisted_auth.save(io, persisted_auth.path);
    _ = auth.remove(provider_id);
}

pub fn loadTokens(allocator: std.mem.Allocator, auth: *Auth) !Tokens {
    const serialized_tokens = auth.key(provider_id) orelse return error.NotSignedIn;
    return std.json.parseFromSliceLeaky(Tokens, allocator, serialized_tokens, .{ .ignore_unknown_fields = true }) catch error.NotSignedIn;
}

fn saveTokens(allocator: std.mem.Allocator, io: std.Io, auth: *Auth, tokens: Tokens) !void {
    var serialized_tokens: std.Io.Writer.Allocating = .init(allocator);
    defer serialized_tokens.deinit();
    try std.json.Stringify.value(tokens, .{}, &serialized_tokens.writer);
    try auth.set(provider_id, serialized_tokens.written());
    try auth.save(io, auth.path);
}

const HttpResponse = struct { status: std.http.Status, body: []const u8 };

fn postJson(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, body: []const u8) !HttpResponse {
    return postBody(client, allocator, url, body, "application/json");
}

fn postBody(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, body: []const u8, content_type: []const u8) !HttpResponse {
    const uri = std.Uri.parse(url) catch return error.InvalidHost;
    const extra_headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Originator", .value = pkg.name },
    };
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .not_allowed,
        .headers = .{
            .user_agent = .{ .override = userAgent() },
            .accept_encoding = .{ .override = "identity" },
            .content_type = .{ .override = content_type },
        },
        .extra_headers = &extra_headers,
    });
    defer request.deinit();
    try request.sendBodyComplete(@constCast(body));
    var redirect_buffer: [4096]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const transfer_buffer = try allocator.alloc(u8, 64 * 1024);
    const response_body = try response.reader(transfer_buffer).allocRemaining(allocator, .limited(max_body_bytes));
    return .{ .status = response.head.status, .body = response_body };
}

fn writeFormParameter(writer: *std.Io.Writer, needs_separator: bool, name: []const u8, value: []const u8) !void {
    if (needs_separator) try writer.writeByte('&');
    try std.Uri.Component.percentEncode(writer, name, isFormSafeByte);
    try writer.writeByte('=');
    try std.Uri.Component.percentEncode(writer, value, isFormSafeByte);
}

fn isFormSafeByte(byte: u8) bool {
    const is_unreserved_punctuation = byte == '-' or byte == '.' or byte == '_' or byte == '~';
    return std.ascii.isAlphanumeric(byte) or is_unreserved_punctuation;
}

fn parseJsonObject(allocator: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const parsed_json = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return error.UnexpectedResponse;
    return switch (parsed_json) {
        .object => |value| value,
        else => error.UnexpectedResponse,
    };
}

fn jsonStringField(fields: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    return switch (fields.get(name) orelse return null) {
        .string => |value| value,
        else => null,
    };
}

fn accountIdFromIdToken(allocator: std.mem.Allocator, id_token: []const u8) ![]const u8 {
    const token_claims = switch (try parseJwtPayload(allocator, id_token)) {
        .object => |value| value,
        else => return error.InvalidJwt,
    };
    const openai_auth_claims = switch (token_claims.get("https://api.openai.com/auth") orelse return error.MissingAccountId) {
        .object => |value| value,
        else => return error.MissingAccountId,
    };
    return jsonStringField(openai_auth_claims, "chatgpt_account_id") orelse error.MissingAccountId;
}

fn expirationFromJwt(allocator: std.mem.Allocator, token: []const u8) !?i64 {
    const token_claims = switch (try parseJwtPayload(allocator, token)) {
        .object => |value| value,
        else => return error.InvalidJwt,
    };
    const expiration_claim = token_claims.get("exp") orelse return null;
    return switch (expiration_claim) {
        .integer => |value| value,
        else => null,
    };
}

fn parseJwtPayload(allocator: std.mem.Allocator, token: []const u8) !std.json.Value {
    var token_segments = std.mem.splitScalar(u8, token, '.');
    _ = token_segments.next() orelse return error.InvalidJwt;
    const encoded_payload = token_segments.next() orelse return error.InvalidJwt;
    const decoded_size = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded_payload);
    const decoded_payload = try allocator.alloc(u8, decoded_size);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded_payload, encoded_payload);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, decoded_payload, .{}) catch error.InvalidJwt;
}

fn unixTimestamp(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_s));
}

pub fn userAgent() []const u8 {
    return pkg.name ++ "/" ++ pkg.version;
}

test "login cancellation reports the worker outcome even when completion wins the race" {
    const testing = std.testing;
    const Attempt = enum { success, failure, pending };
    const Worker = struct {
        fn run(login: *Login, attempt: Attempt) void {
            defer login.login_finished.store(true, .release);
            switch (attempt) {
                .success => {},
                .failure => login.login_error = error.TokenExchangeFailed,
                .pending => std.Io.sleep(login.io, .fromSeconds(60), .awake) catch |err| {
                    login.login_error = err;
                },
            }
        }
    };
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    for ([_]Attempt{ .success, .failure, .pending }) |attempt| {
        var login = Login.init(testing.allocator, testing.io, &auth);
        login.arena = .init(testing.allocator);
        login.login_future = try testing.io.concurrent(Worker.run, .{ &login, attempt });
        login.active = true;
        defer login.deinit();
        // The UI has not polled the completed result yet when Escape arrives.
        if (attempt != .pending) {
            while (!login.login_finished.load(.acquire)) try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
        }
        login.cancel();
        login.cancel();
        const result = while (true) {
            if (login.takeResult()) |result| break result;
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
        };
        switch (attempt) {
            .success => try testing.expectEqual(Login.Result.success, result),
            .failure => try testing.expectEqual(error.TokenExchangeFailed, result.failed),
            .pending => try testing.expectEqual(Login.Result.canceled, result),
        }
        try testing.expect(!login.connecting());
        try testing.expect(login.activeCode() == null);
        try testing.expect(login.takeResult() == null);
    }
}

test "a stale caller adopts tokens already refreshed by another process without networking" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const path = try std.fs.path.join(arena, &.{ root, "auth.json" });
    var stale_auth = try Auth.load(testing.allocator, testing.io, path);
    defer stale_auth.deinit();
    const expired: Tokens = .{ .access_token = "expired", .refresh_token = "old", .account_id = "account", .expires_at = 1 };
    try saveTokens(arena, testing.io, &stale_auth, expired);
    var other_process = try Auth.load(testing.allocator, testing.io, path);
    defer other_process.deinit();
    try saveTokens(arena, testing.io, &other_process, .{
        .access_token = "renewed",
        .refresh_token = "rotated",
        .account_id = "account",
        .expires_at = unixTimestamp(testing.io) + 3600,
    });

    var offline_vtable = testing.io.vtable.*;
    offline_vtable.netLookup = std.Io.failingNetLookup;
    offline_vtable.netConnectIp = std.Io.failingNetConnectIp;
    const offline: std.Io = .{ .userdata = testing.io.userdata, .vtable = &offline_vtable };
    const renewed = try ensureFreshTokens(arena, offline, &stale_auth);
    try testing.expectEqualStrings("renewed", renewed.access_token);
    try testing.expectEqualStrings("rotated", renewed.refresh_token);
    // A concurrent 401 for the old access token must reuse the same rotation.
    const retried = try refreshTokens(arena, offline, &stale_auth, expired);
    try testing.expectEqualStrings("renewed", retried.access_token);
    try testing.expectEqualStrings("rotated", (try loadTokens(arena, &stale_auth)).refresh_token);
}

test "Codex tokens survive an auth file reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "auth.json" });
    defer std.testing.allocator.free(path);
    {
        var auth = try Auth.load(std.testing.allocator, std.testing.io, path);
        defer auth.deinit();
        try saveTokens(std.testing.allocator, std.testing.io, &auth, .{
            .access_token = "access",
            .refresh_token = "refresh",
            .account_id = "account",
            .expires_at = 42,
        });
    }

    var auth = try Auth.load(std.testing.allocator, std.testing.io, path);
    defer auth.deinit();
    const tokens = try loadTokens(std.testing.allocator, &auth);
    try std.testing.expectEqualStrings("access", tokens.access_token);
    try std.testing.expectEqualStrings("refresh", tokens.refresh_token);
    try std.testing.expectEqualStrings("account", tokens.account_id);
    try std.testing.expectEqual(@as(?i64, 42), tokens.expires_at);
}

test "disconnecting removes only the persisted Codex credential" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "auth.json" });
    defer std.testing.allocator.free(path);

    var auth = try Auth.load(std.testing.allocator, std.testing.io, path);
    defer auth.deinit();
    try auth.set(provider_id, "tokens");
    try auth.set("openai", "other-secret");
    try auth.save(std.testing.io, path);
    try removeStoredTokens(std.testing.allocator, std.testing.io, &auth);
    try std.testing.expect(auth.key(provider_id) == null);
    try std.testing.expectEqualStrings("other-secret", auth.key("openai").?);

    var reloaded = try Auth.load(std.testing.allocator, std.testing.io, path);
    defer reloaded.deinit();
    try std.testing.expect(reloaded.key(provider_id) == null);
    try std.testing.expectEqualStrings("other-secret", reloaded.key("openai").?);
}
