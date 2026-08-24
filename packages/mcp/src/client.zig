//! One connection to one MCP server.
//!
//! Settles a protocol revision on connect, then answers three questions: what
//! tools are there, run this one, and go away. Everything about which revision
//! is in force lives in `protocol.zig`; this file only asks it.
//!
//! Blocking throughout. There is no read deadline: a server that never answers
//! holds the calling thread, and the caller is expected to be somewhere that
//! can be cancelled from outside.

const std = @import("std");
const testing = std.testing;

const jsonrpc = @import("jsonrpc.zig");
const protocol = @import("protocol.zig");
const Transport = @import("transport/transport.zig");
const Auth = @import("oauth/auth.zig");
const flow = @import("oauth/flow.zig");

const Client = @This();

/// How many `tools/list` pages are followed before giving up. A server paging
/// forever is a broken server, not a big one.
const max_pages: usize = 64;

pub const Error = error{
    /// The server offered no revision this client speaks.
    NoSharedRevision,
    /// The server answered a request with something that is not a result.
    MalformedReply,
    /// The server refused the request. `lastError` has what it said.
    RequestFailed,
    /// The server needs more input before it can answer, which this client
    /// cannot yet provide.
    InputRequired,
};

pub const Options = struct {
    /// How to reach the server. The tag names the wire; each variant carries
    /// the configuration that transport needs.
    transport: Transport.Options,
    /// Who to say we are.
    client: protocol.Implementation,
    /// Force a revision instead of negotiating one. For a server known to
    /// mishandle the probe.
    revision: ?protocol.Revision = null,
    /// How to get credentials when the server asks for them. Null means an
    /// `Unauthorized` is reported to the caller rather than acted on, which is
    /// what a stdio server wants: there is nobody to authorize with.
    authorization: ?Authorization = null,
};

/// What a client needs to answer a `401` on its own.
pub const Authorization = struct {
    /// Where tokens and client registrations live. Borrowed, and must outlive
    /// the client.
    store: *Auth,
    /// How to run the flow when one is needed. Its `challenge` is filled in
    /// per attempt from what the server actually sent.
    flow: flow.Options,
    /// Whether this client may start an authorization the user has to finish.
    ///
    /// False refuses to open a browser: a stored token is refreshed silently,
    /// but a server that needs signing in from scratch is reported as
    /// unauthorized instead. That is what a program starting up wants - the
    /// alternative is a browser window nobody asked for, and minutes of
    /// blocking before the first frame is drawn.
    interactive: bool = true,
};

allocator: std.mem.Allocator,
io: std.Io,
/// The concrete transport, behind the vtable. Both stdio and HTTP plug in here
/// without the client knowing which it is, which is the whole point of the
/// seam. The pointer is into the concrete transport at its embedded
/// `Transport` field; the erased fns recover the parent via `@fieldParentPtr`,
/// and `deinit` frees it.
transport: *Transport,
ids: jsonrpc.Ids = .{},
authorization: ?Authorization = null,
revision: protocol.Revision,
client: protocol.Implementation,
/// What the server said the last time it refused something, owned here so the
/// caller can report it after the arena holding the reply is gone.
last_error: ?[]u8 = null,

/// Connect, agree a revision, and be ready to list.
pub fn connect(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Client {
    const transport = try Transport.start(allocator, io, options.transport);
    errdefer transport.deinit();

    const self = try allocator.create(Client);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .transport = transport,
        .revision = options.revision orelse .v2026_07_28,
        .client = options.client,
        .authorization = options.authorization,
    };

    // A token we already hold goes on before anything is sent. Without this
    // every session would open with a pointless round trip to be refused.
    self.prime();

    if (options.revision) |forced| {
        if (forced.handshakes()) try self.initialize(forced);
    } else {
        try self.negotiate();
    }

    return self;
}

pub fn close(self: *Client) void {
    self.transport.deinit();
    if (self.last_error) |message| self.allocator.free(message);
    self.allocator.destroy(self);
}

/// What the server said when it last refused something. Empty when it has not.
pub fn lastError(self: *const Client) []const u8 {
    return self.last_error orelse "";
}

