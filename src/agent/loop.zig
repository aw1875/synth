//! The agent loop: ask the model, run the tools it asks for, feed the results
//! back, repeat until it answers in prose.

const std = @import("std");
const testing = std.testing;

const Database = @import("../core/database.zig");
const Provider = @import("../provider/provider.zig");
const ask_user = @import("../tools/ask.zig");
const Registry = @import("../tools/registry.zig");
const agents = @import("agent.zig");
const Context = @import("context.zig");
const base_prompt = @import("prompt.zig");
const Project = @import("../core/project.zig");
const skill = @import("../core/skill.zig");
const tool = @import("../tools/tool.zig");
const Conversation = @import("../core/conversation.zig");
const mention = @import("../core/mention.zig");
const Request = @import("request.zig");
const safety = @import("safety.zig");
const Thought = @import("thought.zig");
const ToolRun = @import("tool_run.zig");

const Loop = @This();

/// How many times the same tool call may repeat before the turn is stopped.
/// Two is a model correcting itself; three is a model stuck.
pub const max_repeats: usize = 3;

/// Stands in for an assistant turn that said nothing at all, so the transcript
/// shows a turn happened. Named because a caller reading the transcript back -
/// a subagent handing up its answer - has to tell it from something the model
/// meant to say.
pub const no_reply = "(no reply)";

/// Messages whose pasted images stay in memory. Older ones keep their token in
/// the text but stop being resent; the bodies remain in the blob table.
const max_resident_images: usize = 2;
/// How much attachment text is held in full across the whole transcript. Past
/// this the oldest are cut back to a preview, which is recoverable from the
/// `attachment` table. Generous enough for a handful of skills and mentioned
/// files, small enough that a session full of them cannot grow without bound.
const max_resident_attachment_bytes: usize = 256 * 1024;

/// Cap on tool output fed back to the model. The whole conversation is resent
/// every turn, so an unbounded `read` of a large file does not just cost once -
/// it inflates every request that follows, until the context fills and the
/// model slows to a crawl. The full output is still shown in the transcript.
pub const max_tool_result_bytes: usize = 8 * 1024;

pub const State = enum {
    idle,
    /// Waiting on the model.
    thinking,
    /// Waiting on the user to approve tool calls.
    awaiting_approval,
    /// Waiting on the user to answer a question the model asked.
    awaiting_answer,
    /// Running approved tools.
    running_tools,
    /// Asking the model to summarise the transcript so far.
    compacting,
    /// The user gave up, and the worker has been asked to stop but has not
    /// unwound yet. Still busy: the worker holds the conversation, so nothing
    /// may be submitted or edited until it lets go.
    cancelling,

    /// A human-readable label for the state, for the UI to render.
    pub fn label(self: State) []const u8 {
        return switch (self) {
            .idle => "",
            .thinking => "Thinking",
            .awaiting_approval => "Awaiting approval",
            .awaiting_answer => "Waiting for your answer",
            .running_tools => "Running tools",
            .compacting => "Compacting",
            .cancelling => "Cancelling",
        };
    }
};

/// A remembered "allow always", scoped to the project and to what the call was
/// doing: `bash` approved for `find *` does not approve `rm`. Every other tool
/// stores `*`.
const Allowance = struct {
    tool: []const u8,
    pattern: []const u8,
};

allocator: std.mem.Allocator,
io: std.Io,
provider: Provider,
registry: *const Registry,
conversation: *Conversation,
reads: *tool.ReadLog,
/// Root every tool resolves against. Borrowed.
project_root: []const u8,

/// Persistence, when attached. Null in tests and in `synth run`, which are
/// deliberately stateless. All database calls stay on this (the UI) thread.
db: ?*Database = null,
project_id: ?i64 = null,
/// The session's name, owned. Null until one is given.
session_title: ?[]const u8 = null,
session_id: ?i64 = null,
/// The cwd and model for the session row, held until the session is actually
/// created on the first message. A session is not created just for opening the
/// app.
session_cwd: []const u8 = "",
/// Model the session runs under, recorded on its row. Borrowed from the config
/// until a switch, which is when `session_model_owned` takes over: the
/// provider frees its own copy on the *next* switch, so keeping that slice
/// would leave this dangling.
session_model: []const u8 = "",
session_model_owned: ?[]u8 = null,
/// Database message id for each conversation message, keyed by the message's
/// stable `seq`. Keyed by seq rather than index so trimming older messages from
/// memory does not shift the mapping.
message_ids: std.AutoHashMapUnmanaged(u64, i64) = .empty,

state: State = .idle,
request: ?*Request = null,
tools: ?*ToolRun = null,
/// How many of the running batch's results have been copied into the
/// conversation. Advances while the batch runs, so cards settle one at a time.
tools_adopted: usize = 0,
/// When the user gave up, on the monotonic clock, and whether the workers have
/// been signalled since.
cancel_at_ms: ?i64 = null,
signalled: bool = false,
steps: usize = 0,
/// `seq` of the assistant message whose tool calls are being decided. A seq
/// rather than an index: trimming the transcript shifts indices down and paging
/// history back in shifts them up, either of which would leave a decision
/// pointing at the wrong message.
pending_seq: ?u64 = null,
/// Which pending call the approval prompt is on.
pending_index: usize = 0,
/// Tools the user chose to always allow.
allowed: std.ArrayList(Allowance) = .empty,
/// Whether the preset list of read-only shell commands runs without asking.
/// Off makes every `bash` call a question, however harmless.
auto_approve_safe: bool = true,

/// How a tool call starts a subagent. Installed by whoever assembled the loop,
/// because the implementation needs a loop and the loop must not need it.
delegate: ?tool.Delegate = null,
/// What the model may do this turn. The tool schema sent with every request is
/// this agent's list, and the gate refuses anything outside it.
agent: agents.Agent = agents.all[0],
/// The last batch of tool calls, as tool name and arguments run together, and
/// how many times running it has come back identical. A step ceiling catches a
/// model looping at step two hundred; this catches it at step three.
last_calls: ?[]u8 = null,
repeats: usize = 0,
/// The agent's tool schema, owned and sent with every call.
tools_json: ?[]u8 = null,
/// Base instructions, before the agent's and the project's are appended.
system_prompt: []const u8 = base_prompt.default,
/// Where the app is running, for the environment block. Borrowed.
project: ?*const Project = null,
/// The skills this project offers, for the `<skills>` block. Borrowed, and
/// empty where nothing discovered any.
skills: []const skill.Skill = &.{},
/// The assembled system prompt, shared by the steps of one turn.
prompt_cache: Context.Cache = .{},
/// Set when a turn ends in failure, for the UI to surface.
last_error: ?anyerror = null,
/// Running totals for the session, for the sidebar.
usage: Usage = .{},
/// Fraction of the model's context window past which a finished turn triggers
/// compaction on its own. Zero disables it.
auto_compact_at: f64 = 0.85,
/// Set while the outstanding request is a summarisation rather than a turn.
compacting: bool = false,

