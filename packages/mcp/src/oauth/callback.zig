//! The loopback HTTP server that captures an OAuth authorization code.
//!
//! When the user authorizes this client in their browser, the authorization
//! server redirects them to `http://127.0.0.1:{port}{path}?code=...&state=...`.
//! This file owns the short-lived server that receives exactly that one
//! request, matches its `state` against the flow that is waiting, and hands
//! the code back to whoever called `wait`.
//!
//! One flow at a time, deliberately. A CLI authorizes one MCP server, blocks
//! on the browser, and moves on; a process-global registry of concurrent
//! flows would be state to get wrong for no gain. Two servers needing auth
//! authorize one after the other.
//!
//! The server is `httpz` rather than a hand-rolled `std.http.Server` accept
//! loop: request parsing, query decoding, and the worker threads are all
//! things it already does correctly.

const std = @import("std");
const httpz = @import("httpz");

pub const default_port: u16 = 19876;
pub const default_path: []const u8 = "/mcp/oauth/callback";

/// How many consecutive ports `start` probes before giving up. The redirect
/// URI is registered with the authorization server per flow, so any port in
/// the range is as good as any other.
pub const port_attempts: u16 = 16;

/// How long `wait` blocks before giving up on the browser.
pub const default_timeout_ns: u64 = 5 * std.time.ns_per_min;

pub const Error = error{
    /// Every port in the probed range was taken.
    NoFreePort,
    /// The redirect never arrived before the deadline.
    Timeout,
};

/// What the redirect carried. `denied` is not an error at this layer: the
/// user declining is an outcome the caller reports, not a failure to handle.
pub const Outcome = union(enum) {
    /// A code, ready to exchange for tokens.
    code: Code,
    /// The `error_description` the authorization server sent, or its `error`
    /// code when no description came with it.
    denied: []const u8,

    pub const Code = struct {
        code: []const u8,
        /// The issuer, when the authorization server sent one (RFC 9207).
        /// Checking it against the issuer the flow started with is what stops
        /// a mix-up attack: a code minted by one server, redirected to a
        /// client that thinks it is talking to another.
        iss: ?[]const u8 = null,
    };
};

/// Resolves the `(port, path)` a redirect URI names, so a stored URI can be
/// listened on again without re-deriving it from config. Falls back to the
/// defaults for anything that is not a loopback URI.
pub fn parseRedirectUri(redirect_uri: []const u8) struct { port: u16, path: []const u8 } {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, redirect_uri, prefix)) {
        return .{ .port = default_port, .path = default_path };
    }

    const after_host = redirect_uri[prefix.len..];
    const slash = std.mem.findScalar(u8, after_host, '/') orelse after_host.len;
    const port = std.fmt.parseInt(u16, after_host[0..slash], 10) catch {
        return .{ .port = default_port, .path = default_path };
    };

    const path = after_host[slash..];
    return .{ .port = port, .path = if (path.len == 0) "/" else path };
}

/// The rendezvous between httpz's worker thread, which writes the outcome,
/// and the thread blocked in `wait`, which reads it.
///
/// A poll rather than a condition variable: `std.Io.Condition` has no timed
/// wait, and `wait` needs a deadline because the failure mode being guarded
/// against is a browser that never comes back. At `poll_interval` against a
/// flow measured in seconds of human attention, the latency does not matter.
const Rendezvous = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    /// Outlives the request arena the handler runs on, so the code is duped
    /// into it before the handler returns.
    allocator: std.mem.Allocator,
    expected_state: []const u8,
    outcome: ?Outcome = null,

    /// Record the first outcome. Later redirects for the same state are
    /// ignored: the flow is already settled.
    fn settle(self: *Rendezvous, outcome: Outcome) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.outcome != null) return;
        self.outcome = outcome;
    }

    fn settled(self: *Rendezvous) ?Outcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.outcome;
    }
};

/// How often `wait` looks for an arrived redirect.
const poll_interval_ns: u64 = 25 * std.time.ns_per_ms;

const Server = httpz.Server(*Rendezvous);

const ok_body =
    \\<html><body style="font-family:system-ui;padding:3rem">
    \\<h2>Authorization complete</h2>
    \\<p>You can close this tab and return to your terminal.</p>
    \\</body></html>
;

const denied_body =
    \\<html><body style="font-family:system-ui;padding:3rem">
    \\<h2>Authorization failed</h2>
    \\<p>You can close this tab and return to your terminal.</p>
    \\</body></html>
;

