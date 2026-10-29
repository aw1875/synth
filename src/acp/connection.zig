//! The client end of ACP: an agent reached over a child's stdio, or over a
//! socket already connected to one.

const std = @import("std");

const pkg = @import("pkg");

const rpc = @import("rpc.zig");
const protocol = @import("protocol.zig");
const synth = @import("synth.zig");

const Connection = @This();

/// This machine, as a host name.
pub const here = ".";

allocator: std.mem.Allocator,
io: std.Io,
transport: Transport,
read_buffer: [64 * 1024]u8 = undefined,
write_buffer: [64 * 1024]u8 = undefined,
reader: std.Io.File.Reader = undefined,
writer: std.Io.File.Writer = undefined,
lines: rpc.LineReader,
next_id: i64 = 1,

const Transport = union(enum) {
    child: std.process.Child,
    /// A socket, read and written both ways.
    socket: std.Io.File,
};

/// Why a connection was refused, in words for the person who asked.
pub const Diagnostic = struct {
    buffer: [256]u8 = undefined,
    message: []const u8 = "",

    pub fn say(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.buffer, fmt, args) catch fmt;
    }
};

/// Start `synth acp` in `cwd` with this terminal's environment, so the
/// session's tools see what a shell here would.
pub fn spawn(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !*Connection {
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    // Its stderr would land on the screen the TUI is drawing.
    const child = try std.process.spawn(io, .{
        .argv = &.{ exe, "acp" },
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const self = try create(allocator, io, .{ .child = child });
    self.reader = child.stdout.?.readerStreaming(io, &self.read_buffer);
    self.writer = child.stdin.?.writerStreaming(io, &self.write_buffer);
    return self;
}

/// Talk over a socket already connected to an agent. The connection owns it.
pub fn overSocket(allocator: std.mem.Allocator, io: std.Io, socket: std.Io.File) !*Connection {
    const self = try create(allocator, io, .{ .socket = socket });
    self.reader = socket.readerStreaming(io, &self.read_buffer);
    self.writer = socket.writerStreaming(io, &self.write_buffer);
    return self;
}

fn create(allocator: std.mem.Allocator, io: std.Io, transport: Transport) !*Connection {
    const self = try allocator.create(Connection);
    self.* = .{ .allocator = allocator, .io = io, .transport = transport, .lines = .init(allocator) };
    return self;
}

/// Hang up, and for a child, wait for it to go: its session ends with it.
pub fn close(self: *Connection) void {
    self.interrupt();
    switch (self.transport) {
        .child => |*child| _ = child.wait(self.io) catch {},
        .socket => |socket| socket.close(self.io),
    }
    self.lines.deinit();
    self.allocator.destroy(self);
}

/// Stop reading from another thread: whoever is blocked in `next` gets end
/// of stream once the agent sees its input end.
pub fn interrupt(self: *Connection) void {
    switch (self.transport) {
        .child => |*child| if (child.stdin) |stdin| {
            stdin.close(self.io);
            child.stdin = null;
        },
        .socket => |socket| _ = std.posix.system.shutdown(socket.handle, std.posix.SHUT.RDWR),
    }
}

/// Say hello, asking for synth's extension, and saying questions can be
/// put to us as forms.
pub fn initialize(self: *Connection, arena: std.mem.Allocator, diagnostic: ?*Diagnostic) !void {
    _ = self.call(arena, protocol.method.initialize, protocol.Initialize{
        .protocolVersion = protocol.version,
        .clientCapabilities = .{ .elicitation = .{ .form = .{} } },
        .clientInfo = .{ .name = pkg.name, .version = pkg.version },
        ._meta = .{ .synth = .{ .protocol = synth.version } },
    }, diagnostic) catch |err| {
        if (err == error.ConnectionLost) if (diagnostic) |d| d.say("the agent did not answer", .{});
        return err;
    };
}

/// Send a request, returning the id its reply will carry.
pub fn request(self: *Connection, method: []const u8, params: anytype) !rpc.Id {
    const id: rpc.Id = .{ .number = self.next_id };
    self.next_id += 1;
    try rpc.request(&self.writer.interface, id, method, params);
    try self.writer.interface.flush();
    return id;
}

pub fn notify(self: *Connection, method: []const u8, params: anytype) !void {
    try rpc.notify(&self.writer.interface, method, params);
    try self.writer.interface.flush();
}

/// Answer a request the agent made.
pub fn reply(self: *Connection, id: rpc.Id, value: anytype) !void {
    try rpc.result(&self.writer.interface, id, value);
    try self.writer.interface.flush();
}

/// Refuse a request the agent made.
pub fn fail(self: *Connection, id: rpc.Id, error_code: i64, message: []const u8) !void {
    try rpc.fail(&self.writer.interface, id, error_code, message);
    try self.writer.interface.flush();
}

/// The next message, parsed into `arena`, or null once the agent is gone.
pub fn next(self: *Connection, arena: std.mem.Allocator) !?rpc.Message {
    const line = try self.lines.next(&self.reader.interface) orelse return null;
    return try rpc.Message.parse(arena, try arena.dupe(u8, line));
}

/// Send a request and wait for its reply, passing over anything else. Only
/// for before a reader thread takes the connection over.
pub fn call(self: *Connection, arena: std.mem.Allocator, method: []const u8, params: anytype, diagnostic: ?*Diagnostic) !std.json.Value {
    const id = try self.request(method, params);
    while (try self.next(arena)) |message| {
        if (message.method != null or message.id == null or !message.id.?.eql(id)) continue;
        if (message.err) |err| {
            if (diagnostic) |d| d.say("{s}", .{err.message});
            return error.Refused;
        }
        return message.result orelse .null;
    }
    return error.ConnectionLost;
}