pub const Usage = struct {
    /// Prompt size of the most recent call. The whole conversation is resent
    /// every turn, so this is how full the context currently is.
    context_tokens: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    eval_duration_ns: u64 = 0,
    /// Model calls, which exceeds user turns whenever tools are involved.
    calls: u32 = 0,

    /// Generation speed across the session, or null before anything ran.
    pub fn tokensPerSecond(self: Usage) ?f64 {
        if (self.eval_duration_ns == 0 or self.output_tokens == 0) return null;
        const seconds = @as(f64, @floatFromInt(self.eval_duration_ns)) / std.time.ns_per_s;
        if (seconds <= 0) return null;
        return @as(f64, @floatFromInt(self.output_tokens)) / seconds;
    }

    /// Fraction of the context window in use, or null when the limit is
    /// unknown.
    pub fn contextFraction(self: Usage, limit: u32) ?f64 {
        if (limit == 0 or self.context_tokens == 0) return null;
        return @as(f64, @floatFromInt(self.context_tokens)) / @as(f64, @floatFromInt(limit));
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    registry: *const Registry,
    conversation: *Conversation,
    reads: *tool.ReadLog,
    project_root: []const u8,
) Loop {
    return .{
        .allocator = allocator,
        .io = io,
        .provider = provider,
        .registry = registry,
        .conversation = conversation,
        .reads = reads,
        .project_root = project_root,
    };
}

/// Attach persistence. Resolves the project and seeds the "always allow" list
/// from remembered approvals. The session row itself is deferred until the
/// first message, so merely opening the app does not create an empty session.
/// Call once, before the first `submit`.
pub fn attachDatabase(
    self: *Loop,
    db: *Database,
    project_name: []const u8,
    cwd: []const u8,
    model: []const u8,
) !void {
    self.db = db;
    self.project_id = try db.resolveProject(self.project_root, "git", project_name);
    self.session_cwd = cwd;
    self.session_model = model;

    const remembered = try db.approvals(self.project_id.?, self.allocator);
    defer {
        for (remembered) |approval| approval.deinit(self.allocator);
        self.allocator.free(remembered);
    }
    for (remembered) |approval| try self.remember(approval.tool, approval.pattern);
}

/// Rename the current session. The row is created first if the session has not
/// written anything yet, so a name given before the first prompt still sticks.
pub fn rename(self: *Loop, name: []const u8) !void {
    const db = self.db orelse return;
    const session_id = try self.ensureSession();
    try db.setSessionTitle(session_id, name);

    if (self.session_title) |old| self.allocator.free(old);
    self.session_title = if (name.len > 0) try self.allocator.dupe(u8, name) else null;
}

/// Record a model switch against the session.
pub fn setModel(self: *Loop, model: []const u8) !void {
    const owned = try self.allocator.dupe(u8, model);
    if (self.session_model_owned) |previous| self.allocator.free(previous);
    self.session_model_owned = owned;
    self.session_model = owned;

    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    try db.setSessionModel(session_id, owned);
}

/// What this session is called, or "" when it is untitled.
pub fn title(self: *const Loop) []const u8 {
    return self.session_title orelse "";
}

/// Adopt an existing session: its id, its name, and the tail of its transcript.
/// `limit` messages are loaded; anything older stays in the database and pages
/// in when the transcript is scrolled to the top.
pub fn resumeSession(self: *Loop, session_id: i64, limit: usize) !void {
    const db = self.db orelse return error.NoDatabase;

    const total = try db.countMessages(session_id);
    const loaded = try db.loadMessages(self.allocator, session_id, std.math.maxInt(i64), limit);
    defer self.allocator.free(loaded);

    std.mem.reverse(Conversation.Message, loaded);
    try self.conversation.adopt(loaded, total - @min(total, loaded.len));

    self.session_id = session_id;
    if (self.session_title) |old| self.allocator.free(old);
    self.session_title = null;
    const name = try db.sessionTitle(session_id, self.allocator);
    if (name.len > 0) self.session_title = name else self.allocator.free(name);

    try self.restoreModel(session_id);
    try self.restoreAgent(session_id);
}

/// Point the provider back at the model the session was last run under.
fn restoreModel(self: *Loop, session_id: i64) !void {
    const db = self.db orelse return;
    const set = self.provider.set_model orelse return;

    const stored = try db.sessionModel(session_id, self.allocator);
    defer self.allocator.free(stored);
    if (stored.len == 0) return;
    if (std.mem.eql(u8, stored, self.provider.model)) return;

    const now = set(self.provider.userdata, stored) catch return;
    self.provider.model = now.model;
    if (now.name.len > 0) self.provider.name = now.name;
    self.provider.context_limit = now.context_limit;
    self.provider.vision = now.vision;
    try self.setModel(now.model);
}

/// Switch agents: rebuild the tool schema, hand it to the provider with the
/// agent's instructions, and remember it on the session.
pub fn useAgent(self: *Loop, id: []const u8) !void {
    const chosen = agents.findOrDefault(id);
    const json = try self.registry.schemaJson(self.allocator, chosen.tools);
    errdefer self.allocator.free(json);

    if (self.tools_json) |old| self.allocator.free(old);
    self.tools_json = json;
    self.agent = chosen;

    self.prompt_cache.invalidate(self.allocator);

    if (self.db) |db| {
        if (self.session_id) |session_id| try db.setSessionAgent(session_id, chosen.id);
    }
}

/// Everything one call needs besides the transcript. Assembling it here rather
/// than in the backend is what keeps a provider from having to know what an
/// agent is.
fn turn(self: *Loop, instruction: []const u8) Provider.Turn {
    return .{
        .system = self.systemPrompt(),
        .tools_json = self.tools_json orelse "",
        .instruction = instruction,
    };
}

/// The base instructions, the agent's, and the project's, assembled once per
/// turn and reused across its tool steps.
fn systemPrompt(self: *Loop) []const u8 {
    const project = self.project orelse return self.system_prompt;
    return self.prompt_cache.get(
        self.allocator,
        self.io,
        self.system_prompt,
        self.agent.prompt,
        project,
        self.skills,
    ) catch self.system_prompt;
}

/// The agent after the current one, applied. What one key cycles through.
pub fn cycleAgent(self: *Loop) !void {
    try self.useAgent(agents.next(self.agent.id).id);
}

/// Point the loop back at the agent the session was last run under.
fn restoreAgent(self: *Loop, session_id: i64) !void {
    const db = self.db orelse return;
    const stored = try db.sessionAgent(session_id, self.allocator);
    defer self.allocator.free(stored);
    if (stored.len == 0) return;
    try self.useAgent(stored);
}

/// The database this loop persists to, for the UI's session picker.
pub fn database(self: *Loop) ?*Database {
    return self.db;
}

/// The handle this session is resumed by, or "" when there is no database.
/// Caller owns the result.
pub fn sessionHandle(self: *Loop, allocator: std.mem.Allocator) ![]const u8 {
    const db = self.db orelse return allocator.dupe(u8, "");
    const session_id = self.session_id orelse return allocator.dupe(u8, "");
    return db.sessionPublicId(session_id, allocator);
}

/// Create the session row if it does not exist yet. Called lazily on the first
/// message so an empty launch leaves no session behind.
fn ensureSession(self: *Loop) !i64 {
    if (self.session_id) |id| return id;
    const db = self.db orelse return error.NoDatabase;
    const project_id = self.project_id orelse return error.NoProject;
    const id = try db.createSession(project_id, self.session_cwd, self.session_model);
    self.session_id = id;
    return id;
}

/// Ask every live worker to give up. Non-blocking: the joins still happen in
/// `deinit`, but a provider that checks the flag cuts that wait from "however
/// long the model takes" to a chunk or two.
pub fn requestStop(self: *Loop) void {
    if (self.request) |request| request.requestStop();
    if (self.tools) |tools| tools.requestStop();
}

pub fn deinit(self: *Loop) void {
    if (self.session_title) |t| self.allocator.free(t);
    self.session_title = null;
    if (self.session_model_owned) |m| self.allocator.free(m);
    self.session_model_owned = null;
    if (self.request) |request| {
        request.cancel();
        request.destroy();
        self.request = null;
    }
    if (self.tools) |tools| {
        tools.cancel();
        tools.destroy();
        self.tools = null;
    }

    self.prompt_cache.deinit(self.allocator);
    if (self.last_calls) |calls| self.allocator.free(calls);
    if (self.tools_json) |json| self.allocator.free(json);
    for (self.allowed.items) |allowance| {
        self.allocator.free(allowance.tool);
        self.allocator.free(allowance.pattern);
    }
    self.allowed.deinit(self.allocator);
    self.message_ids.deinit(self.allocator);
}

pub fn isBusy(self: *const Loop) bool {
    return self.state != .idle;
}

/// Re-read the backend's current state into the copy of `Provider` held here.
/// Safe only between turns: the backend writes some of this from the worker
/// thread.
pub fn syncProvider(self: *Loop) void {
    const now = self.provider.current();
    self.provider.model = now.model;
    if (now.name.len > 0) self.provider.name = now.name;
    self.provider.context_limit = now.context_limit;
    self.provider.vision = now.vision;
}

/// What the loop is doing, for the UI's status row.
pub fn label(self: *Loop) []const u8 {
    if (self.state == .thinking) {
        if (self.request) |request| {
            if (request.thoughts.isClosed()) return "Responding";
        }
    }
    return self.state.label();
}

/// The thinking stream of the in-flight request, for the UI to render.
pub fn thoughts(self: *Loop) ?*Thought.Stream {
    const request = self.request orelse return null;
    return &request.thoughts;
}

/// The answer as it streams in, for the UI to render before the turn lands.
pub fn streamingText(self: *Loop) ?*Thought.Stream {
    const request = self.request orelse return null;
    return &request.content;
}

/// What the composer held back from the draft: pasted blocks and images, each
/// standing in the prompt as a token. Borrowed for the length of the call.
pub const Extras = struct {
    attachments: []const mention.Attachment = &.{},
    /// Base64-encoded image data.
    images: []const []const u8 = &.{},
};

/// What the model is asked for when compacting. The summary is fed back as the
/// only history, so it has to carry the parts a later turn would need.
const compaction_prompt =
    \\Summarise this conversation so far, for your own use as the only record of
    \\it. Keep: what the user is trying to do, decisions made and why, files and
    \\symbols touched, what worked, what failed, and anything still outstanding.
    \\Drop pleasantries and repeated tool output. Write it as notes, not prose,
    \\and do not address the user.
;

/// Ask the model to summarise the transcript. The summary lands as a system
/// message, which is where `buildMessages` starts from - everything before it
/// stays in the transcript and in the database, but stops being sent.
pub fn compact(self: *Loop) !void {
    if (self.isBusy()) return;
    if (self.conversation.messages.items.len == 0) return;

    self.compacting = true;
    self.request = try Request.start(
        self.allocator,
        self.io,
        self.provider,
        self.conversation,
        self.turn(compaction_prompt),
    );
    self.state = .compacting;
}

/// Whether the context is full enough that the next turn should be compacted
/// first. False when the provider does not report a window.
pub fn shouldCompact(self: *const Loop) bool {
    if (self.auto_compact_at <= 0) return false;
    const fraction = self.usage.contextFraction(self.provider.context_limit) orelse return false;
    return fraction >= self.auto_compact_at;
}

/// Turn a finished summarisation into the system message that replaces the
/// history it summarises.
fn finishCompaction(self: *Loop, summary: []const u8) !void {
    self.compacting = false;
    self.state = .idle;
    if (summary.len == 0) return;

    _ = try self.conversation.append(.{ .role = .system, .text = summary });
    try self.persistMessage(self.conversation.messages.items.len - 1);

    self.usage.context_tokens = 0;
}

/// Start a turn. Attachments come from `@path` mentions in the prompt, plus
/// whatever the composer held back.
pub fn submit(self: *Loop, prompt: []const u8, extras: Extras) !void {
    if (self.isBusy()) return;

    var mentioned: mention.Resolved =
        mention.resolve(self.allocator, self.io, self.project_root, prompt) catch .{};
    defer mentioned.deinit(self.allocator);

    const files = mentioned.attachments;
    const attachments = try self.allocator.alloc(mention.Attachment, files.len + extras.attachments.len);
    defer self.allocator.free(attachments);
    @memcpy(attachments[0..files.len], files);
    @memcpy(attachments[files.len..], extras.attachments);

    const images = try self.allocator.alloc([]const u8, mentioned.images.len + extras.images.len);
    defer self.allocator.free(images);
    @memcpy(images[0..mentioned.images.len], mentioned.images);
    @memcpy(images[mentioned.images.len..], extras.images);

    _ = try self.conversation.addUser(prompt, attachments, images);
    try self.persistMessage(self.conversation.messages.items.len - 1);
    self.steps = 0;
    self.repeats = 0;
    if (self.last_calls) |calls| self.allocator.free(calls);
    self.last_calls = null;
    self.last_error = null;
    try self.ask();
}

/// Page up to `limit` older messages in from the database, prepending them to
/// the conversation. Returns how many were loaded. No-op without a database or
/// when there is no older history.
pub fn pageHistory(self: *Loop, limit: usize) !usize {
    const db = self.db orelse return 0;
    const session_id = self.session_id orelse return 0;
    const before = self.conversation.firstSeq() orelse return 0;
    if (before == 0) return 0;

    const loaded = try db.loadMessages(self.allocator, session_id, @intCast(before), limit);
    if (loaded.len == 0) {
        self.allocator.free(loaded);
        return 0;
    }

    std.mem.reverse(Conversation.Message, loaded);
    try self.conversation.prepend(loaded);
    self.allocator.free(loaded);
    return loaded.len;
}

/// Load the full reasoning body for a message, replacing its in-memory preview.
/// No-op without a database, or when the message has no reasoning, or when the
/// preview already holds the full text.
pub fn loadThinking(self: *Loop, msg: *Conversation.Message) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    if (msg.thinking_bytes <= Conversation.preview_bytes) return;
    if (msg.thinking) |t| {
        if (t.len >= msg.thinking_bytes) return;
    }

    const full = try db.loadThinking(self.allocator, session_id, @intCast(msg.seq)) orelse return;
    if (msg.thinking) |t| self.allocator.free(t);
    msg.thinking = full;
}

