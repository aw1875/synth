//! The HTTP transport: a remote MCP server behind Streamable HTTP.
//!
//! One POST per message. The reply is either `application/json` carrying a
//! single JSON-RPC message, a `text/event-stream` carrying one or more, or
//! `202 Accepted` with no body at all - which is what a server returns for a
//! notification, since there is nothing to answer.
//!
//! ## Where the messages live
//!
//! The seam promises `receive` a slice valid until the next call, so this
//! file holds exactly one message at a time in `last` and frees it on the
//! call after. A buffered JSON body is read whole and the request closed; an
//! SSE body keeps its request alive, because the reader borrows from it, and
//! closes it when the stream ends.
//!
//! ## Authorization
//!
//! A `401` is not a failure to retry here. It is reported as
//! `Unauthorized`, with whatever the server put in `WWW-Authenticate` kept in
//! `challenge` - that header is how RFC 9728 points a client at the protected
//! resource metadata it needs to start an OAuth flow. Once the flow produces
//! a token, `setBearer` installs it and the same transport carries on.

const std = @import("std");

const Transport = @import("transport.zig");

const Http = @This();

/// Longest single message, in either direction. A tool result can carry a
/// whole file, so this is generous; a server that exceeds it has almost
/// certainly gone wrong.
pub const default_max_message: usize = 4 * 1024 * 1024;

/// Room for the header block `std.http.Client` replays across a redirect
/// chain. RFC 9110 suggests at least this much.
const redirect_buffer_bytes: usize = 8 * 1024;

/// The session header MCP defines for Streamable HTTP. A server that opens a
/// session names it here on its first reply, and expects it back on every
/// request after that.
const session_header = "mcp-session-id";

/// The revision header MCP defines for Streamable HTTP. A server that supports
/// more than one version uses it to know which it is being spoken to in, and
/// some refuse a request without it.
const version_header = "mcp-protocol-version";

pub const Options = struct {
    /// The MCP endpoint, an absolute URL.
    url: []const u8,
    /// Extra headers sent with every request. Copied.
    headers: []const std.http.Header = &.{},
    /// The OAuth access token, sent as `Authorization: Bearer`. Copied.
    bearer: ?[]const u8 = null,
    max_message: usize = default_max_message,
};

/// What a POST left behind for `receive` to hand out.
const Pending = union(enum) {
    /// Nothing outstanding: either nothing was sent, or everything sent has
    /// been read.
    none,
    /// The server took the message and has nothing to say back. `receive`
    /// after this is a caller waiting for a reply that is never coming.
    accepted,
    /// A whole `application/json` body, owned, not yet handed out.
    json: []u8,
    /// A live `text/event-stream`. The request outlives the reader that
    /// borrows from it, so both are freed together when the stream ends.
    stream: Stream,

    const Stream = struct {
        request: *std.http.Client.Request,
        reader: *std.Io.Reader,
    };
};

allocator: std.mem.Allocator,
io: std.Io,
client: std.http.Client,
/// Owned. `uri` is parsed over this, so the two live and die together.
url: []u8,
uri: std.Uri,
/// Owned, names and values both: an `Options.headers` borrowed from a config
/// arena would outlive nothing in particular.
extra: []std.http.Header,
/// The `Authorization` value, kept whole rather than re-formatted per send.
authorization: ?[]u8 = null,
/// The session the server opened, echoed back on every later request.
session: ?[]u8 = null,
/// The revision settled on, sent with every request once it is known.
version: ?[]u8 = null,
/// What the server said the last time it answered `401`.
challenge: ?[]u8 = null,
max_message: usize,
redirect_buffer: []u8,
send_buffer: []u8,
transfer_buffer: []u8,
pending: Pending = .none,
/// The message the last `receive` handed out, freed on the next call. This is
/// what makes the borrowed-slice contract true.
last: ?[]u8 = null,
/// The seam. Set up after this struct reaches its final address, because the
/// erased fn pointers recover `*Http` from `*Transport` via `@fieldParentPtr`.
transport: Transport,

const vtable: Transport.VTable = .{
    .send = sendErased,
    .receive = receiveErased,
    .deinit = deinitErased,
    .set_bearer = setBearerErased,
    .challenge = challengeErased,
    .set_protocol_version = setProtocolVersionErased,
};

