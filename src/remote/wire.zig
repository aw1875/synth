//! The remote protocol: what a client and a session server say to each other,
//! one JSON object per line.
//!
//! `Up` is what a client sends and `Down` what the server sends; both travel as
//! a `Frame`, which flattens `type` and `id` into the payload's object, so
//! `{"type":"decide","id":7,"decision":"once"}` is one frame. A request carries
//! an `id` and is answered by the `reply` with the same one; events carry none.
//!
//! A connection drives at most one session at a time, the one it attached, so
//! commands and events need not name it.
//!
//! Compatibility is additive: both sides skip `type`s and fields they do not
//! know, so a new message or optional field never bumps `version`. The enums
//! borrowed from the agent - roles, states, statuses - travel by tag name, so
//! renaming or adding a tag in one of those is a breaking change.

const std = @import("std");
const testing = std.testing;

const Conversation = @import("../core/conversation.zig");
const mention = @import("../core/mention.zig");
const todo = @import("../core/todo.zig");
const Loop = @import("../agent/loop.zig");

/// Bumped only on a breaking change. A mismatch is refused with an error that
/// names the side to update.
pub const version: u32 = 1;

/// Longest line either side accepts. Pasted images ride inside `submit` as
/// base64, so this is generous.
pub const max_line: usize = 16 * 1024 * 1024;

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    status: Conversation.ToolCall.Status,
    /// The preview the server holds; `load_tool_result` fetches the rest.
    result: ?[]const u8 = null,
    result_bytes: u64 = 0,
    elapsed_ms: ?u64 = null,
};

pub const Attachment = struct {
    path: []const u8,
    content: []const u8,
    content_bytes: u64 = 0,
};

/// A transcript message as the server holds it in memory: heavy bodies are
/// previews, and the byte counts say how much more there is to load.
pub const Message = struct {
    seq: u64,
    role: Conversation.Role,
    text: []const u8,
    thinking: ?[]const u8 = null,
    thinking_ms: ?u64 = null,
    thinking_bytes: u64 = 0,
    tool_calls: []const ToolCall = &.{},
    tool_name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    attachments: []const Attachment = &.{},

    /// Borrows `msg`'s strings; only the arrays are allocated.
    pub fn from(arena: std.mem.Allocator, msg: *const Conversation.Message) !Message {
        const calls = try arena.alloc(ToolCall, msg.tool_calls.len);
        for (msg.tool_calls, calls) |call, *out| out.* = .{
            .id = call.id,
            .name = call.name,
            .arguments = call.arguments,
            .status = call.status,
            .result = call.result,
            .result_bytes = call.result_bytes,
            .elapsed_ms = call.elapsed_ms,
        };
        const attachments = try arena.alloc(Attachment, msg.attachments.len);
        for (msg.attachments, attachments) |attachment, *out| out.* = .{
            .path = attachment.path,
            .content = attachment.content,
            .content_bytes = attachment.content_bytes,
        };
        return .{
            .seq = msg.seq,
            .role = msg.role,
            .text = msg.text,
            .thinking = msg.thinking,
            .thinking_ms = msg.thinking_ms,
            .thinking_bytes = msg.thinking_bytes,
            .tool_calls = calls,
            .tool_name = msg.tool_name,
            .tool_call_id = msg.tool_call_id,
            .attachments = attachments,
        };
    }

    /// A transcript message owning a copy of everything, `seq` kept.
    pub fn toOwned(self: Message, allocator: std.mem.Allocator) !Conversation.Message {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const calls = try arena.alloc(Conversation.ToolCall, self.tool_calls.len);
        for (self.tool_calls, calls) |call, *out| out.* = .{
            .id = call.id,
            .name = call.name,
            .arguments = call.arguments,
            .status = call.status,
            .result = call.result,
            .result_bytes = call.result_bytes,
            .elapsed_ms = call.elapsed_ms,
        };
        const attachments = try arena.alloc(mention.Attachment, self.attachments.len);
        for (self.attachments, attachments) |attachment, *out| out.* = .{
            .path = attachment.path,
            .content = attachment.content,
            .content_bytes = attachment.content_bytes,
        };
        const view: Conversation.Message = .{
            .seq = self.seq,
            .role = self.role,
            .text = self.text,
            .thinking = self.thinking,
            .thinking_ms = self.thinking_ms,
            .thinking_bytes = self.thinking_bytes,
            .tool_calls = calls,
            .tool_name = self.tool_name,
            .tool_call_id = self.tool_call_id,
            .attachments = attachments,
        };
        return view.clone(allocator);
    }
};

