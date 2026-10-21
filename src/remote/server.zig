//! The session server: one per user on a machine, listening on a unix socket.
//!
//! Every hosted session runs on a worker thread of its own, which owns its
//! loop, its database connection and its provider client, and is the only
//! thread that touches them. Clients reach a session through its inbox -
//! attaching included - so a snapshot and the events after it are cut from
//! one consistent view, with nothing lost or repeated between the two.
//!
//! Each client has a reader thread, which decodes frames and routes them, and
//! a writer thread, which drains one outbox. Replies and events share that
//! outbox, so a client sees them in the order they were produced.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const pkg = @import("pkg");
const mcp = @import("mcp");

const wire = @import("wire.zig");
const Config = @import("../core/config.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const mention = @import("../core/mention.zig");
const Project = @import("../core/project.zig");
const skill = @import("../core/skill.zig");
const skill_tool = @import("../tools/skill.zig");
const project_files = @import("../core/files.zig");
const Loop = @import("../agent/loop.zig");
const Stack = @import("../agent/stack.zig");
const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const SignInTask = @import("../provider/chatgpt_sign_in.zig");
const SignOutTask = @import("../provider/chatgpt_sign_out.zig");
const Providers = @import("providers.zig");
const mcp_tools = @import("../tools/mcp.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const Provider = @import("../provider/provider.zig");

const Server = @This();

/// Messages a session keeps in memory, as the TUI does. Older ones stay in
/// the database and page back in on request.
const max_messages: usize = 200;

/// How often a busy session is polled. An idle one sleeps until told to act.
const poll_interval: std.Io.Duration = .fromMilliseconds(20);

/// What a client may have queued and unsent before it is cut off. A client
/// that falls this far behind reattaches and starts from a fresh snapshot,
/// rather than the server holding an unbounded backlog for it.
const max_outbox_bytes: usize = 64 * 1024 * 1024;

/// Where each session's provider client comes from.
pub const Source = union(enum) {
    /// Each session spawns a client of its own from this one: a client is
    /// single-writer, and sessions run turns at the same time.
    providers: *Providers,
    /// Every session answers through this provider. For tests, whose fake
    /// providers keep no per-request state.
    provider: Provider,
};

pub const Options = struct {
    config: *const Config,
    /// Where to listen. The lock file sits next to it.
    socket_path: []const u8,
    /// The database sessions persist to. Each worker opens its own connection.
    database_path: []const u8,
    source: Source,
    home: ?[]const u8 = null,
    /// Where MCP tokens and on/off choices are kept. Each session reads its
    /// own copy: the store has no lock, and sessions connect at once.
    mcp_auth_path: ?[]const u8 = null,
    /// The program file the server runs, to notice it being replaced.
    executable: ?[]const u8 = null,
    /// Called when a client asks the server to stop, to let it go.
    on_shutdown: ?*const fn () void = null,
    /// How long a session with nothing to do and nobody attached stays
    /// loaded. It stays stored after, and attaching loads it again.
    idle_unload: std.Io.Duration = .fromSeconds(5 * 60),
};

allocator: std.mem.Allocator,
io: std.Io,
options: Options,
/// Owned copy of `options.socket_path`.
path: []u8,
listener: std.Io.net.Server,
accept_thread: std.Thread = undefined,
/// The server's own connection, for creating and resolving sessions. A
/// connection is single-threaded and client threads share this one.
db: Database,
db_mutex: std.Io.Mutex = .init,
/// Guards `sessions`, `retired` and `clients`.
mutex: std.Io.Mutex = .init,
sessions: std.ArrayList(*Hosted) = .empty,
/// What the program file looked like at start, while `options.executable` is set.
started_from: ?Build = null,
/// Sessions taken out of the list, unloading or stopped, until their worker
/// is joined. Loading one again waits for it to finish first.
retired: std.ArrayList(*Hosted) = .empty,
clients: std.ArrayList(*Client) = .empty,

/// `$XDG_RUNTIME_DIR/<name>/server.sock` where the machine has a runtime
/// directory (tmpfs, gone on reboot, which is right for a socket), else the
/// state directory.
pub fn socketPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_RUNTIME_DIR")) |runtime| {
        return std.fs.path.join(allocator, &.{ runtime, pkg.name, "server.sock" });
    }
    return Config.dataPath(allocator, env, "server.sock");
}

/// Whether something answers on `path` right now.
///
/// Connects with plain posix calls rather than `std.Io.net`, whose unix connect
/// treats a refusal - a dead server's socket, the very answer asked for here -
/// as an unexpected errno, and prints a stack trace for it in a debug build.
pub fn probe(path: []const u8) bool {
    const posix = std.posix;
    var address: posix.sockaddr.un = .{ .path = undefined };
    if (path.len >= address.path.len) return false;
    @memset(&address.path, 0);
    @memcpy(address.path[0..path.len], path);

    const cloexec: u32 = if (std.Io.Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
    const opened = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM | cloexec, 0);
    if (posix.errno(opened) != .SUCCESS) return false;
    const fd: posix.fd_t = @intCast(opened);
    defer _ = posix.system.close(fd);
    return posix.errno(posix.system.connect(fd, @ptrCast(&address), @sizeOf(posix.sockaddr.un))) == .SUCCESS;
}

/// Bind the socket and start accepting. A live server already on the path is
/// `error.AlreadyRunning`; a dead one's socket file is replaced.
pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Server {
    const path = try allocator.dupe(u8, options.socket_path);
    errdefer allocator.free(path);
    try Config.ensureDir(io, path);
    try restrictDir(io, path);

    // Held across probe and bind, so two servers starting at once cannot both bind.
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    defer allocator.free(lock_path);
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive });
    defer lock.close(io);

    if (probe(path)) return error.AlreadyRunning;
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.Io.net.UnixAddress.init(path);
    var listener = try address.listen(io, .{});
    errdefer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    try restrictSocket(io, path);

    var db = try Database.init(allocator, io, options.database_path);
    errdefer db.deinit();

    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .options = options,
        .path = path,
        .listener = listener,
        .db = db,
        .started_from = if (options.executable) |file| Build.of(io, file) else null,
    };
    self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    return self;
}

/// Stop accepting, hang up on every client, end every session, and remove
/// the socket file.
pub fn stop(self: *Server) void {
    // Closing a listener leaves `accept` blocked on a dead descriptor; `shutdown` wakes it.
    _ = std.posix.system.shutdown(self.listener.socket.handle, std.posix.SHUT.RDWR);
    self.accept_thread.join();
    self.listener.deinit(self.io);
    std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};

    self.mutex.lockUncancelable(self.io);
    var clients = self.clients;
    self.clients = .empty;
    for (clients.items) |client| client.hangUp();
    self.mutex.unlock(self.io);
    for (clients.items) |client| client.destroy();
    clients.deinit(self.allocator);

    self.mutex.lockUncancelable(self.io);
    var sessions = self.sessions;
    self.sessions = .empty;
    self.mutex.unlock(self.io);
    for (sessions.items) |hosted| hosted.end();
    sessions.deinit(self.allocator);

    self.mutex.lockUncancelable(self.io);
    var retired = self.retired;
    self.retired = .empty;
    self.mutex.unlock(self.io);
    for (retired.items) |hosted| hosted.reap();
    retired.deinit(self.allocator);

    self.db.deinit();
    self.allocator.free(self.path);
    self.allocator.destroy(self);
}

/// A build of the program, told apart by its file.
const Build = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: i96,

    fn of(io: std.Io, path: []const u8) ?Build {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds };
    }
};

/// Whether the program file has been replaced since the server started.
fn outdated(self: *Server) bool {
    const file = self.options.executable orelse return false;
    const started = self.started_from orelse return false;
    const now = Build.of(self.io, file) orelse return true;
    return !std.meta.eql(started, now);
}

/// Let the server go, if nobody would notice: no session busy, and nobody
/// attached to one.
fn shutdown(self: *Server) !void {
    const let_go = self.options.on_shutdown orelse return error.NotStoppable;
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.sessions.items) |hosted| {
            if (hosted.inUse()) return error.InUse;
        }
    }
    let_go();
}

fn acceptLoop(self: *Server) void {
    while (true) {
        const stream = self.listener.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            error.ConnectionAborted => continue,
            else => return,
        };
        self.reapClients();
        self.reapSessions();
        if (!peerIsUs(stream)) {
            stream.close(self.io);
            continue;
        }
        const client = Client.create(self, stream) catch {
            stream.close(self.io);
            continue;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clients.append(self.allocator, client) catch {
            client.hangUp();
            client.destroy();
        };
    }
}

/// Free the clients that have hung up. Done as new ones arrive, so a server
/// that runs for weeks holds only the clients still connected.
fn reapClients(self: *Server) void {
    var finished: std.ArrayList(*Client) = .empty;
    defer finished.deinit(self.allocator);

    self.mutex.lockUncancelable(self.io);
    var at: usize = 0;
    while (at < self.clients.items.len) {
        const client = self.clients.items[at];
        if (!client.finished.load(.acquire)) {
            at += 1;
            continue;
        }
        finished.append(self.allocator, client) catch break;
        _ = self.clients.swapRemove(at);
    }
    self.mutex.unlock(self.io);

    for (finished.items) |client| client.destroy();
}

/// Join and free the sessions that have unloaded themselves.
fn reapSessions(self: *Server) void {
    var finished: std.ArrayList(*Hosted) = .empty;
    defer finished.deinit(self.allocator);

    self.mutex.lockUncancelable(self.io);
    var at: usize = 0;
    while (at < self.retired.items.len) {
        const hosted = self.retired.items[at];
        if (!hosted.done.isSet()) {
            at += 1;
            continue;
        }
        finished.append(self.allocator, hosted) catch break;
        _ = self.retired.swapRemove(at);
    }
    self.mutex.unlock(self.io);

    for (finished.items) |hosted| hosted.reap();
}

/// Move a session from the list to `retired`, if the list's reference is the
/// only one and nothing is queued for it. Under the mutex every new reference
/// is taken under, so no client can be on its way in.
fn retire(self: *Server, hosted: *Hosted) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (hosted.refs.load(.acquire) != 1 or !hosted.inboxEmpty()) return false;
    self.retired.ensureUnusedCapacity(self.allocator, 1) catch return false;
    const at = std.mem.indexOfScalar(*Hosted, self.sessions.items, hosted) orelse return false;
    _ = self.sessions.swapRemove(at);
    self.retired.appendAssumeCapacity(hosted);
    return true;
}

/// Refuse a peer whose uid is not ours. `SO_PEERCRED` is Linux; elsewhere the
/// owner-only directory and socket are the whole defence.
fn peerIsUs(stream: std.Io.net.Stream) bool {
    if (builtin.os.tag != .linux) return true;

    const Credentials = extern struct { pid: i32, uid: u32, gid: u32 };
    var peer: Credentials = undefined;
    var len: std.posix.socklen_t = @sizeOf(Credentials);
    const rc = linux.getsockopt(stream.socket.handle, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&peer), &len);
    if (linux.errno(rc) != .SUCCESS) return false;
    return peer.uid == linux.getuid();
}

fn restrictSocket(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o600), .{});
}

fn restrictDir(io: std.Io, socket_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(socket_path) orelse return;
    // `setPermissions` on a directory needs it opened for iteration.
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    try dir.setPermissions(io, .fromMode(0o700));
}

/// The model a new session starts on. Caller owns the result.
fn sourceModel(self: *Server, allocator: std.mem.Allocator) ![]const u8 {
    return switch (self.options.source) {
        .providers => |providers| providers.model(allocator),
        .provider => |provider| allocator.dupe(u8, provider.model),
    };
}