/// Work out which revision to speak.
///
/// `server/discover` is only required from `2026-07-28`. An older server may
/// refuse it with a JSON-RPC error or, as at least one deployed server does,
/// with a 4xx. Both mean the same thing: ask the old way.
///
/// `server/discover` is required from `2026-07-28` and absent before it, which
/// makes it the probe: an answer settles the version outright, and a
/// method-not-found means the server is old enough to want a handshake.
fn negotiate(self: *Client) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (self.request(arena, "server/discover", null)) |result| {
        const offered = try protocol.parseDiscover(arena, result);
        self.revision = protocol.best(offered) orelse return Error.NoSharedRevision;
        self.announceRevision();
        if (self.revision.handshakes()) try self.initialize(self.revision);
        return;
    } else |err| switch (err) {
        Error.RequestFailed,
        Error.MalformedReply,
        Transport.Error.RequestRejected,
        Transport.Error.UnsupportedResponse,
        Transport.Error.UnexpectedStatus,
        => {},
        else => return err,
    }

    // Refused. Either the method is unknown, which means an older server, or
    // the version was rejected, which means one that wants to be asked
    // differently. Both are answered by the handshake.
    try self.initialize(.v2025_11_25);
}

/// The old revision's handshake: `initialize`, then a notification saying we
/// have taken in the answer.
fn initialize(self: *Client, revision: protocol.Revision) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var params: std.Io.Writer.Allocating = .init(arena);
    try protocol.writeInitializeParams(&params.writer, revision, self.client);

    const result = try self.request(arena, "initialize", params.written());

    // The server names the revision it will actually speak, which need not be
    // the one asked for. An answer we do not know leaves the asked-for one in
    // place: it is the only one we could have been talking anyway.
    self.revision = protocol.parseInitialize(result) orelse revision;
    self.announceRevision();

    var out: std.Io.Writer.Allocating = .init(arena);
    try jsonrpc.writeNotification(&out.writer, "notifications/initialized", null);
    try self.sendAuthorized(out.written());
}

/// Every tool the server offers, following pagination. Allocated in `arena`.
pub fn listTools(self: *Client, arena: std.mem.Allocator) ![]const protocol.Tool {
    var all: std.ArrayList(protocol.Tool) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;

    while (pages < max_pages) : (pages += 1) {
        var params: std.Io.Writer.Allocating = .init(arena);
        try protocol.writeListParams(&params.writer, self.revision, self.client, cursor);

        const result = try self.request(arena, "tools/list", params.written());
        const page = try protocol.parseToolList(arena, result);
        try all.appendSlice(arena, page.tools);

        const next = page.next_cursor orelse break;
        if (next.len == 0) break;
        cursor = next;
    }

    return all.toOwnedSlice(arena);
}

/// Run one tool. `arguments` is the raw JSON object a model produced.
pub fn call(
    self: *Client,
    arena: std.mem.Allocator,
    name: []const u8,
    arguments: []const u8,
) !protocol.CallResult {
    var params: std.Io.Writer.Allocating = .init(arena);
    try protocol.writeCallParams(&params.writer, self.revision, self.client, name, arguments);

    const result = try self.request(arena, "tools/call", params.written());
    const parsed = try protocol.parseCallResult(arena, result);

    // A server asking for more input is answered by retrying the call with the
    // answers attached. Until that exists, saying so beats handing back an
    // interim result as though it were the answer.
    if (parsed.result_type == .input_required) return Error.InputRequired;

    return parsed;
}

/// Send a request and read until its reply arrives.
///
/// Anything else the server says in the meantime is dealt with on the way past:
/// a notification is dropped, and a request is refused, because a server left
/// waiting on an answer it will never get is a server that stops responding.
fn request(
    self: *Client,
    arena: std.mem.Allocator,
    method: []const u8,
    params: ?[]const u8,
) !std.json.Value {
    const id = self.ids.take();

    var out: std.Io.Writer.Allocating = .init(arena);
    try jsonrpc.writeRequest(&out.writer, id, method, params);
    try self.sendAuthorized(out.written());

    while (true) {
        const line = try self.transport.receive();
        const message = jsonrpc.Message.parse(arena, line) catch continue;

        if (message.isCall()) {
            if (message.id) |theirs| try self.refuse(arena, theirs, message.method.?);
            continue;
        }

        const theirs = message.id orelse continue;
        if (!theirs.eql(id)) continue;

        if (message.err) |failure| {
            try self.remember(failure);
            return Error.RequestFailed;
        }
        return message.result orelse Error.MalformedReply;
    }
}

/// Tell the transport which revision both ends settled on, so every later
/// request says so. A transport with nowhere to put it answers false, which is
/// not a failure: stdio settles the version in the handshake and never
/// mentions it again.
fn announceRevision(self: *Client) void {
    _ = self.transport.setProtocolVersion(self.revision.string()) catch {};
}

/// Send one message, and if the server refuses it for want of credentials,
/// get new ones and send it again.
///
/// Exactly one retry. A second refusal with a token minted seconds earlier is
/// the server saying no to this client, not a token that had gone stale, and
/// trying harder would only mean opening a browser in a loop.
fn sendAuthorized(self: *Client, message: []const u8) !void {
    self.transport.send(message) catch |err| {
        if (err != Transport.Error.Unauthorized) return err;
        if (!try self.reauthorize()) return err;
        try self.transport.send(message);
    };
}

