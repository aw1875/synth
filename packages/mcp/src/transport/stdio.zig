//! The stdio transport: a server as a child process, one JSON message per line.
//!
//! MCP frames stdio messages by newline, and forbids an embedded newline in a
//! message, so reading is `takeDelimiter` and writing is "append one". No
//! length prefixes, no framing headers.
//!
//! A server's own logging goes to its stderr, which is why `stderr` is a choice
//! here: a TUI wants it thrown away, a headless run usually wants to see it.

const std = @import("std");
const testing = std.testing;

const Transport = @import("transport.zig");

const StdioTransport = @This();

/// Longest single message. A tool result can carry a whole file, so this is
/// generous; a server that exceeds it has almost certainly gone wrong.
pub const default_max_message: usize = 4 * 1024 * 1024;

pub const Stderr = enum {
    /// Thrown away. What a TUI wants: a server writing to the terminal would
    /// draw over the screen.
    ignore,
    /// Straight to this process's stderr, for a headless run where a server's
    /// own complaints are the fastest way to find a misconfiguration.
    inherit,
};

/// The configuration for a stdio server. Carried by `Transport.Options.stdio`
/// and translated by `Transport.start` into a running `StdioTransport`.
pub const Options = struct {
    /// The command, already split. `argv[0]` is resolved against PATH.
    argv: []const []const u8,
    /// Working directory for the server, or null to inherit.
    cwd: ?[]const u8 = null,
    /// Replaces the server's environment when given. Null inherits this
    /// process's, which is usually what a server needs to find its own tools.
    environ_map: ?*const std.process.Environ.Map = null,
    stderr: Stderr = .ignore,
    max_message: usize = default_max_message,
};

pub const Error = error{
    /// The server closed its output, which for a child process means it exited.
    ServerClosed,
    /// A single message ran past `max_message`.
    MessageTooLong,
};

allocator: std.mem.Allocator,
io: std.Io,
child: std.process.Child,
/// Owned; the reader and writer below borrow these and must not outlive them.
read_buffer: []u8,
write_buffer: []u8,
reader: std.Io.File.Reader,
writer: std.Io.File.Writer,
/// Cleared by `stop`, so stopping twice is safe and sending afterwards is an
/// error rather than a write to a closed pipe.
running: bool = true,
/// The seam exposed to the rest of the program. Set up after
/// this struct reaches its final address, because the vtable's erased fn
/// pointers recover `*StdioTransport` from `*Transport` via
/// `@fieldParentPtr`.
transport: Transport,

/// Spawn the server and wire up its pipes.
///
/// Heap-allocated because the reader and writer hold pointers into this struct
/// and into the buffers beside them: a `Transport` returned by value would
/// leave every one of them pointing at a dead frame.
pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*StdioTransport {
    if (options.argv.len == 0) return error.InvalidCommand;

    const self = try allocator.create(StdioTransport);
    errdefer allocator.destroy(self);

    const read_buffer = try allocator.alloc(u8, options.max_message);
    errdefer allocator.free(read_buffer);

    const write_buffer = try allocator.alloc(u8, 64 * 1024);
    errdefer allocator.free(write_buffer);

    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = switch (options.stderr) {
            .ignore => .ignore,
            .inherit => .inherit,
        },
    });
    errdefer child.kill(io);

    const vtable: *const Transport.VTable = &.{
        .send = sendErased,
        .receive = receiveErased,
        .deinit = deinitErased,
    };

    self.* = .{
        .allocator = allocator,
        .io = io,
        .child = child,
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .reader = undefined,
        .writer = undefined,
        .transport = .{ .vtable = vtable },
    };

    self.reader = self.child.stdout.?.reader(io, self.read_buffer);
    self.writer = self.child.stdin.?.writer(io, self.write_buffer);
    return self;
}

/// Send one message, adding the newline that ends it.
pub fn send(self: *StdioTransport, message: []const u8) !void {
    if (!self.running) return Error.ServerClosed;

    self.writer.interface.writeAll(message) catch return Error.ServerClosed;
    self.writer.interface.writeByte('\n') catch return Error.ServerClosed;
    self.writer.interface.flush() catch return Error.ServerClosed;
}

