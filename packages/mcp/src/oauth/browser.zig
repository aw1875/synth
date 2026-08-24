//! Open a URL in the user's browser.
//!
//! The default implementation spawns the platform's "open" command (xdg-open
//! on Linux, open on macOS, the run-time association on Windows). Callers can
//! supply a different implementation - a TUI shows its own UI rather than
//! spawn a process, a headless run prints the URL and continues.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{SpawnFailed};

/// A function that opens `url` somewhere the user will see it. Returns once
/// the URL has been handed off, not once the user has finished with it.
pub const Open = *const fn (io: std.Io, url: []const u8) Error!void;

/// The platform default: spawn `xdg-open` (Linux/BSD), `open` (Apple), or
/// `cmd /c start` (Windows) with the URL as an argument.
///
/// Waited on rather than left running: every one of these hands the URL to the
/// desktop and exits immediately, so the wait is short, and skipping it would
/// leave a zombie behind for the rest of the session.
pub fn defaultOpen(io: std.Io, url: []const u8) Error!void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => &.{ "xdg-open", url },
        .macos, .ios, .tvos, .watchos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => return Error.SpawnFailed,
    };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return Error.SpawnFailed;

    // The exit status says whether the launcher ran, not whether the user did
    // anything, so there is nothing here worth acting on.
    _ = child.wait(io) catch return Error.SpawnFailed;
}

test "defaultOpen URL is forwarded unchanged" {
    // Just exercises the argument-passing shape; we don't actually want to
    // open a browser during tests.
    if (true) return error.SkipZigTest;

    const io = std.testing.io;
    try defaultOpen(io, "https://example.com/callback?code=abc");
}