fn handle(rendezvous: *Rendezvous, request: *httpz.Request, response: *httpz.Response) !void {
    const query = try request.query();

    const state = query.get("state") orelse return badRequest(response, "missing state");

    // A redirect carrying a state we did not mint is stale or forged. It is
    // answered and dropped without touching the flow that is still waiting.
    if (!std.crypto.timing_safe.eql([32]u8, digest(state), digest(rendezvous.expected_state))) {
        return badRequest(response, "state mismatch");
    }

    if (query.get("error")) |code| {
        const description = query.get("error_description") orelse code;
        const owned = rendezvous.allocator.dupe(u8, description) catch return badRequest(response, "out of memory");
        rendezvous.settle(.{ .denied = owned });

        response.status = 200;
        response.content_type = .HTML;
        response.body = denied_body;
        return;
    }

    const code = query.get("code") orelse return badRequest(response, "missing code");
    const owned = rendezvous.allocator.dupe(u8, code) catch return badRequest(response, "out of memory");

    const issuer: ?[]const u8 = if (query.get("iss")) |raw|
        rendezvous.allocator.dupe(u8, raw) catch return badRequest(response, "out of memory")
    else
        null;

    rendezvous.settle(.{ .code = .{ .code = owned, .iss = issuer } });

    response.status = 200;
    response.content_type = .HTML;
    response.body = ok_body;
}

fn badRequest(response: *httpz.Response, message: []const u8) void {
    response.status = 400;
    response.content_type = .TEXT;
    response.body = message;
}

/// Compare states without leaking their length or contents through timing.
/// Hashing first lets the constant-time comparison work on a fixed width.
fn digest(value: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &out, .{});
    return out;
}

pub const Options = struct {
    /// The `state` this flow generated. Only a redirect carrying it settles
    /// the flow.
    state: []const u8,
    /// The first port to probe. `start` walks upward from here.
    port: u16 = default_port,
    path: []const u8 = default_path,
};