/// Start a session in `root`: a row for it now, so it has a handle to attach
/// by before anything is said in it, and a worker to host it.
fn open(self: *Server, root: []const u8, latest: bool) !*Hosted {
    const wanted = try resolveRoot(self.allocator, root, self.options.home);
    defer self.allocator.free(wanted);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, wanted, self.allocator);
    defer self.allocator.free(cwd);
    var project = try Project.detect(self.allocator, self.io, cwd);
    defer project.deinit(self.allocator);

    const id, const handle, const resumed = blk: {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        const project_id = try self.db.resolveProject(project.root, "git", project.name());
        if (latest) {
            if (try self.db.latestSession(project_id)) |id| break :blk .{ id, try self.db.sessionPublicId(id, self.allocator), true };
        }
        const model = try self.sourceModel(self.allocator);
        defer self.allocator.free(model);
        const id = try self.db.createSession(project_id, cwd, model);
        break :blk .{ id, try self.db.sessionPublicId(id, self.allocator), false };
    };
    defer self.allocator.free(handle);
    if (resumed) return self.acquire(handle);
    return self.host(id, handle, cwd);
}

/// Where `root` names on this machine. A client is elsewhere and cannot know
/// the server's working directory, so a relative path, or one starting `~`,
/// is taken from the home directory, as ssh would. Caller owns the result.
fn resolveRoot(allocator: std.mem.Allocator, root: []const u8, home: ?[]const u8) ![]u8 {
    const base = home orelse return allocator.dupe(u8, root);
    if (std.fs.path.isAbsolute(root)) return allocator.dupe(u8, root);
    if (std.mem.eql(u8, root, "~")) return allocator.dupe(u8, base);
    const relative = if (std.mem.startsWith(u8, root, "~/")) root[2..] else root;
    return std.fs.path.join(allocator, &.{ base, relative });
}

/// The session a handle names, hosting it from the database if it is not
/// live. The caller holds a reference and releases it.
fn acquire(self: *Server, handle: []const u8) !*Hosted {
    if (self.findLive(handle)) |hosted| return hosted;
    // What the database says about it is only settled once its last worker is done.
    self.awaitLeft(handle);

    const id, const cwd = blk: {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        const id = try self.db.sessionByHandle(handle) orelse return error.UnknownSession;
        break :blk .{ id, try self.db.sessionCwd(id, self.allocator) };
    };
    defer self.allocator.free(cwd);
    return self.host(id, handle, cwd);
}

fn findLive(self: *Server, handle: []const u8) ?*Hosted {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.sessions.items) |hosted| {
        if (std.mem.eql(u8, hosted.handle, handle)) {
            hosted.retain();
            return hosted;
        }
    }
    return null;
}

/// Start a worker for a session row and wait for it to come up. Two clients
/// asking for the same stored session at once share one worker: the second
/// finds the first's in the list, and its commands queue until it is up.
///
/// Whoever takes a session out of the list owns its join and the list's
/// reference, which is what `end` gives up.
fn host(self: *Server, id: i64, handle: []const u8, cwd: []const u8) !*Hosted {
    const hosted = spawned: while (true) {
        const old = old: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.sessions.items) |live| {
                if (live.id == id) {
                    live.retain();
                    return live;
                }
            }
            if (self.leaving(id)) |old| break :old old;

            const hosted = try Hosted.create(self, id, handle, cwd);
            errdefer hosted.release();
            try self.sessions.ensureUnusedCapacity(self.allocator, 1);
            hosted.thread = try std.Thread.spawn(.{}, Worker.run, .{hosted});
            self.sessions.appendAssumeCapacity(hosted);
            hosted.retain();
            break :spawned hosted;
        };
        old.done.waitUncancelable(self.io);
        old.release();
    };

    hosted.ready.waitUncancelable(self.io);
    const failure = hosted.failure orelse return hosted;
    if (self.forget(hosted)) hosted.end();
    hosted.release();
    return failure;
}

/// Wait until no worker for `handle` is still on its way out.
fn awaitLeft(self: *Server, handle: []const u8) void {
    while (true) {
        const old = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.retired.items) |old| {
                if (std.mem.eql(u8, old.handle, handle) and !old.done.isSet()) {
                    old.retain();
                    break :blk old;
                }
            }
            return;
        };
        old.done.waitUncancelable(self.io);
        old.release();
    }
}

/// A worker for session `id` that is still on its way out, retained. Called
/// with the mutex held.
fn leaving(self: *Server, id: i64) ?*Hosted {
    for (self.retired.items) |old| {
        if (old.id == id and !old.done.isSet()) {
            old.retain();
            return old;
        }
    }
    return null;
}

/// Take a session out of the list, so nothing new can find it. False when
/// someone else already has.
fn forget(self: *Server, hosted: *Hosted) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.sessions.items, 0..) |live, at| {
        if (live == hosted) {
            _ = self.sessions.swapRemove(at);
            return true;
        }
    }
    return false;
}

/// End a live session. Its transcript stays in the database, and loading it
/// again waits for this worker to finish.
fn stopSession(self: *Server, handle: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.sessions.items, 0..) |live, at| {
        if (!std.mem.eql(u8, live.handle, handle)) continue;
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        _ = self.sessions.swapRemove(at);
        self.retired.appendAssumeCapacity(live);
        live.exiting.store(true, .release);
        live.wake.set(self.io);
        return;
    }
    return error.UnknownSession;
}

fn summaries(self: *Server, arena: std.mem.Allocator) ![]wire.Summary {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const out = try arena.alloc(wire.Summary, self.sessions.items.len);
    for (self.sessions.items, out) |hosted, *summary| summary.* = try hosted.summary(arena);
    return out;
}

/// The live sessions, most recently touched first, then up to `stored` of
/// the most recent ones that are not loaded.
fn listing(self: *Server, arena: std.mem.Allocator, stored: u32) ![]const wire.Summary {
    const live = try self.summaries(arena);
    const recent = blk: {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        break :blk try self.db.recentSessions(arena, live.len + stored);
    };

    var out: std.ArrayList(wire.Summary) = try .initCapacity(arena, live.len + stored);
    for (live) |summary| {
        var known = summary;
        for (recent) |info| {
            if (!std.mem.eql(u8, info.public_id, summary.handle)) continue;
            known.updated_at = info.updated_at;
            known.messages = info.messages;
        }
        out.appendAssumeCapacity(known);
    }
    std.mem.sort(wire.Summary, out.items, {}, newerFirst);

    for (recent) |info| {
        if (out.items.len == live.len + stored) break;
        const loaded = for (live) |summary| {
            if (std.mem.eql(u8, summary.handle, info.public_id)) break true;
        } else false;
        if (loaded) continue;
        out.appendAssumeCapacity(.{
            .handle = info.public_id,
            .title = info.title,
            .root = info.cwd,
            .updated_at = info.updated_at,
            .messages = info.messages,
        });
    }
    return out.items;
}

fn newerFirst(_: void, a: wire.Summary, b: wire.Summary) bool {
    return a.updated_at > b.updated_at;
}

/// A command for a session's worker. Owns its frame: the line it was decoded
/// from is copied into `arena` first, so nothing points at the reader's buffer.
const Command = struct {
    arena: std.heap.ArenaAllocator,
    client: *Client,
    id: ?u64 = null,
    body: Body,
    /// Its place in an inbox. Intrusive, so queueing never allocates and a
    /// detach can never fail to arrive.
    node: std.DoublyLinkedList.Node = .{},

    const Body = union(enum) {
        request: wire.Up,
        /// Stop sending to `client`, then set the event.
        detach: *std.Io.Event,
    };

    fn create(allocator: std.mem.Allocator, client: *Client, body: Body) !*Command {
        const self = try allocator.create(Command);
        self.* = .{ .arena = .init(allocator), .client = client, .body = body };
        return self;
    }

    fn of(node: *std.DoublyLinkedList.Node) *Command {
        return @fieldParentPtr("node", node);
    }

    fn destroy(self: *Command) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    /// Answer a command the session will never run.
    fn refuse(self: *Command, io: std.Io, reason: []const u8) void {
        switch (self.body) {
            .request => self.client.replyError(self.id, reason),
            .detach => |done| done.set(io),
        }
    }
};

/// A live session as the rest of the server sees it. Counted: the session
/// list holds one reference and every attached client another, so a session
/// stopped while a client still points at it is freed by whoever lets go last.
const Hosted = struct {
    server: *Server,
    id: i64,
    handle: []u8,
    cwd: []u8,
    refs: std.atomic.Value(u32) = .init(1),
    thread: std.Thread = undefined,

    /// Set once the worker has built the session, or failed to.
    ready: std.Io.Event = .unset,
    /// Why the worker could not build it. Written before `ready`.
    failure: ?anyerror = null,

    /// Raised for every command, and by `end`.
    wake: std.Io.Event = .unset,
    exiting: std.atomic.Value(bool) = .init(false),
    /// The worker is finished with the session, and only needs joining.
    done: std.Io.Event = .unset,
    inbox_mutex: std.Io.Mutex = .init,
    inbox: std.DoublyLinkedList = .{},
    /// Once set, nothing more is queued: commands are refused on the spot.
    exited: bool = false,

    /// What a listing shows, written by the worker.
    summary_mutex: std.Io.Mutex = .init,
    title: []u8 = &.{},
    state: Loop.State = .idle,
    clients: u32 = 0,

    fn create(server: *Server, id: i64, handle: []const u8, cwd: []const u8) !*Hosted {
        const allocator = server.allocator;
        const self = try allocator.create(Hosted);
        errdefer allocator.destroy(self);
        const owned_handle = try allocator.dupe(u8, handle);
        errdefer allocator.free(owned_handle);
        self.* = .{
            .server = server,
            .id = id,
            .handle = owned_handle,
            .cwd = try allocator.dupe(u8, cwd),
        };
        return self;
    }

    fn retain(self: *Hosted) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *Hosted) void {
        const held = self.refs.fetchSub(1, .acq_rel);
        // Down to the list's: the worker starts counting toward unloading.
        if (held == 2) self.wake.set(self.server.io);
        if (held != 1) return;
        const allocator = self.server.allocator;
        std.debug.assert(self.inbox.first == null);
        allocator.free(self.title);
        allocator.free(self.handle);
        allocator.free(self.cwd);
        allocator.destroy(self);
    }

    /// Ask the worker to finish, wait for it, and drop the list's reference.
    /// The caller has already taken the session out of the list.
    fn end(self: *Hosted) void {
        self.exiting.store(true, .release);
        self.wake.set(self.server.io);
        self.reap();
    }

    /// Join the worker, which has finished or been told to, and drop the
    /// list's reference.
    fn reap(self: *Hosted) void {
        self.thread.join();
        self.release();
    }

    fn inboxEmpty(self: *Hosted) bool {
        self.inbox_mutex.lockUncancelable(self.server.io);
        defer self.inbox_mutex.unlock(self.server.io);
        return self.inbox.first == null;
    }

    /// Queue a command, or refuse it at once when the worker has gone.
    fn send(self: *Hosted, command: *Command) void {
        const io = self.server.io;
        self.inbox_mutex.lockUncancelable(io);
        const exited = self.exited;
        if (!exited) self.inbox.append(&command.node);
        self.inbox_mutex.unlock(io);

        if (exited) {
            command.refuse(io, "the session has ended");
            command.destroy();
        } else {
            self.wake.set(io);
        }
    }

    /// Everything queued, oldest first, leaving the inbox empty.
    fn take(self: *Hosted) std.DoublyLinkedList {
        self.inbox_mutex.lockUncancelable(self.server.io);
        defer self.inbox_mutex.unlock(self.server.io);
        const taken = self.inbox;
        self.inbox = .{};
        return taken;
    }

    /// Stop queueing, and refuse whatever is still waiting.
    fn abandon(self: *Hosted, reason: []const u8) void {
        self.inbox_mutex.lockUncancelable(self.server.io);
        self.exited = true;
        self.inbox_mutex.unlock(self.server.io);

        var leftover = self.take();
        while (leftover.popFirst()) |node| {
            const command = Command.of(node);
            command.refuse(self.server.io, reason);
            command.destroy();
        }
    }

    fn inUse(self: *Hosted) bool {
        self.summary_mutex.lockUncancelable(self.server.io);
        defer self.summary_mutex.unlock(self.server.io);
        return self.state != .idle or self.clients > 0;
    }

    fn summary(self: *Hosted, arena: std.mem.Allocator) !wire.Summary {
        self.summary_mutex.lockUncancelable(self.server.io);
        defer self.summary_mutex.unlock(self.server.io);
        return .{
            .handle = self.handle,
            .title = try arena.dupe(u8, self.title),
            .root = self.cwd,
            .state = self.state,
            .clients = self.clients,
            .live = true,
        };
    }
};