/// Read one message. The slice points into this transport's own buffer and is
/// only valid until the next `receive`, so a caller keeping it must copy.
pub fn receive(self: *StdioTransport) ![]const u8 {
    if (!self.running) return Error.ServerClosed;

    while (true) {
        const line = self.reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return Error.MessageTooLong,
            error.ReadFailed => return Error.ServerClosed,
        } orelse return Error.ServerClosed;

        // A server may write a blank line between messages; nothing says it
        // must not, and an empty line is not a message.
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        return trimmed;
    }
}

/// Close the server down: shut its input, which is how a well-behaved server is
/// told to exit, then make sure it is gone.
///
/// The spec asks for stdin close, then SIGTERM, then SIGKILL, each with a grace
/// period. There is no non-blocking wait to build that on, so this closes and
/// then terminates: a server that would have exited on its own is killed a
/// moment earlier than it deserved, which costs nothing.
pub fn stop(self: *StdioTransport) void {
    if (!self.running) return;
    self.running = false;

    if (self.child.stdin) |*stdin| {
        stdin.close(self.io);
        self.child.stdin = null;
    }
    self.child.kill(self.io);
}

pub fn destroy(self: *StdioTransport) void {
    self.stop();
    const allocator = self.allocator;
    allocator.free(self.read_buffer);
    allocator.free(self.write_buffer);
    allocator.destroy(self);
}

// Vtable fn pointers. Each receives the `*Transport` the seam hands back and
// recovers the parent `*StdioTransport` via `@fieldParentPtr`: the field name
// here is fixed in stone because `Transport.start` looks it up the same way.
fn sendErased(t: *Transport, message: []const u8) Transport.Error!void {
    const self: *StdioTransport = @fieldParentPtr("transport", t);
    return self.send(message);
}

fn receiveErased(t: *Transport) Transport.Error![]const u8 {
    const self: *StdioTransport = @fieldParentPtr("transport", t);
    return self.receive();
}

fn deinitErased(t: *Transport) void {
    const self: *StdioTransport = @fieldParentPtr("transport", t);
    self.destroy();
}

/// A command that echoes each line back, for exercising the framing without a
/// real server. `cat` is on every machine this runs on.
fn echoCommand() []const []const u8 {
    return &.{ "cat", "-u" };
}

test "messages round-trip a line at a time" {
    const allocator = testing.allocator;

    var stdio = StdioTransport.start(allocator, testing.io, .{ .argv = echoCommand() }) catch |err| {
        // No `cat`, or spawning is not allowed here. The framing is what is
        // under test, not the sandbox.
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer stdio.destroy();

    try stdio.send("{\"jsonrpc\":\"2.0\",\"id\":1}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", try stdio.receive());

    try stdio.send("{\"second\":true}");
    try testing.expectEqualStrings("{\"second\":true}", try stdio.receive());
}

test "a blank line is skipped rather than returned as a message" {
    const allocator = testing.allocator;

    var stdio = StdioTransport.start(allocator, testing.io, .{ .argv = echoCommand() }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer stdio.destroy();

    try stdio.send("");
    try stdio.send("   ");
    try stdio.send("{\"real\":1}");

    // The whitespace-only line is a message as far as framing goes; only a
    // truly empty one is skipped.
    try testing.expectEqualStrings("   ", try stdio.receive());
    try testing.expectEqualStrings("{\"real\":1}", try stdio.receive());
}

test "a server that exits is reported as closed, not as a hang" {
    const allocator = testing.allocator;

    var stdio = StdioTransport.start(allocator, testing.io, .{ .argv = &.{"true"} }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer stdio.destroy();

    try testing.expectError(Error.ServerClosed, stdio.receive());
}

test "stopping twice is safe, and sending afterwards fails" {
    const allocator = testing.allocator;

    var stdio = StdioTransport.start(allocator, testing.io, .{ .argv = echoCommand() }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer stdio.destroy();

    stdio.stop();
    stdio.stop();

    try testing.expectError(Error.ServerClosed, stdio.send("{}"));
    try testing.expectError(Error.ServerClosed, stdio.receive());
}

test "an empty command is refused before anything is spawned" {
    try testing.expectError(
        error.InvalidCommand,
        StdioTransport.start(testing.allocator, testing.io, .{ .argv = &.{} }),
    );
}