/// A running loopback server with exactly one flow outstanding.
pub const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Owns `expected_state`, `path`, and whatever the handler duped into it,
    /// so a caller frees one thing.
    arena: std.heap.ArenaAllocator,
    server: *Server,
    thread: std.Thread,
    rendezvous: *Rendezvous,
    port: u16,
    path: []const u8,

    /// Bind a loopback port, start serving, and return before the browser is
    /// opened. Heap-allocated: `Server` holds a pointer to its own router and
    /// the handler holds a pointer to `rendezvous`, so a `Listener` returned
    /// by value would leave both aimed at a dead frame.
    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Listener {
        const self = try allocator.create(Listener);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .arena = .init(allocator),
            .server = undefined,
            .thread = undefined,
            .rendezvous = undefined,
            .port = try freePort(io, options.port),
            .path = undefined,
        };
        errdefer self.arena.deinit();

        const arena = self.arena.allocator();
        self.path = try arena.dupe(u8, options.path);

        self.rendezvous = try arena.create(Rendezvous);
        self.rendezvous.* = .{
            .io = io,
            .allocator = arena,
            .expected_state = try arena.dupe(u8, options.state),
        };

        self.server = try allocator.create(Server);
        errdefer allocator.destroy(self.server);

        self.server.* = try Server.init(io, allocator, .{
            .address = .localhost(self.port),
            // One worker and a single-thread pool: this server answers one
            // request in its whole life.
            .workers = .{ .count = 1 },
            .thread_pool = .{ .count = 1 },
        }, self.rendezvous);
        errdefer self.server.deinit();

        var router = try self.server.router(.{});
        router.get(self.path, handle, .{});

        self.thread = try self.server.listenInNewThread();
        return self;
    }

    /// The redirect URI to register with the authorization server and send
    /// the browser to. Allocated with `allocator`; the caller frees it.
    pub fn redirectUri(self: *const Listener, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.port, self.path });
    }

    /// Block until the redirect arrives or `timeout_ns` elapses. The returned
    /// slices are owned by the `Listener` and die with it, so a caller that
    /// keeps the code past `deinit` copies it.
    pub fn wait(self: *Listener, timeout_ns: u64) Error!Outcome {
        var waited: u64 = 0;
        while (true) {
            if (self.rendezvous.settled()) |outcome| return outcome;
            if (waited >= timeout_ns) return Error.Timeout;
            std.Io.sleep(self.io, .fromNanoseconds(poll_interval_ns), .awake) catch return Error.Timeout;
            waited += poll_interval_ns;
        }
    }

    pub fn deinit(self: *Listener) void {
        self.server.stop();
        self.thread.join();
        self.server.deinit();
        self.allocator.destroy(self.server);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

/// Find a loopback port nothing is listening on, starting at `first`. The
/// probe socket is closed before httpz binds the same port, which is a race
/// in principle; in practice nothing else is racing for a port in this range,
/// and losing it surfaces as a `wait` timeout rather than silent breakage.
fn freePort(io: std.Io, first: u16) Error!u16 {
    var port = first;
    const last = first +| (port_attempts - 1);
    while (port <= last) : (port += 1) {
        const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
        var probe = std.Io.net.IpAddress.listen(&address, io, .{ .mode = .stream }) catch continue;
        probe.deinit(io);
        return port;
    }
    return Error.NoFreePort;
}

const testing = std.testing;

test "parseRedirectUri extracts a port and path" {
    {
        const r = parseRedirectUri("http://127.0.0.1:8080/foo/bar");
        try testing.expectEqual(@as(u16, 8080), r.port);
        try testing.expectEqualStrings("/foo/bar", r.path);
    }
    {
        const r = parseRedirectUri("http://127.0.0.1:7774");
        try testing.expectEqual(@as(u16, 7774), r.port);
        try testing.expectEqualStrings("/", r.path);
    }
    {
        const r = parseRedirectUri("http://127.0.0.1:7774/");
        try testing.expectEqual(@as(u16, 7774), r.port);
        try testing.expectEqualStrings("/", r.path);
    }
}

test "parseRedirectUri falls back to defaults" {
    for ([_][]const u8{
        "https://example.com/cb",
        "http://127.0.0.1:not-a-port/cb",
        "http://localhost:19876/cb",
    }) |uri| {
        const r = parseRedirectUri(uri);
        try testing.expectEqual(default_port, r.port);
        try testing.expectEqualStrings(default_path, r.path);
    }
}

test "a redirect carrying the right state settles the flow" {
    const allocator = testing.allocator;
    const io = testing.io;

    var listener = try Listener.start(allocator, io, .{ .state = "state-abc" });
    defer listener.deinit();

    const uri = try listener.redirectUri(allocator);
    defer allocator.free(uri);

    const target = try std.fmt.allocPrint(allocator, "{s}?code=the-code&state=state-abc", .{uri});
    defer allocator.free(target);

    try get(allocator, io, target);

    const outcome = try listener.wait(std.time.ns_per_s * 10);
    try testing.expectEqualStrings("the-code", outcome.code.code);
    try testing.expect(outcome.code.iss == null);
}

test "a redirect carrying an error settles the flow as denied" {
    const allocator = testing.allocator;
    const io = testing.io;

    var listener = try Listener.start(allocator, io, .{ .state = "state-abc" });
    defer listener.deinit();

    const uri = try listener.redirectUri(allocator);
    defer allocator.free(uri);

    const target = try std.fmt.allocPrint(
        allocator,
        "{s}?error=access_denied&error_description=nope&state=state-abc",
        .{uri},
    );
    defer allocator.free(target);

    try get(allocator, io, target);

    const outcome = try listener.wait(std.time.ns_per_s * 10);
    try testing.expectEqualStrings("nope", outcome.denied);
}

test "a redirect carrying the wrong state leaves the flow waiting" {
    const allocator = testing.allocator;
    const io = testing.io;

    var listener = try Listener.start(allocator, io, .{ .state = "state-abc" });
    defer listener.deinit();

    const uri = try listener.redirectUri(allocator);
    defer allocator.free(uri);

    const target = try std.fmt.allocPrint(allocator, "{s}?code=the-code&state=forged", .{uri});
    defer allocator.free(target);

    try get(allocator, io, target);

    try testing.expectError(Error.Timeout, listener.wait(std.time.ns_per_ms * 250));
}

test "two listeners started at once land on different ports" {
    const allocator = testing.allocator;
    const io = testing.io;

    var first = try Listener.start(allocator, io, .{ .state = "one" });
    defer first.deinit();

    var second = try Listener.start(allocator, io, .{ .state = "two", .port = first.port });
    defer second.deinit();

    try testing.expect(first.port != second.port);
}

/// Drive one GET at the listener and drop the response. The tests only care
/// that the handler ran.
fn get(allocator: std.mem.Allocator, io: std.Io, target: []const u8) !void {
    var client: std.http.Client = .{ .io = io, .allocator = allocator };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(target), .{ .keep_alive = false });
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    var transfer_buffer: [4096]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try response.reader(&transfer_buffer).streamRemaining(&discard.writer);
}