/// Everything a hosted session owns, on its worker thread's stack. Nothing
/// here is reachable from any other thread.
const Worker = struct {
    hosted: *Hosted,
    allocator: std.mem.Allocator,
    io: std.Io,
    db: Database = undefined,
    spawned: ?*Backend.Spawned = null,
    /// Catalog id of the provider the session answers through, which the
    /// effort chosen for each of its models is remembered under.
    provider_id: []const u8 = "",
    sign_in: ?*SignInTask = null,
    mcp_auth: ?mcp.Auth = null,
    sign_out: ?*SignOutTask = null,
    stack: *Stack = undefined,
    subscribers: std.ArrayList(*Client) = .empty,
    /// Every message sent, by seq, with a signature of the parts of it that
    /// change after it is appended.
    sent: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// The status as last sent, encoded.
    sent_status: std.ArrayList(u8) = .empty,
    /// The request whose stream was last sent, and how far.
    stream_request: u64 = 0,
    stream_thinking: usize = 0,
    stream_text: usize = 0,
    stream_closed: bool = false,
    /// Since when the session has had nothing to do and nobody attached.
    alone_since: ?std.Io.Timestamp = null,

    fn run(hosted: *Hosted) void {
        var self: Worker = .{ .hosted = hosted, .allocator = hosted.server.allocator, .io = hosted.server.io };
        self.build() catch |err| {
            hosted.failure = err;
            self.close("the session could not start");
            hosted.done.set(self.io);
            hosted.ready.set(self.io);
            return;
        };
        hosted.ready.set(self.io);
        self.serve();
        self.close("the session has ended");
        self.teardown();
        hosted.done.set(self.io);
    }

    fn build(self: *Worker) !void {
        const server = self.hosted.server;
        self.db = try Database.init(self.allocator, self.io, server.options.database_path);
        errdefer self.db.deinit();
        if (server.options.mcp_auth_path) |path| {
            self.mcp_auth = mcp.Auth.load(self.allocator, self.io, path) catch mcp.Auth.init(self.allocator);
        }
        errdefer if (self.mcp_auth) |*store| store.deinit();

        const provider: Provider, const backend: ?*Backend = switch (server.options.source) {
            .provider => |provider| .{ provider, null },
            .providers => |providers| blk: {
                self.spawned, self.provider_id = try providers.spawn(self.allocator);
                break :blk .{ self.spawned.?.provider(), &self.spawned.?.backend };
            },
        };
        errdefer if (self.spawned) |spawned| spawned.deinit();

        self.stack = try Stack.create(self.allocator, self.io, .{
            .config = server.options.config,
            .provider = provider,
            .backend = backend,
            .cwd = self.hosted.cwd,
            .home = server.options.home,
            .db = &self.db,
            .mcp_auth = if (self.mcp_auth) |*store| store else null,
        });
        errdefer self.stack.destroy();
        self.stack.convo.max_messages = max_messages;
        try self.stack.loop.resumeSession(self.hosted.id, max_messages);
        self.restoreEffort();
    }

    fn teardown(self: *Worker) void {
        if (self.sign_in) |task| task.abandon();
        if (self.sign_out) |task| task.abandon();
        // Opening a session makes its row up front; one never spoken in is not worth keeping.
        if (self.stack.convo.totalCount() == 0) self.db.deleteSession(self.hosted.id) catch {};
        self.stack.loop.requestStop();
        self.stack.destroy();
        if (self.spawned) |spawned| spawned.deinit();
        if (self.mcp_auth) |*store| store.deinit();
        self.db.deinit();
        self.subscribers.deinit(self.allocator);
        self.sent.deinit(self.allocator);
        self.sent_status.deinit(self.allocator);
    }

    fn serve(self: *Worker) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();

        while (!self.hosted.exiting.load(.acquire)) {
            self.hosted.wake.reset();
            self.drainInbox();
            self.step();
            self.publish(arena_state.allocator()) catch |err| self.broadcastNotice("Could not report progress: {s}", .{@errorName(err)});
            _ = arena_state.reset(.retain_capacity);

            const busy = self.stack.loop.isBusy() or self.stack.runner.busy() or self.sign_in != null or
                self.sign_out != null or self.stack.mcp_host.connecting();
            if (busy) {
                self.alone_since = null;
                self.hosted.wake.waitTimeout(self.io, .{ .duration = .{ .raw = poll_interval, .clock = .awake } }) catch {};
                continue;
            }
            const left = self.idleLeft() orelse {
                if (self.hosted.server.retire(self.hosted)) return;
                self.alone_since = null;
                continue;
            };
            self.hosted.wake.waitTimeout(self.io, .{ .duration = .{ .raw = left, .clock = .awake } }) catch {};
        }
    }

    /// How much longer an idle session stays loaded, or null when its time
    /// is up. Nobody attached is the list's reference being the only one.
    fn idleLeft(self: *Worker) ?std.Io.Duration {
        const grace = self.hosted.server.options.idle_unload;
        if (self.stack.loop.state != .idle or self.hosted.refs.load(.acquire) != 1) {
            self.alone_since = null;
            return grace;
        }
        const now = std.Io.Clock.now(.awake, self.io);
        const since = self.alone_since orelse now;
        self.alone_since = since;
        const waited = since.durationTo(now);
        if (waited.nanoseconds >= grace.nanoseconds) return null;
        return .fromNanoseconds(grace.nanoseconds - waited.nanoseconds);
    }

    /// Tell the subscribers they are on their own, then stop taking commands.
    /// In that order: refusing a queued detach lets its client go, and a
    /// client that has gone must no longer be a subscriber.
    fn close(self: *Worker, reason: []const u8) void {
        for (self.subscribers.items) |client| client.send(.{ .body = .{ .ended = .{} } });
        self.subscribers.clearRetainingCapacity();
        self.hosted.abandon(reason);
    }

    fn drainInbox(self: *Worker) void {
        var commands = self.hosted.take();
        while (commands.popFirst()) |node| {
            const command = Command.of(node);
            defer command.destroy();
            switch (command.body) {
                .detach => |done| {
                    self.unsubscribe(command.client);
                    done.set(self.io);
                },
                .request => |request| self.perform(command.client, command.id, request, command.arena.allocator()) catch |err| {
                    command.client.replyError(command.id, describe(err));
                },
            }
        }
    }

    fn perform(self: *Worker, client: *Client, id: ?u64, request: wire.Up, arena: std.mem.Allocator) !void {
        const loop = &self.stack.loop;
        switch (request) {
            .attach => |attach| return self.subscribe(client, id, attach.history, arena),
            .submit => |submit| {
                if (loop.isBusy()) {
                    _ = try loop.steer(submit.text);
                } else {
                    const attachments = try arena.alloc(mention.Attachment, submit.attachments.len);
                    for (submit.attachments, attachments) |attachment, *out| out.* = .{
                        .path = attachment.path,
                        .content = attachment.content,
                        .content_bytes = attachment.content_bytes,
                    };
                    try loop.submit(submit.text, .{ .attachments = attachments, .images = submit.images });
                }
            },
            .steer => |steer| _ = try loop.steer(steer.text),
            .cancel => try loop.cancel(),
            .decide => |decide| try loop.decide(decide.decision),
            .answer => |answer| try loop.answer(answer.text),
            .compact => try loop.compact(),
            .rename => |rename| try loop.rename(rename.title),
            .use_agent => |use| try loop.useAgent(use.agent),
            .run_skill => |invoked| {
                if (loop.isBusy()) return error.Busy;
                const found = skill.findIn(self.stack.skills.skills, skill.idOf(invoked.line)) orelse return error.UnknownSkill;
                const attachment: mention.Attachment = .{
                    .path = try std.fs.path.join(arena, &.{ found.dir, skill.file_name }),
                    .content = try skill_tool.render(arena, found),
                };
                try loop.submit(invoked.line, .{ .attachments = &.{attachment} });
            },
            .set_model => |set| {
                const switching = if (set.provider_id) |wanted| !std.mem.eql(u8, wanted, self.provider_id) else false;
                if (switching) {
                    if (loop.isBusy()) return error.Busy;
                    try self.useProvider(catalog.find(set.provider_id.?) orelse return error.UnknownProvider, null, null);
                }
                try loop.switchModel(set.model);
                self.rememberModel();
                if (set.effort) |level| try self.chooseEffort(level) else self.restoreEffort();
                if (switching) self.announceProvider();
            },
            .providers => return client.reply(id, try (try self.providerSource()).states(arena, &self.db, self.provider_id)),
            .connect_provider => |asked| try self.connectProvider(asked.provider, asked.host, asked.key),
            .cancel_sign_in => if (self.sign_in) |task| task.cancel(),
            .toggle_mcp => |toggle| try self.toggleMcp(toggle.name),
            .sign_out => try self.signOut(),
            .set_effort => |set| {
                if (loop.isBusy()) return error.Busy;
                try self.chooseEffort(set.effort);
            },
            .models => |asked| return client.reply(id, try self.models(arena, asked.recent)),
            .load_tool_result => |load| return client.reply(id, try self.loadToolResult(arena, load.seq, load.call)),
            .load_thinking => |load| return client.reply(id, try self.loadThinking(arena, load.seq)),
            .load_attachment => |load| return client.reply(id, try self.loadAttachment(arena, load.seq, load.index)),
            .page_history => |page| return client.reply(id, try self.loadHistory(arena, page.before_seq, page.limit)),
            .subagent => |asked| return client.reply(id, try self.subagentTranscript(arena, asked.seq, asked.call)),
            .sessions => |asked| return client.reply(id, try self.storedSessions(arena, asked.limit)),
            .search => |query| return client.reply(id, try self.search(arena, query.query, query.limit)),
            .hello, .list, .open, .detach, .stop, .files, .shutdown => return error.NotASessionCommand,
        }
        client.reply(id, {});
    }

    fn subscribe(self: *Worker, client: *Client, id: ?u64, history: u32, arena: std.mem.Allocator) !void {
        try self.subscribers.ensureUnusedCapacity(self.allocator, 1);
        // What older subscribers are owed goes first, so the snapshot starts where events resume.
        try self.publish(arena);

        const messages = self.stack.convo.messages.items;
        const kept = messages[messages.len - @min(messages.len, history) ..];
        const wired = try arena.alloc(wire.Message, kept.len);
        for (kept, wired) |*msg, *out| out.* = try wire.Message.from(arena, msg);

        const loop = &self.stack.loop;
        const stream: ?wire.Stream = if (loop.request) |request| .{
            .request = self.stream_request,
            .thinking = try request.thoughts.copyRange(arena, 0, self.stream_thinking),
            .text = try request.content.copyRange(arena, 0, self.stream_text),
            .closed = self.stream_closed,
        } else null;

        const skills = try arena.alloc(wire.Skill, self.stack.skills.skills.len);
        for (self.stack.skills.skills, skills) |found, *out| out.* = .{
            .id = found.id,
            .name = found.name,
            .description = found.description,
            .dir = found.dir,
        };

        client.send(.{ .body = .{ .snapshot = .{
            .status = try self.currentStatus(arena),
            .messages = wired,
            .dropped = self.stack.convo.dropped + (messages.len - kept.len),
            .stream = stream,
            .skills = .{ .found = skills, .looked_in = self.stack.skills.paths },
        } } });
        self.subscribers.appendAssumeCapacity(client);
        self.recordClients();
        client.reply(id, {});
    }

    fn unsubscribe(self: *Worker, client: *Client) void {
        for (self.subscribers.items, 0..) |subscriber, at| {
            if (subscriber == client) {
                _ = self.subscribers.swapRemove(at);
                break;
            }
        }
        self.recordClients();
    }

    fn recordClients(self: *Worker) void {
        self.hosted.summary_mutex.lockUncancelable(self.io);
        defer self.hosted.summary_mutex.unlock(self.io);
        self.hosted.clients = @intCast(self.subscribers.items.len);
    }

    /// Advance the session, and do what a TUI's tick does for a local one:
    /// compact when the context is filling, and start the next turn from
    /// whatever was typed while the last one ran.
    fn step(self: *Worker) void {
        const loop = &self.stack.loop;
        _ = self.stack.runner.poll() catch |err| self.broadcastNotice("Subagent failed: {s}", .{@errorName(err)});
        _ = loop.poll() catch |err| self.broadcastNotice("The turn failed: {s}", .{@errorName(err)});

        if (loop.takeHookNotice()) |notice| {
            defer self.allocator.free(notice);
            self.broadcast(.{ .body = .{ .notice = .{ .text = notice } } });
        }
        self.settleSignOut();
        self.settleMcp();
        if (loop.isBusy()) return;
        self.settleSignIn();
        if (loop.shouldCompact()) {
            loop.compact() catch |err| self.broadcastNotice("Could not compact: {s}", .{@errorName(err)});
            return;
        }
        if (loop.takeSteering()) |prompt| {
            defer self.allocator.free(prompt);
            loop.submit(prompt, .{}) catch |err| self.broadcastNotice("Could not start the next turn: {s}", .{@errorName(err)});
        }
    }

    /// Send whatever changed since the last call: new and changed messages,
    /// the streaming request, and the status.
    fn publish(self: *Worker, arena: std.mem.Allocator) !void {
        const convo = &self.stack.convo;
        for (convo.messages.items) |*msg| {
            const mark = signature(msg);
            const entry = try self.sent.getOrPut(self.allocator, msg.seq);
            if (entry.found_existing and entry.value_ptr.* == mark) continue;
            const message = try wire.Message.from(arena, msg);
            self.broadcast(.{ .body = if (entry.found_existing)
                .{ .updated = .{ .message = message } }
            else
                .{ .appended = .{ .message = message } } });
            entry.value_ptr.* = mark;
        }
        if (self.sent.count() > convo.messages.items.len) try self.forgetTrimmed(arena);

        try self.publishStream(arena);

        const status = try self.currentStatus(arena);
        var encoded: std.Io.Writer.Allocating = .init(arena);
        try wire.encode(&encoded.writer, wire.Frame(wire.Down){ .body = .{ .status = status } });
        if (!std.mem.eql(u8, encoded.written(), self.sent_status.items)) {
            for (self.subscribers.items) |client| client.push(encoded.written());
            self.sent_status.clearRetainingCapacity();
            try self.sent_status.appendSlice(self.allocator, encoded.written());
            self.recordSummary(status);
        }
    }

    fn forgetTrimmed(self: *Worker, arena: std.mem.Allocator) !void {
        const first = self.stack.convo.firstSeq() orelse std.math.maxInt(u64);
        var trimmed: std.ArrayList(u64) = .empty;
        var it = self.sent.keyIterator();
        while (it.next()) |seq| {
            if (seq.* < first) try trimmed.append(arena, seq.*);
        }
        for (trimmed.items) |seq| _ = self.sent.remove(seq);
    }

    fn publishStream(self: *Worker, arena: std.mem.Allocator) !void {
        const loop = &self.stack.loop;
        const request = loop.request orelse return;
        if (loop.requests_started != self.stream_request) {
            self.stream_request = loop.requests_started;
            self.stream_thinking = 0;
            self.stream_text = 0;
            self.stream_closed = false;
        }
        const thinking = try request.thoughts.copyRange(arena, self.stream_thinking, null);
        const text = try request.content.copyRange(arena, self.stream_text, null);
        const closed = request.thoughts.isClosed();
        if (thinking.len == 0 and text.len == 0 and closed == self.stream_closed) return;

        self.broadcast(.{ .body = .{ .stream = .{
            .request = self.stream_request,
            .thinking = thinking,
            .text = text,
            .closed = closed,
        } } });
        self.stream_thinking += thinking.len;
        self.stream_text += text.len;
        self.stream_closed = closed;
    }

    fn currentStatus(self: *Worker, arena: std.mem.Allocator) !wire.Status {
        const loop = &self.stack.loop;
        const pending_call = loop.firstPending();

        var notes: []const []const u8 = &.{};
        if (loop.pending_seq) |seq| {
            const texts = try arena.alloc([]const u8, loop.notes.len);
            for (texts, 0..) |*text, index| text.* = loop.toolNote(seq, index) orelse "";
            notes = texts;
        }
        return .{
            .state = loop.state,
            .label = loop.label(),
            .title = loop.title(),
            .handle = self.hosted.handle,
            .root = self.hosted.cwd,
            .project = self.stack.project.root,
            .branch = self.stack.project.branch orelse "",
            .agent = loop.agent.id,
            .model = loop.provider.model,
            .provider = loop.provider.name,
            .provider_id = self.provider_id,
            .provider_missing = if (self.providerSource()) |providers| providers.isMissing(self.provider_id) else |_| false,
            .sign_in = if (self.sign_in) |task| .{ .url = task.sign_in.url, .port = task.sign_in.callbackPort() } else null,
            .chatgpt_signed_in = self.chatgptSignedIn(),
            .context_limit = loop.provider.context_limit,
            .switchable = loop.provider.switchable(),
            .effort = loop.provider.effort,
            .efforts = loop.provider.effortsFor(loop.provider.model).levels,
            .usage = loop.usage,
            .todos = loop.todos.items.items,
            .mcp = try self.stack.mcp_host.statuses(arena),
            .pending_seq = loop.pending_seq,
            .pending_call = if (pending_call) |index| @intCast(index) else null,
            .pending_description = self.pendingDescription(),
            .notes = notes,
            .steering = loop.pendingSteering(),
            .outcome = loop.outcome,
            .request = if (loop.request != null) loop.requests_started else null,
            .finished = loop.finished,
        };
    }

    fn chatgptSignedIn(self: *Worker) bool {
        const providers = self.providerSource() catch return false;
        const store = providers.chatgpt orelse return false;
        return store.isSignedIn();
    }

    fn pendingDescription(self: *Worker) []const u8 {
        const loop = &self.stack.loop;
        const index = loop.firstPending() orelse return "";
        const seq = loop.pending_seq orelse return "";
        const msg = self.held(seq) orelse return "";
        if (index >= msg.tool_calls.len) return "";
        const definition = self.stack.registry.get(msg.tool_calls[index].name) orelse return "";
        return definition.description;
    }

    fn recordSummary(self: *Worker, status: wire.Status) void {
        const hosted = self.hosted;
        hosted.summary_mutex.lockUncancelable(self.io);
        defer hosted.summary_mutex.unlock(self.io);
        hosted.state = status.state;
        if (std.mem.eql(u8, hosted.title, status.title)) return;
        const title = self.allocator.dupe(u8, status.title) catch return;
        self.allocator.free(hosted.title);
        hosted.title = title;
    }

    fn loadToolResult(self: *Worker, arena: std.mem.Allocator, seq: u64, index: u32) ![]const u8 {
        if (self.held(seq)) |msg| {
            if (index >= msg.tool_calls.len) return error.UnknownToolCall;
            const call = msg.tool_calls[index];
            if (call.result) |result| {
                if (result.len >= call.result_bytes) return result;
            }
        }
        const session_id = self.stack.loop.session_id orelse return error.UnknownMessage;
        return try self.db.loadToolResult(arena, session_id, @intCast(seq), index) orelse error.UnknownToolCall;
    }

    fn loadAttachment(self: *Worker, arena: std.mem.Allocator, seq: u64, index: u32) ![]const u8 {
        if (self.held(seq)) |msg| {
            if (index >= msg.attachments.len) return error.UnknownAttachment;
            if (!msg.attachments[index].shortened()) return msg.attachments[index].content;
        }
        const session_id = self.stack.loop.session_id orelse return error.UnknownMessage;
        return try self.db.loadAttachment(arena, session_id, @intCast(seq), index) orelse error.UnknownAttachment;
    }

    fn loadThinking(self: *Worker, arena: std.mem.Allocator, seq: u64) ![]const u8 {
        if (self.held(seq)) |msg| {
            if (msg.thinking) |text| {
                if (text.len >= msg.thinking_bytes) return text;
            }
        }
        const session_id = self.stack.loop.session_id orelse return error.UnknownMessage;
        return try self.db.loadThinking(arena, session_id, @intCast(seq)) orelse "";
    }

    fn loadHistory(self: *Worker, arena: std.mem.Allocator, before_seq: u64, limit: u32) ![]const wire.Message {
        const session_id = self.stack.loop.session_id orelse return &.{};
        const loaded = try self.db.loadMessages(arena, session_id, @intCast(before_seq), limit);
        std.mem.reverse(Conversation.Message, loaded);
        const out = try arena.alloc(wire.Message, loaded.len);
        for (loaded, out) |*msg, *wired| wired.* = try wire.Message.from(arena, msg);
        return out;
    }

    fn providerSource(self: *Worker) !*Providers {
        return switch (self.hosted.server.options.source) {
            .providers => |providers| providers,
            .provider => error.ProviderFixed,
        };
    }

    fn connectProvider(self: *Worker, id: []const u8, at: []const u8, key: ?[]const u8) !void {
        const providers = try self.providerSource();
        if (self.stack.loop.isBusy()) return error.Busy;
        const entry = catalog.find(id) orelse return error.UnknownProvider;
        if (entry.key == .oauth and !providers.isReady(entry)) return self.beginSignIn(providers);
        try self.useProvider(entry, at, key);
        self.announceProvider();
    }

    /// Point the session at a provider, at `host` or the one it was last
    /// reached at, and remember it as the choice for sessions to come.
    fn useProvider(self: *Worker, entry: catalog.Entry, at: ?[]const u8, key: ?[]const u8) !void {
        const providers = try self.providerSource();
        var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena_state.deinit();
        const where = at orelse try Providers.hostOf(arena_state.allocator(), &self.db, entry);

        const loop = &self.stack.loop;
        loop.provider = try providers.connect(&self.spawned.?.backend, entry, where, key);
        self.provider_id = entry.id;
        try loop.setModel(loop.provider.model);
        self.db.setProviderHost(entry.id, where) catch |err| self.broadcastNotice("Could not remember the host: {s}", .{@errorName(err)});
        self.db.setActiveProvider(entry.id) catch |err| self.broadcastNotice("Could not remember the provider: {s}", .{@errorName(err)});
        self.restoreEffort();
    }

    fn announceProvider(self: *Worker) void {
        const entry = catalog.findOrDefault(self.provider_id);
        const provider = self.stack.loop.provider;
        if (entry.key == .oauth) return self.broadcastNotice("Connected to your {s}, running {s}.", .{ entry.label, provider.model });
        self.broadcastNotice("Connected {s} at {s}, running {s}.", .{ entry.label, self.spawned.?.backend.currentHost(), provider.model });
    }

    fn beginSignIn(self: *Worker, providers: *Providers) !void {
        if (self.sign_in != null) return;
        const store = providers.chatgpt orelse return error.NoCredentialStore;
        self.sign_in = SignInTask.start(self.allocator, self.io, store) catch |err| {
            return self.broadcastNotice("{s}", .{SignInTask.explain(err)});
        };
    }

    /// Once the browser has come back, between turns: connect, or say why not.
    fn settleSignIn(self: *Worker) void {
        const task = self.sign_in orelse return;
        if (!task.isFinished()) return;
        self.sign_in = null;
        task.finish() catch |err| return self.broadcastNotice("{s}", .{SignInTask.explain(err)});

        const entry = catalog.find(catalog.chatgpt_id).?;
        self.useProvider(entry, entry.host, null) catch |err| {
            return self.broadcastNotice("Could not reach {s}: {s}", .{ entry.label, @errorName(err) });
        };
        self.announceProvider();
        self.welcomeToPlanUsage();
    }

    /// Said once, the first time this installation signs in.
    fn welcomeToPlanUsage(self: *Worker) void {
        const welcomed_key = "chatgpt:welcomed";
        var buffer: [16]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const welcomed = self.db.setting(fixed.allocator(), welcomed_key) catch "";
        if (welcomed.len > 0) return;
        self.broadcastNotice("You're using your ChatGPT plan. Requests in synth count toward its usage. Manage usage with /usage or at {s}", .{chatgpt_auth.usage_url});
        self.db.setSetting(welcomed_key, "1") catch {};
    }

    fn signOut(self: *Worker) !void {
        const providers = try self.providerSource();
        const store = providers.chatgpt orelse return error.NoCredentialStore;
        if (self.sign_out != null) return;
        if (!store.isSignedIn()) return self.broadcastNotice("Not signed in to ChatGPT.", .{});
        self.sign_out = try SignOutTask.start(self.allocator, self.io, store);
    }

    fn settleSignOut(self: *Worker) void {
        const task = self.sign_out orelse return;
        if (!task.isFinished()) return;
        self.sign_out = null;
        const confirmed = task.finish() catch |err| return self.broadcastNotice("Could not sign out of ChatGPT: {s}", .{@errorName(err)});
        self.broadcastNotice("{s}", .{if (confirmed)
            "Signed out of ChatGPT."
        else
            "Signed out of ChatGPT here, but OpenAI did not confirm it. You can disconnect synth in ChatGPT settings."});

        const providers = self.providerSource() catch return;
        providers.signedOut();
        if (std.mem.eql(u8, self.provider_id, catalog.chatgpt_id)) {
            self.db.setActiveProvider("") catch |err| self.broadcastNotice("Could not clear the provider: {s}", .{@errorName(err)});
        }
    }

    fn toggleMcp(self: *Worker, name: []const u8) !void {
        const mcp_host = &self.stack.mcp_host;
        const server = for (mcp_host.servers) |server| {
            if (std.mem.eql(u8, server.name, name)) break server;
        } else return error.UnknownServer;
        if (mcp_host.connecting()) return error.StillConnecting;
        const store = mcp_host.auth orelse return error.NoMcpState;

        const wanted = mcp_host.wants(server);
        try store.setEnabled(server.name, !wanted);
        store.save(self.io, null) catch |err| self.broadcastNotice("Could not remember that: {s}", .{@errorName(err)});
        if (wanted) {
            if (mcp_host.disconnect(&self.stack.registry, server.name)) try self.stack.loop.useAgent(self.stack.loop.agent.id);
        } else {
            try mcp_host.beginConnectAll(mcp_host.servers, mcp_host.client);
        }
    }

    /// Once servers turned on have been reached: offer their tools, and say
    /// which would not come up.
    fn settleMcp(self: *Worker) void {
        const mcp_host = &self.stack.mcp_host;
        if (!mcp_host.settled()) return;
        const added = mcp_host.install(&self.stack.registry) catch 0;
        if (added > 0) self.stack.loop.useAgent(self.stack.loop.agent.id) catch |err| {
            self.broadcastNotice("Could not offer the new tools: {s}", .{@errorName(err)});
        };
        for (mcp_host.failures.items) |failure| self.broadcastNotice("MCP server {s} failed: {s}", .{ failure.server, failure.reason });
    }

    /// Have sessions to come start on the model this one switched to, which
    /// is what the next launch did when each TUI ran its own session.
    fn rememberModel(self: *Worker) void {
        const model = self.stack.loop.provider.model;
        if (model.len == 0) return;
        const key = std.fmt.allocPrint(self.allocator, "model:{s}", .{self.provider_id}) catch return;
        defer self.allocator.free(key);
        self.db.setSetting(key, model) catch |err| self.broadcastNotice("Could not remember the model: {s}", .{@errorName(err)});
        const providers = self.providerSource() catch return;
        providers.useModel(self.provider_id, model) catch |err| self.broadcastNotice("New sessions stay on the old model: {s}", .{@errorName(err)});
    }

    /// Put the model back on the effort last chosen for it, or its default.
    fn restoreEffort(self: *Worker) void {
        const loop = &self.stack.loop;
        const remembered = self.db.rememberedEffort(self.allocator, self.provider_id, loop.provider.model) catch "";
        defer self.allocator.free(remembered);
        loop.setEffort(remembered);
    }

    fn chooseEffort(self: *Worker, level: []const u8) !void {
        const loop = &self.stack.loop;
        loop.setEffort(level);
        try self.db.rememberEffort(self.allocator, self.provider_id, loop.provider.model, level);
    }

    fn models(self: *Worker, arena: std.mem.Allocator, recent: u32) !wire.Models {
        const provider = self.stack.loop.provider;
        const offered = switch (self.hosted.server.options.source) {
            .providers => |providers| try providers.offered(arena, &self.db, provider, self.provider_id),
            .provider => try Providers.offeredBy(arena, &self.db, self.provider_id, provider.name, provider),
        };
        const project_id = self.stack.loop.project_id orelse return .{ .offered = offered };
        return .{ .offered = offered, .recent = try self.db.recentModels(arena, project_id, recent) };
    }

    fn storedSessions(self: *Worker, arena: std.mem.Allocator, limit: u32) ![]const wire.Stored {
        const project_id = self.stack.loop.project_id orelse return &.{};
        const stored = try self.db.listSessions(arena, project_id, limit);
        const out = try arena.alloc(wire.Stored, stored.len);
        for (stored, out) |info, *wired| wired.* = .{
            .handle = info.public_id,
            .title = info.title,
            .updated_at = info.updated_at,
            .messages = info.messages,
        };
        return out;
    }

    fn search(self: *Worker, arena: std.mem.Allocator, query: []const u8, limit: u32) ![]const wire.Hit {
        const project_id = self.stack.loop.project_id orelse return &.{};
        const hits = try self.db.search(arena, project_id, query, limit);
        const out = try arena.alloc(wire.Hit, hits.len);
        for (hits, out) |hit, *wired| wired.* = .{
            .handle = hit.public_id,
            .title = hit.title,
            .role = hit.role,
            .excerpt = hit.excerpt,
        };
        return out;
    }

    /// The transcript of the subagent call `index` of message `seq` ran: in
    /// memory while it runs, from the database once it has answered.
    fn subagentTranscript(self: *Worker, arena: std.mem.Allocator, seq: u64, index: u32) !wire.Transcript {
        const loop = &self.stack.loop;
        if (loop.pending_seq == seq) {
            if (self.stack.runner.viewable(index)) |child| {
                const messages = child.convo.messages.items;
                const out = try arena.alloc(wire.Message, messages.len);
                for (messages, out) |*msg, *wired| wired.* = try wire.Message.from(arena, msg);
                return .{ .live = true, .messages = out };
            }
        }

        const session_id = loop.session_id orelse return error.NoTranscript;
        const message = try self.db.messageId(session_id, @intCast(seq)) orelse return error.NoTranscript;
        const call = try self.db.toolCallId(message, index) orelse return error.NoTranscript;
        const child = try self.db.subagentSession(call) orelse return error.NoTranscript;
        const loaded = try self.db.loadMessages(arena, child, std.math.maxInt(i64), max_messages);
        std.mem.reverse(Conversation.Message, loaded);
        const out = try arena.alloc(wire.Message, loaded.len);
        for (loaded, out) |*msg, *wired| wired.* = try wire.Message.from(arena, msg);
        return .{ .messages = out };
    }

    fn held(self: *Worker, seq: u64) ?*const Conversation.Message {
        for (self.stack.convo.messages.items) |*msg| {
            if (msg.seq == seq) return msg;
        }
        return null;
    }

    fn broadcast(self: *Worker, frame: wire.Frame(wire.Down)) void {
        for (self.subscribers.items) |client| client.send(frame);
    }

    fn broadcastNotice(self: *Worker, comptime fmt: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, fmt, args) catch fmt;
        self.broadcast(.{ .body = .{ .notice = .{ .text = text } } });
    }
};

