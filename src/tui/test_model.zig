//! Models for tests: one drawing a session set by hand, and one driving a
//! session a test agent runs.

const std = @import("std");
const testing = std.testing;

const Agent = @import("../acp/agent.zig");
const Connection = @import("../acp/connection.zig");
const Mirror = @import("../acp/mirror.zig");
const Model = @import("model.zig");

/// A wired model on a session with nothing behind it. Its status is the
/// test's to set; nothing polls it.
pub fn offline(model: *Model) !void {
    model.* = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .conversation = .init(testing.allocator),
        .input = .init(testing.allocator),
        .cwd = try testing.allocator.dupe(u8, ""),
        .cwd_display = try testing.allocator.dupe(u8, ""),
    };
    model.mirror = try Mirror.offline(testing.allocator, testing.io, &model.conversation, "test");
    try model.wire();
}

/// A wired model driving a fresh session on a test agent.
pub const Served = struct {
    fixture: *Agent.Fixture,
    model: *Model,

    pub fn create() !Served {
        const fixture = try Agent.Fixture.create();
        errdefer fixture.destroy();

        const model = try testing.allocator.create(Model);
        errdefer testing.allocator.destroy(model);
        model.* = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .conversation = .init(testing.allocator),
            .input = .init(testing.allocator),
            .cwd = try testing.allocator.dupe(u8, ""),
            .cwd_display = try testing.allocator.dupe(u8, "test"),
        };
        const connection = try Connection.overSocket(testing.allocator, testing.io, try fixture.socket());
        model.mirror = Mirror.open(testing.allocator, testing.io, connection, &model.conversation, Connection.here, null, .{ .new = fixture.project }, null) catch |err| {
            model.conversation.deinit();
            model.input.deinit();
            testing.allocator.free(model.cwd);
            testing.allocator.free(model.cwd_display);
            return err;
        };
        try model.wire();
        errdefer model.deinit();
        try model.showReplacedTranscript();
        _ = model.mirror.takeSwitched();
        return .{ .fixture = fixture, .model = model };
    }

    pub fn destroy(self: Served) void {
        self.model.deinit();
        testing.allocator.destroy(self.model);
        self.fixture.destroy();
    }

    /// Poll the session until `done` says so, or fail after a few seconds.
    pub fn pollUntil(self: Served, comptime done: fn (*Model) bool) !void {
        for (0..500) |_| {
            _ = try self.model.mirror.poll();
            if (done(self.model)) return;
            try std.Io.sleep(testing.io, .fromMilliseconds(10), .awake);
        }
        return error.TimedOut;
    }
};
