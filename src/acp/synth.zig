//! synth's own extension to ACP, for a client that draws a session the way the
//! TUI does: whole messages as the agent holds them, a status with everything
//! the sidebar shows, and requests for what ACP has no method for. Every
//! method is `_synth/...`, which ACP sets aside for extensions, and a client
//! that never asked for them is never sent them.
//!
//! The enums borrowed from the agent - roles, states, statuses - travel by tag
//! name, so renaming or adding a tag in one of those is a breaking change.

const std = @import("std");
const testing = std.testing;

const Conversation = @import("../core/conversation.zig");
const mention = @import("../core/mention.zig");
const todo = @import("../core/todo.zig");
const mcp_tools = @import("../tools/mcp.zig");
const Loop = @import("../agent/loop.zig");

/// Bumped only on a breaking change to this extension.
pub const version: u32 = 1;

/// What a client puts under `_meta.synth` on `initialize` to be sent this
/// extension, and what the agent answers with.
pub const Hello = struct {
    protocol: u32,
};

pub const method = struct {
    /// Agent to client: everything about the session, after it is set up.
    pub const snapshot = "_synth/snapshot";
    pub const appended = "_synth/appended";
    /// A message already sent has changed: a call settled, a preview shrank.
    pub const updated = "_synth/updated";
    pub const stream = "_synth/stream";
    pub const status = "_synth/status";
    /// Something to tell the person: a hook refused a prompt, a command failed.
    pub const notice = "_synth/notice";

    /// Client to agent.
    pub const compact = "_synth/compact";
    pub const rename = "_synth/rename";
    pub const providers = "_synth/providers";
    pub const connect_provider = "_synth/connect_provider";
    pub const cancel_sign_in = "_synth/cancel_sign_in";
    pub const sign_out = "_synth/sign_out";
    pub const toggle_mcp = "_synth/toggle_mcp";
    pub const files = "_synth/files";
    pub const models = "_synth/models";
    pub const load_tool_result = "_synth/load_tool_result";
    pub const load_attachment = "_synth/load_attachment";
    pub const load_thinking = "_synth/load_thinking";
    pub const subagent = "_synth/subagent";
    pub const page_history = "_synth/page_history";
    pub const search = "_synth/search";
    /// Keep the session running once every client has gone, to be attached
    /// to again over its socket.
    pub const detach = "_synth/detach";
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    status: Conversation.ToolCall.Status,
    /// The preview the agent holds; `load_tool_result` fetches the rest.
    result: ?[]const u8 = null,
    result_bytes: u64 = 0,
    elapsed_ms: ?u64 = null,
};

pub const Attachment = struct {
    path: []const u8,
    content: []const u8,
    content_bytes: u64 = 0,
};

/// A transcript message as the agent holds it in memory: heavy bodies are
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
    /// The directory the session runs in, on the agent's machine.
    root: []const u8 = "",
    /// The repository holding it, and its checked-out branch.
    project: []const u8 = "",
    branch: []const u8 = "",
    agent: []const u8 = "",
    model: []const u8 = "",
    provider: []const u8 = "",
    /// The provider's catalog id.
    provider_id: []const u8 = "",
    /// Nothing usable answers the session: a turn asks for a provider first.
    provider_missing: bool = false,
    /// A ChatGPT sign-in this session started, waiting on a browser.
    sign_in: ?SignIn = null,
    /// The agent holds a ChatGPT sign-in, which `/logout` would end.
    chatgpt_signed_in: bool = false,
    context_limit: u32 = 0,
    /// Whether the model can be shown images.
    vision: bool = true,
    /// Whether the provider offers other models to switch to.
    switchable: bool = false,
    /// The reasoning effort in force, and the levels the model offers.
    effort: []const u8 = "",
    efforts: []const []const u8 = &.{},
    usage: Loop.Usage = .{},
    todos: []const todo.Item = &.{},
    /// Every configured MCP server, and where it stands.
    mcp: []const mcp_tools.Status = &.{},
    /// The message whose tool calls are being decided or run, and the call
    /// waiting on a decision, if one is.
    pending_seq: ?u64 = null,
    pending_call: ?u32 = null,
    /// What the tool waiting on a decision does, for the person deciding.
    pending_description: []const u8 = "",
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

pub const SignIn = struct {
    url: []const u8,
    /// Where the browser is sent back to, on the agent's machine.
    port: u16,
};