/// Load an attachment in full, replacing its in-memory preview. No-op without a
/// database, or when the preview already holds the whole file.
pub fn loadAttachment(self: *Loop, msg: *Conversation.Message, index: usize) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    if (index >= msg.attachments.len) return;

    const attachment = &msg.attachments[index];
    if (!attachment.shortened()) return;

    const full = try db.loadAttachment(
        self.allocator,
        session_id,
        @intCast(msg.seq),
        @intCast(index),
    ) orelse return;

    self.allocator.free(attachment.content);
    attachment.content = full;
}

/// Load the full result body for a tool call, replacing its in-memory preview.
/// No-op without a database, or when the preview already holds the full text.
pub fn loadToolResult(self: *Loop, msg: *Conversation.Message, call_index: usize) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    if (call_index >= msg.tool_calls.len) return;
    const call = &msg.tool_calls[call_index];
    if (call.result_bytes <= Conversation.preview_bytes) return;
    if (call.result) |r| {
        if (r.len >= call.result_bytes) return;
    }

    const full = try db.loadToolResult(
        self.allocator,
        session_id,
        @intCast(msg.seq),
        @intCast(call_index),
    ) orelse return;
    if (call.result) |r| self.allocator.free(r);
    call.result = full;
}

fn ask(self: *Loop) !void {
    self.steps += 1;
    if (self.steps > self.agent.steps) {
        return self.stop("Stopped: too many tool calls in one turn.");
    }

    self.request = try Request.start(
        self.allocator,
        self.io,
        self.provider,
        self.conversation,
        self.turn(""),
    );
    self.state = .thinking;
}

/// Abandon the turn, discarding whatever the worker had produced.
pub fn cancel(self: *Loop) !void {
    if (!self.isBusy()) return;
    if (self.state == .cancelling) return;

    // Asking is all that happens here. Waiting for the worker to unwind is what
    // `Io.Future.cancel` does, and it does it on the calling thread - which is
    // the UI's, so a provider midway through generating would freeze the
    // terminal until it finished. The worker is reaped in `poll` instead.
    self.requestStop();

    self.cancel_at_ms = tool.monotonicMilliseconds(self.io);
    self.signalled = false;
    self.compacting = false;
    self.state = .cancelling;
}

/// How long a worker is given to stop because it was asked to, before it is
/// signalled instead.
///
/// Asking is cheap and lets a worker unwind tidily, but it only reaches one
/// that checks: a provider between chunks, a tool between waits. A worker
/// blocked in a read that never returns never gets the chance, and waiting for
/// it is what leaves a turn sitting on `Cancelling` for minutes.
const cancel_grace_ms: i64 = 250;

/// Reap a cancelled turn once its worker has actually stopped.
///
/// Nothing here touches the conversation until both workers are gone: the
/// provider borrows it, and a tool run writes into results the loop is about to
/// free.
fn pollCancelled(self: *Loop) !bool {
    if (self.request) |request| {
        if (!request.isFinished()) {
            self.signalStragglers();
            return false;
        }
        request.join();
        request.destroy();
        self.request = null;
    }

    if (self.tools) |tools| {
        if (!tools.isFinished()) {
            self.signalStragglers();
            return false;
        }
        tools.join();
        tools.destroy();
        self.tools = null;
    }

    try self.abandonPending();

    self.state = .idle;
    return true;
}

/// Mark every call the cancelled turn left unfinished, so the transcript says
/// what happened to it rather than leaving a row spinning forever.
/// Signal a worker that has not stopped on its own once the grace period is
/// up. Signalling interrupts a blocked syscall, which is the only thing that
/// reaches a worker stuck in a read.
fn signalStragglers(self: *Loop) void {
    if (self.signalled) return;

    const since = self.cancel_at_ms orelse return;
    if (tool.monotonicMilliseconds(self.io) - since < cancel_grace_ms) return;

    self.signalled = true;
    if (self.request) |request| request.cancel();
    if (self.tools) |tools| tools.cancel();
}

fn abandonPending(self: *Loop) !void {
    const index = self.pendingIndex() orelse return;
    for (self.conversation.messages.items[index].tool_calls, 0..) |*call, i| {
        if (call.status != .pending and call.status != .running) continue;
        call.status = .rejected;
        if (call.result == null) {
            call.result = try self.allocator.dupe(u8, "cancelled");
            call.result_bytes = "cancelled".len;
        }
        try self.persistToolCall(index, i);
    }
}

/// Advance the loop. Called from the UI's tick; returns true if anything
/// changed and the screen needs redrawing.
pub fn poll(self: *Loop) !bool {
    return switch (self.state) {
        .idle, .awaiting_approval, .awaiting_answer => false,
        .thinking, .compacting => self.pollRequest(),
        .running_tools => self.pollTools(),
        .cancelling => self.pollCancelled(),
    };
}

