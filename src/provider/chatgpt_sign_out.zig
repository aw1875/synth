//! Signing out of ChatGPT off the thread that asked: revoking the session is
//! a network round trip, and a TUI or a session must not stall on it.

const std = @import("std");

const chatgpt_auth = @import("chatgpt_auth.zig");

const SignOutTask = @This();

allocator: std.mem.Allocator,
io: std.Io,
store: *chatgpt_auth.Store,
future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
outcome: anyerror!bool = false,

pub fn start(allocator: std.mem.Allocator, io: std.Io, store: *chatgpt_auth.Store) !*SignOutTask {
    const self = try allocator.create(SignOutTask);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .store = store };
    self.future = try io.concurrent(run, .{self});
    return self;
}

fn run(self: *SignOutTask) void {
    defer self.done.store(true, .release);
    self.outcome = self.store.signOut();
}

pub fn isFinished(self: *SignOutTask) bool {
    return self.done.load(.acquire);
}

/// Whether OpenAI confirmed the revocation. Only call once `isFinished`.
pub fn finish(self: *SignOutTask) anyerror!bool {
    self.future.await(self.io);
    const outcome = self.outcome;
    self.allocator.destroy(self);
    return outcome;
}

/// For quitting: stop at the next cancelation point rather than wait on the
/// network.
pub fn abandon(self: *SignOutTask) void {
    self.future.cancel(self.io);
    self.allocator.destroy(self);
}
