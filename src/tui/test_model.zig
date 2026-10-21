//! Models for tests: one drawing a session set by hand, and one driving a
//! session a test server runs.

const std = @import("std");
const testing = std.testing;

const client = @import("../remote/client.zig");
const Mirror = @import("../remote/mirror.zig");
const Server = @import("../remote/server.zig");
const wire = @import("../remote/wire.zig");
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

/// A wired model driving a fresh session on a test server.
pub const Served = struct {
    fixture: *Server.Fixture,
    model: *Model,

    pub fn create() !Served {
        const fixture = try Server.Fixture.create();
        errdefer fixture.destroy();

        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const stream = try (try std.Io.net.UnixAddress.init(fixture.server.path)).connect(testing.io);
        const connection = try client.Connection.openStream(testing.allocator, testing.io, stream, null);
        var attached = false;
        defer if (!attached) connection.close();
        const opened = try connection.call(arena, .{ .open = .{ .root = fixture.project } }, null);
        const handle = (try wire.parseResult(wire.Summary, arena, opened)).handle;

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
        model.mirror = Mirror.attach(testing.allocator, testing.io, connection, &model.conversation, "test", handle, null) catch |err| {
            model.conversation.deinit();
            model.input.deinit();
            testing.allocator.free(model.cwd);
            testing.allocator.free(model.cwd_display);
            return err;
        };
        attached = true;
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