/// Listed here rather than on the session's worker: a large tree takes a
/// while, and a turn should not wait on it.
fn projectFiles(server: *Server, arena: std.mem.Allocator, cwd: []const u8) ![]const []const u8 {
    var project = try Project.detect(server.allocator, server.io, cwd);
    defer project.deinit(server.allocator);
    return project_files.list(arena, server.io, project.root, .{ .directories = true });
}

/// Why a request failed, for the person who made it.
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownSession => "no such session",
        error.FileNotFound => "no such directory",
        error.NotDir => "not a directory",
        error.ModelFixed => "this provider has only the one model",
        error.NotASessionCommand => "not a session command",
        error.Busy => "finish the turn first",
        error.UnknownSkill => "no such skill",
        error.InUse => "a session is busy or attached",
        error.NotStoppable => "this server cannot be stopped from here",
        error.ProviderFixed => "this server's provider is fixed",
        error.UnknownProvider => "no such provider",
        error.NoCredentialStore => "no ChatGPT credential file could be opened",
        error.UnknownServer => "no such MCP server",
        error.UnknownAttachment => "no such attachment",
        error.NoTranscript => "that call left no transcript",
        error.StillConnecting => "still connecting - try again in a moment",
        error.NoMcpState => "no MCP state file, so this cannot be remembered",
        else => @errorName(err),
    };
}

