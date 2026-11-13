const std = @import("std");
const ChatGPT = @import("chatgpt_sign_in.zig");
const chatgpt_auth = @import("chatgpt_auth.zig");
const copilot = @import("copilot_auth.zig");
const catalog = @import("catalog.zig");

const SignIn = @This();

allocator: std.mem.Allocator,
io: std.Io,
id: []const u8,
chatgpt: ?*ChatGPT = null,
arena: std.heap.ArenaAllocator,
code: ?copilot.Code = null,
url: []const u8 = "",
user_code: []const u8 = "",
port: u16 = 0,
future: ?std.Io.Future(void) = null,
canceled: std.atomic.Value(bool) = .init(false),
done: std.atomic.Value(bool) = .init(false),
code_ready: std.atomic.Value(bool) = .init(false),
outcome: anyerror!void = {},
token: ?[]const u8 = null,

pub fn start(allocator: std.mem.Allocator, io: std.Io, id: []const u8, store: ?*chatgpt_auth.Store) !*SignIn {
    const self = try allocator.create(SignIn);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .id = id, .arena = .init(allocator) };
    errdefer self.arena.deinit();
    if (std.mem.eql(u8, id, catalog.chatgpt_id)) {
        const task = try ChatGPT.start(allocator, io, store orelse return error.NoCredentialStore);
        self.chatgpt = task;
        self.url = task.sign_in.url;
        self.port = task.sign_in.callbackPort();
    } else if (std.mem.eql(u8, id, catalog.copilot_id)) {
        self.future = try io.concurrent(run, .{self});
    } else return error.UnknownProvider;
    return self;
}

fn run(self: *SignIn) void {
    defer self.done.store(true, .release);
    self.poll() catch |err| {
        self.outcome = err;
    };
}

fn poll(self: *SignIn) !void {
    const code = try copilot.requestCode(self.arena.allocator(), self.io);
    self.code = code;
    self.url = code.verification_uri;
    self.user_code = code.user_code;
    self.code_ready.store(true, .release);
    const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromSeconds(code.expires_in));
    var interval: u64 = @max(code.interval, 1);
    while (std.Io.Clock.awake.now(self.io).durationTo(deadline).nanoseconds > 0) {
        var waited: u64 = 0;
        while (waited < interval * 1000 + 500) : (waited += 100) {
            if (self.canceled.load(.acquire)) return error.SignInCanceled;
            try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
        }
        if (self.canceled.load(.acquire)) return error.SignInCanceled;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        switch (try copilot.poll(scratch.allocator(), self.io, code.device_code)) {
            .pending => {},
            .slow_down => interval += 5,
            .token => |token| {
                _ = try copilot.discover(scratch.allocator(), self.io, token);
                self.token = try self.arena.allocator().dupe(u8, token);
                return;
            },
        }
    }
    return error.SignInTimedOut;
}

pub const Status = struct { url: []const u8, port: u16, user_code: []const u8 };

pub fn status(self: *SignIn) Status {
    if (self.chatgpt == null and !self.code_ready.load(.acquire)) return .{ .url = "", .port = 0, .user_code = "" };
    return .{ .url = self.url, .port = self.port, .user_code = self.user_code };
}

pub fn isFinished(self: *SignIn) bool {
    if (self.chatgpt) |task| return task.isFinished();
    return self.done.load(.acquire);
}

pub fn cancel(self: *SignIn) void {
    if (self.chatgpt) |task| task.cancel();
    self.canceled.store(true, .release);
    if (self.future) |*future| {
        future.cancel(self.io);
        self.done.store(true, .release);
    }
}

pub fn finish(self: *SignIn, allocator: std.mem.Allocator) !?[]u8 {
    defer self.destroy();
    if (self.chatgpt) |task| {
        try task.finish();
        return null;
    }
    if (self.future) |*future| future.await(self.io);
    if (self.canceled.load(.acquire)) return error.SignInCanceled;
    try self.outcome;
    return if (self.token) |token| try allocator.dupe(u8, token) else null;
}

pub fn abandon(self: *SignIn) void {
    if (self.chatgpt) |task| task.abandon();
    if (self.future) |*future| future.cancel(self.io);
    self.destroy();
}

fn destroy(self: *SignIn) void {
    self.arena.deinit();
    self.allocator.destroy(self);
}

test "canceling a device sign-in interrupts its pending I/O task" {
    const testing = std.testing;
    const task = try testing.allocator.create(SignIn);
    task.* = .{ .allocator = testing.allocator, .io = testing.io, .id = catalog.copilot_id, .arena = .init(testing.allocator) };
    const Wait = struct {
        fn run(io: std.Io) void {
            std.Io.sleep(io, .fromSeconds(60), .awake) catch {};
        }
    };
    task.future = try testing.io.concurrent(Wait.run, .{testing.io});
    try testing.expectEqualStrings("", task.status().user_code);
    task.cancel();
    try testing.expect(task.isFinished());
    try testing.expectError(error.SignInCanceled, task.finish(testing.allocator));
}

pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.CopilotNotEntitled => "This GitHub account has no Copilot chat access. Check that your organization assigned you a Copilot seat.",
        error.CopilotAccessDenied => "GitHub denied Copilot access. Check your organization's Copilot and OAuth app policies.",
        error.CopilotSessionExpired => "GitHub rejected the saved credential. Sign in to Copilot again with ctrl+p.",
        error.UntrustedCopilotEndpoint => "GitHub returned an unexpected Copilot API host. No credential was sent to it.",
        else => ChatGPT.explain(err),
    };
}
