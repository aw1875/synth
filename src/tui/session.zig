//! The session the TUI drives: a loop running in this process, or one running
//! on a server and mirrored here.
//!
//! What only a local session has - its database, a provider client to
//! reconfigure - comes back empty for a remote one, and the features built on
//! it stand down. What a remote session is asked lands on a later poll.

const std = @import("std");

const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const todo = @import("../core/todo.zig");
const Loop = @import("../agent/loop.zig");
const Thought = @import("../agent/thought.zig");
const Provider = @import("../provider/provider.zig");
const Mirror = @import("../remote/mirror.zig");

pub const Session = union(enum) {
    local: *Loop,
    remote: *Mirror,

    pub fn isRemote(self: Session) bool {
        return self == .remote;
    }

    /// Advance the session, or take in what the server sent. Whether
    /// anything changed.
    pub fn poll(self: Session) !bool {
        return switch (self) {
            .local => |loop| loop.poll(),
            .remote => |mirror| mirror.poll(),
        };
    }

    pub fn isBusy(self: Session) bool {
        return switch (self) {
            .local => |loop| loop.isBusy(),
            .remote => |mirror| mirror.isBusy(),
        };
    }

    pub fn state(self: Session) Loop.State {
        return switch (self) {
            .local => |loop| loop.state,
            .remote => |mirror| mirror.status.state,
        };
    }

    pub fn label(self: Session) []const u8 {
        return switch (self) {
            .local => |loop| loop.label(),
            .remote => |mirror| mirror.label(),
        };
    }

    pub fn thoughts(self: Session) ?*Thought.Stream {
        return switch (self) {
            .local => |loop| loop.thoughts(),
            .remote => |mirror| mirror.thoughts(),
        };
    }

    pub fn streamingText(self: Session) ?*Thought.Stream {
        return switch (self) {
            .local => |loop| loop.streamingText(),
            .remote => |mirror| mirror.streamingText(),
        };
    }

    pub fn pendingCall(self: Session) ?*Conversation.ToolCall {
        return switch (self) {
            .local => |loop| loop.pendingCall(),
            .remote => |mirror| mirror.pendingCall(),
        };
    }

    pub fn firstPending(self: Session) ?usize {
        return switch (self) {
            .local => |loop| loop.firstPending(),
            .remote => |mirror| if (mirror.status.pending_call) |index| index else null,
        };
    }

    pub fn pendingSeq(self: Session) ?u64 {
        return switch (self) {
            .local => |loop| loop.pending_seq,
            .remote => |mirror| mirror.status.pending_seq,
        };
    }

    pub fn pendingSteering(self: Session) []const []const u8 {
        return switch (self) {
            .local => |loop| loop.pendingSteering(),
            .remote => |mirror| mirror.status.steering,
        };
    }

    /// Steering left over from a turn that ended, to start the next one with.
    /// A server starts that turn itself.
    pub fn takeSteering(self: Session) ?[]const u8 {
        return switch (self) {
            .local => |loop| loop.takeSteering(),
            .remote => null,
        };
    }

    pub fn dropSteering(self: Session) void {
        switch (self) {
            .local => |loop| loop.dropSteering(),
            .remote => {},
        }
    }

    /// Whether the transcript was replaced by another session's since the
    /// last call. A local session is replaced only when the TUI asks for it.
    pub fn takeSwitched(self: Session) bool {
        return switch (self) {
            .local => false,
            .remote => |mirror| mirror.takeSwitched(),
        };
    }

    /// The answer to something asked of a remote session, which the caller
    /// frees. A local session answers on the spot.
    pub fn takeAnswer(self: Session) ?Mirror.Answer {
        return switch (self) {
            .local => null,
            .remote => |mirror| mirror.takeAnswer(),
        };
    }

    /// Something to show the person, which the caller frees.
    pub fn takeNotice(self: Session) ?[]u8 {
        return switch (self) {
            .local => |loop| loop.takeHookNotice(),
            .remote => |mirror| mirror.takeNotice(),
        };
    }

    /// Whether to compact before the next turn. A server decides that itself.
    pub fn shouldCompact(self: Session) bool {
        return switch (self) {
            .local => |loop| loop.shouldCompact(),
            .remote => false,
        };
    }

    pub fn outcome(self: Session) ?Loop.Outcome {
        return switch (self) {
            .local => |loop| loop.outcome,
            .remote => |mirror| mirror.status.outcome,
        };
    }

    pub fn finishedTurns(self: Session) u64 {
        return switch (self) {
            .local => |loop| loop.finished,
            .remote => |mirror| mirror.status.finished,
        };
    }

    pub fn toolNote(self: Session, seq: u64, index: usize) ?[]const u8 {
        return switch (self) {
            .local => |loop| loop.toolNote(seq, index),
            .remote => |mirror| mirror.toolNote(seq, index),
        };
    }

    pub fn title(self: Session) []const u8 {
        return switch (self) {
            .local => |loop| loop.title(),
            .remote => |mirror| mirror.status.title,
        };
    }

    pub fn agentId(self: Session) []const u8 {
        return switch (self) {
            .local => |loop| loop.agent.id,
            .remote => |mirror| mirror.status.agent,
        };
    }

    pub fn usage(self: Session) Loop.Usage {
        return switch (self) {
            .local => |loop| loop.usage,
            .remote => |mirror| mirror.status.usage,
        };
    }

    pub fn todos(self: Session) *todo.List {
        return switch (self) {
            .local => |loop| &loop.todos,
            .remote => |mirror| &mirror.todos,
        };
    }

    /// The model answering, as far as showing it goes.
    pub fn provider(self: Session) *const Provider {
        return switch (self) {
            .local => |loop| &loop.provider,
            .remote => |mirror| &mirror.provider,
        };
    }

    pub fn submit(self: Session, prompt: []const u8, extras: Loop.Extras) !void {
        return switch (self) {
            .local => |loop| loop.submit(prompt, extras),
            .remote => |mirror| mirror.submit(prompt, extras),
        };
    }

    pub fn steer(self: Session, text: []const u8) !bool {
        return switch (self) {
            .local => |loop| loop.steer(text),
            .remote => |mirror| mirror.steer(text),
        };
    }

    pub fn answer(self: Session, text: []const u8) !void {
        return switch (self) {
            .local => |loop| loop.answer(text),
            .remote => |mirror| mirror.answer(text),
        };
    }

    pub fn cancel(self: Session) !void {
        return switch (self) {
            .local => |loop| loop.cancel(),
            .remote => |mirror| mirror.cancel(),
        };
    }

    pub fn decide(self: Session, decision: Loop.Decision) !void {
        return switch (self) {
            .local => |loop| loop.decide(decision),
            .remote => |mirror| mirror.decide(decision),
        };
    }

    pub fn compact(self: Session) !void {
        return switch (self) {
            .local => |loop| loop.compact(),
            .remote => |mirror| mirror.compact(),
        };
    }

    pub fn rename(self: Session, name: []const u8) !void {
        return switch (self) {
            .local => |loop| loop.rename(name),
            .remote => |mirror| mirror.rename(name),
        };
    }

    pub fn useAgent(self: Session, id: []const u8) !void {
        return switch (self) {
            .local => |loop| loop.useAgent(id),
            .remote => |mirror| mirror.useAgent(id),
        };
    }

    /// Ask the workers to give up, on the way out. A remote session carries
    /// on without us, which is the point of it.
    pub fn requestStop(self: Session) void {
        switch (self) {
            .local => |loop| loop.requestStop(),
            .remote => {},
        }
    }

    pub fn pageHistory(self: Session, limit: usize) !usize {
        return switch (self) {
            .local => |loop| loop.pageHistory(limit),
            .remote => |mirror| mirror.pageHistory(limit),
        };
    }

    pub fn loadThinking(self: Session, msg: *Conversation.Message) !void {
        return switch (self) {
            .local => |loop| loop.loadThinking(msg),
            .remote => |mirror| mirror.loadThinking(msg),
        };
    }

    /// A remote session sends attachments whole, so there is nothing to load.
    pub fn loadAttachment(self: Session, msg: *Conversation.Message, index: usize) !void {
        return switch (self) {
            .local => |loop| loop.loadAttachment(msg, index),
            .remote => {},
        };
    }

    pub fn loadToolResult(self: Session, msg: *Conversation.Message, index: usize) !void {
        return switch (self) {
            .local => |loop| loop.loadToolResult(msg, index),
            .remote => |mirror| mirror.loadToolResult(msg, index),
        };
    }

    /// The database transcripts are kept in, when it is this machine's.
    pub fn database(self: Session) ?*Database {
        return switch (self) {
            .local => |loop| loop.db,
            .remote => null,
        };
    }

    pub fn projectId(self: Session) ?i64 {
        return switch (self) {
            .local => |loop| loop.project_id,
            .remote => null,
        };
    }

    pub fn sessionId(self: Session) ?i64 {
        return switch (self) {
            .local => |loop| loop.session_id,
            .remote => null,
        };
    }

    /// The handle the session is resumed or reattached by. Caller owns it.
    pub fn sessionHandle(self: Session, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .local => |loop| loop.sessionHandle(allocator),
            .remote => |mirror| allocator.dupe(u8, mirror.status.handle),
        };
    }
};