/// What can change about a message once it is in the transcript: calls
/// settle, and heavy bodies shrink to previews once they are persisted.
fn signature(msg: *const Conversation.Message) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, msg.text.len);
    std.hash.autoHash(&hasher, if (msg.thinking) |text| text.len else 0);
    std.hash.autoHash(&hasher, msg.thinking_ms);
    for (msg.tool_calls) |call| {
        std.hash.autoHash(&hasher, call.status);
        std.hash.autoHash(&hasher, if (call.result) |result| result.len else 0);
        std.hash.autoHash(&hasher, call.result_bytes);
        std.hash.autoHash(&hasher, call.elapsed_ms);
    }
    for (msg.attachments) |attachment| std.hash.autoHash(&hasher, attachment.content.len);
    return hasher.final();
}

/// One connection.
const Client = struct {
    server: *Server,
    stream: std.Io.net.Stream,
    reader_thread: std.Thread = undefined,
    writer_thread: std.Thread = undefined,
    read_buffer: []u8,
    /// Raised once the reader is done with everything but being freed.
    finished: std.atomic.Value(bool) = .init(false),
    /// The session this connection drives, and the command that will leave
    /// it, made up front so leaving never fails. Reader thread only.
    attached: ?*Hosted = null,
    leave: ?*Command = null,
    left: std.Io.Event = .unset,

    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    outbox: std.ArrayList([]u8) = .empty,
    outbox_bytes: usize = 0,
    /// No more is sent: the client hung up, fell too far behind, or the
    /// server is stopping.
    closing: bool = false,

    fn create(server: *Server, stream: std.Io.net.Stream) !*Client {
        const allocator = server.allocator;
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);
        self.* = .{
            .server = server,
            .stream = stream,
            .read_buffer = try allocator.alloc(u8, wire.max_line),
        };
        errdefer allocator.free(self.read_buffer);

        self.writer_thread = try std.Thread.spawn(.{}, writeLoop, .{self});
        errdefer {
            self.close();
            self.writer_thread.join();
        }
        self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    /// Join both threads and free. The reader must be on its way out: it
    /// has finished, or `hangUp` has cut its socket.
    fn destroy(self: *Client) void {
        const allocator = self.server.allocator;
        self.reader_thread.join();
        self.writer_thread.join();
        self.stream.close(self.server.io);
        for (self.outbox.items) |line| allocator.free(line);
        self.outbox.deinit(allocator);
        allocator.free(self.read_buffer);
        allocator.destroy(self);
    }

    /// Cut the connection from outside, which ends the reader's read.
    fn hangUp(self: *Client) void {
        self.stream.shutdown(self.server.io, .both) catch {};
    }

    fn close(self: *Client) void {
        self.mutex.lockUncancelable(self.server.io);
        defer self.mutex.unlock(self.server.io);
        self.closing = true;
        self.ready.signal(self.server.io);
    }

    /// Queue an encoded line. A client that has fallen too far behind is
    /// cut off instead.
    fn push(self: *Client, line: []const u8) void {
        const io = self.server.io;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closing) return;
        if (self.outbox_bytes + line.len > max_outbox_bytes) return self.overflow();

        const copy = self.server.allocator.dupe(u8, line) catch return self.overflow();
        self.outbox.append(self.server.allocator, copy) catch {
            self.server.allocator.free(copy);
            return self.overflow();
        };
        self.outbox_bytes += copy.len;
        self.ready.signal(io);
    }

    /// Called with the mutex held.
    fn overflow(self: *Client) void {
        self.closing = true;
        self.ready.signal(self.server.io);
        self.hangUp();
    }

    fn send(self: *Client, frame: wire.Frame(wire.Down)) void {
        var encoded: std.Io.Writer.Allocating = .init(self.server.allocator);
        defer encoded.deinit();
        wire.encode(&encoded.writer, frame) catch return self.cutOff();
        self.push(encoded.written());
    }

    /// Answer a request. `result` is void for a plain acknowledgement.
    fn reply(self: *Client, id: ?u64, result: anytype) void {
        if (@TypeOf(result) == void) return self.send(.{ .id = id, .body = .{ .reply = .{ .ok = true } } });
        var encoded: std.Io.Writer.Allocating = .init(self.server.allocator);
        defer encoded.deinit();
        wire.encodeResult(&encoded.writer, id, result) catch return self.cutOff();
        self.push(encoded.written());
    }

    fn replyError(self: *Client, id: ?u64, reason: []const u8) void {
        self.send(.{ .id = id, .body = .{ .reply = .{ .ok = false, .@"error" = reason } } });
    }

    fn cutOff(self: *Client) void {
        self.mutex.lockUncancelable(self.server.io);
        defer self.mutex.unlock(self.server.io);
        self.overflow();
    }

    fn writeLoop(self: *Client) void {
        const io = self.server.io;
        var buffer: [64 * 1024]u8 = undefined;
        var writer = self.stream.writer(io, &buffer);
        var batch: std.ArrayList([]u8) = .empty;
        defer batch.deinit(self.server.allocator);

        while (true) {
            self.mutex.lockUncancelable(io);
            while (self.outbox.items.len == 0 and !self.closing) self.ready.waitUncancelable(io, &self.mutex);
            if (self.outbox.items.len == 0) {
                self.mutex.unlock(io);
                self.stream.shutdown(io, .send) catch {};
                return;
            }
            std.mem.swap(std.ArrayList([]u8), &batch, &self.outbox);
            self.outbox_bytes = 0;
            self.mutex.unlock(io);

            defer {
                for (batch.items) |line| self.server.allocator.free(line);
                batch.clearRetainingCapacity();
            }
            for (batch.items) |line| writer.interface.writeAll(line) catch return self.cutOff();
            writer.interface.flush() catch return self.cutOff();
        }
    }

    fn readLoop(self: *Client) void {
        defer self.finished.store(true, .release);
        defer self.close();
        defer self.detach();

        var reader = self.stream.reader(self.server.io, self.read_buffer);
        if (!(self.handshake(&reader.interface) catch false)) return;
        while (true) {
            const line = (wire.readLine(&reader.interface) catch return) orelse return;
            self.handle(line) catch |err| switch (err) {
                error.OutOfMemory => return,
            };
        }
    }

    fn handshake(self: *Client, reader: *std.Io.Reader) !bool {
        var arena_state: std.heap.ArenaAllocator = .init(self.server.allocator);
        defer arena_state.deinit();

        const line = try wire.readLine(reader) orelse return false;
        const frame = try wire.Frame(wire.Up).decode(arena_state.allocator(), line) orelse return false;
        if (frame.body != .hello) return false;
        self.send(.{ .body = .{ .hello = .{
            .protocol = wire.version,
            .server = pkg.name ++ " " ++ pkg.version,
            .outdated = self.server.outdated(),
        } } });
        return frame.body.hello.protocol == wire.version;
    }

    /// Decoded straight into a command's arena, since most frames are bound
    /// for a session's inbox and must outlive the reader's buffer.
    fn handle(self: *Client, line: []const u8) error{OutOfMemory}!void {
        const command = try Command.create(self.server.allocator, self, undefined);
        var queued = false;
        defer if (!queued) command.destroy();
        const arena = command.arena.allocator();

        const decoded = wire.Frame(wire.Up).decode(arena, try arena.dupe(u8, line)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedMessage => return self.replyError(null, "malformed message"),
        };
        const frame = decoded orelse {
            const id = wire.idOf(arena, line) orelse return;
            return self.replyError(id, "unknown request; update " ++ pkg.name ++ " on the server");
        };
        command.id = frame.id;
        command.body = .{ .request = frame.body };

        switch (frame.body) {
            .hello => self.replyError(frame.id, "already said hello"),
            .list => |request| {
                const sessions = self.server.listing(arena, request.stored) catch |err| return self.replyError(frame.id, describe(err));
                self.reply(frame.id, sessions);
            },
            .open => |request| {
                const hosted = self.server.open(request.root, request.latest) catch |err| {
                    const reason = std.fmt.allocPrint(arena, "{s}: {s}", .{ describe(err), request.root }) catch describe(err);
                    return self.replyError(frame.id, reason);
                };
                defer hosted.release();
                self.reply(frame.id, try hosted.summary(arena));
            },
            .shutdown => {
                self.server.shutdown() catch |err| return self.replyError(frame.id, describe(err));
                self.reply(frame.id, {});
            },
            .stop => |request| {
                self.server.stopSession(request.handle) catch |err| return self.replyError(frame.id, describe(err));
                self.reply(frame.id, {});
            },
            .detach => {
                self.detach();
                self.reply(frame.id, {});
            },
            .files => {
                const hosted = self.attached orelse return self.replyError(frame.id, "not attached to a session");
                const files = projectFiles(self.server, arena, hosted.cwd) catch |err| return self.replyError(frame.id, describe(err));
                self.reply(frame.id, files);
            },
            .attach => |request| {
                self.detach();
                const leave = try Command.create(self.server.allocator, self, .{ .detach = &self.left });
                const hosted = self.server.acquire(request.handle) catch |err| {
                    leave.destroy();
                    return self.replyError(frame.id, describe(err));
                };
                self.attached = hosted;
                self.leave = leave;
                queued = true;
                hosted.send(command);
            },
            else => {
                const hosted = self.attached orelse return self.replyError(frame.id, "not attached to a session");
                queued = true;
                hosted.send(command);
            },
        }
    }

    /// Leave the attached session, once its worker has stopped sending here.
    fn detach(self: *Client) void {
        const hosted = self.attached orelse return;
        defer hosted.release();
        self.left.reset();
        hosted.send(self.leave.?);
        self.left.waitUncancelable(self.server.io);
        self.attached = null;
        self.leave = null;
    }
};

