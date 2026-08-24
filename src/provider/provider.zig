const std = @import("std");

const Conversation = @import("../core/conversation.zig");

/// The seam every model backend plugs into.
const Provider = @This();

userdata: *anyopaque,
respond: *const fn (*anyopaque, *Conversation, Turn, std.mem.Allocator, ?Sink) anyerror!Reply,
name: []const u8,
/// The model tag this provider is talking to, e.g. `qwen3`. Distinct from
/// `name`, which is the backend ("Ollama"). Shown together as
/// "model · backend".
model: []const u8 = "",
/// Context window in tokens, or 0 when unknown.
context_limit: u32 = 0,
/// Whether the model can be shown images. False means an attached image is
/// dropped from the request, which the composer says up front rather than
/// letting it be sent into a void.
vision: bool = true,

/// Models this backend can be pointed at. Null when it has only one, which is
/// why the UI asks rather than assuming - a hosted backend may not offer a
/// choice at all. Caller owns the result and each name.
list_models: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![][]const u8 = null,
/// Switch models mid-session, returning what the caller should now display.
/// Null alongside `list_models`.
set_model: ?*const fn (*anyopaque, []const u8) anyerror!Current = null,
/// What the backend is pointed at now. Called after a turn lands: the window a
/// model is *loaded* with is not knowable until it is running.
refresh: ?*const fn (*anyopaque) Current = null,
/// Point the backend at another endpoint, with another credential, and say
/// what it is running as afterwards. Null for a backend with nothing to
/// connect to - a local process, a fake in a test.
reconnect: ?*const fn (*anyopaque, Connection) anyerror!Current = null,
/// Turn an error from `respond` into something a person can act on. Optional;
/// without it the caller has only the error name.
describe_error: ?*const fn (*anyopaque, anyerror, std.mem.Allocator) anyerror![]const u8 = null,

/// Everything one call needs that is not the transcript. Assembled by the
/// caller: which agent is in force, what it may call and what it was told are
/// decisions a backend has no business making, and a backend that assembled its
/// own prompt would have to be told about agents to do it.
pub const Turn = struct {
    /// The system prompt, complete. Borrowed for the length of the call.
    system: []const u8,
    /// Tool definitions as JSON, from `Registry.schemaJson`. Empty means the
    /// model is told about no tools at all.
    tools_json: []const u8 = "",
    /// A one-off instruction, sent as the last user message and not part of the
    /// transcript. Compaction is what this is for.
    instruction: []const u8 = "",
};

/// Where a backend should point, and what to call it there. The label is the
/// provider's, not the backend's: one ollama client serves both the server on
/// this machine and the hosted one, and the sidebar has to say which.
pub const Connection = struct {
    label: []const u8,
    host: []const u8,
    api_key: ?[]const u8 = null,
};

/// What a backend is pointed at right now. `model` and `name` are owned by the
/// provider and stay valid until the next switch.
pub const Current = struct {
    model: []const u8,
    /// What the backend is called now, e.g. "Ollama Cloud".
    name: []const u8 = "",
    context_limit: u32 = 0,
    vision: bool = true,
};

/// Whether this backend can be pointed somewhere else at runtime.
pub fn connectable(self: Provider) bool {
    return self.reconnect != null;
}

/// Re-read what the backend is pointed at, for a caller holding a copy of this
/// struct that may have gone stale. Cheap: no I/O, only what the backend has
/// already learned.
pub fn current(self: Provider) Current {
    const refresh = self.refresh orelse return .{
        .model = self.model,
        .name = self.name,
        .context_limit = self.context_limit,
        .vision = self.vision,
    };
    return refresh(self.userdata);
}

/// What went wrong, in the backend's own words where it has any. Caller owns
/// the result.
pub fn explain(self: Provider, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    const describe = self.describe_error orelse
        return std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    return describe(self.userdata, err, allocator) catch
        std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
}

/// Whether this backend offers a choice of model.
pub fn switchable(self: Provider) bool {
    return self.list_models != null and self.set_model != null;
}

/// The models on offer, newest first. Empty when the backend has no choice.
pub fn models(self: Provider, allocator: std.mem.Allocator) ![][]const u8 {
    const list = self.list_models orelse return allocator.alloc([]const u8, 0);
    return list(self.userdata, allocator);
}

/// What a turn cost. Zero when the provider does not report it.
pub const Usage = struct {
    /// Tokens in the request. Doubles as "how full is the context", since the
    /// whole conversation is resent each turn.
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    /// Time spent generating, for a tokens-per-second figure.
    eval_duration_ns: u64 = 0,
};

/// One turn from the model: prose, tool calls, or both.
pub const Reply = struct {
    /// Allocated with the respond allocator; owned by the caller.
    text: []const u8 = "",
    /// Tool calls the model wants run. Owned by the caller, which frees each
    /// call with `Conversation.ToolCall.deinit`.
    tool_calls: []Conversation.ToolCall = &.{},
    usage: Usage = .{},

    pub fn deinit(self: *Reply, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.tool_calls) |*call| call.deinit(allocator);
        allocator.free(self.tool_calls);
    }
};

/// Where a provider pushes partial output as it arrives. Every callback runs on
/// the worker thread, so implementations must be thread safe.
pub const Sink = struct {
    userdata: *anyopaque,
    /// A fragment of the model's thinking output.
    onThinking: *const fn (*anyopaque, []const u8) void,
    /// A fragment of the model's answer. Without this the reply only appears
    /// once the whole turn lands, which reads as a hang on a long answer.
    onText: *const fn (*anyopaque, []const u8) void,
    /// The model has stopped reasoning and started answering. What follows can
    /// take far longer than the thinking did - a tool call whose arguments are
    /// a whole file, say - so a UI timing the thought needs to be told where it
    /// ended. Defaulted: a provider that cannot tell simply never calls it.
    onThinkingDone: *const fn (*anyopaque) void = ignoreThinkingDone,
    /// Whether the caller has given up on this turn. A worker thread cannot be
    /// killed, so a provider that streams must check between chunks and return
    /// early - otherwise quitting mid-turn blocks until the model is done.
    stopped: *const fn (*anyopaque) bool,
};

fn ignoreThinkingDone(_: *anyopaque) void {}
