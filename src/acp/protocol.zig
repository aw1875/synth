//! ACP, the Agent Client Protocol (agentclientprotocol.com), version 1: the
//! part of it synth speaks. Field names are the protocol's own camelCase, so
//! these types serialise as they are.
//!
//! A client that says it speaks synth's extension (`_meta.synth` on
//! `initialize`) is sent `synth.zig`'s notifications in place of
//! `session/update`; everything else here is shared by every client.

const std = @import("std");
const testing = std.testing;

const synth = @import("synth.zig");

pub const version: u32 = 1;

/// Methods a client calls on the agent.
pub const method = struct {
    pub const initialize = "initialize";
    pub const session_new = "session/new";
    pub const session_load = "session/load";
    pub const session_prompt = "session/prompt";
    pub const session_cancel = "session/cancel";
    pub const session_set_mode = "session/set_mode";
    pub const session_set_config_option = "session/set_config_option";
    pub const session_list = "session/list";
    pub const session_close = "session/close";
    pub const session_resume = "session/resume";
    pub const session_delete = "session/delete";
    /// Agent to client.
    pub const session_update = "session/update";
    pub const session_request_permission = "session/request_permission";
    pub const elicitation_create = "elicitation/create";
    pub const fs_read_text_file = "fs/read_text_file";
    pub const fs_write_text_file = "fs/write_text_file";
    pub const terminal_create = "terminal/create";
    pub const terminal_output = "terminal/output";
    pub const terminal_wait_for_exit = "terminal/wait_for_exit";
    pub const terminal_kill = "terminal/kill";
    pub const terminal_release = "terminal/release";
    /// Either way: the request with this id no longer needs an answer.
    pub const cancel_request = "$/cancel_request";
};

pub const Implementation = struct {
    name: []const u8,
    version: []const u8 = "",
};

pub const Meta = struct {
    synth: ?synth.Hello = null,
};

pub const Initialize = struct {
    protocolVersion: u32,
    clientCapabilities: ClientCapabilities = .{},
    clientInfo: ?Implementation = null,
    _meta: ?Meta = null,
};

pub const ClientCapabilities = struct {
    /// Files read and written through the client: an editor's buffers.
    fs: ?struct {
        readTextFile: bool = false,
        writeTextFile: bool = false,
    } = null,
    /// Runs commands in terminals of its own, shown as they run.
    terminal: bool = false,
    elicitation: ?struct {
        /// Present, even empty, when the client draws forms.
        form: ?struct {} = null,
    } = null,

    pub fn drawsForms(self: ClientCapabilities) bool {
        const elicitation = self.elicitation orelse return false;
        return elicitation.form != null;
    }
};

pub const Initialized = struct {
    protocolVersion: u32 = version,
    agentCapabilities: AgentCapabilities = .{},
    agentInfo: Implementation,
    authMethods: []const struct {} = &.{},
    _meta: ?Meta = null,
};

pub const AgentCapabilities = struct {
    loadSession: bool = true,
    mcpCapabilities: struct { http: bool = true } = .{},
    promptCapabilities: struct {
        image: bool = true,
        audio: bool = false,
        embeddedContext: bool = true,
    } = .{},
    sessionCapabilities: struct {
        list: struct {} = .{},
        close: struct {} = .{},
        @"resume": struct {} = .{},
        delete: struct {} = .{},
    } = .{},
};

pub const NewSession = struct {
    cwd: []const u8,
    /// Servers the client wants connected beside those in synth's config.
    mcpServers: []const McpServer = &.{},
};

pub const LoadSession = struct {
    sessionId: []const u8,
    cwd: []const u8 = "",
    mcpServers: []const McpServer = &.{},
};

/// A server run as a child when it names a `command`, else reached at its
/// `url` (`type` "http"). Read loosely: ACP's `anyOf` has no single shape.
pub const McpServer = struct {
    type: ?[]const u8 = null,
    name: []const u8,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    env: []const NameValue = &.{},
    url: ?[]const u8 = null,
    headers: []const NameValue = &.{},
};

pub const NameValue = struct { name: []const u8, value: []const u8 };

pub const SessionSetup = struct {
    sessionId: []const u8,
    modes: ?Modes = null,
    configOptions: []const ConfigOption = &.{},
};