test "socketPath sits under XDG_RUNTIME_DIR when there is one" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");

    const path = try socketPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/" ++ pkg.name ++ "/server.sock", path);
}

/// Answers the first turn by thinking aloud and asking to write a note, and
/// the second, once the note is written, with "done". Each answer waits on
/// `gate` after the thinking, so a test can catch a request mid-stream. Offers
/// two models, each at two efforts.
pub const Script = struct {
    gate: std.Io.Event = .is_set,
    model: []const u8 = offered[0],
    effort: []const u8 = "",

    const offered = [_][]const u8{ "scripted", "bigger" };
    const levels = [_][]const u8{ "low", "high" };

    fn provider(self: *Script) Provider {
        return .{
            .name = "script",
            .model = self.model,
            .userdata = self,
            .respond = respond,
            .list_models = listModels,
            .set_model = setModel,
            .refresh = refresh,
            .efforts = efforts,
            .set_effort = setEffort,
        };
    }

    fn listModels(_: *anyopaque, allocator: std.mem.Allocator) ![][]const u8 {
        const names = try allocator.alloc([]const u8, offered.len);
        for (offered, names) |name, *copy| copy.* = try allocator.dupe(u8, name);
        return names;
    }

    fn setModel(ptr: *anyopaque, name: []const u8) !Provider.Current {
        const self: *Script = @ptrCast(@alignCast(ptr));
        self.model = for (offered) |known| {
            if (std.mem.eql(u8, known, name)) break known;
        } else return error.UnknownModel;
        return refresh(ptr);
    }

    fn refresh(ptr: *anyopaque) Provider.Current {
        const self: *Script = @ptrCast(@alignCast(ptr));
        return .{ .model = self.model, .name = "script", .effort = efforts(ptr, self.model).pick(self.effort) };
    }

    fn efforts(_: *anyopaque, _: []const u8) Provider.Efforts {
        return .{ .levels = &levels, .default = levels[0] };
    }

    fn setEffort(ptr: *anyopaque, level: []const u8) void {
        const self: *Script = @ptrCast(@alignCast(ptr));
        self.effort = efforts(ptr, self.model).pick(level);
    }

    fn respond(ptr: *anyopaque, convo: *Conversation, _: Provider.Turn, allocator: std.mem.Allocator, sink: ?Provider.Sink) !Provider.Reply {
        const self: *Script = @ptrCast(@alignCast(ptr));
        if (sink) |s| {
            s.onThinking(s.userdata, "weighing it up");
            s.onThinkingDone(s.userdata);
        }
        self.gate.waitUncancelable(std.testing.io);
        const last = convo.last();
        if (last != null and last.?.role == .tool) return .{ .text = try allocator.dupe(u8, "done") };

        const calls = try allocator.alloc(Conversation.ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call-1"),
            .name = try allocator.dupe(u8, "write"),
            .arguments = try allocator.dupe(u8, "{\"path\":\"note.txt\",\"content\":\"remote\"}"),
        };
        return .{ .text = try allocator.dupe(u8, "Let me write that down."), .tool_calls = calls };
    }
};