/// Everything about a session that is not its transcript, sent whole whenever
/// any of it changes.
pub const Status = struct {
    state: Loop.State = .idle,
    /// What the session says it is doing: `Loop.label`.
    label: []const u8 = "",
    title: []const u8 = "",
    handle: []const u8 = "",
    agent: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    context_limit: u32 = 0,
    usage: Loop.Usage = .{},
    todos: []const todo.Item = &.{},
    /// The message whose tool calls are being decided or run, and the call
    /// waiting on a decision, if one is.
    pending_seq: ?u64 = null,
    pending_call: ?u32 = null,
    /// What each running call last said it was doing, by index into the
    /// pending message's calls.
    notes: []const []const u8 = &.{},
    /// Prompts typed while busy, waiting for the next step.
    steering: []const []const u8 = &.{},
    outcome: ?Loop.Outcome = null,
    /// The request streaming right now, as `Stream.request` numbers it.
    request: ?u64 = null,
    /// Turns finished so far, so a client can tell a new ending from one it
    /// has already seen.
    finished: u64 = 0,
};

/// What the in-flight request has streamed so far, or since the last event.
pub const Stream = struct {
    /// Which request this is. A new number starts a new stream.
    request: u64,
    thinking: []const u8 = "",
    text: []const u8 = "",
    /// The model has moved on from thinking to its answer.
    closed: bool = false,
};

pub const Snapshot = struct {
    status: Status,
    /// The tail of the transcript, oldest first.
    messages: []const Message,
    /// Messages before the first one here, still in the database.
    dropped: u64 = 0,
    stream: ?Stream = null,
};

/// A session in a listing.
pub const Summary = struct {
    handle: []const u8,
    title: []const u8 = "",
    root: []const u8 = "",
    state: Loop.State = .idle,
    /// Clients attached right now.
    clients: u32 = 0,
};

pub const Up = union(enum) {
    hello: struct {
        protocol: u32,
        client: []const u8 = "",
    },
    /// Live sessions. Replied with `[]Summary`.
    list: struct {},
    /// Start a session in `root` on the server's machine. Replied with its
    /// `Summary`.
    open: struct {
        root: []const u8,
    },
    /// Drive a session, live or stored, by handle. A `snapshot` arrives
    /// before the reply, and events follow it.
    attach: struct {
        handle: []const u8,
        history: u32 = 200,
    },
    detach: struct {},
    /// End a session: cancel it, unload it, keep its transcript.
    stop: struct {
        handle: []const u8,
    },
    submit: struct {
        text: []const u8,
        /// Text the composer held back from the prompt, a long paste say.
        attachments: []const Attachment = &.{},
        images: []const []const u8 = &.{},
    },
    steer: struct {
        text: []const u8,
    },
    cancel: struct {},
    decide: struct {
        decision: Loop.Decision,
    },
    answer: struct {
        text: []const u8,
    },
    compact: struct {},
    rename: struct {
        title: []const u8,
    },
    use_agent: struct {
        id: []const u8,
    },
    set_model: struct {
        model: []const u8,
    },
    /// Replied with the whole result as a string.
    load_tool_result: struct {
        seq: u64,
        call: u32,
    },
    /// Replied with the whole reasoning as a string.
    load_thinking: struct {
        seq: u64,
    },
    /// Replied with up to `limit` messages before `before_seq`, oldest first.
    page_history: struct {
        before_seq: u64,
        limit: u32 = 50,
    },
};

pub const Down = union(enum) {
    hello: struct {
        protocol: u32,
        server: []const u8 = "",
    },
    /// The answer to the request with the same `id`. `result` is whatever
    /// that request is documented to return.
    reply: struct {
        ok: bool,
        @"error": ?[]const u8 = null,
        result: ?std.json.Value = null,
    },
    snapshot: Snapshot,
    appended: struct {
        message: Message,
    },
    /// A message already sent has changed: a call settled, a preview shrank.
    updated: struct {
        message: Message,
    },
    stream: Stream,
    status: Status,
    /// Something to tell the person: a hook refused a prompt, a command failed.
    notice: struct {
        text: []const u8,
    },
    /// The attached session was stopped; the connection is detached.
    ended: struct {},
};

