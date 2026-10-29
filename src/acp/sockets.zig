//! Where a session listens for clients besides the one that started it: one
//! socket per session, `<dir>/<handle>.sock`, in a directory only its owner
//! can enter. Listing live sessions is listing this directory.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const posix = std.posix;

const suffix = ".sock";

/// `$SYNTH_SOCKET_DIR`, else `/tmp/synth-<uid>`, as tmux keeps its own.
/// Neither `$TMPDIR` nor `$XDG_RUNTIME_DIR`: a nix shell or an ssh login can
/// each have a different one, where every terminal must find the same
/// sessions; and logind empties the runtime directory at logout, taking a
/// detached session's socket with it.
pub fn dir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("SYNTH_SOCKET_DIR")) |given| return allocator.dupe(u8, given);
    return std.fmt.allocPrint(allocator, "/tmp/synth-{d}", .{uid()});
}

/// Make `path` if it is missing, and refuse it unless it is a directory of
/// ours that no one else can enter: whoever can connect to a session can run
/// commands in it.
pub fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const found = try ownership(path);
    if (!found.is_dir or found.uid != uid() or found.mode & 0o077 != 0) return error.UnsafeSocketDir;
}

/// The socket a session listens on. Too long a path for a socket address is
/// an error here rather than a socket bound at a truncated name.
pub fn pathFor(allocator: std.mem.Allocator, socket_dir: []const u8, handle: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}" ++ suffix, .{ socket_dir, handle });
    if (path.len >= address_room) {
        allocator.free(path);
        return error.SocketPathTooLong;
    }
    return path;
}

/// The handle a socket in the directory belongs to, or null for anything else
/// found there.
pub fn handleOf(name: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    return name[0 .. name.len - suffix.len];
}

const address_room = @typeInfo(@FieldType(posix.sockaddr.un, "path")).array.len;

/// Connect to the session listening on `path`. The caller owns the result.
///
/// Plain posix calls rather than `std.Io.net`, whose unix connect treats a
/// refusal - a dead session's socket, an answer worth having here - as an
/// unexpected errno, and prints a stack trace for it in a debug build.
pub fn connect(path: []const u8) !std.Io.File {
    var address: posix.sockaddr.un = .{ .path = undefined };
    if (path.len >= address.path.len) return error.SocketPathTooLong;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);

    const opened = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (posix.errno(opened) != .SUCCESS) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(opened);
    errdefer _ = posix.system.close(fd);
    return switch (posix.errno(posix.system.connect(fd, @ptrCast(&address), @sizeOf(posix.sockaddr.un)))) {
        .SUCCESS => .{ .handle = fd, .flags = .{ .nonblocking = false } },
        .NOENT, .CONNREFUSED => error.NotListening,
        else => error.ConnectFailed,
    };
}

/// Whether a session answers on `path` right now.
pub fn probe(io: std.Io, path: []const u8) bool {
    const file = connect(path) catch return false;
    file.close(io);
    return true;
}

/// Accepting clients on a session's socket, on a thread of its own, until
/// stopped.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    server: std.Io.net.Server,
    thread: std.Thread = undefined,
    context: *anyopaque,
    /// Takes the client over; it owns the file from here.
    accepted: *const fn (context: *anyopaque, client: std.Io.File) void,

    /// Bind `path`, replacing a socket no one answers on. A live one is
    /// `error.AlreadyListening`: that session is hosted elsewhere.
    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        context: *anyopaque,
        accepted: *const fn (context: *anyopaque, client: std.Io.File) void,
    ) !*Listener {
        if (probe(io, path)) return error.AlreadyListening;
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const address = try std.Io.net.UnixAddress.init(path);
        var server = try address.listen(io, .{});
        errdefer {
            server.deinit(io);
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
        }
        try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{});

        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .path = try allocator.dupe(u8, path),
            .server = server,
            .context = context,
            .accepted = accepted,
        };
        errdefer allocator.free(self.path);
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// Stop accepting and remove the socket. Clients already taken are left
    /// to whoever took them.
    pub fn stop(self: *Listener) void {
        // Closing a listener leaves `accept` blocked on a dead descriptor; `shutdown` wakes it.
        _ = posix.system.shutdown(self.server.socket.handle, posix.SHUT.RDWR);
        self.thread.join();
        self.server.deinit(self.io);
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *Listener) void {
        while (true) {
            const stream = self.server.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return,
            };
            if (!peerIsUs(stream.socket.handle)) {
                stream.close(self.io);
                continue;
            }
            self.accepted(self.context, .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = false } });
        }
    }
};

