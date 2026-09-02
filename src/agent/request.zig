//! One provider turn, running off the UI's event loop.

const std = @import("std");

const Provider = @import("../provider/provider.zig");
const Conversation = @import("../core/conversation.zig");
const Thought = @import("thought.zig");
const tool = @import("../tools/tool.zig");

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
/// Whether the future has been awaited and freed. Awaiting twice is undefined,
/// and cancelling happens on a worker thread while the owner still holds this.
reaped: bool = false,
done: std.atomic.Value(bool) = .init(false),
/// A cooperative nudge, checked by the provider between chunks. Cancellation
/// proper is `cancel`; this is the cheap non-blocking half, and it covers the
/// case where a provider swallows `error.Canceled` from an inner call.
stop: std.atomic.Value(bool) = .init(false),
/// When a chunk last arrived, on the monotonic clock. A connection that died
/// mid-stream looks exactly like a model still thinking, and the only thing
/// that tells them apart is how long the silence has run.
progress_ms: std.atomic.Value(i64) = .init(0),
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
        .progress_ms = .init(tool.monotonicMilliseconds(io)),
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

/// Non-blocking check for the owning thread. True once nothing has arrived for
/// `limit_ms`, which from this side is what a dead connection looks like: the
/// kernel keeps retransmitting into it for a quarter of an hour before the read
/// fails on its own. Zero or less disables the check, matching the turn budgets.
pub fn stalled(self: *Request, limit_ms: i64) bool {
    if (limit_ms <= 0) return false;
    if (self.isFinished()) return false;
    const quiet = tool.monotonicMilliseconds(self.io) - self.progress_ms.load(.acquire);
    return quiet >= limit_ms;
}

pub fn join(self: *Request) void {
    if (self.reaped) return;
    self.reaped = true;
    self.future.await(self.io);
}

/// Interrupt the turn and wait for it to unwind.
///
/// Blocks for as long as the worker takes to notice, which for a provider
/// midway through a socket read is not bounded by anything this side controls.
/// Never call it from the thread drawing the screen.
pub fn cancel(self: *Request) void {
    if (self.reaped) return;
    self.reaped = true;
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
    self.markProgress();
    self.thoughts.append(bytes);
}

/// Worker thread, via the provider's sink.
fn onText(ptr: *anyopaque, bytes: []const u8) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.markProgress();
    self.content.append(bytes);
}

/// Worker thread. Says the connection is still delivering.
fn markProgress(self: *Request) void {
    self.progress_ms.store(tool.monotonicMilliseconds(self.io), .release);
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