pub fn Frame(comptime Body: type) type {
    return struct {
        id: ?u64 = null,
        body: Body,

        const Self = @This();

        pub fn jsonStringify(self: Self, jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField("type");
            try jws.write(@tagName(self.body));
            if (self.id) |id| {
                try jws.objectField("id");
                try jws.write(id);
            }
            switch (self.body) {
                inline else => |payload| inline for (std.meta.fields(@TypeOf(payload))) |field| {
                    const value = @field(payload, field.name);
                    if (@typeInfo(field.type) != .optional or value != null) {
                        try jws.objectField(field.name);
                        try jws.write(value);
                    }
                },
            }
            try jws.endObject();
        }

        /// Null for a `type` this build does not know: a newer peer may send
        /// messages we predate, and skipping them is the versioning rule.
        /// Strings point into `arena` or `line`.
        pub fn decode(arena: std.mem.Allocator, line: []const u8) error{ OutOfMemory, MalformedMessage }!?Self {
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| return malformed(err);
            if (value != .object) return error.MalformedMessage;

            const name = switch (value.object.get("type") orelse return error.MalformedMessage) {
                .string => |s| s,
                else => return error.MalformedMessage,
            };
            const tag = std.meta.stringToEnum(std.meta.Tag(Body), name) orelse return null;

            const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
            const id: ?u64 = if (value.object.get("id")) |id|
                std.json.parseFromValueLeaky(u64, arena, id, options) catch |err| return malformed(err)
            else
                null;
            switch (tag) {
                inline else => |t| {
                    const Payload = @FieldType(Body, @tagName(t));
                    const payload = std.json.parseFromValueLeaky(Payload, arena, value, options) catch |err|
                        return malformed(err);
                    return .{ .id = id, .body = @unionInit(Body, @tagName(t), payload) };
                },
            }
        }
    };
}

/// Running out of memory is not the peer's fault, and is not reported as if it were.
fn malformed(err: anyerror) error{ OutOfMemory, MalformedMessage } {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedMessage;
}

/// One frame as one line. The caller flushes.
pub fn encode(w: *std.Io.Writer, frame: anytype) !void {
    try std.json.Stringify.value(frame, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// A successful reply carrying `result`, written straight from its type.
pub fn encodeResult(w: *std.Io.Writer, id: ?u64, result: anytype) !void {
    var jws: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try jws.beginObject();
    try jws.objectField("type");
    try jws.write("reply");
    if (id) |value| {
        try jws.objectField("id");
        try jws.write(value);
    }
    try jws.objectField("ok");
    try jws.write(true);
    try jws.objectField("result");
    try jws.write(result);
    try jws.endObject();
    try w.writeByte('\n');
}

/// A reply's result as the type its request is documented to return.
pub fn parseResult(comptime T: type, arena: std.mem.Allocator, result: ?std.json.Value) !T {
    const value = result orelse return error.MalformedMessage;
    return std.json.parseFromValueLeaky(T, arena, value, .{ .ignore_unknown_fields = true }) catch |err|
        malformed(err);
}

/// The next non-empty line, without its line ending. Null once the peer has
/// closed its side.
pub fn readLine(reader: *std.Io.Reader) !?[]const u8 {
    while (true) {
        const line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.LineTooLong,
            error.ReadFailed => return error.ReadFailed,
        } orelse return null;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len > 0) return trimmed;
    }
}

fn roundTrip(comptime Body: type, arena: std.mem.Allocator, frame: Frame(Body)) !Frame(Body) {
    var out: std.Io.Writer.Allocating = .init(arena);
    try encode(&out.writer, frame);
    return (try Frame(Body).decode(arena, std.mem.trimEnd(u8, out.written(), "\n"))).?;
}

test "a frame flattens its type and id into the payload" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try encode(&out.writer, Frame(Up){ .id = 7, .body = .{ .decide = .{ .decision = .once } } });
    try testing.expectEqualStrings("{\"type\":\"decide\",\"id\":7,\"decision\":\"once\"}\n", out.written());
}