/// Refuse a peer whose uid is not ours. `SO_PEERCRED` is Linux; elsewhere the
/// owner-only directory and socket are the whole defence.
fn peerIsUs(fd: posix.fd_t) bool {
    if (builtin.os.tag != .linux) return true;
    const linux = std.os.linux;
    const Credentials = extern struct { pid: i32, uid: u32, gid: u32 };
    var peer: Credentials = undefined;
    var len: posix.socklen_t = @sizeOf(Credentials);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&peer), &len);
    if (linux.errno(rc) != .SUCCESS) return false;
    return peer.uid == linux.getuid();
}

fn uid() posix.uid_t {
    return if (builtin.os.tag == .linux) std.os.linux.getuid() else std.c.getuid();
}

const Ownership = struct { is_dir: bool, uid: posix.uid_t, mode: u32 };

/// Who owns `path` and what it lets others do, without following a link: a
/// link planted where the directory should be is refused, not trusted.
fn ownership(path: []const u8) !Ownership {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buffer, "{s}", .{path});
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var found: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &found);
        if (linux.errno(rc) != .SUCCESS) return error.StatFailed;
        return .{ .is_dir = linux.S.ISDIR(found.mode), .uid = found.uid, .mode = found.mode & 0o7777 };
    }
    var found: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, name, &found, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.StatFailed;
    return .{ .is_dir = std.c.S.ISDIR(found.mode), .uid = found.uid, .mode = @intCast(found.mode & 0o7777) };
}

fn tmpPath(tmp: *testing.TmpDir, buffer: []u8, name: []const u8) ![]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ root[0..n], name });
}

test "a socket directory is made private, and refused once others can enter it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer, "sockets");

    try ensureDir(testing.io, path);
    try ensureDir(testing.io, path);
    try testing.expectEqual(@as(u32, 0o700), (try ownership(path)).mode);

    var opened = try std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
    defer opened.close(testing.io);
    try opened.setPermissions(testing.io, .fromMode(0o755));
    try testing.expectError(error.UnsafeSocketDir, ensureDir(testing.io, path));
}

test "a socket path that will not fit an address is refused, not cut short" {
    const long = "/tmp/" ++ "d" ** 100;
    try testing.expectError(error.SocketPathTooLong, pathFor(testing.allocator, long, "ses_abcdefgh"));
    const fits = try pathFor(testing.allocator, "/tmp/synth-1000", "ses_abcdefgh");
    defer testing.allocator.free(fits);
    try testing.expectEqualStrings("ses_abcdefgh", handleOf(std.fs.path.basename(fits)).?);
}

test "a listener hands over who connects, and leaves no socket behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer, "ses_test.sock");

    const Taken = struct {
        got: std.atomic.Value(i32) = .init(-1),
        fn accepted(context: *anyopaque, client: std.Io.File) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const before = self.got.swap(client.handle, .acq_rel);
            if (before >= 0) _ = posix.system.close(before);
        }
    };
    var taken: Taken = .{};
    try testing.expect(!probe(testing.io, path));
    const listener = try Listener.start(testing.allocator, testing.io, path, &taken, Taken.accepted);
    try testing.expectError(error.AlreadyListening, Listener.start(testing.allocator, testing.io, path, &taken, Taken.accepted));

    const client = try connect(path);
    defer client.close(testing.io);
    for (0..500) |_| {
        if (taken.got.load(.acquire) >= 0) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
    const server_end = taken.got.load(.acquire);
    try testing.expect(server_end >= 0);
    _ = posix.system.close(server_end);

    listener.stop();
    try testing.expectError(error.NotListening, connect(path));
}