/// Put a token we already have on the transport, if there is one to be had
/// without asking the user anything. Failures are deliberately swallowed: this
/// is an optimisation, and the `401` path is what actually has to work.
fn prime(self: *Client) void {
    const auth = self.authorization orelse return;
    const token = flow.accessToken(self.allocator, self.io, auth.store, auth.flow) catch return;
    _ = self.transport.setBearer(token orelse return) catch return;
}

/// Get credentials the server will accept and install them. False means there
/// is no way to: no authorization configured, or a transport with no notion of
/// it. The caller reports the refusal in that case.
///
/// A refresh is tried before a browser, and a refusal is taken at its word: if
/// the server rejected the token we hold, a stored copy of that same token is
/// no answer, whatever this end believes about its expiry.
fn reauthorize(self: *Client) !bool {
    const auth = self.authorization orelse return false;

    var options = auth.flow;
    options.challenge = self.transport.challenge();

    const token = token: {
        if (flow.refresh(self.allocator, self.io, auth.store, options)) |fresh| {
            break :token fresh;
        } else |_| {
            if (!auth.interactive) return false;
            break :token try flow.authorize(self.allocator, self.io, auth.store, options);
        }
    };

    if (!try self.transport.setBearer(token)) return false;

    // Tokens are worth keeping across runs; a store with nowhere to go says so
    // and is left alone.
    auth.store.save(self.io, null) catch {};
    return true;
}

/// Turn down a request from the server. Nothing this client offers is something
/// a server can ask for, so every one of them gets the same answer.
fn refuse(self: *Client, arena: std.mem.Allocator, id: jsonrpc.Id, method: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeAll("{\"jsonrpc\":\"" ++ jsonrpc.version ++ "\",\"id\":");
    try id.write(w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{jsonrpc.ErrorObject.method_not_found});
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    try w.writeAll("}}");

    try self.transport.send(out.written());
}

/// Keep what the server complained about, in memory this client owns.
fn remember(self: *Client, failure: jsonrpc.ErrorObject) !void {
    if (self.last_error) |old| self.allocator.free(old);
    self.last_error = try std.fmt.allocPrint(
        self.allocator,
        "{s} (code {d})",
        .{ failure.message, failure.code },
    );
}

/// A server script for the tests: a shell that answers a fixed sequence of
/// lines. Enough to drive negotiation and a call without a real MCP server.
fn scripted(replies: []const u8) [3][]const u8 {
    return .{ "sh", "-c", replies };
}

/// Build a server script from groups of replies: one group per request the
/// client makes, and every line in the group written before the next request is
/// waited for.
///
/// Grouping is the whole point. A flat line-per-read script deadlocks the
/// moment a request is answered by more than one message - a notification
/// followed by the result, say - because the script would sit waiting for a
/// request the client is not going to send until it has been answered.
/// A shell server that answers each request with one group of lines.
///
/// `linger` decides what it does once the script is spent: staying alive gives
/// a trailing notification somewhere to go, and exiting is how a test asks for
/// a server that dies.
fn replyScript(comptime groups: []const []const []const u8, comptime linger: bool) []const u8 {
    comptime var script: []const u8 = "";
    inline for (groups) |group| {
        script = script ++ "read -r _ 2>/dev/null; ";
        inline for (group) |line| {
            script = script ++ "printf '%s\\n' '" ++ line ++ "'; ";
        }
    }
    return if (linger) script ++ "cat > /dev/null" else script ++ "exit 0";
}

fn connectScripted(comptime groups: []const []const []const u8) !*Client {
    return connectScript(comptime replyScript(groups, true));
}

/// The same, but the server exits once its script is spent.
fn connectScriptedExiting(comptime groups: []const []const []const u8) !*Client {
    return connectScript(comptime replyScript(groups, false));
}

fn connectScript(comptime script: []const u8) !*Client {
    const argv = comptime scripted(script);
    return Client.connect(testing.allocator, testing.io, .{
        .transport = .{ .stdio = .{ .argv = &argv } },
        .client = .{ .name = "test", .version = "1" },
    });
}

test "a server that answers discovery settles on the new revision" {
    var client = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\",\"2025-11-25\"]}}"},
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    try testing.expectEqual(protocol.Revision.v2026_07_28, client.revision);
}

test "a server that does not know discovery falls back to the handshake" {
    var client = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"unknown method\"}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-11-25\",\"serverInfo\":{\"name\":\"old\"}}}"},
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    try testing.expectEqual(protocol.Revision.v2025_11_25, client.revision);
}

test "a server offering nothing we speak is refused" {
    const result = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"1999-01-01\"]}}"},
    });
    if (result) |client| {
        client.close();
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        try testing.expectEqual(Error.NoSharedRevision, err);
    }
}

