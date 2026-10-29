//! JSON-RPC 2.0 as ACP frames it: one message per line, in either direction.
//!
//! Reading leans on `mcp.jsonrpc`, which parses any message loosely. Writing
//! is here, typed, so a payload is serialised straight onto the wire rather
//! than built as a string first.

const std = @import("std");
const testing = std.testing;

const mcp = @import("mcp");

pub const jsonrpc = mcp.jsonrpc;
pub const Id = jsonrpc.Id;
pub const Message = jsonrpc.Message;
pub const ErrorObject = jsonrpc.ErrorObject;

/// Longest line either side accepts. Pasted images ride inside a prompt as
/// base64, so this is generous.
pub const max_line: usize = 16 * 1024 * 1024;

const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// A request to the peer, answered by a reply carrying `id`.
pub fn request(w: *std.Io.Writer, id: Id, method: []const u8, params: anytype) !void {
    var jws: std.json.Stringify = .{ .writer = w, .options = options };
    try jws.beginObject();
    try header(&jws);
    try jws.objectField("id");
    try writeId(&jws, id);
    try jws.objectField("method");
    try jws.write(method);
    try jws.objectField("params");
    try jws.write(params);
    try jws.endObject();
    try w.writeByte('\n');
}

/// A notification: a request with no id, which is never answered.
pub fn notify(w: *std.Io.Writer, method: []const u8, params: anytype) !void {
    var jws: std.json.Stringify = .{ .writer = w, .options = options };
    try jws.beginObject();
    try header(&jws);
    try jws.objectField("method");
    try jws.write(method);
    try jws.objectField("params");
    try jws.write(params);
    try jws.endObject();
    try w.writeByte('\n');
}

/// The successful answer to request `id`.
pub fn result(w: *std.Io.Writer, id: Id, value: anytype) !void {
    var jws: std.json.Stringify = .{ .writer = w, .options = options };
    try jws.beginObject();
    try header(&jws);
    try jws.objectField("id");
    try writeId(&jws, id);
    try jws.objectField("result");
    try jws.write(value);
    try jws.endObject();
    try w.writeByte('\n');
}

/// Request `id` failed, for the reason in `message`.
pub fn fail(w: *std.Io.Writer, id: ?Id, error_code: i64, message: []const u8) !void {
    var jws: std.json.Stringify = .{ .writer = w, .options = options };
    try jws.beginObject();
    try header(&jws);
    try jws.objectField("id");
    if (id) |known| try writeId(&jws, known) else try jws.write(null);
    try jws.objectField("error");
    try jws.write(.{ .code = error_code, .message = message });
    try jws.endObject();
    try w.writeByte('\n');
}

/// Error codes JSON-RPC reserves, and the ones ACP adds.
pub const code = struct {
    pub const parse_error: i64 = -32700;
    pub const invalid_request: i64 = -32600;
    pub const method_not_found: i64 = -32601;
    pub const invalid_params: i64 = -32602;
    pub const internal_error: i64 = -32603;
    /// ACP: the request was cancelled with `$/cancel_request`.
    pub const request_cancelled: i64 = -32800;
};

fn header(jws: *std.json.Stringify) !void {
    try jws.objectField("jsonrpc");
    try jws.write(jsonrpc.version);
}

fn writeId(jws: *std.json.Stringify, id: Id) !void {
    switch (id) {
        .number => |n| try jws.write(n),
        .string => |s| try jws.write(s),
    }
}

/// A message's params, or its result, as the type its method documents.
pub fn parse(comptime T: type, arena: std.mem.Allocator, value: ?std.json.Value) error{ OutOfMemory, InvalidParams }!T {
    const given = value orelse std.json.Value{ .object = .empty };
    return std.json.parseFromValueLeaky(T, arena, given, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidParams,
    };
}

/// Lines read off a connection, each held in memory sized to it. A read
/// buffer of `max_line` would be resident from the start, since safe builds
/// fill every allocation.
pub const LineReader = struct {
    line: std.Io.Writer.Allocating,

    /// Past this, the line's memory is given back before the next read, so
    /// one pasted image does not stay resident for the whole connection.
    const retained: usize = 64 * 1024;

    pub fn init(allocator: std.mem.Allocator) LineReader {
        return .{ .line = .init(allocator) };
    }

    pub fn deinit(self: *LineReader) void {
        self.line.deinit();
    }

    /// The next non-empty line, without its line ending, valid until the
    /// next call. Null once the peer has closed its side.
    pub fn next(self: *LineReader, reader: *std.Io.Reader) !?[]const u8 {
        while (true) {
            self.reset();
            _ = reader.streamDelimiterLimit(&self.line.writer, '\n', .limited(max_line)) catch |err| switch (err) {
                error.StreamTooLong => return error.LineTooLong,
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return error.OutOfMemory,
            };
            const ended = if (reader.takeByte()) |_| true else |err| switch (err) {
                error.EndOfStream => false,
                error.ReadFailed => return error.ReadFailed,
            };
            const trimmed = std.mem.trimEnd(u8, self.line.written(), "\r");
            if (trimmed.len > 0) return trimmed;
            if (!ended) return null;
        }
    }

    fn reset(self: *LineReader) void {
        if (self.line.writer.buffer.len <= retained) return self.line.clearRetainingCapacity();
        const allocator = self.line.allocator;
        self.line.deinit();
        self.line = .init(allocator);
    }
};

test "each kind of message is one line of JSON-RPC" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try request(&out.writer, .{ .number = 3 }, "session/request_permission", .{ .sessionId = "ses_a" });
    try notify(&out.writer, "session/cancel", .{ .sessionId = "ses_a" });
    try result(&out.writer, .{ .string = "x" }, .{ .stopReason = "end_turn", .missing = @as(?u8, null) });
    try fail(&out.writer, .{ .number = 4 }, code.method_not_found, "no such method");
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{"sessionId":"ses_a"}}
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"ses_a"}}
        \\{"jsonrpc":"2.0","id":"x","result":{"stopReason":"end_turn"}}
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"no such method"}}
        \\
    , out.written());
}

test "params parse as their type, and a bad shape is invalid params" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = try Message.parse(arena, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\",\"params\":{\"cwd\":\"/src\",\"extra\":1}}");
    const Params = struct { cwd: []const u8 };
    try testing.expectEqualStrings("/src", (try parse(Params, arena, message.params)).cwd);
    try testing.expectError(error.InvalidParams, parse(struct { cwd: u32 }, arena, message.params));
    try testing.expectEqual(@as(u8, 0), (try parse(struct { n: u8 = 0 }, arena, null)).n);
}

test "lines longer than the read buffer come whole, and their memory is given back" {
    const long = "x" ** (LineReader.retained * 2);
    var source: std.Io.Reader = .fixed("one\r\n\n" ++ long ++ "\ntwo\nlast");
    var limited_buffer: [16]u8 = undefined;
    var limited = source.limited(.unlimited, &limited_buffer);
    var lines: LineReader = .init(testing.allocator);
    defer lines.deinit();

    try testing.expectEqualStrings("one", (try lines.next(&limited.interface)).?);
    try testing.expectEqualStrings(long, (try lines.next(&limited.interface)).?);
    try testing.expectEqualStrings("two", (try lines.next(&limited.interface)).?);
    try testing.expect(lines.line.writer.buffer.len <= LineReader.retained);
    try testing.expectEqualStrings("last", (try lines.next(&limited.interface)).?);
    try testing.expectEqual(null, try lines.next(&limited.interface));
}
