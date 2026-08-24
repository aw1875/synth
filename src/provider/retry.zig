//! When a failed request is worth sending again, and how long to wait first.
//!
//! Only before anything has been streamed. Once a reply has started arriving,
//! sending the request again would duplicate what the reader already has, so
//! both backends retry around the request and not around the turn.
//!
//! The distinction that matters is refusal versus congestion. A 400 means the
//! request was wrong and will be wrong again; a 429 or a 503 means the server
//! is busy or briefly broken, which is what waiting is for.

const std = @import("std");

pub const Policy = struct {
    /// Total attempts, including the first. Three retries past the original.
    attempts: usize = 4,
    /// Wait before the first retry. Doubles each time.
    base_ms: u64 = 500,
    /// Longest wait between attempts, whatever the doubling says.
    max_ms: u64 = 8_000,
    /// Longest wait a server's own `Retry-After` can ask for. Past this the
    /// request is failed rather than held: a turn that resumes in four minutes
    /// is not a turn anyone is still waiting on.
    max_retry_after_ms: u64 = 60_000,
};

/// Whether a status is worth another attempt.
pub fn transient(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests, .request_timeout => true,
        // 501 and 505 are refusals dressed as server errors: the server is
        // saying it will never do this, not that it could not this time.
        .not_implemented, .http_version_not_supported => false,
        else => status.class() == .server_error,
    };
}

/// The same question for a backend that reports a failure as text rather than
/// a status. Weaker by nature, so it only matches what a rate limit or an
/// outage actually says.
pub fn transientText(why: []const u8) bool {
    const needles: []const []const u8 = &.{
        "429",              "rate limit", "rate_limit",
        "too many request", "503",        "502",
        "504",              "overloaded", "server_error",
        "unavailable",      "try again",  "temporarily",
    };
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(why, needle) != null) return true;
    }
    return false;
}

/// How long to wait before attempt `n`, counting the first attempt as 1.
///
/// A server that named a delay gets it, clamped: `Retry-After` is the one
/// number that knows about the other side's queue. Otherwise the wait doubles.
pub fn waitMs(policy: Policy, attempt: usize, retry_after_ms: ?u64) u64 {
    if (retry_after_ms) |asked| return @min(asked, policy.max_retry_after_ms);

    const doublings: u6 = @intCast(@min(attempt -| 1, 16));
    const grown = policy.base_ms *| (@as(u64, 1) << doublings);
    return @min(grown, policy.max_ms);
}

/// Whether a wait the server asked for is longer than we are prepared to hold
/// a turn open for.
pub fn tooLong(policy: Policy, retry_after_ms: ?u64) bool {
    const asked = retry_after_ms orelse return false;
    return asked > policy.max_retry_after_ms;
}

/// `Retry-After` as milliseconds. Only the delta-seconds form: the HTTP-date
/// form needs a clock and a date parser to answer a question the seconds form
/// answers directly, and no provider sends it.
pub fn retryAfterMs(header: ?[]const u8) ?u64 {
    const text = std.mem.trim(u8, header orelse return null, " \t");
    if (text.len == 0) return null;

    const seconds = std.fmt.parseInt(u64, text, 10) catch return null;
    return seconds *| 1000;
}

const testing = std.testing;

test "congestion is retried and refusal is not" {
    try testing.expect(transient(.too_many_requests));
    try testing.expect(transient(.internal_server_error));
    try testing.expect(transient(.bad_gateway));
    try testing.expect(transient(.service_unavailable));
    try testing.expect(transient(.gateway_timeout));
    try testing.expect(transient(.request_timeout));

    try testing.expect(!transient(.ok));
    try testing.expect(!transient(.bad_request));
    try testing.expect(!transient(.unauthorized));
    try testing.expect(!transient(.not_found));
    try testing.expect(!transient(.not_implemented));
}

test "a rejection that reads like congestion is retried" {
    try testing.expect(transientText("HTTP 429: rate limit exceeded"));
    try testing.expect(transientText("upstream overloaded, try again later"));
    try testing.expect(transientText("503 Service Unavailable"));

    try testing.expect(!transientText("context length exceeded"));
    try testing.expect(!transientText("model not found"));
    try testing.expect(!transientText(""));
}

test "the wait doubles and then stops growing" {
    const policy: Policy = .{ .base_ms = 500, .max_ms = 8_000 };

    try testing.expectEqual(@as(u64, 500), waitMs(policy, 1, null));
    try testing.expectEqual(@as(u64, 1_000), waitMs(policy, 2, null));
    try testing.expectEqual(@as(u64, 2_000), waitMs(policy, 3, null));
    try testing.expectEqual(@as(u64, 4_000), waitMs(policy, 4, null));
    try testing.expectEqual(@as(u64, 8_000), waitMs(policy, 5, null));
    try testing.expectEqual(@as(u64, 8_000), waitMs(policy, 50, null));
}

test "a server that named a delay gets it, within reason" {
    const policy: Policy = .{};

    try testing.expectEqual(@as(u64, 3_000), waitMs(policy, 1, 3_000));
    try testing.expectEqual(policy.max_retry_after_ms, waitMs(policy, 1, 600_000));

    try testing.expect(!tooLong(policy, 3_000));
    try testing.expect(!tooLong(policy, null));
    try testing.expect(tooLong(policy, 600_000));
}

test "Retry-After is read as seconds, and anything else is ignored" {
    try testing.expectEqual(@as(?u64, 2_000), retryAfterMs("2"));
    try testing.expectEqual(@as(?u64, 0), retryAfterMs("0"));
    try testing.expectEqual(@as(?u64, 30_000), retryAfterMs("  30 "));

    try testing.expect(retryAfterMs(null) == null);
    try testing.expect(retryAfterMs("") == null);
    try testing.expect(retryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT") == null);
    try testing.expect(retryAfterMs("-5") == null);
}