fn pollRequest(self: *Loop) !bool {
    const request = self.request orelse return false;
    if (!request.isFinished()) return false;

    request.join();
    self.request = null;
    defer request.destroy();

    self.syncProvider();

    const thinking: ?[]const u8 = if (request.thoughts.isEmpty())
        null
    else
        try request.thoughts.snapshot(self.allocator);
    defer if (thinking) |t| self.allocator.free(t);
    const thinking_ms = request.thoughts.elapsedMs();

    if (request.failed) |err| {
        self.last_error = err;
        self.compacting = false;

        const detail = self.provider.explain(err, self.allocator) catch
            try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
        defer self.allocator.free(detail);

        const text = try std.fmt.allocPrint(self.allocator, "Request failed - {s}", .{detail});
        defer self.allocator.free(text);
        _ = try self.conversation.addAssistant(text, thinking, thinking_ms);
        try self.persistMessage(self.conversation.messages.items.len - 1);
        self.state = .idle;
        return true;
    }

    if (request.reply) |reply| {
        self.usage.calls += 1;
        self.usage.input_tokens += reply.usage.prompt_tokens;
        self.usage.output_tokens += reply.usage.completion_tokens;
        self.usage.eval_duration_ns += reply.usage.eval_duration_ns;
        if (reply.usage.prompt_tokens > 0) {
            self.usage.context_tokens = reply.usage.prompt_tokens;
        }
    }

    const reply = request.reply orelse {
        self.compacting = false;
        self.state = .idle;
        return true;
    };

    if (self.compacting) {
        try self.finishCompaction(reply.text);
        return true;
    }

    const text = if (reply.text.len == 0 and reply.tool_calls.len == 0)
        no_reply
    else
        reply.text;

    _ = try self.conversation.append(.{
        .role = .assistant,
        .text = text,
        .thinking = thinking,
        .thinking_ms = thinking_ms,
        .tool_calls = reply.tool_calls,
    });
    try self.persistMessage(self.conversation.messages.items.len - 1);

    if (reply.tool_calls.len == 0) {
        self.state = .idle;
        self.repeats = 0;
        return true;
    }

    if (try self.repeating(reply.tool_calls)) {
        try self.stop("Stopped: the same tool call came back three times running.");
        return true;
    }

    self.pending_seq = self.conversation.messages.items[self.conversation.messages.items.len - 1].seq;
    self.pending_index = 0;
    try self.autoApprove();
    return true;
}

/// End the turn with a message saying why. The message is an assistant turn, so
/// the model sees it too and a later turn is not left guessing.
fn stop(self: *Loop, reason: []const u8) !void {
    _ = try self.conversation.addAssistant(reason, null, null);
    try self.persistMessage(self.conversation.messages.items.len - 1);
    self.state = .idle;
    self.repeats = 0;
}

/// Whether this batch of calls is the one before it, again. Identical means
/// same tools in the same order with the same arguments: a model reading three
/// files and then re-reading one of them is working, not looping.
fn repeating(self: *Loop, calls: []const Conversation.ToolCall) !bool {
    var signature: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer signature.deinit();
    for (calls) |call| {
        try signature.writer.print("{s}\x00{s}\x00", .{ call.name, call.arguments });
    }
    const current = try signature.toOwnedSlice();

    if (self.last_calls) |previous| {
        if (std.mem.eql(u8, previous, current)) {
            self.allocator.free(current);
            self.repeats += 1;
            return self.repeats >= max_repeats;
        }
        self.allocator.free(previous);
    }

    self.last_calls = current;
    self.repeats = 1;
    return false;
}

/// Settle every call that needs no decision, then either run what is approved
/// or stop for the user.
fn autoApprove(self: *Loop) !void {
    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;

    for (calls, 0..) |*call, i| {
        if (call.status != .pending) continue;
        if (!self.agent.allows(call.name)) {
            try self.refuse(message_index, i);
            continue;
        }
        if (self.needsNoDecision(call)) call.status = .running;
    }

    if (self.firstPending() != null) {
        self.state = .awaiting_approval;
        return;
    }
    try self.runApproved();
}

/// The question the model is waiting on an answer to, or null when it is not.
pub fn pendingQuestion(self: *Loop) ?*Conversation.ToolCall {
    if (self.state != .awaiting_answer) return null;
    return self.firstAsk();
}

/// The first `ask_user` call still waiting to be answered.
fn firstAsk(self: *Loop) ?*Conversation.ToolCall {
    const message_index = self.pendingIndex() orelse return null;
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls) |*call| {
        if (call.status != .running) continue;
        if (std.mem.eql(u8, call.name, ask_user.name)) return call;
    }
    return null;
}

/// Write the user's answer in as the result of the question, then carry on.
///
/// The answer settles one call. Anything else the model asked for in the same
/// batch runs afterwards, and a second question stops the turn again.
pub fn answer(self: *Loop, text: []const u8) !void {
    if (self.state != .awaiting_answer) return;

    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;

    for (calls, 0..) |*call, i| {
        if (call.status != .running) continue;
        if (!std.mem.eql(u8, call.name, ask_user.name)) continue;

        call.status = .ok;
        call.result = try self.allocator.dupe(u8, text);
        call.result_bytes = text.len;
        try self.persistToolCall(message_index, i);
        break;
    }

    if (self.firstAsk() != null) return;
    try self.runApproved();
}

/// Where the message being decided currently sits, or null when there is no
/// decision outstanding - or when that message has been trimmed out from under
/// it, which `Conversation.trim` is written to avoid.
fn pendingIndex(self: *const Loop) ?usize {
    const seq = self.pending_seq orelse return null;
    for (self.conversation.messages.items, 0..) |msg, i| {
        if (msg.seq == seq) return i;
    }
    return null;
}

/// Index of the next call still waiting on the user.
pub fn firstPending(self: *Loop) ?usize {
    const message_index = self.pendingIndex() orelse return null;
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls, 0..) |call, i| {
        if (call.status == .pending) return i;
    }
    return null;
}

/// The call the approval prompt is currently asking about.
pub fn pendingCall(self: *Loop) ?*Conversation.ToolCall {
    const message_index = self.pendingIndex() orelse return null;
    const index = self.firstPending() orelse return null;
    return &self.conversation.messages.items[message_index].tool_calls[index];
}

pub const Decision = enum { once, always, deny };

/// Record the user's answer for the call currently being asked about.
pub fn decide(self: *Loop, decision: Decision) !void {
    const call = self.pendingCall() orelse return;
    const message_index = self.pendingIndex() orelse return;
    const call_index = self.firstPending() orelse return;

    switch (decision) {
        .once => call.status = .running,
        .always => {
            call.status = .running;
            try self.allow(call);
        },
        .deny => {
            call.status = .rejected;
            call.result = try self.allocator.dupe(u8, "denied by the user");
            call.result_bytes = "denied by the user".len;
            try self.persistToolCall(message_index, call_index);
        },
    }

    if (decision == .always) try self.autoApproveRemaining(message_index);

    if (self.firstPending() != null) return;
    try self.runApproved();
}

/// Mark every still-pending call in `message_index` as approved when the
/// allowance list or a read-only tool definition covers it. Used after a
/// decision that may have changed the answer for calls beyond the first.
fn autoApproveRemaining(self: *Loop, message_index: usize) !void {
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls) |*call| {
        if (call.status != .pending) continue;
        if (self.needsNoDecision(call)) call.status = .running;
    }
}

/// Turn down a call the current agent has no business making. The model was
/// not told this tool exists, so this is a hallucinated name or a stale schema;
/// either way it comes back as a result it can read rather than a prompt the
/// user has to answer.
fn refuse(self: *Loop, message_index: usize, call_index: usize) !void {
    const call = &self.conversation.messages.items[message_index].tool_calls[call_index];
    const reason = try std.fmt.allocPrint(
        self.allocator,
        "{s} is not available in {s} mode",
        .{ call.name, self.agent.label },
    );
    call.status = .rejected;
    call.result = reason;
    call.result_bytes = reason.len;
    try self.persistToolCall(message_index, call_index);
}

/// Whether this call can run without stopping for the user: a tool that only
/// reads, a shell command the preset safe list covers, or something the user
/// has already said always to allow.
fn needsNoDecision(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (!self.agent.allows(call.name)) return false;
    if (self.escapesProject(call)) return false;

    const definition = self.registry.get(call.name) orelse return false;
    if (definition.read_only) return true;
    if (self.isSafe(call)) return true;
    return self.isAllowed(call);
}