test "unknown types are skipped and unknown fields ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(null, try Frame(Down).decode(arena, "{\"type\":\"from_the_future\"}"));
    const frame = (try Frame(Down).decode(arena, "{\"type\":\"notice\",\"text\":\"hi\",\"colour\":\"red\"}")).?;
    try testing.expectEqualStrings("hi", frame.body.notice.text);
}

test "malformed lines are refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.MalformedMessage, Frame(Up).decode(arena, "{"));
    try testing.expectError(error.MalformedMessage, Frame(Up).decode(arena, "[1,2]"));
    try testing.expectError(error.MalformedMessage, Frame(Up).decode(arena, "{\"id\":7}"));
    try testing.expectError(error.MalformedMessage, Frame(Up).decode(arena, "{\"type\":7}"));
    try testing.expectError(error.MalformedMessage, Frame(Up).decode(arena, "{\"type\":\"decide\",\"decision\":\"maybe\"}"));
    try testing.expectError(error.MalformedMessage, Frame(Up).decode(arena, "{\"type\":\"cancel\",\"id\":-1}"));
}

test "a snapshot round-trips" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const calls = [_]ToolCall{.{ .id = "c0", .name = "bash", .arguments = "{\"command\":\"ls\"}", .status = .pending }};
    const frame = try roundTrip(Down, arena, .{ .body = .{ .snapshot = .{
        .status = .{
            .state = .awaiting_approval,
            .usage = .{ .calls = 3 },
            .todos = &.{.{ .text = "wait for the user", .status = .active }},
            .pending_seq = 40,
            .pending_call = 0,
            .outcome = .done,
        },
        .messages = &.{.{ .seq = 40, .role = .assistant, .text = "on it", .tool_calls = &calls }},
        .dropped = 12,
        .stream = .{ .request = 2, .thinking = "hm" },
    } } });

    const snap = frame.body.snapshot;
    try testing.expectEqual(Loop.State.awaiting_approval, snap.status.state);
    try testing.expectEqual(@as(u32, 3), snap.status.usage.calls);
    try testing.expectEqual(todo.Status.active, snap.status.todos[0].status);
    try testing.expectEqual(@as(?u32, 0), snap.status.pending_call);
    try testing.expectEqual(@as(?Loop.Outcome, .done), snap.status.outcome);
    try testing.expectEqualStrings("bash", snap.messages[0].tool_calls[0].name);
    try testing.expectEqual(@as(u64, 12), snap.dropped);
    try testing.expectEqualStrings("hm", snap.stream.?.thinking);
}

test "a typed result rides a reply and parses back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    const sessions = [_]Summary{.{ .handle = "ses_abc", .root = "/src/api", .state = .thinking, .clients = 2 }};
    try encodeResult(&out.writer, 4, &sessions);

    const frame = (try Frame(Down).decode(arena, std.mem.trimEnd(u8, out.written(), "\n"))).?;
    try testing.expectEqual(@as(?u64, 4), frame.id);
    try testing.expect(frame.body.reply.ok);
    const parsed = try parseResult([]const Summary, arena, frame.body.reply.result);
    try testing.expectEqualStrings("ses_abc", parsed[0].handle);
    try testing.expectEqual(Loop.State.thinking, parsed[0].state);
}

test "a message survives the wire and comes back owned" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    var calls = [_]Conversation.ToolCall{.{ .id = "c0", .name = "read", .arguments = "{}", .status = .ok, .result = "body", .result_bytes = 9000 }};
    var attachments = [_]mention.Attachment{.{ .path = "a.zig", .content = "const a = 1;" }};
    const original = try convo.append(.{ .role = .assistant, .text = "done", .thinking = "why", .tool_calls = &calls, .attachments = &attachments });

    const frame = try roundTrip(Down, arena, .{ .body = .{ .appended = .{ .message = try Message.from(arena, original) } } });
    var owned = try frame.body.appended.message.toOwned(testing.allocator);
    defer owned.deinit(testing.allocator);

    try testing.expectEqual(original.seq, owned.seq);
    try testing.expectEqualStrings("why", owned.thinking.?);
    try testing.expectEqualStrings("body", owned.tool_calls[0].result.?);
    try testing.expectEqual(@as(u64, 9000), owned.tool_calls[0].result_bytes);
    try testing.expectEqualStrings("const a = 1;", owned.attachments[0].content);
}
