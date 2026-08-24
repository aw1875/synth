//! One provider turn, running off the UI's event loop.

const std = @import("std");

const Provider = @import("../provider/provider.zig");
const Conversation = @import("../core/conversation.zig");
const Thought = @import("thought.zig");

const Request = @This();

allocator: std.mem.Allocator,
io: std.Io,
provider: Provider,
conversation: *Conversation,
/// Owned copy of the turn's strings: the loop is free to rebuild its prompt or
/// switch agents while this is in flight.
turn: Provider.Turn,
thoughts: Thought.Stream,
/// The answer as it arrives, for the UI to render before the turn lands.
content: Thought.Stream,

future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
/// A cooperative nudge, checked by the provider between chunks. Cancellation
/// proper is `cancel`; this is the cheap non-blocking half, and it covers the
/// case where a provider swallows `error.Canceled` from an inner call.
stop: std.atomic.Value(bool) = .init(false),
/// Allocated with `allocator`; ownership passes to whoever calls `join`.
reply: ?Provider.Reply = null,
failed: ?anyerror = null,

/// Spawn the worker. The returned request is owned by the caller, which must
/// eventually call `join` or `cancel`, then `destroy`.
pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    conversation: *Conversation,
    turn: Provider.Turn,
) !*Request {
    const self = try allocator.create(Request);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .provider = provider,
        .conversation = conversation,
        .turn = .{
            .system = try allocator.dupe(u8, turn.system),
            .tools_json = try allocator.dupe(u8, turn.tools_json),
            .instruction = try allocator.dupe(u8, turn.instruction),
        },
        .thoughts = .init(allocator, io),
        .content = .init(allocator, io),
    };
    errdefer {
        self.freeTurn();
        self.thoughts.deinit();
        self.content.deinit();
    }

    self.future = try io.concurrent(run, .{self});
    return self;
}

/// Non-blocking check for the owning thread.
pub fn isFinished(self: *Request) bool {
    return self.done.load(.acquire);
}

/// Ask the provider to give up between chunks. Non-blocking, and on its own
/// no guarantee: a provider blocked waiting for the first byte never reaches
/// the check. Pair it with `cancel`.
pub fn requestStop(self: *Request) void {
    self.stop.store(true, .release);
}

pub fn join(self: *Request) void {
    self.future.await(self.io);
}

/// Interrupt the turn and wait for it to unwind.
pub fn cancel(self: *Request) void {
    self.requestStop();
    self.future.cancel(self.io);
}

pub fn destroy(self: *Request) void {
    const allocator = self.allocator;
    self.thoughts.deinit();
    self.content.deinit();
    if (self.reply) |*reply| reply.deinit(allocator);
    self.freeTurn();
    allocator.destroy(self);
}

fn freeTurn(self: *Request) void {
    self.allocator.free(self.turn.system);
    self.allocator.free(self.turn.tools_json);
    self.allocator.free(self.turn.instruction);
}

fn run(self: *Request) void {
    defer self.done.store(true, .release);

    self.reply = self.provider.respond(
        self.provider.userdata,
        self.conversation,
        self.turn,
        self.allocator,
        .{
            .userdata = self,
            .onThinking = onThinking,
            .onText = onText,
            .onThinkingDone = onThinkingDone,
            .stopped = stopped,
        },
    ) catch |err| {
        self.failed = err;
        return;
    };
}

/// Worker thread, via the provider's sink.
fn onThinking(ptr: *anyopaque, bytes: []const u8) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.thoughts.append(bytes);
}

/// Worker thread, via the provider's sink.
fn onText(ptr: *anyopaque, bytes: []const u8) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.content.append(bytes);
}

/// Worker thread, via the provider's sink.
fn onThinkingDone(ptr: *anyopaque) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.thoughts.close();
}

/// Worker thread, via the provider's sink.
fn stopped(ptr: *anyopaque) bool {
    const self: *Request = @ptrCast(@alignCast(ptr));
    return self.stop.load(.acquire);
}