/// What `session/load` answers: everything `session/new` does but the id.
pub const Loaded = struct {
    modes: ?Modes = null,
    configOptions: []const ConfigOption = &.{},
};

pub const Modes = struct {
    currentModeId: []const u8,
    availableModes: []const Mode,
};

pub const Mode = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

/// A setting chosen from a list: a session's model, or its reasoning effort.
pub const ConfigOption = struct {
    id: []const u8,
    name: []const u8,
    category: ?[]const u8 = null,
    type: []const u8 = "select",
    currentValue: []const u8,
    options: []const ConfigValue,
};

pub const ConfigValue = struct {
    value: []const u8,
    name: []const u8,
};

pub const config_model = "model";
pub const config_effort = "effort";

pub const ReadTextFile = struct {
    sessionId: []const u8,
    path: []const u8,
};

pub const TextFile = struct {
    content: []const u8,
};

pub const WriteTextFile = struct {
    sessionId: []const u8,
    path: []const u8,
    content: []const u8,
};

pub const CreateTerminal = struct {
    sessionId: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    outputByteLimit: ?u64 = null,
};

pub const TerminalCreated = struct {
    terminalId: []const u8,
};

pub const TerminalRef = struct {
    sessionId: []const u8,
    terminalId: []const u8,
};

pub const ExitStatus = struct {
    exitCode: ?u32 = null,
    signal: ?[]const u8 = null,
};

pub const TerminalOutput = struct {
    output: []const u8,
    truncated: bool = false,
    exitStatus: ?ExitStatus = null,
};

pub const Prompt = struct {
    sessionId: []const u8,
    /// Content blocks, read loosely: see `Content.of`.
    prompt: []const std.json.Value,
};

pub const StopReason = enum { end_turn, max_tokens, max_turn_requests, refusal, cancelled };

pub const Prompted = struct {
    stopReason: StopReason,
};

/// A result with nothing to say. An empty literal would encode as `[]`.
pub const Empty = struct {};

pub const SessionId = struct {
    sessionId: []const u8,
};

pub const SetMode = struct {
    sessionId: []const u8,
    modeId: []const u8,
};

pub const SetConfigOption = struct {
    sessionId: []const u8,
    configId: []const u8,
    value: []const u8,
    _meta: ?struct { synth: ?synth.SetModel = null } = null,
};

pub const ConfigOptions = struct {
    configOptions: []const ConfigOption,
};

pub const ListSessions = struct {
    cwd: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
};

pub const SessionList = struct {
    sessions: []const SessionInfo,
    nextCursor: ?[]const u8 = null,
};

pub const SessionInfo = struct {
    sessionId: []const u8,
    cwd: []const u8,
    title: ?[]const u8 = null,
    /// ISO 8601.
    updatedAt: ?[]const u8 = null,
    _meta: ?struct { synth: synth.Stored } = null,
};

pub const PermissionKind = enum { allow_once, allow_always, reject_once, reject_always };

pub const PermissionOption = struct {
    optionId: []const u8,
    name: []const u8,
    kind: PermissionKind,
};

pub const RequestPermission = struct {
    sessionId: []const u8,
    toolCall: ToolCall,
    options: []const PermissionOption,
};

/// The answer to `session/request_permission`: the option picked, or null when
/// the client says the turn was cancelled first.
pub fn chosenOption(value: ?std.json.Value) ?[]const u8 {
    const outcome = field(field(value, "outcome"), "outcome") orelse return null;
    if (outcome != .string or !std.mem.eql(u8, outcome.string, "selected")) return null;
    const chosen = field(field(value, "outcome"), "optionId") orelse return null;
    return if (chosen == .string) chosen.string else null;
}

/// `elicitation/create` for a form, put to the person on behalf of a call.
/// `Fields` is the form's properties, one field each.
pub fn FormElicitation(comptime Fields: type) type {
    return struct {
        sessionId: []const u8,
        toolCallId: ?[]const u8 = null,
        mode: []const u8 = "form",
        message: []const u8,
        requestedSchema: struct {
            type: []const u8 = "object",
            properties: Fields,
            required: []const []const u8 = &.{},
        },
    };
}

/// The answer to `elicitation/create`: `accept` with what was filled in, or
/// `decline` or `cancel`.
pub fn Elicited(comptime Filled: type) type {
    return struct {
        action: []const u8,
        content: ?Filled = null,
    };
}

