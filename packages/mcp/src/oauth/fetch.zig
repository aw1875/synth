//! The one HTTP helper the OAuth files share.
//!
//! Discovery and registration are both "send a little JSON, read a little
//! JSON back", and neither wants a streaming reader or a connection that
//! outlives the call. Everything lands in the caller's arena, including the
//! body, so one `deinit` cleans up a whole discovery chain.
//!
//! A non-2xx status is returned rather than raised. Discovery leans on that:
//! a `404` from one well-known URL is the signal to try the next one, not a
//! failure.

const std = @import("std");

/// Longest metadata document read. These are small by nature; anything past
/// this is a server that has gone wrong or is not a metadata endpoint at all.
pub const max_body_bytes: usize = 256 * 1024;

pub const Response = struct {
    status: std.http.Status,
    /// Owned by the arena the call was given.
    body: []const u8,

    pub fn ok(self: Response) bool {
        return self.status.class() == .success;
    }
};

/// GET a JSON document.
pub fn get(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, url: []const u8) !Response {
    return send(gpa, arena, io, .GET, url, null);
}

/// POST a JSON document and read the JSON answer.
pub fn postJson(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
) !Response {
    return send(gpa, arena, io, .POST, url, body);
}

fn send(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
) !Response {
    var client: std.http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    var collected: std.Io.Writer.Allocating = .init(arena);
    errdefer collected.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .headers = .{
            .content_type = if (body != null) .{ .override = "application/json" } else .omit,
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/json" },
        },
        .payload = body,
        .response_writer = &collected.writer,
    }) catch return error.FetchFailed;

    if (collected.written().len > max_body_bytes) return error.ResponseTooLong;

    return .{ .status = result.status, .body = try collected.toOwnedSlice() };
}
