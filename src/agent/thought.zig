//! Thinking output streamed from a provider while a request runs.

const std = @import("std");

/// Thinking text accumulated while a request is in flight.
pub const Stream = struct {
    allocator: std.mem.Allocator,
    /// `std.Io.Mutex` takes the io implementation on every lock/unlock, so the
    /// stream carries one.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,

    /// When the request started, which is when the model starts reasoning.
    started: std.Io.Timestamp,
    /// When the last fragment arrived. Reasoning is over by definition once the
    /// model moves on to content, so this is the end of the thinking window.
    ended: ?std.Io.Timestamp = null,
    /// Set once the model has moved on to its answer. The request usually runs
    /// on for a long time after that - generating prose, or the arguments of a
    /// tool call - and none of it is thinking, so the clock stops here.
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Stream {
        return .{
            .allocator = allocator,
            .io = io,
            .started = .now(io, .awake),
        };
    }

    /// Milliseconds since the request started, for showing progress while it
    /// is still running. Frozen at the thinking time once the model has moved
    /// on, so a long write does not inflate a short thought.
    pub fn liveElapsedMs(self: *Stream) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return self.elapsedMsLocked() orelse 0;

        const now: std.Io.Timestamp = .now(self.io, .awake);
        const ns = self.started.durationTo(now).nanoseconds;
        if (ns <= 0) return 0;
        return @intCast(@divFloor(ns, std.time.ns_per_ms));
    }

    /// Worker thread. The model has stopped reasoning: everything after this
    /// belongs to the answer.
    pub fn close(self: *Stream) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closed = true;
    }

    /// True once the model has moved past reasoning, for a UI that wants to
    /// say what it is doing now rather than what it was doing.
    pub fn isClosed(self: *Stream) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.closed;
    }

    /// Milliseconds spent thinking, or null if the model never thought.
    pub fn elapsedMs(self: *Stream) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.elapsedMsLocked();
    }

    fn elapsedMsLocked(self: *Stream) ?u64 {
        const ended = self.ended orelse return null;
        const ns = self.started.durationTo(ended).nanoseconds;
        if (ns <= 0) return 0;
        return @intCast(@divFloor(ns, std.time.ns_per_ms));
    }

    pub fn deinit(self: *Stream) void {
        self.text.deinit(self.allocator);
    }

    /// Worker thread. Dropping a fragment on OOM beats failing the request.
    pub fn append(self: *Stream, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.text.appendSlice(self.allocator, bytes) catch {};
        self.ended = .now(self.io, .awake);
    }

    /// UI thread. Copies so rendering never holds the lock.
    pub fn snapshot(self: *Stream, arena: std.mem.Allocator) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return arena.dupe(u8, self.text.items);
    }

    pub fn isEmpty(self: *Stream) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.text.items.len == 0;
    }
};

test "the clock stops when the model moves on from thinking" {
    const testing = std.testing;
    const io = testing.io;

    var stream: Stream = .init(testing.allocator, io);
    defer stream.deinit();

    stream.append("weighing it up");
    try std.Io.sleep(io, .fromMilliseconds(2), .real);

    try testing.expect(stream.liveElapsedMs() >= stream.elapsedMs().?);

    stream.close();
    const thought = stream.liveElapsedMs();

    try std.Io.sleep(io, .fromMilliseconds(5), .real);
    try testing.expectEqual(thought, stream.liveElapsedMs());
    try testing.expectEqual(stream.elapsedMs().?, stream.liveElapsedMs());
    try testing.expect(stream.isClosed());
}

test "a stream closed without a thought reports no elapsed time" {
    const testing = std.testing;

    var stream: Stream = .init(testing.allocator, testing.io);
    defer stream.deinit();

    stream.close();
    try testing.expectEqual(@as(?u64, null), stream.elapsedMs());
    try testing.expectEqual(@as(u64, 0), stream.liveElapsedMs());
}