/// Whether a call names a path outside the project.
///
/// Such a call never skips the gate, whatever the tool says about being
/// read-only: reading `~/.ssh/id_rsa` is not made safe by `read` being a
/// read-only tool. Anything unparseable counts as escaping, so a malformed
/// argument is asked about rather than waved through.
fn escapesProject(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (call.arguments.len == 0) return false;

    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments, .{}) catch return false;
    const fields = switch (parsed) {
        .object => |object| object,
        else => return false,
    };

    for ([_][]const u8{ "path", "file" }) |name| {
        const value = fields.get(name) orelse continue;
        if (value != .string) continue;
        if (value.string.len == 0) continue;
        if (!self.withinProject(arena, value.string)) return true;
    }
    return false;
}

fn withinProject(self: *const Loop, arena: std.mem.Allocator, path: []const u8) bool {
    const joined = if (std.fs.path.isAbsolute(path))
        arena.dupe(u8, path) catch return false
    else
        std.fs.path.join(arena, &.{ self.project_root, path }) catch return false;

    const resolved = std.fs.path.resolve(arena, &.{joined}) catch return false;
    if (!std.mem.startsWith(u8, resolved, self.project_root)) return false;
    if (resolved.len == self.project_root.len) return true;
    return resolved[self.project_root.len] == std.fs.path.sep;
}

/// Whether the preset list of read-only commands covers this call. Only `bash`
/// has commands to classify; every other tool is settled by `read_only`.
fn isSafe(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (!self.auto_approve_safe) return false;
    if (!std.mem.eql(u8, call.name, "bash")) return false;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.arguments, .{}) catch return false;
    if (parsed.value != .object) return false;
    const command = jsonString(parsed.value.object, "command") orelse return false;

    return safety.verdict(arena, command) == .safe;
}

/// Truncate tool output destined for the model, keeping the head and marking
/// what was dropped so it does not look like the tool simply stopped.
fn trimForModel(self: *Loop, result: []const u8) ![]const u8 {
    if (result.len <= max_tool_result_bytes) return result;

    var cut = max_tool_result_bytes;
    if (std.mem.lastIndexOfScalar(u8, result[0..cut], '\n')) |newline| cut = newline;

    return std.fmt.allocPrint(
        self.allocator,
        "{s}\n... truncated, {d} more bytes not shown",
        .{ result[0..cut], result.len - cut },
    );
}

/// Record an "allow always" for what this call is doing, and persist it.
fn allow(self: *Loop, call: *const Conversation.ToolCall) !void {
    const patterns = try approvalPatterns(self.allocator, call.name, call.arguments);
    defer freePatterns(self.allocator, patterns);

    for (patterns) |pattern| {
        try self.remember(call.name, pattern);
        if (self.db) |db| {
            if (self.project_id) |project_id| {
                try db.addApproval(project_id, call.name, pattern);
            }
        }
    }
}

/// Hold an allowance in memory, without touching the database.
fn remember(self: *Loop, name: []const u8, pattern: []const u8) !void {
    for (self.allowed.items) |allowance| {
        if (std.mem.eql(u8, allowance.tool, name) and
            std.mem.eql(u8, allowance.pattern, pattern)) return;
    }

    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);
    try self.allowed.append(self.allocator, .{
        .tool = name_copy,
        .pattern = try self.allocator.dupe(u8, pattern),
    });
}

/// What an "allow always" on this call covers, as one pattern per program the
/// command runs.
pub fn approvalPatterns(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: []const u8,
) ![]const []const u8 {
    if (!std.mem.eql(u8, name, "bash")) return onePattern(allocator, "*");

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch
        return onePattern(allocator, arguments);
    defer parsed.deinit();
    if (parsed.value != .object) return onePattern(allocator, arguments);

    const command = jsonString(parsed.value.object, "command") orelse
        return onePattern(allocator, arguments);
    const trimmed = std.mem.trim(u8, command, " \t\r\n");

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();

    const programs = try shellPrograms(arena_state.allocator(), trimmed) orelse
        return onePattern(allocator, trimmed);
    if (programs.len == 0) return onePattern(allocator, trimmed);

    if (programs.len == 1 and std.mem.eql(u8, programs[0], trimmed)) {
        return onePattern(allocator, trimmed);
    }

    const out = try allocator.alloc([]const u8, programs.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |pattern| allocator.free(pattern);
        allocator.free(out);
    }
    for (programs, out) |program, *pattern| {
        pattern.* = try std.fmt.allocPrint(allocator, "{s} *", .{program});
        filled += 1;
    }
    return out;
}

pub fn freePatterns(allocator: std.mem.Allocator, patterns: []const []const u8) void {
    for (patterns) |pattern| allocator.free(pattern);
    allocator.free(patterns);
}

fn onePattern(allocator: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(out);
    out[0] = try allocator.dupe(u8, pattern);
    return out;
}

/// The distinct programs `command` runs, in the order they appear, or null when
/// the line uses something the splitter will not vouch for.
fn shellPrograms(arena: std.mem.Allocator, command: []const u8) !?[][]const u8 {
    const parts = try safety.segments(arena, command) orelse return null;

    var names: std.ArrayList([]const u8) = .empty;
    next: for (parts) |part| {
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, part.program)) continue :next;
        }
        try names.append(arena, part.program);
    }
    return names.items;
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn isAllowed(self: *const Loop, call: *const Conversation.ToolCall) bool {
    const patterns = approvalPatterns(self.allocator, call.name, call.arguments) catch return false;
    defer freePatterns(self.allocator, patterns);

    for (patterns) |pattern| {
        if (!self.covers(call.name, pattern)) return false;
    }
    return true;
}

fn covers(self: *const Loop, name: []const u8, pattern: []const u8) bool {
    for (self.allowed.items) |allowance| {
        if (!std.mem.eql(u8, allowance.tool, name)) continue;
        if (std.mem.eql(u8, allowance.pattern, "*")) return true;
        if (std.mem.eql(u8, allowance.pattern, pattern)) return true;
        if (allowance.pattern.len == pattern.len + 2 and
            std.mem.startsWith(u8, allowance.pattern, pattern) and
            std.mem.endsWith(u8, allowance.pattern, " *")) return true;
    }
    return false;
}

/// Persist the message at `index` (the most recently appended one) and its
/// tool calls and reasoning blob. No-op when no database is attached.
fn persistMessage(self: *Loop, index: usize) !void {
    const db = self.db orelse return;
    const session_id = try self.ensureSession();

    const msg = &self.conversation.messages.items[index];
    const role = @tagName(msg.role);
    const thinking_ms: ?i64 = if (msg.thinking_ms) |ms| @intCast(ms) else null;
    const thinking_bytes: i64 = @intCast(msg.thinking_bytes);

    const message_id = try db.appendMessage(
        session_id,
        @intCast(msg.seq),
        role,
        msg.text,
        thinking_ms,
        thinking_bytes,
    );
    try self.message_ids.put(self.allocator, msg.seq, message_id);

    if (msg.thinking) |thinking| {
        if (thinking.len > 0) {
            try db.appendBlob(message_id, 0, "reasoning", thinking);
            self.shrinkThinking(msg);
        }
    }

    for (msg.attachments, 0..) |attachment, i| {
        try db.appendAttachment(message_id, @intCast(i), attachment.path, attachment.content);
    }

    for (msg.images, 0..) |image, i| {
        try db.appendBlob(message_id, @intCast(i), "image", image);
    }
    self.conversation.dropOldImages(max_resident_images);
    self.conversation.shrinkAttachments(max_resident_attachment_bytes);

    for (msg.tool_calls, 0..) |call, i| {
        try db.appendToolCall(
            message_id,
            @intCast(i),
            call.id,
            call.name,
            call.arguments,
            @tagName(call.status),
            call.result,
            @intCast(call.result_bytes),
        );
    }
}

/// Persist a tool call's settled status and result. No-op without a database.
fn persistToolCall(self: *Loop, message_index: usize, call_index: usize) !void {
    const db = self.db orelse return;
    const msg = &self.conversation.messages.items[message_index];
    const message_id = self.message_ids.get(msg.seq) orelse return;

    const call = &msg.tool_calls[call_index];

    if (call.result) |result| {
        if (result.len > Conversation.preview_bytes) {
            try db.appendBlob(message_id, @intCast(call_index), "tool_result", result);
        }
    }

    try db.updateToolCall(
        message_id,
        @intCast(call_index),
        @tagName(call.status),
        call.result,
        @intCast(call.result_bytes),
    );
    self.shrinkResult(call);
}

/// Replace a message's reasoning with a preview, freeing the full copy. The
/// full text is already in the blob table.
fn shrinkThinking(self: *Loop, msg: *Conversation.Message) void {
    const thinking = msg.thinking orelse return;
    if (thinking.len <= Conversation.preview_bytes) return;
    const preview = Conversation.preview(self.allocator, thinking) catch return;
    self.allocator.free(thinking);
    msg.thinking = preview;
}