pub const StringProperty = struct {
    type: []const u8 = "string",
    title: ?[]const u8 = null,
    /// The values to pick from, when it is a choice.
    oneOf: ?[]const EnumOption = null,
};

pub const EnumOption = struct {
    @"const": []const u8,
    title: []const u8,
};

pub const CancelRequest = struct {
    requestId: std.json.Value,
};

pub const ToolKind = enum { read, edit, delete, move, search, execute, think, fetch, switch_mode, other };
pub const ToolStatus = enum { pending, in_progress, completed, failed };

pub const ToolCall = struct {
    toolCallId: []const u8,
    title: ?[]const u8 = null,
    kind: ?ToolKind = null,
    status: ?ToolStatus = null,
    content: ?[]const ToolContent = null,
    locations: ?[]const Location = null,
    rawInput: ?std.json.Value = null,
};

/// A call's content: text, or a terminal the client keeps (`type`
/// "terminal").
pub const ToolContent = struct {
    type: []const u8 = "content",
    content: ?Text = null,
    terminalId: ?[]const u8 = null,
};

pub const Location = struct {
    path: []const u8,
};

pub const Text = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const Chunk = struct {
    content: Text,
    messageId: ?[]const u8 = null,
};

pub const PlanEntry = struct {
    content: []const u8,
    priority: []const u8 = "medium",
    status: []const u8,
};

/// One `session/update`, flattened under its `sessionUpdate` tag as the
/// protocol has it.
pub const Update = union(enum) {
    user_message_chunk: Chunk,
    agent_message_chunk: Chunk,
    agent_thought_chunk: Chunk,
    tool_call: ToolCall,
    tool_call_update: ToolCall,
    plan: struct { entries: []const PlanEntry },
    current_mode_update: struct { currentModeId: []const u8 },
    config_option_update: struct { configOptions: []const ConfigOption },
    session_info_update: struct { title: ?[]const u8 = null },
    usage_update: struct { used: u64, size: u64 },

    pub fn jsonStringify(self: Update, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("sessionUpdate");
        try jws.write(@tagName(self));
        switch (self) {
            inline else => |payload| inline for (std.meta.fields(@TypeOf(payload))) |member| {
                const value = @field(payload, member.name);
                if (@typeInfo(member.type) != .optional or value != null) {
                    try jws.objectField(member.name);
                    try jws.write(value);
                }
            },
        }
        try jws.endObject();
    }
};

pub const Notification = struct {
    sessionId: []const u8,
    update: Update,
};

/// A prompt content block, as much of it as synth takes in or sends.
pub const Content = union(enum) {
    text: []const u8,
    /// Base64 PNG data.
    image: []const u8,
    /// A file the client attached, by path, with its text.
    resource: struct { path: []const u8, text: []const u8 },
    /// A file or other resource the client only named.
    link: []const u8,
    /// Anything else, which is skipped.
    other,

    pub fn jsonStringify(self: Content, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("type");
        switch (self) {
            .text => |text| {
                try jws.write("text");
                try jws.objectField("text");
                try jws.write(text);
            },
            .image => |data| {
                try jws.write("image");
                try jws.objectField("mimeType");
                try jws.write("image/png");
                try jws.objectField("data");
                try jws.write(data);
            },
            .resource => |resource| {
                try jws.write("resource");
                try jws.objectField("resource");
                try jws.write(.{ .uri = resource.path, .text = resource.text });
            },
            .link => |uri| {
                try jws.write("resource_link");
                try jws.objectField("uri");
                try jws.write(uri);
                try jws.objectField("name");
                try jws.write(std.fs.path.basename(uri));
            },
            .other => return error.WriteFailed,
        }
        try jws.endObject();
    }

    pub fn of(block: std.json.Value) Content {
        const kind = field(block, "type") orelse return .other;
        if (kind != .string) return .other;
        if (std.mem.eql(u8, kind.string, "text")) return .{ .text = string(field(block, "text")) orelse return .other };
        if (std.mem.eql(u8, kind.string, "image")) return .{ .image = string(field(block, "data")) orelse return .other };
        if (std.mem.eql(u8, kind.string, "resource")) {
            const resource = field(block, "resource");
            const uri = string(field(resource, "uri")) orelse return .other;
            const text = string(field(resource, "text")) orelse return .other;
            return .{ .resource = .{ .path = pathOf(uri), .text = text } };
        }
        if (std.mem.eql(u8, kind.string, "resource_link")) return .{ .link = string(field(block, "uri")) orelse return .other };
        return .other;
    }
};

