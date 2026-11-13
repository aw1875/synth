const std = @import("std");
const pkg = @import("pkg");

pub const api_host = "https://api.githubcopilot.com";
pub const client_id = "Ov23liUMCAtBpKG5Mpoa";
pub const api_version = "2026-08-01";
pub const default_integration_id = "copilot-sdk";
const max_body_bytes = 4 * 1024 * 1024;

pub const Code = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: u32 = 900,
    interval: u32 = 5,
};

pub const Poll = union(enum) {
    pending,
    slow_down,
    token: []const u8,
};

pub fn requestCode(arena: std.mem.Allocator, io: std.Io) !Code {
    const body = try request(arena, io, "https://github.com/login/device/code", null, "{\"client_id\":\"" ++ client_id ++ "\",\"scope\":\"read:user\"}", &.{});
    const code = try std.json.parseFromSliceLeaky(Code, arena, body, .{ .ignore_unknown_fields = true });
    if (code.device_code.len == 0 or code.user_code.len == 0 or
        !std.mem.eql(u8, code.verification_uri, "https://github.com/login/device")) return error.UnexpectedResponse;
    return code;
}

pub fn poll(arena: std.mem.Allocator, io: std.Io, device_code: []const u8) !Poll {
    const payload = try std.json.Stringify.valueAlloc(arena, .{
        .client_id = client_id,
        .device_code = device_code,
        .grant_type = "urn:ietf:params:oauth:grant-type:device_code",
    }, .{});
    const body = try request(arena, io, "https://github.com/login/oauth/access_token", null, payload, &.{});
    return parsePoll(arena, body);
}

fn parsePoll(arena: std.mem.Allocator, body: []const u8) !Poll {
    const Reply = struct { access_token: []const u8 = "", @"error": []const u8 = "" };
    const reply = try std.json.parseFromSliceLeaky(Reply, arena, body, .{ .ignore_unknown_fields = true });
    if (reply.access_token.len > 0) return .{ .token = reply.access_token };
    if (std.mem.eql(u8, reply.@"error", "authorization_pending")) return .pending;
    if (std.mem.eql(u8, reply.@"error", "slow_down")) return .slow_down;
    if (std.mem.eql(u8, reply.@"error", "access_denied")) return error.AuthorizationDenied;
    if (std.mem.eql(u8, reply.@"error", "expired_token")) return error.SignInTimedOut;
    return error.UnexpectedResponse;
}

pub fn discover(arena: std.mem.Allocator, io: std.Io, token: []const u8) ![]const u8 {
    const body = try request(arena, io, "https://api.github.com/copilot_internal/user", token, null, &.{});
    return parseAccount(arena, body);
}

fn parseAccount(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Account = struct {
        chat_enabled: ?bool = null,
        endpoints: ?struct { api: ?[]const u8 = null } = null,
    };
    const account = try std.json.parseFromSliceLeaky(Account, arena, body, .{ .ignore_unknown_fields = true });
    if (account.chat_enabled == false) return error.CopilotNotEntitled;
    const endpoint = if (account.endpoints) |endpoints| endpoints.api orelse api_host else api_host;
    if (!trustedEndpoint(endpoint)) return error.UntrustedCopilotEndpoint;
    return std.mem.trimEnd(u8, endpoint, "/");
}

pub fn trustedEndpoint(endpoint: []const u8) bool {
    const uri = std.Uri.parse(endpoint) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null or (uri.port != null and uri.port != 443)) return false;
    const host = switch (uri.host orelse return false) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
    return std.ascii.eqlIgnoreCase(host, "api.githubcopilot.com") or
        std.mem.endsWith(u8, host, ".githubcopilot.com");
}

pub fn headers(integration_id: []const u8) ![5]std.http.Header {
    if (integration_id.len == 0) return error.InvalidCopilotIntegrationId;
    for (integration_id) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidCopilotIntegrationId;
    }
    return .{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Copilot-Integration-Id", .value = integration_id },
        .{ .name = "User-Agent", .value = "synth/" ++ pkg.version },
        .{ .name = "Openai-Intent", .value = "conversation-edits" },
        .{ .name = "X-GitHub-Api-Version", .value = api_version },
    };
}