/// Heap-allocated because the reader borrows the buffers beside it and the
/// vtable's erased fns recover this struct from a pointer into it: an `Http`
/// returned by value would leave both aimed at a dead frame.
pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Http {
    const self = try allocator.create(Http);
    errdefer allocator.destroy(self);

    const url = try allocator.dupe(u8, options.url);
    errdefer allocator.free(url);

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    const extra = try copyHeaders(allocator, options.headers);
    errdefer freeHeaders(allocator, extra);

    const redirect_buffer = try allocator.alloc(u8, redirect_buffer_bytes);
    errdefer allocator.free(redirect_buffer);

    const send_buffer = try allocator.alloc(u8, options.max_message);
    errdefer allocator.free(send_buffer);

    const transfer_buffer = try allocator.alloc(u8, options.max_message);
    errdefer allocator.free(transfer_buffer);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .client = .{ .io = io, .allocator = allocator },
        .url = url,
        .uri = uri,
        .extra = extra,
        .max_message = options.max_message,
        .redirect_buffer = redirect_buffer,
        .send_buffer = send_buffer,
        .transfer_buffer = transfer_buffer,
        .transport = .{ .vtable = &vtable },
    };

    errdefer self.client.deinit();
    try self.setBearer(options.bearer);

    return self;
}

pub fn destroy(self: *Http) void {
    const allocator = self.allocator;
    self.clear();
    self.client.deinit();
    if (self.authorization) |value| allocator.free(value);
    if (self.session) |value| allocator.free(value);
    if (self.version) |value| allocator.free(value);
    if (self.challenge) |value| allocator.free(value);
    freeHeaders(allocator, self.extra);
    allocator.free(self.transfer_buffer);
    allocator.free(self.send_buffer);
    allocator.free(self.redirect_buffer);
    allocator.free(self.url);
    allocator.destroy(self);
}

/// What the server said the last time it answered `401`, or empty when it has
/// not. RFC 9728 puts the protected resource metadata URL in here.
pub fn challengeHeader(self: *const Http) []const u8 {
    return self.challenge orelse "";
}

/// Replace the credentials sent with each request. A null token drops the
/// header entirely, which is how a signed-out state is expressed.
pub fn setBearer(self: *Http, token: ?[]const u8) std.mem.Allocator.Error!void {
    const replacement = if (token) |value|
        try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{value})
    else
        null;

    if (self.authorization) |old| self.allocator.free(old);
    self.authorization = replacement;
}

/// Name the revision in force, sent with every later request.
pub fn setProtocolVersion(self: *Http, version: []const u8) std.mem.Allocator.Error!void {
    const owned = try self.allocator.dupe(u8, version);
    if (self.version) |old| self.allocator.free(old);
    self.version = owned;
}