/// A server in a scratch directory, hosting sessions in `project/` and
/// answering through `Script`. For tests, here and of the clients.
pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    config: Config,
    script: Script,
    project: []const u8,
    server: *Server,

    pub fn create() !*Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const self = try allocator.create(Fixture);
        errdefer allocator.destroy(self);
        self.script = .{};
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.arena = .init(allocator);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.config = .{ .arena = .init(allocator) };
        errdefer self.config.arena.deinit();

        // Its own repository, or the project would be the one these tests live in.
        try self.tmp.dir.createDirPath(io, "project/.git");
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try arena.dupe(u8, buffer[0..try self.tmp.dir.realPath(io, &buffer)]);
        self.project = try std.fs.path.join(arena, &.{ dir, "project" });

        self.server = try start(allocator, io, .{
            .config = &self.config,
            .socket_path = try std.fs.path.join(arena, &.{ dir, "s.sock" }),
            .database_path = try std.fs.path.join(arena, &.{ dir, "synth.db" }),
            .source = .{ .provider = self.script.provider() },
        });
        return self;
    }

    pub fn destroy(self: *Fixture) void {
        self.server.stop();
        self.config.arena.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
        std.testing.allocator.destroy(self);
    }

    fn connect(self: *Fixture) !*TestClient {
        return TestClient.connect(self.server.path);
    }
};

/// The far end of a connection, reading frames as they come.
const TestClient = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buffer: [256 * 1024]u8 = undefined,
    write_buffer: [4096]u8 = undefined,
    arena: std.heap.ArenaAllocator,
    next_id: u64 = 1,

    const Down = wire.Frame(wire.Down);

    fn connect(path: []const u8) !*TestClient {
        const io = std.testing.io;
        const self = try std.testing.allocator.create(TestClient);
        errdefer std.testing.allocator.destroy(self);
        const address = try std.Io.net.UnixAddress.init(path);
        self.* = .{ .stream = try address.connect(io), .reader = undefined, .writer = undefined, .arena = .init(std.testing.allocator) };

        // A missing event fails the test rather than hanging it.
        const timeout: linux.timeval = .{ .sec = 10, .usec = 0 };
        _ = linux.setsockopt(self.stream.socket.handle, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));

        self.reader = self.stream.reader(io, &self.read_buffer);
        self.writer = self.stream.writer(io, &self.write_buffer);
        return self;
    }

    fn close(self: *TestClient) void {
        self.stream.close(std.testing.io);
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }

    fn hello(self: *TestClient) !void {
        _ = try self.greet();
    }

    /// Say hello, returning whether the server says it is outdated.
    fn greet(self: *TestClient) !bool {
        _ = try self.send(.{ .hello = .{ .protocol = wire.version, .client = "test" } });
        const frame = try self.next();
        try std.testing.expect(frame.body == .hello);
        return frame.body.hello.outdated;
    }

    fn send(self: *TestClient, body: wire.Up) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        try wire.encode(&self.writer.interface, wire.Frame(wire.Up){ .id = id, .body = body });
        try self.writer.interface.flush();
        return id;
    }

    /// The next frame, or `error.Closed` once the server hangs up.
    fn next(self: *TestClient) !Down {
        const line = try wire.readLine(&self.reader.interface) orelse return error.Closed;
        return (try Down.decode(self.arena.allocator(), try self.arena.allocator().dupe(u8, line))) orelse self.next();
    }

    /// Read until the reply to `id`, which must be a success.
    fn expectOk(self: *TestClient, id: u64) !?std.json.Value {
        while (true) {
            const frame = try self.next();
            if (frame.body != .reply or frame.id != id) continue;
            const reply = frame.body.reply;
            if (!reply.ok) {
                std.debug.print("request {d} failed: {s}\n", .{ id, reply.@"error" orelse "" });
                return error.RequestFailed;
            }
            return reply.result;
        }
    }

    fn expectError(self: *TestClient, id: u64) ![]const u8 {
        while (true) {
            const frame = try self.next();
            if (frame.body != .reply or frame.id != id) continue;
            try std.testing.expect(!frame.body.reply.ok);
            return frame.body.reply.@"error".?;
        }
    }

    /// Read until a status running `model` at `effort`.
    fn awaitModel(self: *TestClient, model: []const u8, effort: []const u8) !void {
        while (true) {
            const frame = try self.next();
            if (frame.body != .status) continue;
            const status = frame.body.status;
            if (std.mem.eql(u8, status.model, model) and std.mem.eql(u8, status.effort, effort)) return;
        }
    }

    /// Read until a status in `state`, returning it.
    fn awaitState(self: *TestClient, state: Loop.State) !wire.Status {
        while (true) {
            const frame = try self.next();
            if (frame.body == .status and frame.body.status.state == state) return frame.body.status;
        }
    }

    fn open(self: *TestClient, root: []const u8) !wire.Summary {
        const result = try self.expectOk(try self.send(.{ .open = .{ .root = root } }));
        return wire.parseResult(wire.Summary, self.arena.allocator(), result);
    }

    /// Attach, returning the snapshot that comes before the reply.
    fn attach(self: *TestClient, handle: []const u8) !wire.Snapshot {
        const id = try self.send(.{ .attach = .{ .handle = handle } });
        const snapshot = try self.next();
        try std.testing.expect(snapshot.body == .snapshot);
        _ = try self.expectOk(id);
        return snapshot.body.snapshot;
    }

    fn list(self: *TestClient) ![]const wire.Summary {
        const result = try self.expectOk(try self.send(.{ .list = .{} }));
        return wire.parseResult([]const wire.Summary, self.arena.allocator(), result);
    }
};

test "a session opens, is listed, and attaches with a snapshot" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.hello();

    const opened = try client.open(fixture.project);
    try std.testing.expect(std.mem.startsWith(u8, opened.handle, "ses_"));
    try std.testing.expectEqualStrings(fixture.project, opened.root);

    const before = try client.list();
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqual(@as(u32, 0), before[0].clients);

    const snapshot = try client.attach(opened.handle);
    try std.testing.expectEqualStrings(opened.handle, snapshot.status.handle);
    try std.testing.expectEqual(Loop.State.idle, snapshot.status.state);
    try std.testing.expectEqual(@as(usize, 0), snapshot.messages.len);

    const after = try client.list();
    try std.testing.expectEqual(@as(u32, 1), after[0].clients);

    try std.testing.expectEqualStrings("no such session", try client.expectError(try client.send(.{ .attach = .{ .handle = "ses_00000000" } })));
}

test "a turn runs over the socket, its approval included" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.hello();
    _ = try client.attach((try client.open(fixture.project)).handle);

    fixture.script.gate.reset();
    _ = try client.expectOk(try client.send(.{ .submit = .{ .text = "make a note" } }));

    var appended: std.ArrayList(wire.Message) = .empty;
    const arena = client.arena.allocator();
    var thinking: std.ArrayList(u8) = .empty;
    var streaming: ?u64 = null;
    while (!std.mem.eql(u8, thinking.items, "weighing it up") or streaming == null) {
        const frame = try client.next();
        switch (frame.body) {
            .stream => |stream| {
                try thinking.appendSlice(arena, stream.thinking);
                try std.testing.expect(stream.closed);
            },
            .appended => |appended_body| try appended.append(arena, appended_body.message),
            .status => |status| if (status.request) |request| {
                streaming = request;
            },
            else => {},
        }
    }
    fixture.script.gate.set(std.testing.io);

    const asking = while (true) {
        const frame = try client.next();
        switch (frame.body) {
            .appended => |appended_body| try appended.append(arena, appended_body.message),
            .status => |status| if (status.state == .awaiting_approval) break status,
            else => {},
        }
    };
    try std.testing.expectEqual(Conversation.Role.user, appended.items[0].role);
    const asked = appended.items[appended.items.len - 1];
    try std.testing.expectEqual(asked.seq, asking.pending_seq.?);
    try std.testing.expectEqual(@as(?u32, 0), asking.pending_call);
    try std.testing.expectEqualStrings("write", asked.tool_calls[0].name);
    try std.testing.expectEqualStrings("weighing it up", asked.thinking.?);

    _ = try client.expectOk(try client.send(.{ .decide = .{ .decision = .once } }));
    var settled = false;
    var answered = false;
    const done = while (true) {
        const frame = try client.next();
        switch (frame.body) {
            .updated => |updated| if (updated.message.seq == asked.seq and updated.message.tool_calls[0].status == .ok) {
                settled = true;
            },
            .appended => |appended_body| if (std.mem.eql(u8, appended_body.message.text, "done")) {
                answered = true;
            },
            .status => |status| if (status.state == .idle and status.finished == 1) break status,
            else => {},
        }
    };
    try std.testing.expect(settled);
    try std.testing.expect(answered);
    try std.testing.expectEqual(@as(?Loop.Outcome, .done), done.outcome);

    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(arena, &.{ fixture.project, "note.txt" }), arena, .limited(64));
    try std.testing.expectEqualStrings("remote", written);

    const result = try client.expectOk(try client.send(.{ .load_tool_result = .{ .seq = asked.seq, .call = 0 } }));
    try std.testing.expect((try wire.parseResult([]const u8, arena, result)).len > 0);
}

test "a client that leaves mid-turn finds it waiting, and another can answer it" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    const first = try fixture.connect();
    try first.hello();
    const handle = (try first.open(fixture.project)).handle;
    _ = try first.attach(handle);
    _ = try first.expectOk(try first.send(.{ .submit = .{ .text = "make a note" } }));
    _ = try first.awaitState(.awaiting_approval);
    first.close();

    const second = try fixture.connect();
    defer second.close();
    try second.hello();
    const watcher = try fixture.connect();
    defer watcher.close();
    try watcher.hello();

    const snapshot = try second.attach(handle);
    try std.testing.expectEqual(Loop.State.awaiting_approval, snapshot.status.state);
    const pending = snapshot.messages[snapshot.messages.len - 1];
    try std.testing.expectEqual(pending.seq, snapshot.status.pending_seq.?);
    try std.testing.expectEqual(Conversation.ToolCall.Status.pending, pending.tool_calls[0].status);
    _ = try watcher.attach(handle);

    _ = try second.expectOk(try second.send(.{ .decide = .{ .decision = .once } }));
    try std.testing.expectEqual(@as(u64, 1), (try watcher.awaitState(.idle)).finished);
    try std.testing.expectEqual(@as(u64, 1), (try second.awaitState(.idle)).finished);
}

test "a stopped session ends for its clients and resumes from the database" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.hello();
    const handle = (try client.open(fixture.project)).handle;
    _ = try client.attach(handle);
    _ = try client.expectOk(try client.send(.{ .submit = .{ .text = "make a note" } }));
    _ = try client.awaitState(.awaiting_approval);
    _ = try client.expectOk(try client.send(.{ .decide = .{ .decision = .once } }));
    _ = try client.awaitState(.idle);

    const other = try fixture.connect();
    defer other.close();
    try other.hello();
    _ = try other.expectOk(try other.send(.{ .stop = .{ .handle = handle } }));
    while ((try client.next()).body != .ended) {}
    try std.testing.expectEqual(@as(usize, 0), (try other.list()).len);
    try std.testing.expectEqualStrings("the session has ended", try client.expectError(try client.send(.{ .cancel = .{} })));

    const resumed = try other.attach(handle);
    try std.testing.expectEqual(Loop.State.idle, resumed.status.state);
    const last = resumed.messages[resumed.messages.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last.text, "done") != null or resumed.messages.len >= 4);
    try std.testing.expectEqual(@as(usize, 1), (try other.list()).len);
}

