//! A ChatGPT browser sign-in running off the UI thread.
//!
//! The wait is minutes of a person reading a consent screen. Done on the
//! thread that draws, it would freeze the screen and swallow ctrl+c, so it
//! runs here and the tick loop polls it.

const std = @import("std");

const chatgpt_auth = @import("../provider/chatgpt_auth.zig");

const SignInTask = @This();

allocator: std.mem.Allocator,
io: std.Io,
sign_in: *chatgpt_auth.SignIn,
future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
outcome: anyerror!void = {},

pub fn start(allocator: std.mem.Allocator, io: std.Io, store: *chatgpt_auth.Store) !*SignInTask {
    const self = try allocator.create(SignInTask);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .sign_in = try chatgpt_auth.SignIn.begin(allocator, io, store),
    };
    errdefer self.sign_in.destroy();
    self.future = try io.concurrent(run, .{self});
    return self;
}

fn run(self: *SignInTask) void {
    defer self.done.store(true, .release);
    _ = self.sign_in.finish(chatgpt_auth.sign_in_timeout_ns) catch |err| {
        self.outcome = err;
    };
}

pub fn url(self: *const SignInTask) []const u8 {
    return self.sign_in.url;
}

pub fn isFinished(self: *SignInTask) bool {
    return self.done.load(.acquire);
}

/// Settles within one poll of the callback listener.
pub fn cancel(self: *SignInTask) void {
    self.sign_in.cancel();
}

/// Wait for the worker, release everything, and hand back how it went.
/// Only call once `isFinished`, or after `cancel`.
pub fn finish(self: *SignInTask) anyerror!void {
    self.future.await(self.io);
    const outcome = self.outcome;
    self.sign_in.destroy();
    self.allocator.destroy(self);
    return outcome;
}

/// What to tell the person when a sign-in did not complete.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.SignInCanceled => "Sign-in canceled.",
        error.SignInTimedOut => "Sign-in timed out waiting for the browser. Try again with ctrl+p.",
        error.AuthorizationDenied => "Sign-in was declined in the browser.",
        error.PlanUsageNotGranted => "Signed in, but synth was not allowed to use your ChatGPT plan. Sign in again and allow plan usage.",
        error.AccountMismatch => "That is a different ChatGPT account than the one synth was registered with. Sign out first with /logout.",
        error.ClientMismatch, error.RegistrationIncomplete => "OpenAI did not finish registering synth. Try signing in again.",
        error.InvalidIdToken => "OpenAI's sign-in response could not be verified, so it was not trusted.",
        error.NoFreePort => "Could not open a local port for the sign-in callback.",
        else => "Sign-in failed.",
    };
}