test "tools are listed and a call comes back as text" {
    var client = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"hello there\"}]}}"},
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = try client.listTools(arena);
    try testing.expectEqual(@as(usize, 1), tools.len);
    try testing.expectEqualStrings("echo", tools[0].name);
    try testing.expectEqualStrings("Echo", tools[0].description);

    const result = try client.call(arena, "echo", "{\"text\":\"hello there\"}");
    try testing.expectEqualStrings("hello there", result.text);
    try testing.expect(!result.is_error);
}

test "a refused call reports what the server said" {
    var client = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"missing argument path\"}}"},
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(Error.RequestFailed, client.call(arena_state.allocator(), "read", "{}"));
    try testing.expect(std.mem.indexOf(u8, client.lastError(), "missing argument") != null);
    try testing.expect(std.mem.indexOf(u8, client.lastError(), "-32602") != null);
}

test "a notification arriving mid-call is stepped over" {
    var client = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        // Both of these follow the one `tools/call` request.
        &.{
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}",
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}",
        },
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const result = try client.call(arena_state.allocator(), "anything", "{}");
    try testing.expectEqualStrings("done", result.text);
}

test "an input_required result is reported rather than mistaken for an answer" {
    var client = connectScripted(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":[]}}"},
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(Error.InputRequired, client.call(arena_state.allocator(), "ask", "{}"));
}

test "a server that dies is an error, not a hang" {
    var client = connectScriptedExiting(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
    }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer client.close();

    // The scripted server answers the negotiation and exits. Nothing needs to
    // kill it: the next call finds the far end of the pipe already gone, which
    // is exactly the situation being tested.

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(
        Transport.Error.ServerClosed,
        client.call(arena_state.allocator(), "anything", "{}"),
    );
}

/// A transport that refuses everything for want of credentials, for exercising
/// the `401` path without a server to be refused by.
const RefusingTransport = struct {
    transport: Transport,
    sends: usize = 0,

    const vtable: Transport.VTable = .{
        .send = sendErased,
        .receive = receiveErased,
        .deinit = deinitErased,
    };

    fn init() RefusingTransport {
        return .{ .transport = .{ .vtable = &vtable } };
    }

    fn sendErased(t: *Transport, _: []const u8) Transport.Error!void {
        const self: *RefusingTransport = @alignCast(@fieldParentPtr("transport", t));
        self.sends += 1;
        return Transport.Error.Unauthorized;
    }

    fn receiveErased(_: *Transport) Transport.Error![]const u8 {
        return Transport.Error.ServerClosed;
    }

    fn deinitErased(_: *Transport) void {}
};

fn testClient(transport: *Transport) Client {
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .transport = transport,
        .revision = .v2026_07_28,
        .client = .{ .name = "test", .version = "1" },
    };
}

test "a refusal with no authorization configured is reported, not acted on" {
    var refusing = RefusingTransport.init();
    var client = testClient(&refusing.transport);

    try testing.expectError(Transport.Error.Unauthorized, client.sendAuthorized("{}"));

    // Sent once. Retrying without a way to get credentials would just be the
    // same refusal again.
    try testing.expectEqual(@as(usize, 1), refusing.sends);
}

test "priming does nothing when there is no authorization" {
    var refusing = RefusingTransport.init();
    var client = testClient(&refusing.transport);

    client.prime();
    try testing.expectEqual(@as(usize, 0), refusing.sends);
}

test "priming is a no-op when the store has nothing for this server" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    var refusing = RefusingTransport.init();
    var client = testClient(&refusing.transport);
    client.authorization = .{
        .store = &store,
        .flow = .{
            .name = "files",
            .server_url = "https://mcp.example/mcp",
            .client_name = "test",
        },
    };

    client.prime();
    try testing.expectEqual(@as(usize, 0), refusing.sends);
}

test "a transport with no notion of credentials reports an empty challenge" {
    var refusing = RefusingTransport.init();
    try testing.expectEqualStrings("", refusing.transport.challenge());
    try testing.expect(!try refusing.transport.setBearer("token"));
}

test "a non-interactive client refuses rather than opening a browser" {
    var store: Auth = .init(testing.allocator);
    defer store.deinit();

    var refusing = RefusingTransport.init();
    var client = testClient(&refusing.transport);
    client.authorization = .{
        .store = &store,
        .flow = .{
            .name = "files",
            .server_url = "https://mcp.example/mcp",
            .client_name = "test",
        },
        .interactive = false,
    };

    try testing.expectError(Transport.Error.Unauthorized, client.sendAuthorized("{}"));
    try testing.expectEqual(@as(usize, 1), refusing.sends);
}