test "a client speaking another protocol hears the server's and is let go" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();

    _ = try client.send(.{ .hello = .{ .protocol = wire.version + 1 } });
    const hello = try client.next();
    try std.testing.expectEqual(wire.version, hello.body.hello.protocol);
    try std.testing.expectError(error.Closed, client.next());
}

test "a live server is left alone, and a dead one's socket replaced" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const socket = try std.Io.Dir.cwd().statFile(std.testing.io, fixture.server.path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), socket.permissions.toMode() & 0o777);
    var options = fixture.server.options;
    try std.testing.expectError(error.AlreadyRunning, start(std.testing.allocator, std.testing.io, options));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "dead.sock" });
    defer std.testing.allocator.free(path);
    var dead = try (try std.Io.net.UnixAddress.init(path)).listen(std.testing.io, .{});
    dead.deinit(std.testing.io);

    options.socket_path = path;
    const replacement = try start(std.testing.allocator, std.testing.io, options);
    replacement.stop();
}

test "a model is listed with its efforts, and the effort chosen for it comes back with it" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.hello();
    const snapshot = try client.attach((try client.open(fixture.project)).handle);
    try std.testing.expect(snapshot.status.switchable);
    try std.testing.expectEqualStrings("low", snapshot.status.effort);
    try std.testing.expectEqual(@as(usize, 2), snapshot.status.efforts.len);

    _ = try client.expectOk(try client.send(.{ .set_effort = .{ .effort = "high" } }));
    try client.awaitModel("scripted", "high");
    _ = try client.expectOk(try client.send(.{ .set_model = .{ .model = "bigger" } }));
    try client.awaitModel("bigger", "low");
    _ = try client.expectOk(try client.send(.{ .set_model = .{ .model = "scripted" } }));
    try client.awaitModel("scripted", "high");
    _ = try client.expectOk(try client.send(.{ .set_model = .{ .model = "bigger", .effort = "high" } }));
    try client.awaitModel("bigger", "high");
    var db = try Database.init(std.testing.allocator, std.testing.io, fixture.server.options.database_path);
    defer db.deinit();
    const remembered = try db.setting(client.arena.allocator(), "model:");
    try std.testing.expectEqualStrings("bigger", remembered);

    const result = try client.expectOk(try client.send(.{ .models = .{} }));
    const models = try wire.parseResult(wire.Models, client.arena.allocator(), result);
    try std.testing.expectEqual(@as(usize, 2), models.offered.len);
    for (models.offered) |offered| try std.testing.expectEqualStrings("high", offered.effort);
    try std.testing.expectEqualStrings("low", models.offered[0].efforts[0]);

    try std.testing.expectEqualStrings("UnknownModel", try client.expectError(try client.send(.{ .set_model = .{ .model = "missing" } })));
}

test "a session's directory is found from home unless it is absolute" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { root: []const u8, home: ?[]const u8, want: []const u8 }{
        .{ .root = "/srv/api", .home = "/home/me", .want = "/srv/api" },
        .{ .root = "~", .home = "/home/me", .want = "/home/me" },
        .{ .root = "~/src/api", .home = "/home/me", .want = "/home/me/src/api" },
        .{ .root = "src/api", .home = "/home/me", .want = "/home/me/src/api" },
        .{ .root = "src/api", .home = null, .want = "src/api" },
    };
    for (cases) |case| {
        const got = try resolveRoot(allocator, case.root, case.home);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

/// Wait for the list of live sessions to reach `count`, or fail after a few seconds.
fn awaitLive(client: *TestClient, count: usize) !void {
    for (0..300) |_| {
        if ((try client.list()).len == count) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    return error.TimedOut;
}

test "an idle session nobody watches unloads, and attaching loads it again" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    fixture.server.options.idle_unload = .fromMilliseconds(50);
    const client = try fixture.connect();
    defer client.close();
    try client.hello();

    const handle = (try client.open(fixture.project)).handle;
    _ = try client.attach(handle);
    _ = try client.expectOk(try client.send(.{ .submit = .{ .text = "make a note" } }));
    _ = try client.awaitState(.awaiting_approval);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(150), .awake);
    _ = try client.expectOk(try client.send(.{ .detach = .{} }));
    try std.testing.expectEqual(@as(usize, 1), (try client.list()).len);

    _ = try client.attach(handle);
    _ = try client.expectOk(try client.send(.{ .decide = .{ .decision = .once } }));
    _ = try client.awaitState(.idle);
    _ = try client.expectOk(try client.send(.{ .detach = .{} }));
    try awaitLive(client, 0);

    const snapshot = try client.attach(handle);
    try std.testing.expect(snapshot.messages.len >= 4);
    try std.testing.expectEqual(@as(usize, 1), (try client.list()).len);
    _ = try client.expectOk(try client.send(.{ .detach = .{} }));
    try awaitLive(client, 0);

    const empty = (try client.open(fixture.project)).handle;
    try awaitLive(client, 0);
    try std.testing.expectEqualStrings("no such session", try client.expectError(try client.send(.{ .attach = .{ .handle = empty } })));
}

var shutdown_asked: std.atomic.Value(bool) = .init(false);

fn noteShutdown() void {
    shutdown_asked.store(true, .release);
}

test "a server whose program was replaced says so, and steps aside once nobody is using it" {
    const io = std.testing.io;
    const fixture = try Fixture.create();
    defer fixture.destroy();
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "program", .data = "old build" });
    const program = try std.fs.path.join(fixture.arena.allocator(), &.{ std.fs.path.dirname(fixture.project).?, "program" });
    fixture.server.options.executable = program;
    fixture.server.options.on_shutdown = noteShutdown;
    fixture.server.started_from = Build.of(io, program);

    const client = try fixture.connect();
    defer client.close();
    try std.testing.expect(!try client.greet());

    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "program", .data = "a newer build" });
    const newer = try fixture.connect();
    defer newer.close();
    try std.testing.expect(try newer.greet());

    _ = try client.attach((try client.open(fixture.project)).handle);
    try std.testing.expectEqualStrings("a session is busy or attached", try newer.expectError(try newer.send(.{ .shutdown = .{} })));
    try std.testing.expect(!shutdown_asked.load(.acquire));

    _ = try client.expectOk(try client.send(.{ .detach = .{} }));
    _ = try newer.expectOk(try newer.send(.{ .shutdown = .{} }));
    try std.testing.expect(shutdown_asked.load(.acquire));
}

test "a session connects a provider through its server, which keeps the key and the choice" {
    const io = std.testing.io;
    const Auth = @import("../core/auth.zig");
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const arena = fixture.arena.allocator();
    const dir = std.fs.path.dirname(fixture.project).?;
    const auth_path = try std.fs.path.join(arena, &.{ dir, "auth.json" });

    var auth = try Auth.load(std.testing.allocator, io, auth_path);
    defer auth.deinit();
    var template: Backend = .init(.ollama, .{ .allocator = std.testing.allocator, .io = io, .host = "http://127.0.0.1:9", .label = "Ollama" });
    defer template.deinit();
    var providers: Providers = .init(io, &auth, null, &template, "ollama", true);

    var options = fixture.server.options;
    options.socket_path = try std.fs.path.join(arena, &.{ dir, "p.sock" });
    options.source = .{ .providers = &providers };
    const server = try start(std.testing.allocator, io, options);
    defer server.stop();

    const client = try TestClient.connect(server.path);
    defer client.close();
    try client.hello();
    const snapshot = try client.attach((try client.open(fixture.project)).handle);
    try std.testing.expect(snapshot.status.provider_missing);
    try std.testing.expectEqualStrings("ollama", snapshot.status.provider_id);

    const connect = try client.send(.{ .connect_provider = .{ .provider = "openai-compat", .host = "http://127.0.0.1:9", .key = "sk-test" } });
    var announced = false;
    while (true) {
        const frame = try client.next();
        switch (frame.body) {
            .notice => |notice| if (std.mem.startsWith(u8, notice.text, "Connected ")) {
                try std.testing.expect(std.mem.indexOf(u8, notice.text, "http://127.0.0.1:9") != null);
                announced = true;
            },
            .reply => try std.testing.expect(frame.id != connect or frame.body.reply.ok),
            .status => |status| if (std.mem.eql(u8, status.provider_id, "openai-compat")) {
                try std.testing.expect(!status.provider_missing);
                break;
            },
            else => {},
        }
    }
    try std.testing.expect(announced);

    var saved = try Auth.load(std.testing.allocator, io, auth_path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("sk-test", saved.key("openai-compat").?);

    const listed = try client.expectOk(try client.send(.{ .providers = .{} }));
    const states = try wire.parseResult([]const wire.ProviderState, client.arena.allocator(), listed);
    for (states) |state| {
        const chosen = std.mem.eql(u8, state.id, "openai-compat");
        try std.testing.expectEqual(chosen, state.active);
        if (chosen) try std.testing.expect(state.connected);
    }
}

/// Read until a status whose first MCP server is in `state`.
fn awaitMcp(client: *TestClient, state: mcp_tools.Status.State) !wire.Status {
    while (true) {
        const frame = try client.next();
        if (frame.body != .status) continue;
        const status = frame.body.status;
        if (status.mcp.len > 0 and status.mcp[0].state == state) return status;
    }
}

test "a session's MCP servers are reported, and one turned off stays off" {
    const io = std.testing.io;
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const arena = fixture.arena.allocator();
    fixture.config.mcp = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"servers":{"broken":{"command":"/nonexistent/synth-test-mcp"}}}
    , .{});
    const auth_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(fixture.project).?, "mcp-auth.json" });
    fixture.server.options.mcp_auth_path = auth_path;

    const client = try fixture.connect();
    defer client.close();
    try client.hello();
    const snapshot = try client.attach((try client.open(fixture.project)).handle);
    try std.testing.expectEqual(@as(usize, 1), snapshot.status.mcp.len);
    try std.testing.expectEqualStrings("broken", snapshot.status.mcp[0].name);
    try std.testing.expectEqual(mcp_tools.Status.State.failed, snapshot.status.mcp[0].state);

    _ = try client.expectOk(try client.send(.{ .toggle_mcp = .{ .name = "broken" } }));
    _ = try awaitMcp(client, .off);
    var saved = try mcp.Auth.load(std.testing.allocator, io, auth_path);
    defer saved.deinit();
    try std.testing.expect(!saved.isEnabled("broken"));

    _ = try client.expectOk(try client.send(.{ .toggle_mcp = .{ .name = "broken" } }));
    _ = try awaitMcp(client, .failed);
    try std.testing.expectEqualStrings("no such MCP server", try client.expectError(try client.send(.{ .toggle_mcp = .{ .name = "missing" } })));
}

test "a request this server does not know is answered, not left hanging" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const client = try fixture.connect();
    defer client.close();
    try client.hello();

    try client.writer.interface.writeAll("{\"type\":\"from_the_future\",\"id\":41}\n");
    try client.writer.interface.flush();
    const reason = try client.expectError(41);
    try std.testing.expect(std.mem.startsWith(u8, reason, "unknown request"));
}