/// A provider in the catalog, as the agent has it.
pub const ProviderState = struct {
    id: []const u8,
    host: []const u8,
    /// It has what it needs: a key, or a sign-in.
    connected: bool = false,
    /// The one the session answers through.
    active: bool = false,
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

/// A skill the agent offers. Its instructions stay there: a prompt of
/// `/id args` runs it.
pub const Skill = struct {
    id: []const u8,
    name: []const u8 = "",
    description: []const u8 = "",
    dir: []const u8 = "",
};

pub const Skills = struct {
    found: []const Skill = &.{},
    /// Every directory the agent looked in.
    looked_in: []const []const u8 = &.{},
};

pub const Snapshot = struct {
    sessionId: []const u8,
    status: Status,
    /// The tail of the transcript, oldest first.
    messages: []const Message,
    /// Messages before the first one here, still in the database.
    dropped: u64 = 0,
    stream: ?Stream = null,
    skills: Skills = .{},
};

/// What `session/list` adds about a stored session.
pub const Stored = struct {
    messages: u64 = 0,
    /// Milliseconds since the epoch.
    updated_at: i64 = 0,
    /// Hosted by a process right now, so it is attached to rather than
    /// loaded.
    live: bool = false,
};

/// What a subagent said: its transcript, oldest first.
pub const Transcript = struct {
    /// Still running, so this is how far it has got.
    live: bool = false,
    messages: []const Message = &.{},
};

/// A model the agent's provider offers.
pub const Offered = struct {
    name: []const u8,
    /// The provider offering it, and its catalog id.
    provider: []const u8 = "",
    provider_id: []const u8 = "",
    /// Reasoning effort levels, mildest first; empty when there is no choice.
    efforts: []const []const u8 = &.{},
    /// The level it runs at if chosen: the last one chosen, or its default.
    effort: []const u8 = "",
};

pub const Models = struct {
    offered: []const Offered = &.{},
    /// Models this project has used, most recently first.
    recent: []const []const u8 = &.{},
};

/// A message matching a search, in the session's project.
pub const Hit = struct {
    handle: []const u8,
    title: []const u8 = "",
    role: []const u8,
    excerpt: []const u8,
};

/// What `session/set_config_option` for the model may say besides the model:
/// the effort to run it at, and the provider offering it when that is not
/// the one in use.
pub const SetModel = struct {
    effort: ?[]const u8 = null,
    provider: ?[]const u8 = null,
};

/// Notification params, each naming its session as ACP's do.
pub const Appended = struct { sessionId: []const u8, message: Message };
pub const StreamUpdate = struct { sessionId: []const u8, stream: Stream };
pub const StatusUpdate = struct { sessionId: []const u8, status: Status };
pub const Notice = struct { sessionId: []const u8, text: []const u8 };

/// Request params.
pub const Rename = struct { sessionId: []const u8, title: []const u8 };
pub const ConnectProvider = struct {
    sessionId: []const u8,
    provider: []const u8,
    host: []const u8,
    key: ?[]const u8 = null,
};
pub const ToggleMcp = struct { sessionId: []const u8, name: []const u8 };
pub const ListModels = struct { sessionId: []const u8, recent: u32 = 5 };
pub const LoadToolResult = struct { sessionId: []const u8, seq: u64, call: u32 };
pub const LoadAttachment = struct { sessionId: []const u8, seq: u64, index: u32 };
pub const LoadThinking = struct { sessionId: []const u8, seq: u64 };
pub const Subagent = struct { sessionId: []const u8, seq: u64, call: u32 };
pub const PageHistory = struct { sessionId: []const u8, before_seq: u64, limit: u32 = 50 };
pub const Search = struct { sessionId: []const u8, query: []const u8, limit: u32 = 20 };

test "a message survives the wire and comes back owned" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();
    var calls = [_]Conversation.ToolCall{.{ .id = "c0", .name = "read", .arguments = "{}", .status = .ok, .result = "body", .result_bytes = 9000 }};
    var attachments = [_]mention.Attachment{.{ .path = "a.zig", .content = "const a = 1;" }};
    const original = try convo.append(.{ .role = .assistant, .text = "done", .thinking = "why", .tool_calls = &calls, .attachments = &attachments });

    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(try Message.from(arena, original), .{ .emit_null_optional_fields = false }, &out.writer);
    const parsed = try std.json.parseFromSliceLeaky(Message, arena, out.written(), .{});
    var owned = try parsed.toOwned(testing.allocator);
    defer owned.deinit(testing.allocator);

    try testing.expectEqual(original.seq, owned.seq);
    try testing.expectEqualStrings("why", owned.thinking.?);
    try testing.expectEqualStrings("body", owned.tool_calls[0].result.?);
    try testing.expectEqual(@as(u64, 9000), owned.tool_calls[0].result_bytes);
    try testing.expectEqualStrings("const a = 1;", owned.attachments[0].content);
}