/// Replace a tool call's result with a preview, freeing the full copy. The full
/// text is already in the blob table.
fn shrinkResult(self: *Loop, call: *Conversation.ToolCall) void {
    const result = call.result orelse return;
    if (result.len <= Conversation.preview_bytes) return;
    const preview = Conversation.preview(self.allocator, result) catch return;
    self.allocator.free(result);
    call.result = preview;
}

/// Flush the read log to the `read_file` table. No-op without a database.
fn persistReads(self: *Loop) !void {
    const db = self.db orelse return;
    const session_id = try self.ensureSession();

    var it = self.reads.iterator();
    while (it.next()) |entry| {
        try db.recordRead(session_id, entry.key_ptr.*, @intCast(entry.value_ptr.*));
    }
}

/// Hand every approved call to a worker. Denials skip straight to their result.
fn runApproved(self: *Loop) !void {
    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;

    var batch: std.ArrayList(ToolRun.Call) = .empty;
    defer batch.deinit(self.allocator);

    for (calls, 0..) |call, i| {
        if (call.status != .running) continue;
        try batch.append(self.allocator, .{
            .index = i,
            .name = call.name,
            .arguments = call.arguments,
            .allow_outside = !self.needsNoDecision(&call),
        });
    }

    // A question is answered, not run. The rest of the batch waits its turn.
    if (self.firstAsk() != null) {
        self.state = .awaiting_answer;
        return;
    }

    if (batch.items.len == 0) {
        try self.finishToolMessages();
        return;
    }

    self.tools_adopted = 0;
    self.tools = try ToolRun.start(
        self.allocator,
        self.io,
        self.registry,
        self.project_root,
        self.reads,
        self.delegate,
        batch.items,
    );
    self.state = .running_tools;
}

/// Copy across every result the worker has finished so far.
///
/// Called while the batch is still running, so a card settles as its own call
/// lands. Waiting for the whole batch is what made a run of edits look stuck:
/// nothing moved until the last one finished, however long the first took.
///
/// `tools_adopted` is what keeps this idempotent - each result is taken once,
/// so the final pass after the worker exits cannot dupe a result twice and
/// leak the first copy.
fn adoptSettled(self: *Loop, tools: *ToolRun) !void {
    const settled = tools.settledCount();
    if (self.tools_adopted >= settled) return;

    const message_index = self.pendingIndex() orelse return;

    while (self.tools_adopted < settled) : (self.tools_adopted += 1) {
        const result = tools.results[self.tools_adopted];
        const calls = self.conversation.messages.items[message_index].tool_calls;
        if (result.index >= calls.len) continue;

        const call = &calls[result.index];
        call.status = if (result.is_error) .failed else .ok;
        call.result = try self.allocator.dupe(u8, result.content);
        call.result_bytes = result.content.len;
        try self.persistToolCall(message_index, result.index);
    }
}

fn pollTools(self: *Loop) !bool {
    const tools = self.tools orelse return false;

    try self.adoptSettled(tools);
    if (!tools.isFinished()) return false;

    tools.join();
    self.tools = null;
    defer tools.destroy();

    // Anything that landed between the check above and the worker exiting.
    try self.adoptSettled(tools);

    try self.persistReads();

    try self.finishToolMessages();
    return true;
}

/// Append one `.tool` message per settled call, then ask the model again with
/// the results in hand.
fn finishToolMessages(self: *Loop) !void {
    const message_index = self.pendingIndex() orelse return;

    const calls = self.conversation.messages.items[message_index].tool_calls;
    const settled = try self.allocator.alloc(struct {
        name: []const u8,
        id: []const u8,
        result: []const u8,
    }, calls.len);
    defer self.allocator.free(settled);

    var count: usize = 0;
    for (calls) |call| {
        if (!call.status.isSettled()) continue;
        settled[count] = .{
            .name = call.name,
            .id = call.id,
            .result = call.result orelse "",
        };
        count += 1;
    }

    for (settled[0..count]) |entry| {
        const trimmed = try self.trimForModel(entry.result);
        defer if (trimmed.ptr != entry.result.ptr) self.allocator.free(trimmed);
        _ = try self.conversation.addToolResult(entry.name, entry.id, trimmed);
        try self.persistMessage(self.conversation.messages.items.len - 1);
    }

    self.pending_seq = null;
    self.pending_index = 0;
    try self.ask();
}

/// A provider that asks for `list` on its first turn and answers on its
/// second, so the whole approve/execute/resume path is exercisable with no
/// model attached.
const FakeProvider = struct {
    io: std.Io,
    /// Stands in for model latency. Slept in one go, and a cancellation point,
    /// so the cancel test has something real to interrupt.
    latency: std.Io.Duration = .fromMilliseconds(0),
    /// Number of identical calls to emit on the first turn. Default 1.
    parallel_calls: usize = 1,
    /// The tool those calls name.
    tool_name: []const u8 = "list",
    /// The arguments those calls carry.
    tool_arguments: []const u8 = "{\"path\":\".\"}",
    /// Ask for the same tool forever, the way a stuck model does.
    loop_forever: bool = false,

    fn provider(self: *FakeProvider) Provider {
        return .{ .name = "fake", .userdata = self, .respond = respond };
    }

    fn respond(
        ptr: *anyopaque,
        convo: *Conversation,
        asked: Provider.Turn,
        allocator: std.mem.Allocator,
        sink: ?Provider.Sink,
    ) !Provider.Reply {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));

        try std.Io.sleep(self.io, self.latency, .real);
        if (sink) |s| {
            if (s.stopped(s.userdata)) return .{};
            s.onThinking(s.userdata, "thinking about it\n");
        }

        // A one-off instruction is a question, not a turn: answer it rather
        // than reaching for a tool.
        if (asked.instruction.len > 0) {
            return .{ .text = try std.fmt.allocPrint(allocator, "answered: {s}", .{asked.instruction}) };
        }

        const last = convo.last();
        const answering_tool = last != null and last.?.role == .tool;
        if (!answering_tool or self.loop_forever) {
            const n = if (self.parallel_calls == 0) 1 else self.parallel_calls;
            const calls = try allocator.alloc(Conversation.ToolCall, n);
            errdefer allocator.free(calls);
            for (calls, 0..) |*call, i| {
                call.* = .{
                    .id = try std.fmt.allocPrint(allocator, "fake-{d}", .{i + 1}),
                    .name = try allocator.dupe(u8, self.tool_name),
                    .arguments = try allocator.dupe(u8, self.tool_arguments),
                };
            }
            return .{
                .text = try allocator.dupe(u8, "Let me look at the project."),
                .tool_calls = calls,
            };
        }

        const question = if (convo.last()) |msg| msg.text else "";
        return .{ .text = try std.fmt.allocPrint(allocator, "answered: {s}", .{question}) };
    }
};

/// Drive the loop to a stopping point: idle, or waiting on the user. Polls on
/// a short sleep rather than spinning, since the work is on another thread.
fn settle(self: *Loop) !void {
    var waited_ms: usize = 0;
    while (self.isBusy() and self.state != .awaiting_approval and self.state != .awaiting_answer) {
        _ = try self.poll();
        if (!self.isBusy() or self.state == .awaiting_approval or self.state == .awaiting_answer) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
        waited_ms += 1;
        if (waited_ms > 5_000) return error.LoopDidNotSettle;
    }
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    convo: Conversation,
    registry: Registry,
    reads: tool.ReadLog,
    fake: FakeProvider,

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        var tmp = testing.tmpDir(.{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);

        self.* = .{
            .tmp = tmp,
            .root = try testing.allocator.dupe(u8, buf[0..n]),
            .convo = .init(testing.allocator),
            .registry = try Registry.init(testing.allocator),
            .reads = .init(testing.allocator),
            .fake = .{ .io = testing.io },
        };
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.reads.deinit();
        self.registry.deinit();
        self.convo.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn loop(self: *Fixture) Loop {
        return .init(
            testing.allocator,
            testing.io,
            self.fake.provider(),
            &self.registry,
            &self.convo,
            &self.reads,
            self.root,
        );
    }
};

test "a read-only tool call runs without asking" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("what is here?", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);

    const calls = fixture.convo.messages.items[1].tool_calls;
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, calls[0].status);

    try testing.expectEqual(@as(usize, 4), fixture.convo.messages.items.len);
    try testing.expectEqual(Conversation.Role.tool, fixture.convo.messages.items[2].role);
}

test "a mutating tool call stops for approval" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expect(loop.pendingCall() != null);
    try testing.expect(fixture.convo.hasPendingToolCalls());
}

