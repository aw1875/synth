//! The client end of the protocol: a connection to a host's session server.
//!
//! A host is anything `ssh` accepts, reached by running the bridge at the far
//! end, or `.` for this machine, reached by running the bridge here, which
//! also starts the server when none is up. Either way the connection is a
//! child process's stdio, so ssh's own config, keys, agents and jump hosts all
//! apply without any code here knowing about them.

const std = @import("std");

const pkg = @import("pkg");

const wire = @import("wire.zig");

/// This machine, as a host name.
pub const here = ".";

/// Keep the exec channel a clean byte stream: no tty and so no banner in it,
/// and no `RemoteCommand` or `LocalCommand` from the person's config standing
/// in for the bridge. The keepalives notice a dead link in under a minute.
const ssh_options = [_][]const u8{
    "-T",
    "-o",
    "RequestTTY=no",
    "-o",
    "RemoteCommand=none",
    "-o",
    "PermitLocalCommand=no",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=3",
};

/// What runs the bridge for `host`: this program itself for this machine, or
/// ssh running it at the far end. `--` before the host keeps a host that
/// starts with `-` from being read as an option.
fn bridgeCommand(allocator: std.mem.Allocator, host: []const u8, exe: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    if (std.mem.eql(u8, host, here)) {
        try argv.append(allocator, exe);
    } else {
        try argv.append(allocator, "ssh");
        try argv.appendSlice(allocator, &ssh_options);
        try argv.appendSlice(allocator, &.{ "--", host, pkg.name });
    }
    try argv.appendSlice(allocator, &.{ "remote", "bridge" });
    return argv.toOwnedSlice(allocator);
}

test "a remote host is reached through ssh, this machine directly" {
    const testing = std.testing;

    const remote = try bridgeCommand(testing.allocator, "devbox", "/bin/" ++ pkg.name);
    defer testing.allocator.free(remote);
    try testing.expectEqualStrings("ssh", remote[0]);
    try testing.expectEqualStrings("-T", remote[1]);
    const tail = remote[remote.len - 5 ..];
    const expected = [_][]const u8{ "--", "devbox", pkg.name, "remote", "bridge" };
    for (expected, tail) |want, got| try testing.expectEqualStrings(want, got);

    const local = try bridgeCommand(testing.allocator, here, "/bin/" ++ pkg.name);
    defer testing.allocator.free(local);
    const direct = [_][]const u8{ "/bin/" ++ pkg.name, "remote", "bridge" };
    try testing.expectEqual(direct.len, local.len);
    for (direct, local) |want, got| try testing.expectEqualStrings(want, got);
}