pub fn requestModels(arena: std.mem.Allocator, io: std.Io, endpoint: []const u8, token: []const u8, integration_id: []const u8) ![]u8 {
    if (!trustedEndpoint(endpoint)) return error.UntrustedCopilotEndpoint;
    const url = try std.fmt.allocPrint(arena, "{s}/models", .{std.mem.trimEnd(u8, endpoint, "/")});
    const model_headers = try headers(integration_id);
    return request(arena, io, url, token, null, &model_headers);
}

fn request(arena: std.mem.Allocator, io: std.Io, url: []const u8, token: ?[]const u8, payload: ?[]const u8, extra_headers: []const std.http.Header) ![]u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const authorization = if (token) |value| try std.fmt.allocPrint(arena, "Bearer {s}", .{value}) else "";
    var req = try client.request(if (payload != null) .POST else .GET, try std.Uri.parse(url), .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{
            .authorization = if (authorization.len > 0) .{ .override = authorization } else .default,
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = if (extra_headers.len > 0) extra_headers else &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "User-Agent", .value = "synth/" ++ pkg.version },
            .{ .name = "X-GitHub-Api-Version", .value = if (std.mem.startsWith(u8, url, "https://api.github.com/")) "2025-04-01" else api_version },
        },
    });
    defer req.deinit();
    if (payload) |body| try req.sendBodyComplete(@constCast(body)) else try req.sendBodiless();
    var redirect_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    var transfer: [4096]u8 = undefined;
    const body = try response.reader(&transfer).allocRemaining(arena, .limited(max_body_bytes));
    if (response.head.status == .unauthorized) return error.CopilotSessionExpired;
    if (response.head.status == .forbidden) return error.CopilotAccessDenied;
    if (response.head.status.class() != .success) return error.HttpError;
    return body;
}

test "Copilot integration headers preserve synth identity and reject unsafe values" {
    const defaults = try headers(default_integration_id);
    try std.testing.expectEqualStrings("Copilot-Integration-Id", defaults[1].name);
    try std.testing.expectEqualStrings("copilot-sdk", defaults[1].value);
    try std.testing.expectEqualStrings("synth/" ++ pkg.version, defaults[2].value);
    const custom = try headers("my-product-agent");
    try std.testing.expectEqualStrings("my-product-agent", custom[1].value);
    for ([_][]const u8{ "", "bad\r\nInjected:yes", "bad\x00", "bad\x7f", "bad id", "bad\x80" }) |value| {
        try std.testing.expectError(error.InvalidCopilotIntegrationId, headers(value));
    }
}

test "Copilot device polling distinguishes pending, slow down, denial and tokens" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Poll.pending, try parsePoll(a, "{\"error\":\"authorization_pending\"}"));
    try std.testing.expectEqual(Poll.slow_down, try parsePoll(a, "{\"error\":\"slow_down\"}"));
    try std.testing.expectError(error.AuthorizationDenied, parsePoll(a, "{\"error\":\"access_denied\"}"));
    try std.testing.expectError(error.SignInTimedOut, parsePoll(a, "{\"error\":\"expired_token\"}"));
    try std.testing.expectEqualStrings("example", (try parsePoll(a, "{\"access_token\":\"example\"}")).token);
}

test "Copilot account routing honors organization endpoints without leaking tokens" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://api.business.githubcopilot.com", try parseAccount(a, "{\"chat_enabled\":true,\"endpoints\":{\"api\":\"https://api.business.githubcopilot.com/\"}}"));
    try std.testing.expectEqualStrings(api_host, try parseAccount(a, "{}"));
    try std.testing.expectError(error.CopilotNotEntitled, parseAccount(a, "{\"chat_enabled\":false}"));
    try std.testing.expect(!trustedEndpoint("http://api.githubcopilot.com"));
    try std.testing.expect(!trustedEndpoint("https://api.githubcopilot.com.evil.example"));
    try std.testing.expect(!trustedEndpoint("https://evil.example"));
    try std.testing.expect(!trustedEndpoint("https://user@api.githubcopilot.com"));
}