test "denial still reports back to the model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    try loop.submit("go", .{});
    try settle(&loop);
    try loop.decide(.deny);
    try settle(&loop);

    const calls = fixture.convo.messages.items[1].tool_calls;
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, calls[0].status);

    try testing.expectEqual(Conversation.Role.tool, fixture.convo.messages.items[2].role);
    try testing.expect(std.mem.indexOf(u8, fixture.convo.messages.items[2].text, "denied") != null);
    try testing.expectEqual(State.idle, loop.state);
}

test "allow always skips the prompt next time" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    try loop.submit("first", .{});
    try settle(&loop);
    try loop.decide(.always);
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);

    try loop.submit("second", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    const same: Conversation.ToolCall = .{ .id = "", .name = "list", .arguments = "{\"path\":\".\"}" };
    try testing.expect(loop.isAllowed(&same));
    const elsewhere: Conversation.ToolCall = .{ .id = "", .name = "list", .arguments = "{\"path\":\"docs\"}" };
    try testing.expect(loop.isAllowed(&elsewhere));
}

test "allow always covers the rest of a same-message batch" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;
    fixture.fake.parallel_calls = 3;

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);

    try loop.decide(.always);
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);

    const calls = fixture.convo.messages.items[1].tool_calls;
    try testing.expectEqual(@as(usize, 3), calls.len);
    for (calls) |call| {
        try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    }
}

test "usage derives rate and context fraction" {
    const usage: Usage = .{
        .context_tokens = 8_192,
        .output_tokens = 500,
        .eval_duration_ns = 10 * std.time.ns_per_s,
    };

    try testing.expectApproxEqAbs(@as(f64, 50), usage.tokensPerSecond().?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.25), usage.contextFraction(32_768).?, 0.001);

    try testing.expect(usage.contextFraction(0) == null);
    try testing.expect((Usage{}).tokensPerSecond() == null);
}

test "oversized tool output is truncated for the model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    const big = try testing.allocator.alloc(u8, max_tool_result_bytes * 2);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    const trimmed = try loop.trimForModel(big);
    defer testing.allocator.free(trimmed);

    try testing.expect(trimmed.len < big.len);
    try testing.expect(std.mem.indexOf(u8, trimmed, "truncated") != null);

    const small = "fine";
    try testing.expectEqual(small.ptr, (try loop.trimForModel(small)).ptr);
}

test "cancel returns while the worker is still running" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    // Long enough that the worker is certainly still inside `respond` when
    // cancel is called, short enough that reaping it does not slow the suite.
    fixture.fake.latency = .fromMilliseconds(300);

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try testing.expect(loop.isBusy());

    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try loop.cancel();
    const elapsed = started.durationTo(.now(testing.io, .awake)).nanoseconds;

    // The point of the whole thing: asking costs nothing. Waiting for the
    // worker on this thread is what used to freeze the UI.
    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
    try testing.expectEqual(State.cancelling, loop.state);
    try testing.expect(loop.request != null);
    try testing.expect(loop.isBusy());

    // Asking twice changes nothing and still does not block.
    try loop.cancel();
    try testing.expectEqual(State.cancelling, loop.state);

    try loop.settle();

    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.request == null);
    try testing.expect(!fixture.convo.hasPendingToolCalls());
}

test "a cancelled tool run leaves no call still spinning" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try loop.settle();
    try testing.expectEqual(State.awaiting_approval, loop.state);

    try loop.decide(.once);
    try loop.cancel();
    try loop.settle();

    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.tools == null);
    try testing.expect(!fixture.convo.hasPendingToolCalls());

    // Every call the turn left behind says what became of it.
    for (fixture.convo.messages.items) |message| {
        for (message.tool_calls) |call| try testing.expect(call.status.isSettled());
    }
}

test "an always-allow covers the programs a command runs, not every command" {
    const allocator = testing.allocator;

    const expect = struct {
        fn one(command: []const u8, wanted: []const u8) !void {
            const arguments = try std.fmt.allocPrint(
                testing.allocator,
                "{{\"command\":{f}}}",
                .{std.json.fmt(command, .{})},
            );
            defer testing.allocator.free(arguments);
            try many(arguments, &.{wanted});
        }

        fn many(arguments: []const u8, wanted: []const []const u8) !void {
            const patterns = try approvalPatterns(testing.allocator, "bash", arguments);
            defer freePatterns(testing.allocator, patterns);

            try testing.expectEqual(wanted.len, patterns.len);
            for (wanted, patterns) |want, got| try testing.expectEqualStrings(want, got);
        }
    };

    try expect.one("find . -type f -ls", "find *");
    try expect.one("find src -name '*.zig'", "find *");

    try expect.one("find", "find");

    try expect.one("cd /home/adam/repo && grep -rn foo", "grep *");
    try expect.one("cd /tmp;ls", "ls *");

    try expect.many("{\"command\":\"grep -rn foo src | head -20\"}", &.{ "grep *", "head *" });
    try expect.many("{\"command\":\"find . | xargs rm\"}", &.{ "find *", "xargs *" });
    try expect.many(
        "{\"command\":\"cd /a && zig build test 2>&1 | tail -20; echo done\"}",
        &.{ "zig *", "tail *", "echo *" },
    );

    try expect.one("grep \"a|b\" file", "grep *");

    try expect.one("grep -rn foo src/ 2>/dev/null", "grep *");

    try expect.one("grep foo > out.txt", "grep foo > out.txt");
    try expect.one("echo $(rm -rf /)", "echo $(rm -rf /)");
    try expect.one("sleep 10 & rm x", "sleep 10 & rm x");
    try expect.one("VAR=x grep foo", "VAR=x grep foo");

    try expect.one("echo \"exit: $?\"", "echo *");

    try expect.one("cd", "cd");

    try expect.one("sudo rm -rf /", "sudo *");

    const written = try approvalPatterns(allocator, "write", "{\"path\":\"src/main.zig\",\"content\":\"x\"}");
    defer freePatterns(allocator, written);
    try testing.expectEqual(@as(usize, 1), written.len);
    try testing.expectEqualStrings("*", written[0]);
}

test "auto-approval needs every program in a command, not just the first" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.remember("bash", "find *");
    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = "{\"command\":\"find . -type f\"}",
    };
    try testing.expect(loop.isAllowed(&call));

    call.arguments = "{\"command\":\"find . | xargs rm\"}";
    try testing.expect(!loop.isAllowed(&call));

    try loop.remember("bash", "xargs *");
    try testing.expect(loop.isAllowed(&call));
}

test "a read-only command runs without asking, and the toggle takes that away" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = "{\"command\":\"grep -rn foo src | head -20\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));
    try testing.expectEqual(@as(usize, 0), loop.allowed.items.len);

    call.arguments = "{\"command\":\"rm -rf build\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    loop.auto_approve_safe = false;
    call.arguments = "{\"command\":\"grep -rn foo src\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    try loop.remember("bash", "grep *");
    try testing.expect(loop.needsNoDecision(&call));

    loop.auto_approve_safe = true;
    call.arguments = "not json";
    try testing.expect(!loop.isSafe(&call));
    call.arguments = "{\"path\":\"x\"}";
    try testing.expect(!loop.isSafe(&call));
    call.name = "write";
    call.arguments = "{\"command\":\"ls\"}";
    try testing.expect(!loop.isSafe(&call));
}

test "an agent's tools are the ones the model is told about" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.useAgent("build");
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"write\"") != null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"bash\"") != null);

    try loop.useAgent("plan");
    try testing.expectEqualStrings("plan", loop.agent.id);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"write\"") == null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"bash\"") == null);

    try loop.useAgent("review");
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"edit\"") == null);
}

test "a tool outside the agent is refused rather than prompted" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "write";

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.useAgent("plan");
    try loop.submit("go", .{});
    try settle(&loop);

    // Plan mode cannot write, so nothing stops for the user and nothing runs.
    try testing.expectEqual(State.idle, loop.state);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "not available in Plan mode") != null);
}

test "a session comes back in the mode it was left in" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.attachDatabase(&db, "project", fixture.root, "model");
    try loop.useAgent("build");
    try loop.submit("go", .{});
    try settle(&loop);

    try loop.useAgent("review");
    const session_id = loop.session_id.?;

    var resumed = fixture.loop();
    defer resumed.deinit();
    try resumed.attachDatabase(&db, "project", fixture.root, "model");
    try resumed.useAgent("build");
    try resumed.resumeSession(session_id, 50);

    try testing.expectEqualStrings("review", resumed.agent.id);
}

test "the same call three times running stops the turn" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.loop_forever = true;

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    const last = loop.conversation.last().?;
    try testing.expect(std.mem.indexOf(u8, last.text, "three times running") != null);

    // Three model calls, not two hundred: the ceiling never came into it.
    try testing.expect(loop.steps <= max_repeats + 1);
}