/// `file:///a/b` as `/a/b`; anything else as it is.
pub fn pathOf(uri: []const u8) []const u8 {
    const scheme = "file://";
    return if (std.mem.startsWith(u8, uri, scheme)) uri[scheme.len..] else uri;
}

/// The local path a `file:` URI names, percent-escapes decoded. Null for any
/// other scheme, or a file on another host.
pub fn filePath(arena: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const parsed = std.Uri.parse(uri) catch return null;
    if (!std.mem.eql(u8, parsed.scheme, "file")) return null;
    if (parsed.host) |host| {
        const name = try host.toRawMaybeAlloc(arena);
        if (name.len > 0 and !std.mem.eql(u8, name, "localhost")) return null;
    }
    return try parsed.path.toRawMaybeAlloc(arena);
}

fn field(value: ?std.json.Value, name: []const u8) ?std.json.Value {
    const object = switch (value orelse return null) {
        .object => |object| object,
        else => return null,
    };
    return object.get(name);
}

fn string(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

test "a file link names a local path, escapes decoded; other links name none" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("/src/my file.zig", (try filePath(arena, "file:///src/my%20file.zig")).?);
    try testing.expectEqualStrings("/src/a.zig", (try filePath(arena, "file://localhost/src/a.zig")).?);
    try testing.expectEqual(null, try filePath(arena, "file://elsewhere/src/a.zig"));
    try testing.expectEqual(null, try filePath(arena, "https://example.com/a.zig"));

    const block = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"type":"resource_link","name":"a.zig","uri":"file:///src/a.zig"}
    , .{});
    try testing.expectEqualStrings("file:///src/a.zig", Content.of(block).link);
}

test "an update flattens under its tag" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(Notification{
        .sessionId = "ses_a",
        .update = .{ .tool_call_update = .{ .toolCallId = "7.0", .status = .completed } },
    }, .{ .emit_null_optional_fields = false }, &out.writer);
    try testing.expectEqualStrings(
        \\{"sessionId":"ses_a","update":{"sessionUpdate":"tool_call_update","toolCallId":"7.0","status":"completed"}}
    , out.written());
}

test "prompt blocks are read for what synth takes, and the rest skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = try std.json.parseFromSliceLeaky([]const std.json.Value, arena,
        \\[{"type":"text","text":"look"},{"type":"image","mimeType":"image/png","data":"aGk="},
        \\ {"type":"resource","resource":{"uri":"file:///src/a.zig","text":"const a = 1;"}},
        \\ {"type":"audio","data":"x"}]
    , .{});
    try testing.expectEqualStrings("look", Content.of(blocks[0]).text);
    try testing.expectEqualStrings("aGk=", Content.of(blocks[1]).image);
    try testing.expectEqualStrings("/src/a.zig", Content.of(blocks[2]).resource.path);
    try testing.expect(Content.of(blocks[3]) == .other);
}

test "a block sent is read back as the same block" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sent = [_]Content{ .{ .text = "look" }, .{ .image = "aGk=" }, .{ .resource = .{ .path = "pasted", .text = "a paste" } } };
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(sent, .{}, &out.writer);
    const blocks = try std.json.parseFromSliceLeaky([]const std.json.Value, arena, out.written(), .{});
    try testing.expectEqualStrings("look", Content.of(blocks[0]).text);
    try testing.expectEqualStrings("aGk=", Content.of(blocks[1]).image);
    try testing.expectEqualStrings("pasted", Content.of(blocks[2]).resource.path);
    try testing.expectEqualStrings("a paste", Content.of(blocks[2]).resource.text);
}

test "a permission answer names its option, and a cancelled one none" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const picked = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"always\"}}", .{});
    try testing.expectEqualStrings("always", chosenOption(picked).?);
    const cancelled = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"outcome\":{\"outcome\":\"cancelled\"}}", .{});
    try testing.expectEqual(null, chosenOption(cancelled));
}