/// POST one message. The reply is read as far as its head and left in
/// `pending` for `receive` to take apart.
pub fn send(self: *Http, message: []const u8) Transport.Error!void {
    // Anything still outstanding belongs to a request this one supersedes.
    self.clear();

    if (message.len > self.send_buffer.len) return Transport.Error.MessageTooLong;
    const body = self.send_buffer[0..message.len];
    @memcpy(body, message);

    var headers: [5]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "accept", .value = "application/json, text/event-stream" };
    count += 1;
    if (self.authorization) |value| {
        headers[count] = .{ .name = "authorization", .value = value };
        count += 1;
    }
    if (self.session) |value| {
        headers[count] = .{ .name = session_header, .value = value };
        count += 1;
    }
    if (self.version) |value| {
        headers[count] = .{ .name = version_header, .value = value };
        count += 1;
    }

    const all = self.allocator.alloc(std.http.Header, count + self.extra.len) catch
        return Transport.Error.ConnectionFailed;
    defer self.allocator.free(all);
    @memcpy(all[0..count], headers[0..count]);
    @memcpy(all[count..], self.extra);

    const request = self.allocator.create(std.http.Client.Request) catch return Transport.Error.ConnectionFailed;
    var keep_request = false;
    defer if (!keep_request) self.allocator.destroy(request);

    request.* = self.client.request(.POST, self.uri, .{
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = all,
    }) catch return Transport.Error.ConnectionFailed;
    var keep_open = false;
    defer if (!keep_open) request.deinit();

    request.transfer_encoding = .{ .content_length = body.len };
    request.sendBodyComplete(body) catch return Transport.Error.ConnectionFailed;

    var response = request.receiveHead(self.redirect_buffer) catch return Transport.Error.ConnectionFailed;

    // Every string in the head - `content_type` among them, and everything
    // `iterateHeaders` walks - is invalidated the moment a body reader is
    // taken. Whatever this reply has to say is read out first.
    const status = response.head.status;
    const content_type = response.head.content_type;
    const streaming = contains(content_type, "text/event-stream");
    const json = contains(content_type, "application/json");
    try self.captureHeaders(response.head, status);

    switch (status) {
        .unauthorized => return Transport.Error.Unauthorized,
        .accepted, .no_content => {
            self.pending = .accepted;
            return;
        },
        else => switch (status.class()) {
            .success => {},
            .client_error => return Transport.Error.RequestRejected,
            .server_error => return Transport.Error.ServerError,
            else => return Transport.Error.UnexpectedStatus,
        },
    }

    if (streaming) {
        self.pending = .{ .stream = .{
            .request = request,
            .reader = response.reader(self.transfer_buffer),
        } };
        keep_request = true;
        keep_open = true;
        return;
    }

    // A server that sends a body without saying what it is has, in practice,
    // sent JSON; one that names something else has sent something this
    // transport has no business guessing at.
    if (!json and content_type != null) return Transport.Error.UnsupportedResponse;

    const reader = response.reader(self.transfer_buffer);
    self.pending = .{
        .json = reader.allocRemaining(self.allocator, .limited(self.max_message)) catch |err| switch (err) {
            error.StreamTooLong => return Transport.Error.MessageTooLong,
            error.OutOfMemory => return Transport.Error.ConnectionFailed,
            error.ReadFailed => return Transport.Error.ServerClosed,
        },
    };
}

/// Hand out the next message. The slice points into this transport's storage
/// and dies on the following call.
pub fn receive(self: *Http) Transport.Error![]const u8 {
    if (self.last) |message| {
        self.allocator.free(message);
        self.last = null;
    }

    switch (self.pending) {
        .none, .accepted => {
            self.pending = .none;
            return Transport.Error.ServerClosed;
        },
        .json => |body| {
            self.pending = .none;
            if (body.len == 0) {
                self.allocator.free(body);
                return Transport.Error.ServerClosed;
            }
            self.last = body;
            return body;
        },
        .stream => |stream| {
            const message = readSseMessage(self.allocator, stream.reader, self.max_message) catch |err| {
                self.clear();
                return switch (err) {
                    error.StreamTooLong, error.WriteFailed => Transport.Error.MessageTooLong,
                    error.OutOfMemory => Transport.Error.ConnectionFailed,
                    error.ReadFailed => Transport.Error.ConnectionFailed,
                    error.EndOfStream => Transport.Error.ServerClosed,
                };
            };
            self.last = message;
            return message;
        },
    }
}

/// Drop whatever is outstanding: the handed-out message, the buffered body,
/// and the live request an SSE reader is borrowing from.
fn clear(self: *Http) void {
    if (self.last) |message| {
        self.allocator.free(message);
        self.last = null;
    }
    switch (self.pending) {
        .none, .accepted => {},
        .json => |body| self.allocator.free(body),
        .stream => |stream| {
            stream.request.deinit();
            self.allocator.destroy(stream.request);
        },
    }
    self.pending = .none;
}

/// Take the session and the authorization challenge out of a reply's head,
/// before a body reader invalidates them.
fn captureHeaders(self: *Http, head: std.http.Client.Response.Head, status: std.http.Status) Transport.Error!void {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, session_header)) {
            const owned = self.allocator.dupe(u8, header.value) catch return Transport.Error.ConnectionFailed;
            if (self.session) |old| self.allocator.free(old);
            self.session = owned;
            continue;
        }
        if (status == .unauthorized and std.ascii.eqlIgnoreCase(header.name, "www-authenticate")) {
            const owned = self.allocator.dupe(u8, header.value) catch return Transport.Error.ConnectionFailed;
            if (self.challenge) |old| self.allocator.free(old);
            self.challenge = owned;
        }
    }
}