test "different calls are work, not a loop" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    const first: []const Conversation.ToolCall = &.{
        .{ .id = "1", .name = "list", .arguments = "{\"path\":\".\"}" },
    };
    const second: []const Conversation.ToolCall = &.{
        .{ .id = "2", .name = "list", .arguments = "{\"path\":\"src\"}" },
    };

    try testing.expect(!try loop.repeating(first));
    try testing.expect(!try loop.repeating(second));
    try testing.expect(!try loop.repeating(first));
    try testing.expectEqual(@as(usize, 1), loop.repeats);

    // The same one twice is a model correcting itself; three times is stuck.
    try testing.expect(!try loop.repeating(first));
    try testing.expect(try loop.repeating(first));
}

test "an agent's step ceiling is the one that applies" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.useAgent("plan");
    try testing.expectEqual(@as(usize, 40), loop.agent.steps);

    try loop.useAgent("build");
    try testing.expect(loop.agent.steps > 40);
}

test "a pending decision survives history being paged in" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    loop.conversation.next_seq = 50;
    loop.conversation.dropped = 50;

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);

    const before = loop.pendingCall().?;

    var older = [_]Conversation.Message{
        .{ .seq = 10, .role = .user, .text = "" },
        .{ .seq = 11, .role = .assistant, .text = "" },
    };
    try loop.conversation.prepend(&older);

    const after = loop.pendingCall().?;
    try testing.expectEqualStrings(before.name, after.name);
    try testing.expectEqualStrings("list", after.name);
}

test "compaction summarises the transcript into a system message" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("what is here?", .{});
    try settle(&loop);
    const before = loop.conversation.messages.items.len;

    try loop.compact();
    try testing.expectEqual(State.compacting, loop.state);
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(!loop.compacting);

    try testing.expectEqual(before + 1, loop.conversation.messages.items.len);
    const summary = loop.conversation.messages.items[before];
    try testing.expectEqual(Conversation.Role.system, summary.role);
    try testing.expect(summary.text.len > 0);

    // The fake echoes what it was asked, so this is the only proof that the
    // instruction reached the model at all rather than being dropped on the
    // way, which is what happened while it travelled as an unused argument.
    try testing.expect(std.mem.indexOf(u8, summary.text, "Summarise this conversation") != null);
}

test "a turn carries the agent's prompt and tools, not the provider's" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();
    loop.system_prompt = "base instructions";

    try loop.useAgent("plan");
    const planning = loop.turn("");
    try testing.expectEqualStrings("base instructions", planning.system);
    try testing.expect(std.mem.indexOf(u8, planning.tools_json, "\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, planning.tools_json, "\"write\"") == null);
    try testing.expectEqualStrings("", planning.instruction);

    // With a project the agent's own instructions are folded in, and the
    // assembled text is what the backend is handed.
    var project = try Project.detect(testing.allocator, testing.io, fixture.root);
    defer project.deinit(testing.allocator);
    loop.project = &project;

    const with_project = loop.turn("summarise");
    try testing.expect(std.mem.startsWith(u8, with_project.system, "base instructions"));
    try testing.expect(std.mem.indexOf(u8, with_project.system, "plan mode") != null);
    try testing.expect(std.mem.indexOf(u8, with_project.system, "<environment>") != null);
    try testing.expectEqualStrings("summarise", with_project.instruction);
}

test "auto-compaction waits for the context to actually fill" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try testing.expect(!loop.shouldCompact());

    loop.provider.context_limit = 1000;
    loop.usage.context_tokens = 500;
    try testing.expect(!loop.shouldCompact());

    loop.usage.context_tokens = 900;
    try testing.expect(loop.shouldCompact());

    loop.auto_compact_at = 0;
    try testing.expect(!loop.shouldCompact());
}

test "switching models is recorded on the session row" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buffer, "{s}/models.db", .{fixture.root});
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");

    try loop.setModel("second-model");
    try testing.expect(loop.session_id == null);

    const session_id = try loop.ensureSession();
    const at_creation = try db.sessionModel(session_id, testing.allocator);
    defer testing.allocator.free(at_creation);
    try testing.expectEqualStrings("second-model", at_creation);

    try loop.setModel("third-model");
    const after = try db.sessionModel(session_id, testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("third-model", after);

    try testing.expectEqualStrings("third-model", loop.session_model);
    try testing.expect(loop.session_model_owned != null);
}

/// A backend that offers a choice of model, which `FakeProvider` does not.
/// Only the switching half is real: nothing here is ever asked to answer.
const SwitchableProvider = struct {
    buffer: [64]u8 = undefined,
    model: []const u8 = "configured-model",
    switches: usize = 0,

    fn provider(self: *SwitchableProvider) Provider {
        return .{
            .name = "switchable",
            .model = self.model,
            .userdata = self,
            .respond = respond,
            .set_model = switchTo,
        };
    }

    fn respond(_: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
        return error.NotAsked;
    }

    fn switchTo(ptr: *anyopaque, name: []const u8) anyerror!Provider.Current {
        const self: *SwitchableProvider = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, name, "gone")) return error.NoSuchModel;
        self.model = self.buffer[0..name.len];
        @memcpy(self.buffer[0..name.len], name);
        self.switches += 1;
        return .{ .model = self.model, .context_limit = 4096, .vision = false };
    }
};

test "a resumed session runs under the model it was last used with" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buffer, "{s}/resume-model.db", .{fixture.root});
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    const session_id = blk: {
        var loop = fixture.loop();
        defer loop.deinit();
        try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
        const id = try loop.ensureSession();
        try loop.setModel("minimax-m3");
        break :blk id;
    };

    var backend: SwitchableProvider = .{};
    var loop = fixture.loop();
    loop.provider = backend.provider();
    defer loop.deinit();

    try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
    try loop.resumeSession(session_id, 50);

    try testing.expectEqualStrings("minimax-m3", loop.provider.model);
    try testing.expectEqualStrings("minimax-m3", loop.session_model);
    try testing.expectEqual(@as(u32, 4096), loop.provider.context_limit);
    try testing.expect(!loop.provider.vision);
}

test "resume leaves the provider alone when there is nothing to restore" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buffer, "{s}/resume-same.db", .{fixture.root});
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    const session_id = blk: {
        var loop = fixture.loop();
        defer loop.deinit();
        try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
        break :blk try loop.ensureSession();
    };

    var backend: SwitchableProvider = .{};
    var loop = fixture.loop();
    loop.provider = backend.provider();
    defer loop.deinit();

    try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
    try loop.resumeSession(session_id, 50);

    try testing.expectEqualStrings("configured-model", loop.provider.model);
    try testing.expectEqual(@as(usize, 0), backend.switches);

    try db.setSessionModel(session_id, "gone");
    try loop.resumeSession(session_id, 50);
    try testing.expectEqualStrings("configured-model", loop.provider.model);
}

test "a path outside the project is asked about, whatever the tool is" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "read",
        .arguments = "{\"path\":\"src/main.zig\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/etc/passwd\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"../../etc/passwd\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"src/../src/main.zig\"}";
    try testing.expect(loop.needsNoDecision(&call));
}

test "a standing allowance does not extend outside the project" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.remember("write", "*");

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "write",
        .arguments = "{\"path\":\"notes.md\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/tmp/notes.md\"}";
    try testing.expect(!loop.needsNoDecision(&call));
}

test "a question stops the turn and its answer becomes the result" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.tool_name = "ask_user";
    fixture.fake.tool_arguments = "{\"question\":\"Which one?\"}";

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.awaiting_answer, loop.state);

    const asked = loop.pendingQuestion() orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, asked.arguments, "Which one?") != null);

    try loop.answer("the left one");
    try settle(&loop);

    const call = &loop.conversation.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    try testing.expectEqualStrings("the left one", call.result.?);
}

test "an answer offered when nothing was asked is ignored" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try testing.expectEqual(State.idle, loop.state);
    try loop.answer("nobody asked");
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.pendingQuestion() == null);
}

test "a worker that ignores the ask is signalled once the grace is up" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.latency = .fromMilliseconds(30_000);

    try loop.submit("go", .{});
    while (loop.state != .thinking) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }

    try loop.cancel();
    try testing.expectEqual(State.cancelling, loop.state);
    try testing.expect(!loop.signalled);

    _ = try loop.poll();
    try testing.expect(!loop.signalled);

    const started = tool.monotonicMilliseconds(testing.io);
    while (loop.isBusy()) {
        _ = try loop.poll();
        if (tool.monotonicMilliseconds(testing.io) - started > 20_000) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .real);
    }

    try testing.expect(loop.signalled);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(tool.monotonicMilliseconds(testing.io) - started < 20_000);
}