/// Why a connection was refused, in words for the person who asked.
pub const Diagnostic = struct {
    buffer: [256]u8 = undefined,
    message: []const u8 = "",

    pub fn say(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.buffer, fmt, args) catch fmt;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [64 * 1024]u8 = undefined,
    lines: wire.LineReader,
    next_id: u64 = 1,
    /// What the server said it is, from its hello.
    server: []const u8 = "",
    /// The server runs a program since replaced on disk.
    outdated: bool = false,
    hello_arena: std.heap.ArenaAllocator,

    const Transport = union(enum) {
        child: struct {
            process: std.process.Child,
            reader: std.Io.File.Reader,
            writer: std.Io.File.Writer,
        },
        socket: struct {
            stream: std.Io.net.Stream,
            reader: std.Io.net.Stream.Reader,
            writer: std.Io.net.Stream.Writer,
        },
    };

    /// Reach `host` and say hello.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, host: []const u8, diagnostic: ?*Diagnostic) !*Connection {
        const self = try create(allocator, io);
        errdefer self.destroy();

        const exe = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(exe);
        const argv = try bridgeCommand(allocator, host, exe);
        defer allocator.free(argv);

        const process = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.transport = .{ .child = .{ .process = process, .reader = undefined, .writer = undefined } };
        const child = &self.transport.child;
        child.reader = child.process.stdout.?.reader(io, &self.read_buffer);
        child.writer = child.process.stdin.?.writer(io, &self.write_buffer);

        try self.handshake(host, diagnostic);
        return self;
    }

    /// Talk over a stream already connected to a server's socket.
    pub fn openStream(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, diagnostic: ?*Diagnostic) !*Connection {
        const self = try create(allocator, io);
        errdefer self.destroy();
        self.transport = .{ .socket = .{ .stream = stream, .reader = undefined, .writer = undefined } };
        const socket = &self.transport.socket;
        socket.reader = stream.reader(io, &self.read_buffer);
        socket.writer = stream.writer(io, &self.write_buffer);

        try self.handshake(here, diagnostic);
        return self;
    }

    fn create(allocator: std.mem.Allocator, io: std.Io) !*Connection {
        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = undefined,
            .lines = .init(allocator),
            .hello_arena = .init(allocator),
        };
        return self;
    }

    /// Hang up, and for a child, wait for it to go.
    pub fn close(self: *Connection) void {
        switch (self.transport) {
            .child => |*child| {
                if (child.process.stdin) |stdin| stdin.close(self.io);
                child.process.stdin = null;
                _ = child.process.wait(self.io) catch {};
            },
            .socket => |*socket| socket.stream.close(self.io),
        }
        self.destroy();
    }

    fn destroy(self: *Connection) void {
        self.hello_arena.deinit();
        self.lines.deinit();
        self.allocator.destroy(self);
    }

    /// Stop reading from another thread: whoever is blocked in `next` gets
    /// end of stream.
    pub fn interrupt(self: *Connection) void {
        switch (self.transport) {
            .child => |*child| if (child.process.stdin) |stdin| {
                stdin.close(self.io);
                child.process.stdin = null;
            },
            .socket => |*socket| socket.stream.shutdown(self.io, .both) catch {},
        }
    }

    fn reader(self: *Connection) *std.Io.Reader {
        return switch (self.transport) {
            .child => |*child| &child.reader.interface,
            .socket => |*socket| &socket.reader.interface,
        };
    }

    fn writer(self: *Connection) *std.Io.Writer {
        return switch (self.transport) {
            .child => |*child| &child.writer.interface,
            .socket => |*socket| &socket.writer.interface,
        };
    }

    fn handshake(self: *Connection, host: []const u8, diagnostic: ?*Diagnostic) !void {
        _ = try self.send(.{ .hello = .{ .protocol = wire.version, .client = pkg.name ++ " " ++ pkg.version } });
        const answer = self.next(self.hello_arena.allocator()) catch null;
        const frame = answer orelse {
            if (diagnostic) |d| d.say("no session server answered on {s}", .{host});
            return error.NoAnswer;
        };
        if (frame.body != .hello) {
            if (diagnostic) |d| d.say("{s} did not start with hello", .{host});
            return error.NoAnswer;
        }
        const theirs = frame.body.hello.protocol;
        if (theirs != wire.version) {
            if (diagnostic) |d| d.say("{s} speaks protocol {d}, this {s} speaks {d}: update {s} {s}", .{
                host,
                theirs,
                pkg.name,
                wire.version,
                pkg.name,
                if (theirs < wire.version) host else "here",
            });
            return error.ProtocolMismatch;
        }
        self.server = frame.body.hello.server;
        self.outdated = frame.body.hello.outdated;
    }

    /// Send a request, returning the id its reply will carry.
    pub fn send(self: *Connection, body: wire.Up) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        try wire.encode(self.writer(), wire.Frame(wire.Up){ .id = id, .body = body });
        try self.writer().flush();
        return id;
    }

    /// The next frame, decoded into `arena`, or null once the server is gone.
    /// Frames of types this build does not know are skipped.
    pub fn next(self: *Connection, arena: std.mem.Allocator) !?wire.Frame(wire.Down) {
        while (true) {
            const line = try self.lines.next(self.reader()) orelse return null;
            const copy = try arena.dupe(u8, line);
            if (try wire.Frame(wire.Down).decode(arena, copy)) |frame| return frame;
        }
    }

    /// Send a request and wait for its reply, passing over any events. The
    /// result, when there is one, is decoded into `arena`.
    pub fn call(self: *Connection, arena: std.mem.Allocator, body: wire.Up, failure: ?*Diagnostic) !?std.json.Value {
        const id = try self.send(body);
        while (try self.next(arena)) |frame| {
            if (frame.body != .reply or frame.id != id) continue;
            const reply = frame.body.reply;
            if (reply.ok) return reply.result;
            if (failure) |d| d.say("{s}", .{reply.@"error" orelse "refused"});
            return error.Refused;
        }
        return error.ConnectionLost;
    }
};