fn contains(content_type: ?[]const u8, needle: []const u8) bool {
    const value = content_type orelse return false;
    return std.ascii.indexOfIgnoreCase(value, needle) != null;
}

fn copyHeaders(allocator: std.mem.Allocator, headers: []const std.http.Header) ![]std.http.Header {
    const out = try allocator.alloc(std.http.Header, headers.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(out);
    }
    for (headers, 0..) |header, i| {
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        out[i] = .{ .name = name, .value = try allocator.dupe(u8, header.value) };
        copied = i + 1;
    }
    return out;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []std.http.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

/// Read one SSE event off `reader` and return its joined `data:` payload.
/// Multi-line `data:` fields from one event are joined with newlines per
/// spec, and the next event is left in `reader` for a follow-up call.
///
/// EOF before any data is `error.EndOfStream`; EOF part-way through an event
/// returns what had accumulated, because a server that dies mid-event has
/// still told us something. The returned slice is owned by the caller.
///
/// A single `data:` line has to fit in the reader's buffer for `takeDelimiter`
/// to hand it over, which is why that buffer is sized to `max_message` rather
/// than to something merely comfortable. `error.StreamTooLong` from here means
/// the line was longer than a whole message is allowed to be.
fn readSseMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader, limit: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    while (true) {
        const raw = try reader.takeDelimiter('\n');
        const line_or_end = raw orelse {
            if (out.written().len > 0) break;
            return error.EndOfStream;
        };

        const line = std.mem.trimEnd(u8, line_or_end, "\r");
        if (line.len == 0) {
            if (out.written().len > 0) break;
            continue;
        }

        // A comment. Servers send these as keepalives.
        if (std.mem.startsWith(u8, line, ":")) continue;

        const prefix = "data:";
        if (!std.ascii.startsWithIgnoreCase(line, prefix)) continue;

        var value = line[prefix.len..];
        if (std.mem.startsWith(u8, value, " ")) value = value[1..];
        if (value.len == 0) continue;

        if (out.written().len + value.len > limit) return error.StreamTooLong;
        if (out.written().len > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(value);
    }

    return out.toOwnedSlice();
}

fn sendErased(t: *Transport, message: []const u8) Transport.Error!void {
    const self: *Http = @alignCast(@fieldParentPtr("transport", t));
    return self.send(message);
}

fn receiveErased(t: *Transport) Transport.Error![]const u8 {
    const self: *Http = @alignCast(@fieldParentPtr("transport", t));
    return self.receive();
}

fn deinitErased(t: *Transport) void {
    const self: *Http = @alignCast(@fieldParentPtr("transport", t));
    self.destroy();
}

fn setBearerErased(t: *Transport, token: ?[]const u8) std.mem.Allocator.Error!void {
    const self: *Http = @alignCast(@fieldParentPtr("transport", t));
    return self.setBearer(token);
}

fn challengeErased(t: *Transport) []const u8 {
    const self: *Http = @alignCast(@fieldParentPtr("transport", t));
    return self.challengeHeader();
}

fn setProtocolVersionErased(t: *Transport, version: []const u8) std.mem.Allocator.Error!void {
    const self: *Http = @alignCast(@fieldParentPtr("transport", t));
    return self.setProtocolVersion(version);
}

const testing = std.testing;

test "readSseMessage extracts the first data: payload" {
    const input = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n";

    var reader = std.Io.Reader.fixed(input);
    const out = try readSseMessage(testing.allocator, &reader, default_max_message);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", out);
}

test "readSseMessage joins multi-line data fields with newlines" {
    var reader = std.Io.Reader.fixed("data: line one\ndata: line two\n\n");
    const out = try readSseMessage(testing.allocator, &reader, default_max_message);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("line one\nline two", out);
}

test "readSseMessage skips comments and non-data fields" {
    var reader = std.Io.Reader.fixed(": keepalive\nevent: ping\nid: 7\ndata: real\n\n");
    const out = try readSseMessage(testing.allocator, &reader, default_max_message);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("real", out);
}

test "readSseMessage stops after the first complete event" {
    var reader = std.Io.Reader.fixed("data: first\n\ndata: second\n\n");
    const first = try readSseMessage(testing.allocator, &reader, default_max_message);
    defer testing.allocator.free(first);

    try testing.expectEqualStrings("first", first);
    try testing.expectEqualStrings("data: second\n\n", reader.buffered());
}

test "readSseMessage returns EndOfStream on empty input" {
    var reader = std.Io.Reader.fixed("");
    try testing.expectError(error.EndOfStream, readSseMessage(testing.allocator, &reader, default_max_message));
}

test "readSseMessage accepts EOF after a partial event" {
    var reader = std.Io.Reader.fixed("data: hello");
    const out = try readSseMessage(testing.allocator, &reader, default_max_message);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("hello", out);
}

test "readSseMessage refuses an event past the limit" {
    var reader = std.Io.Reader.fixed("data: hello there\n\n");
    try testing.expectError(error.StreamTooLong, readSseMessage(testing.allocator, &reader, 4));
}

test "setBearer replaces and clears the header" {
    var http = try start(testing.allocator, testing.io, .{ .url = "https://example.invalid/mcp" });
    defer http.destroy();

    try testing.expect(http.authorization == null);

    try http.setBearer("first");
    try testing.expectEqualStrings("Bearer first", http.authorization.?);

    try http.setBearer("second");
    try testing.expectEqualStrings("Bearer second", http.authorization.?);

    try http.setBearer(null);
    try testing.expect(http.authorization == null);
}

test "options are copied, not borrowed" {
    const allocator = testing.allocator;

    const url = try allocator.dupe(u8, "https://example.invalid/mcp");
    const name = try allocator.dupe(u8, "x-trace");
    const value = try allocator.dupe(u8, "abc");

    var http = try start(allocator, testing.io, .{
        .url = url,
        .headers = &.{.{ .name = name, .value = value }},
    });
    defer http.destroy();

    allocator.free(url);
    allocator.free(name);
    allocator.free(value);

    try testing.expectEqualStrings("https://example.invalid/mcp", http.url);
    try testing.expectEqualStrings("x-trace", http.extra[0].name);
    try testing.expectEqualStrings("abc", http.extra[0].value);
}

test "receive with nothing outstanding reports a closed server" {
    var http = try start(testing.allocator, testing.io, .{ .url = "https://example.invalid/mcp" });
    defer http.destroy();

    try testing.expectError(Transport.Error.ServerClosed, http.receive());
}

test "a buffered body is handed out once and freed on the next call" {
    var http = try start(testing.allocator, testing.io, .{ .url = "https://example.invalid/mcp" });
    defer http.destroy();

    http.pending = .{ .json = try testing.allocator.dupe(u8, "{\"id\":1}") };

    try testing.expectEqualStrings("{\"id\":1}", try http.receive());
    try testing.expectError(Transport.Error.ServerClosed, http.receive());
}

test "a data line longer than a whole message is refused, not mistaken for the end" {
    const line = "data: " ++ ("x" ** 64) ++ "\n\n";
    var reader = std.Io.Reader.fixed(line);

    try testing.expectError(
        error.StreamTooLong,
        readSseMessage(testing.allocator, &reader, 8),
    );
}

test "the read buffer is large enough for any message the transport allows" {
    var http = try start(testing.allocator, testing.io, .{
        .url = "https://example.invalid/mcp",
        .max_message = 128 * 1024,
    });
    defer http.destroy();

    try testing.expectEqual(@as(usize, 128 * 1024), http.transfer_buffer.len);
}

test "the settled revision is remembered and replaced, not appended" {
    var http = try start(testing.allocator, testing.io, .{ .url = "https://example.invalid/mcp" });
    defer http.destroy();

    try testing.expect(http.version == null);

    try http.setProtocolVersion("2025-11-25");
    try testing.expectEqualStrings("2025-11-25", http.version.?);

    try http.setProtocolVersion("2026-07-28");
    try testing.expectEqualStrings("2026-07-28", http.version.?);
}

test "a transport with no headers says it cannot carry a revision" {
    var stdio = try @import("stdio.zig").start(testing.allocator, testing.io, .{
        .argv = &.{ "cat", "-u" },
    });
    defer stdio.destroy();

    try testing.expect(!try stdio.transport.setProtocolVersion("2025-11-25"));
}
