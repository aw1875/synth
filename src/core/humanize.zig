//! Numbers as a person reads them.

const std = @import("std");

/// Longest string `duration` can produce, so callers can size a buffer.
pub const duration_bytes = 24;

/// A duration in the largest unit that still says something useful:
/// `820ms`, `4.2s`, `4m 12s`, `1h 09m`.
pub fn duration(buffer: []u8, ms: u64) []const u8 {
    std.debug.assert(buffer.len >= duration_bytes);

    if (ms < std.time.ms_per_s) return std.fmt.bufPrint(buffer, "{d}ms", .{ms}) catch unreachable;

    if (ms < std.time.ms_per_min) {
        return std.fmt.bufPrint(buffer, "{d:.1}s", .{
            @as(f64, @floatFromInt(ms)) / std.time.ms_per_s,
        }) catch unreachable;
    }

    const seconds = ms / std.time.ms_per_s;
    if (ms < std.time.ms_per_hour) {
        return std.fmt.bufPrint(buffer, "{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 }) catch unreachable;
    }

    const minutes = seconds / 60;
    return std.fmt.bufPrint(buffer, "{d}h {d:0>2}m", .{ minutes / 60, minutes % 60 }) catch unreachable;
}

test "a duration reads in the largest unit that still says something" {
    var buffer: [duration_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("0ms", duration(&buffer, 0));
    try std.testing.expectEqualStrings("820ms", duration(&buffer, 820));
    try std.testing.expectEqualStrings("1.0s", duration(&buffer, 1000));
    try std.testing.expectEqualStrings("4.2s", duration(&buffer, 4249));
    try std.testing.expectEqualStrings("59.9s", duration(&buffer, 59_900));

    try std.testing.expectEqualStrings("4m 12s", duration(&buffer, 252_100));
    try std.testing.expectEqualStrings("2m 05s", duration(&buffer, 125_000));

    try std.testing.expectEqualStrings("1h 09m", duration(&buffer, 4_140_000));
    try std.testing.expectEqualStrings("3h 00m", duration(&buffer, 3 * std.time.ms_per_hour));

    try std.testing.expectEqualStrings("100h 00m", duration(&buffer, 100 * std.time.ms_per_hour));
}
