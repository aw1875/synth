//! JSON-RPC 2.0, as much of it as MCP uses.
//!
//! Requests are written rather than serialised from a struct: params differ per
//! method and one of them carries `_meta`, so composing the object directly is
//! less work than a type per call. Replies are parsed loosely, because a server
//! is free to send fields we have never heard of.
//!
//! Nothing here knows about MCP. Nothing here knows about the program using it.

const std = @import("std");
const testing = std.testing;

pub const version = "2.0";

/// A request id. We only ever mint numbers, but a reply must be matched to its
/// request by whatever the server echoed back, and a server may normalise.
pub const Id = union(enum) {
    number: i64,
    string: []const u8,

    pub fn eql(self: Id, other: Id) bool {
        return switch (self) {
            .number => |a| switch (other) {
                .number => |b| a == b,
                .string => false,
            },
            .string => |a| switch (other) {
                .number => false,
                .string => |b| std.mem.eql(u8, a, b),
            },
        };
    }

    pub fn write(self: Id, w: *std.Io.Writer) !void {
        switch (self) {
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        }
    }

    /// The id of a parsed message, or null when it has none - which is what
    /// makes a message a notification.
    pub fn from(value: std.json.Value) ?Id {
        return switch (value) {
            .integer => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            else => null,
        };
    }
};

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,

    /// The codes this client has to tell apart. Everything else is reported as
    /// it arrived.
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    /// `UnsupportedProtocolVersion`, renumbered from -32004 in the 2026-07-28
    /// error code allocation policy. Both are recognised: a server built
    /// against the draft still sends the old one.
    pub const unsupported_protocol_version: i64 = -32022;
    pub const unsupported_protocol_version_draft: i64 = -32004;

    pub fn isUnsupportedVersion(self: ErrorObject) bool {
        return self.code == unsupported_protocol_version or
            self.code == unsupported_protocol_version_draft;
    }
};

/// One message read off the wire. A reply carries `result` or `err`; a request
/// or notification from the server carries `method`.
pub const Message = struct {
    id: ?Id = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    err: ?ErrorObject = null,

    /// Whether this is the server asking us something rather than answering.
    pub fn isCall(self: Message) bool {
        return self.method != null;
    }

    /// Parse one line. Allocations land in `arena` and live as long as it does,
    /// which is what lets `result` be handed back as a borrowed value.
    pub fn parse(arena: std.mem.Allocator, line: []const u8) !Message {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch
            return error.MalformedMessage;
        const object = switch (parsed) {
            .object => |o| o,
            else => return error.MalformedMessage,
        };

        var message: Message = .{};
        if (object.get("id")) |value| message.id = Id.from(value);
        if (object.get("method")) |value| {
            if (value == .string) message.method = value.string;
        }
        message.params = object.get("params");
        message.result = object.get("result");

        if (object.get("error")) |value| {
            const fields = switch (value) {
                .object => |o| o,
                else => return error.MalformedMessage,
            };
            message.err = .{
                .code = switch (fields.get("code") orelse std.json.Value{ .null = {} }) {
                    .integer => |n| n,
                    else => 0,
                },
                .message = switch (fields.get("message") orelse std.json.Value{ .null = {} }) {
                    .string => |s| s,
                    else => "",
                },
                .data = fields.get("data"),
            };
        }

        return message;
    }
};

/// Write a request. `params` is a complete JSON object, or null to omit the
/// field entirely - which is not the same as sending `{}`, and some servers
/// care.
pub fn writeRequest(
    w: *std.Io.Writer,
    id: Id,
    method: []const u8,
    params: ?[]const u8,
) !void {
    try w.writeAll("{\"jsonrpc\":\"" ++ version ++ "\",\"id\":");
    try id.write(w);
    try w.writeAll(",\"method\":");
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    if (params) |body| {
        try w.writeAll(",\"params\":");
        try w.writeAll(body);
    }
    try w.writeByte('}');
}

/// Write a notification: a request with no id, which must not be answered.
pub fn writeNotification(w: *std.Io.Writer, method: []const u8, params: ?[]const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"" ++ version ++ "\",\"method\":");
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    if (params) |body| {
        try w.writeAll(",\"params\":");
        try w.writeAll(body);
    }
    try w.writeByte('}');
}

/// Hands out request ids. Monotonic and per-connection, which is all the
/// protocol asks for.
pub const Ids = struct {
    next: i64 = 1,

    pub fn take(self: *Ids) Id {
        const id: Id = .{ .number = self.next };
        self.next += 1;
        return id;
    }
};

test "a request is written with the fields a server expects" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeRequest(&out.writer, .{ .number = 7 }, "tools/call", "{\"name\":\"read\"}");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"read\"}}",
        out.written(),
    );
}

test "params are omitted rather than sent empty" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeRequest(&out.writer, .{ .number = 1 }, "server/discover", null);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\"}",
        out.written(),
    );
}

test "a notification carries no id" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeNotification(&out.writer, "notifications/initialized", null);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        out.written(),
    );
}

test "a result and an error are told apart" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ok = try Message.parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"tools\":[]}}");
    try testing.expect(ok.err == null);
    try testing.expect(ok.result != null);
    try testing.expect(ok.id.?.eql(.{ .number = 3 }));
    try testing.expect(!ok.isCall());

    const bad = try Message.parse(
        arena,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"no such method\"}}",
    );
    try testing.expect(bad.result == null);
    try testing.expectEqual(@as(i64, -32601), bad.err.?.code);
    try testing.expectEqualStrings("no such method", bad.err.?.message);
}

test "an unsupported version is recognised under either code" {
    const current: ErrorObject = .{ .code = -32022, .message = "" };
    const draft: ErrorObject = .{ .code = -32004, .message = "" };
    const other: ErrorObject = .{ .code = -32601, .message = "" };

    try testing.expect(current.isUnsupportedVersion());
    try testing.expect(draft.isUnsupportedVersion());
    try testing.expect(!other.isUnsupportedVersion());
}

test "a message from the server is recognised as a call" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const note = try Message.parse(
        arena,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
    );
    try testing.expect(note.isCall());
    try testing.expect(note.id == null);
    try testing.expectEqualStrings("notifications/tools/list_changed", note.method.?);
}

test "a string id round-trips and compares" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const id: Id = .{ .string = "abc" };
    try id.write(&out.writer);
    try testing.expectEqualStrings("\"abc\"", out.written());

    try testing.expect(id.eql(.{ .string = "abc" }));
    try testing.expect(!id.eql(.{ .string = "abd" }));
    try testing.expect(!id.eql(.{ .number = 1 }));
}

test "garbage is an error, not a crash" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.MalformedMessage, Message.parse(arena, "not json"));
    try testing.expectError(error.MalformedMessage, Message.parse(arena, "[1,2,3]"));
    try testing.expectError(error.MalformedMessage, Message.parse(arena, ""));
}

test "ids are handed out in order" {
    var ids: Ids = .{};
    try testing.expect(ids.take().eql(.{ .number = 1 }));
    try testing.expect(ids.take().eql(.{ .number = 2 }));
    try testing.expect(ids.take().eql(.{ .number = 3 }));
}
