//! MCP servers as synth tools.
//!
//! The only file that knows both sides. `src/mcp/` is its own module and talks
//! in MCP terms; the registry talks in `tool.Tool`. This turns each remote tool
//! into a local one, and each local call back into a remote one.
//!
//! Every MCP tool needs approval before it runs. The protocol has a
//! `readOnlyHint` annotation, and the spec is explicit that a server's
//! description of its own behaviour is untrusted - so a hint from something we
//! just launched is not grounds for skipping the gate.

const std = @import("std");
const testing = std.testing;

const pkg = @import("pkg");
const mcp = @import("mcp");
const tool = @import("tool.zig");
const Registry = @import("registry.zig");

/// How a tool from a server is named locally: `mcp__<server>__<tool>`.
///
/// Long, and worth it. A server offering `read` would otherwise shadow the
/// built-in, two servers offering the same name would collide with each other,
/// and neither failure would be visible in a transcript.
pub const prefix = "mcp__";

/// Cap on a tool name. OpenAI rejects a function name over 64 characters, and a
/// rejected request fails the whole turn rather than the one tool, so the limit
/// is enforced here rather than discovered there.
pub const max_name_bytes: usize = 64;

/// One server to connect to.
pub const Server = struct {
    /// What it is called locally. Appears in every tool name it offers.
    name: []const u8,
    /// How to reach it. Which one a config entry means is settled by whether
    /// it names a `url` or a `command`.
    transport: Transport,
    enabled: bool = true,

    pub const Transport = union(enum) {
        /// Run as a child process and spoken to over its pipes.
        stdio: Stdio,
        /// A remote server over Streamable HTTP, possibly behind OAuth.
        http: Http,
    };

    pub const Stdio = struct {
        command: []const u8,
        args: []const []const u8 = &.{},
        /// Extra environment for the server, on top of this process's.
        env: []const EnvPair = &.{},
        cwd: ?[]const u8 = null,
    };

    pub const Http = struct {
        url: []const u8,
        /// Sent with every request, for a server behind a static key rather
        /// than an OAuth flow.
        headers: []const std.http.Header = &.{},
        /// What to ask the authorization server for. Empty sends no `scope`
        /// at all, which is right for a server that publishes its own
        /// defaults and wrong for one that requires a particular scope, so it
        /// is worth being able to say.
        scopes: []const []const u8 = &.{},
    };

    pub const EnvPair = struct { name: []const u8, value: []const u8 };
};

/// What to tell someone about a server that would not start.
///
/// `Unauthorized` is the one worth translating: it is not a fault so much as a
/// step nobody has taken yet, and the answer is a command rather than a
/// bug report.
fn reasonFor(err: anyerror) []const u8 {
    return switch (err) {
        error.Unauthorized => "not signed in - run `" ++ pkg.name ++ " mcp auth <name>`",
        error.RequestRejected => "the server refused the request",
        error.ServerError => "the server failed to answer",
        error.ConnectionFailed => "could not be reached",
        else => @errorName(err),
    };
}

/// What went wrong bringing a server up, kept so the UI can say so.
pub const Failure = struct {
    server: []const u8,
    reason: []const u8,
};

/// The connected servers and the tools they contributed.
///
/// Owns its clients and every string it registered. Touched from the thread
/// that built it and from the tool worker, never both at once: servers are
/// connected before the loop starts, and calls are run one at a time.
pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Storage for names, bindings and failure text.
    arena: std.heap.ArenaAllocator,
    connections: std.ArrayList(*Connection) = .empty,
    failures: std.ArrayList(Failure) = .empty,
    /// Where a server's own logging goes. A TUI has a screen to protect; a
    /// headless run would rather see why a server refused to start.
    stderr: mcp.Transport.Stderr = .ignore,
    /// Where OAuth tokens and client registrations are kept. Null turns
    /// authorization off: a server that demands it fails to connect rather
    /// than opening a browser nobody asked for.
    auth: ?*mcp.Auth = null,
    /// How the user is sent to an authorization server.
    open: mcp.Browser.Open = mcp.Browser.defaultOpen,
    job: ?*Job = null,
    /// What was configured, kept so a server turned on later can be reached
    /// without the caller holding the list too. Borrowed.
    servers: []const Server = &.{},
    /// Who to say we are, for a connection made after startup.
    client: mcp.Implementation = .{ .name = "", .version = "" },

    pub const Connection = struct {
        name: []const u8,
        client: *mcp.Client,
        /// How many tools this server contributed.
        tools: usize = 0,
        /// What the server offered, duped into the host's arena at connect
        /// time and registered later. Connecting happens on a worker and the
        /// registry belongs to the thread that draws, so the two are separate
        /// steps rather than one.
        offered: []const mcp.Tool = &.{},
        installed: bool = false,
    };

    /// A `connectAll` running on a worker.
    const Job = struct {
        host: *Host,
        servers: []const Server,
        client: mcp.Implementation,
        future: std.Io.Future(void) = undefined,
        done: std.atomic.Value(bool) = .init(false),
    };

    /// What a registered tool carries in `userdata`, so one handler can serve
    /// every server.
    const Binding = struct {
        connection: *Connection,
        /// The name on the server, which is the local name without its prefix.
        remote: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Host {
        return .{ .allocator = allocator, .io = io, .arena = .init(allocator) };
    }

    pub fn deinit(self: *Host) void {
        self.wait();
        for (self.connections.items) |connection| connection.client.close();
        self.connections.deinit(self.allocator);
        self.failures.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Whether anything is connected. False is the ordinary case: most projects
    /// configure no servers at all.
    pub fn any(self: *const Host) bool {
        return self.connections.items.len > 0;
    }

    /// One line per server, connected or not, for a caller that wants to say what
    /// happened. Empty when nothing was configured, so a caller can print nothing.
    /// Caller owns the result.
    ///
    /// This exists because a server that fails to start is otherwise invisible: its
    /// tools are simply absent, which looks exactly like never having configured it.
    pub fn report(self: *const Host, allocator: std.mem.Allocator) ![]const u8 {
        if (self.connections.items.len == 0 and self.failures.items.len == 0) {
            return allocator.dupe(u8, "");
        }

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        for (self.connections.items, 0..) |connection, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.print("{s} ({d} tool{s})", .{
                connection.name,
                connection.tools,
                if (connection.tools == 1) "" else "s",
            });
        }

        for (self.failures.items, 0..) |failure, i| {
            if (self.connections.items.len > 0 or i > 0) try out.writer.writeAll(", ");
            try out.writer.print("{s} FAILED: {s}", .{ failure.server, failure.reason });
        }

        return out.toOwnedSlice();
    }

    /// Connect every enabled server and register what it offers.
    ///
    /// A server that will not start is recorded and skipped. One bad entry in a
    /// config file must not be the reason the program will not open.
    /// Connect every enabled server and register what they offer. Blocking,
    /// which is what a headless run wants: there is nothing to draw meanwhile.
    pub fn connectAll(
        self: *Host,
        registry: *Registry,
        servers: []const Server,
        client: mcp.Implementation,
    ) !void {
        self.servers = servers;
        self.client = client;
        self.reach(servers, client);
        _ = try self.install(registry);
    }

    /// The same, on a worker.
    ///
    /// A cold `npx -y` resolving a package takes ten seconds and an HTTP server
    /// takes a round trip each, none of which the first frame should wait for.
    /// The worker only connects and asks what is on offer; registering happens
    /// in `install`, on the thread that owns the registry.
    pub fn beginConnectAll(
        self: *Host,
        servers: []const Server,
        client: mcp.Implementation,
    ) !void {
        if (self.job != null) return;

        self.servers = servers;
        self.client = client;

        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);

        job.* = .{ .host = self, .servers = servers, .client = client };
        job.future = try self.io.concurrent(reachAll, .{job});
        self.job = job;
    }

    /// Whether a worker is still out.
    pub fn connecting(self: *const Host) bool {
        return self.job != null;
    }

    /// Whether a worker has finished, exactly once. The caller answers by
    /// calling `install`.
    pub fn settled(self: *Host) bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;

        job.future.await(self.io);
        self.allocator.destroy(job);
        self.job = null;
        return true;
    }

    /// Stop a running worker, for teardown.
    ///
    /// Cancelled rather than awaited: a worker is most likely blocked on a
    /// server that is slow to start or a socket that will not answer, and
    /// waiting for it is what made quitting mid-connect hang. Cancelling
    /// signals the blocked call and waits only for the unwind.
    pub fn wait(self: *Host) void {
        const job = self.job orelse return;
        job.future.cancel(self.io);
        self.allocator.destroy(job);
        self.job = null;
    }

    fn reachAll(job: *Job) void {
        defer job.done.store(true, .release);
        job.host.reach(job.servers, job.client);
    }

    /// Open every enabled server and ask what it offers. Touches nothing the
    /// drawing thread owns.
    fn reach(self: *Host, servers: []const Server, client: mcp.Implementation) void {
        for (servers) |server| {
            if (!server.enabled) continue;
            if (self.auth) |store| {
                if (!store.isEnabled(server.name)) continue;
            }
            if (self.find(server.name) != null) continue;

            self.dropFailures(server.name);
            self.connect(server, client) catch |err| {
                self.recordFailure(server.name, reasonFor(err)) catch {};
            };
        }
    }

    /// The connection for `name`, or null when it is not up.
    pub fn find(self: *const Host, name: []const u8) ?*Connection {
        for (self.connections.items) |connection| {
            if (std.mem.eql(u8, connection.name, name)) return connection;
        }
        return null;
    }

    /// Close a server and take its tools back out of the registry. False when
    /// it was not connected in the first place.
    pub fn disconnect(self: *Host, registry: *Registry, name: []const u8) bool {
        // Before the early return: a server that never connected has a
        // failure entry, and turning it off should take that away too.
        self.dropFailures(name);

        const at = for (self.connections.items, 0..) |connection, i| {
            if (std.mem.eql(u8, connection.name, name)) break i;
        } else return false;

        const connection = self.connections.items[at];
        if (connection.installed) {
            var scratch: std.heap.ArenaAllocator = .init(self.allocator);
            defer scratch.deinit();

            for (connection.offered) |remote| {
                const local = localName(scratch.allocator(), connection.name, remote.name) catch continue;
                _ = registry.unregister(local);
            }
        }

        connection.client.close();
        _ = self.connections.orderedRemove(at);
        return true;
    }

    /// Forget what was said about a server last time it was tried, so a retry
    /// does not read as two failures.
    fn dropFailures(self: *Host, name: []const u8) void {
        var i: usize = self.failures.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.failures.items[i].server, name)) {
                _ = self.failures.orderedRemove(i);
            }
        }
    }

    /// Register what the connected servers offered. Returns how many tools
    /// were added, so a caller knows whether the model has to be told again.
    pub fn install(self: *Host, registry: *Registry) !usize {
        var added: usize = 0;
        for (self.connections.items) |connection| {
            if (connection.installed) continue;
            connection.installed = true;

            for (connection.offered) |remote| {
                self.registerTool(registry, connection, remote) catch |err| {
                    try self.recordFailure(connection.name, @errorName(err));
                    continue;
                };
                added += 1;
            }
        }
        return added;
    }

    fn connect(
        self: *Host,
        server: Server,
        client: mcp.Implementation,
    ) !void {
        const arena = self.arena.allocator();

        const options: mcp.Transport.Options = switch (server.transport) {
            .stdio => |stdio| blk: {
                const argv = try arena.alloc([]const u8, stdio.args.len + 1);
                argv[0] = stdio.command;
                @memcpy(argv[1..], stdio.args);

                var environ: ?*const std.process.Environ.Map = null;
                if (stdio.env.len > 0) {
                    const map = try arena.create(std.process.Environ.Map);
                    map.* = .init(arena);
                    for (stdio.env) |pair| try map.put(pair.name, pair.value);
                    environ = map;
                }

                break :blk .{ .stdio = .{
                    .argv = argv,
                    .cwd = stdio.cwd,
                    .environ_map = environ,
                    .stderr = self.stderr,
                } };
            },
            .http => |http| .{ .http = .{ .url = http.url, .headers = http.headers } },
        };

        const authorization: ?mcp.Client.Authorization = switch (server.transport) {
            .stdio => null,
            .http => |http| if (self.auth) |store| .{
                .store = store,
                .flow = .{
                    .name = server.name,
                    .server_url = http.url,
                    .client_name = client.name,
                    .scopes = http.scopes,
                    .open = self.open,
                },
                .interactive = false,
            } else null,
        };

        const connected = try mcp.Client.connect(self.allocator, self.io, .{
            .transport = options,
            .client = client,
            .authorization = authorization,
        });
        errdefer connected.close();

        const connection = try arena.create(Connection);
        connection.* = .{ .name = try arena.dupe(u8, server.name), .client = connected };
        try self.connections.append(self.allocator, connection);

        // A server that connects but cannot be asked what it offers is still a
        // failure, just a later one; unwind it the same way.
        errdefer _ = self.connections.pop();

        var listing: std.heap.ArenaAllocator = .init(self.allocator);
        defer listing.deinit();

        const offered = try connected.listTools(listing.allocator());
        const kept = try arena.alloc(mcp.Tool, offered.len);
        for (offered, kept) |remote, *out| {
            out.* = .{
                .name = try arena.dupe(u8, remote.name),
                .description = try arena.dupe(u8, remote.description),
                .input_schema = try arena.dupe(u8, remote.input_schema),
            };
        }
        connection.offered = kept;
    }

    fn registerTool(
        self: *Host,
        registry: *Registry,
        connection: *Connection,
        remote: mcp.Tool,
    ) !void {
        const arena = self.arena.allocator();

        const name = try localName(arena, connection.name, remote.name);
        const binding = try arena.create(Binding);
        binding.* = .{ .connection = connection, .remote = try arena.dupe(u8, remote.name) };

        try registry.register(.{
            .name = name,
            .description = try describe(arena, connection.name, remote),
            .schema = try schemaFor(arena, remote.input_schema),
            .handler = call,
            // Never. See the note at the top of this file.
            .read_only = false,
            // Never either: one `Client` correlates replies by draining its
            // transport until an id matches, so two calls at once would eat
            // each other's answers.
            .parallel = false,
            .userdata = binding,
            // The registry frees these; they came from this host's arena, which
            // outlives it, so freeing is a no-op that keeps the rule simple.
            .owned = false,
        });
        connection.tools += 1;
    }

    /// Record why a server did not come up, replacing whatever was said about
    /// it last time. One entry per server: a server toggled off and on four
    /// times has failed once, not four times.
    fn recordFailure(self: *Host, server: []const u8, reason: []const u8) !void {
        const arena = self.arena.allocator();
        const owned_reason = try arena.dupe(u8, reason);

        for (self.failures.items) |*failure| {
            if (std.mem.eql(u8, failure.server, server)) {
                failure.reason = owned_reason;
                return;
            }
        }

        try self.failures.append(self.allocator, .{
            .server = try arena.dupe(u8, server),
            .reason = owned_reason,
        });
    }
};

/// Read the `mcp` block of `config.json` into servers to connect.
///
/// The shape is the one every other client uses, so a `claude_desktop_config`
/// entry can be pasted in unchanged:
///
/// ```json
/// {"mcp": {"servers": {
///   "files": {"command": "npx", "args": ["-y", "server-filesystem", "/tmp"]}
/// }}}
/// ```
///
/// A malformed entry is skipped rather than failing the read: one bad server
/// should cost that server, not the config file.
pub fn serversFromJson(arena: std.mem.Allocator, value: std.json.Value) ![]const Server {
    const root = switch (value) {
        .object => |o| o,
        else => return &.{},
    };
    const listed = switch (root.get("servers") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => return &.{},
    };

    var servers: std.ArrayList(Server) = .empty;

    var it = listed.iterator();
    while (it.next()) |entry| {
        const fields = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        if (entry.key_ptr.len == 0) continue;

        const transport: Server.Transport = t: {
            if (stringField(fields.get("url"))) |url| {
                if (url.len == 0) continue;
                break :t .{ .http = .{
                    .url = url,
                    .headers = try headerPairs(arena, fields.get("headers")),
                    .scopes = try stringList(arena, fields.get("scopes")),
                } };
            }

            const command = stringField(fields.get("command")) orelse continue;
            if (command.len == 0) continue;
            break :t .{ .stdio = .{
                .command = command,
                .args = try stringList(arena, fields.get("args")),
                .env = try envPairs(arena, fields.get("env")),
                .cwd = stringField(fields.get("cwd")),
            } };
        };

        try servers.append(arena, .{
            .name = entry.key_ptr.*,
            .transport = transport,
            .enabled = switch (fields.get("enabled") orelse std.json.Value{ .bool = true }) {
                .bool => |b| b,
                else => true,
            },
        });
    }

    return servers.toOwnedSlice(arena);
}

fn stringField(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |s| s,
        else => null,
    };
}

fn stringList(arena: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const found = value orelse return &.{};
    const items = switch (found) {
        .array => |a| a.items,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        try out.append(arena, stringField(item) orelse continue);
    }
    return out.toOwnedSlice(arena);
}

/// Headers sent with every request to a remote server. Same shape as the
/// environment block, and read the same way: an entry whose value is not a
/// string is skipped rather than failing the whole config.
fn headerPairs(arena: std.mem.Allocator, value: ?std.json.Value) ![]const std.http.Header {
    const found = value orelse return &.{};
    const fields = switch (found) {
        .object => |o| o,
        else => return &.{},
    };

    var out: std.ArrayList(std.http.Header) = .empty;
    var it = fields.iterator();
    while (it.next()) |entry| {
        try out.append(arena, .{
            .name = entry.key_ptr.*,
            .value = stringField(entry.value_ptr.*) orelse continue,
        });
    }
    return out.toOwnedSlice(arena);
}

fn envPairs(arena: std.mem.Allocator, value: ?std.json.Value) ![]const Server.EnvPair {
    const found = value orelse return &.{};
    const fields = switch (found) {
        .object => |o| o,
        else => return &.{},
    };

    var out: std.ArrayList(Server.EnvPair) = .empty;
    var it = fields.iterator();
    while (it.next()) |entry| {
        try out.append(arena, .{
            .name = entry.key_ptr.*,
            .value = stringField(entry.value_ptr.*) orelse continue,
        });
    }
    return out.toOwnedSlice(arena);
}

/// Run a remote tool. The binding in `userdata` says which server and which
/// name; everything else is the same as any other tool call.
/// How often a waiting call looks up to see whether it has been cancelled or
/// run out of time.
const poll_slice_ms: u64 = 25;

/// One call in flight on its own worker.
///
/// The call itself blocks on a socket or a pipe with nothing to interrupt it,
/// so the thread that waits has to be a different one from the thread that
/// blocks. This is that split: the worker makes the call, and the tool handler
/// watches the clock and the cancel flag.
const Call = struct {
    binding: *Host.Binding,
    arena: std.mem.Allocator,
    arguments: []const u8,
    future: std.Io.Future(void) = undefined,
    done: std.atomic.Value(bool) = .init(false),
    result: ?mcp.CallResult = null,
    failed: ?anyerror = null,

    fn run(self: *Call) void {
        defer self.done.store(true, .release);

        if (self.binding.connection.client.call(self.arena, self.binding.remote, self.arguments)) |result| {
            self.result = result;
        } else |err| {
            self.failed = err;
        }
    }
};

fn call(ctx: tool.Context, input: tool.Input) !tool.Output {
    const raw = ctx.userdata orelse return tool.Output.err(
        try ctx.allocator.dupe(u8, "this tool is not connected to a server"),
    );
    const binding: *Host.Binding = @ptrCast(@alignCast(raw));

    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var arguments: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(input.arguments, .{}, &arguments.writer);

    var pending: Call = .{
        .binding = binding,
        .arena = arena,
        .arguments = arguments.written(),
    };
    pending.future = try ctx.io.concurrent(Call.run, .{&pending});

    var abandoned = false;
    while (!pending.done.load(.acquire)) {
        if (ctx.shouldStop()) {
            abandoned = true;
            break;
        }
        std.Io.sleep(ctx.io, .fromMilliseconds(poll_slice_ms), .awake) catch break;
    }

    // Reaped either way: the arena the worker writes into dies with this frame.
    if (abandoned) pending.future.cancel(ctx.io) else pending.future.await(ctx.io);

    if (abandoned) {
        const why = if (ctx.givenUp()) "cancelled" else "timed out";
        return tool.Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "{s} on {s}: {s}",
            .{ binding.remote, binding.connection.name, why },
        ));
    }

    if (pending.failed) |err| {
        const detail = binding.connection.client.lastError();
        return tool.Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "{s} on {s}: {s}{s}{s}",
            .{
                binding.remote,
                binding.connection.name,
                @errorName(err),
                if (detail.len > 0) " - " else "",
                detail,
            },
        ));
    }

    const result = pending.result orelse return tool.Output.err(
        try ctx.allocator.dupe(u8, "the server said nothing"),
    );

    const content = try ctx.allocator.dupe(u8, result.text);
    return if (result.is_error) tool.Output.err(content) else tool.Output.ok(content);
}

/// The local name for a remote tool: `mcp__<server>__<tool>`, with anything a
/// provider would reject replaced, and the middle trimmed rather than the end
/// if it will not fit.
pub fn localName(
    allocator: std.mem.Allocator,
    server: []const u8,
    remote: []const u8,
) ![]const u8 {
    // The buffer is scratch and always freed; both paths out of here hand back
    // an allocation of their own, so a caller frees one thing however it went.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll(prefix);
    try writeSanitized(&out.writer, server);
    try out.writer.writeAll("__");
    try writeSanitized(&out.writer, remote);

    const full = out.written();
    if (full.len <= max_name_bytes) return allocator.dupe(u8, full);

    // Over the limit. The tail is the tool's own name and the part that
    // distinguishes one call from another, so the server segment gives way.
    const tail = full[full.len - (max_name_bytes - prefix.len - 2) ..];
    return std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, tail });
}

/// Write `text` with every character a function name may not contain replaced
/// by `_`. Providers validate names against `[a-zA-Z0-9_-]`, and a rejected
/// name fails the whole request.
fn writeSanitized(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        try w.writeByte(if (safe) c else '_');
    }
}

/// The description a model is shown, which says where the tool came from. A
/// bare description does not, and a model choosing between two similar tools on
/// two servers has nothing else to go on.
fn describe(allocator: std.mem.Allocator, server: []const u8, remote: mcp.Tool) ![]const u8 {
    if (remote.description.len == 0) {
        return std.fmt.allocPrint(allocator, "`{s}` from the {s} MCP server.", .{ remote.name, server });
    }
    return std.fmt.allocPrint(allocator, "{s}\n\nFrom the {s} MCP server.", .{ remote.description, server });
}

/// The argument schema, or an empty object schema when the server sent
/// something unusable. A tool with no schema is still callable; a request
/// carrying `null` where a schema belongs is not.
fn schemaFor(allocator: std.mem.Allocator, input_schema: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input_schema, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) {
        return allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}");
    }
    if (trimmed[0] != '{') {
        return allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{}}");
    }
    return allocator.dupe(u8, trimmed);
}

test "a local name is prefixed, namespaced and safe for a provider" {
    const arena_allocator = testing.allocator;

    const plain = try localName(arena_allocator, "files", "read_file");
    defer arena_allocator.free(plain);
    try testing.expectEqualStrings("mcp__files__read_file", plain);

    const messy = try localName(arena_allocator, "my server!", "read/file");
    defer arena_allocator.free(messy);
    try testing.expectEqualStrings("mcp__my_server___read_file", messy);

    for (messy) |c| {
        try testing.expect(std.ascii.isAlphanumeric(c) or c == '_' or c == '-');
    }
}

test "a name too long for a provider is trimmed to fit" {
    const allocator = testing.allocator;

    const long = try localName(allocator, "a" ** 40, "b" ** 40);
    defer allocator.free(long);

    try testing.expect(long.len <= max_name_bytes);
    try testing.expect(std.mem.startsWith(u8, long, prefix));
    // What survives is the end: the tool's own name, not the server's.
    try testing.expect(std.mem.endsWith(u8, long, "b" ** 10));
}

test "a missing or unusable schema becomes an empty object" {
    const allocator = testing.allocator;

    for ([_][]const u8{ "", "null", "  ", "\"a string\"", "[1,2]" }) |input| {
        const schema = try schemaFor(allocator, input);
        defer allocator.free(schema);
        try testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", schema);
    }

    const real = try schemaFor(allocator, "{\"type\":\"object\",\"properties\":{\"path\":{}}}");
    defer allocator.free(real);
    try testing.expect(std.mem.indexOf(u8, real, "path") != null);
}

test "a description says which server a tool came from" {
    const allocator = testing.allocator;

    const described = try describe(allocator, "files", .{
        .name = "read_file",
        .description = "Read a file",
        .input_schema = "{}",
    });
    defer allocator.free(described);
    try testing.expect(std.mem.startsWith(u8, described, "Read a file"));
    try testing.expect(std.mem.indexOf(u8, described, "files MCP server") != null);

    const bare = try describe(allocator, "files", .{
        .name = "read_file",
        .description = "",
        .input_schema = "{}",
    });
    defer allocator.free(bare);
    try testing.expect(std.mem.indexOf(u8, bare, "read_file") != null);
    try testing.expect(std.mem.indexOf(u8, bare, "files MCP server") != null);
}

test "a tool with no binding says so rather than crashing" {
    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const output = try call(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
    }, .{ .arguments = parsed.value });
    defer testing.allocator.free(output.content);

    try testing.expect(output.is_error);
    try testing.expect(std.mem.indexOf(u8, output.content, "not connected") != null);
}

/// A scripted server, the same trick the client's own tests use: one group of
/// replies per request the client makes.
fn scriptedServer(comptime groups: []const []const []const u8) [3][]const u8 {
    comptime var script: []const u8 = "";
    inline for (groups) |group| {
        script = script ++ "read -r _ 2>/dev/null; ";
        inline for (group) |line| {
            script = script ++ "printf '%s\\n' '" ++ line ++ "'; ";
        }
    }
    return .{ "sh", "-c", script ++ "cat > /dev/null" };
}

test "a server's tools are registered, called, and cleaned up" {
    const allocator = testing.allocator;

    const argv = comptime scriptedServer(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"file contents\"}]}}"},
    });

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    host.connectAll(&registry, &.{.{
        .name = "files",
        .transport = .{ .stdio = .{
            .command = argv[0],
            .args = argv[1..],
        } },
    }}, .{ .name = "synth", .version = "test" }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };

    if (!host.any()) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 0), host.failures.items.len);

    const registered = registry.get("mcp__files__read_file") orelse return error.TestUnexpectedResult;
    // A server's own claim about itself is not grounds for skipping the gate.
    try testing.expect(!registered.read_only);
    try testing.expect(std.mem.indexOf(u8, registered.description, "files MCP server") != null);

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    var arguments = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"path\":\"a.txt\"}",
        .{},
    );
    defer arguments.deinit();

    const output = try registry.execute(.{
        .allocator = allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
    }, "mcp__files__read_file", arguments.value);
    defer allocator.free(output.content);

    try testing.expect(!output.is_error);
    try testing.expectEqualStrings("file contents", output.content);
}

test "a server that will not start is recorded, not fatal" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    try host.connectAll(&registry, &.{.{
        .name = "broken",
        .transport = .{ .stdio = .{ .command = "definitely-not-a-real-program-xyz" } },
    }}, .{ .name = "synth", .version = "test" });

    try testing.expect(!host.any());
    try testing.expectEqual(@as(usize, 1), host.failures.items.len);
    try testing.expectEqualStrings("broken", host.failures.items[0].server);
    try testing.expect(host.failures.items[0].reason.len > 0);

    // The built-ins are untouched by a server that never came up.
    try testing.expect(registry.get("read") != null);
}

test "a disabled server is not started at all" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    try host.connectAll(&registry, &.{.{
        .name = "off",
        .transport = .{ .stdio = .{ .command = "definitely-not-a-real-program-xyz" } },
        .enabled = false,
    }}, .{ .name = "synth", .version = "test" });

    try testing.expect(!host.any());
    try testing.expectEqual(@as(usize, 0), host.failures.items.len);
}

test "servers are read from the config block, and junk entries skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"servers":{
        \\"files":{"command":"npx","args":["-y","server-filesystem","/tmp"],"env":{"TOKEN":"abc"},"cwd":"/work"},
        \\"off":{"command":"thing","enabled":false},
        \\"nameless":{"args":["x"]},
        \\"wrong":"not an object"
        \\}}
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const servers = try serversFromJson(arena, value);

    try testing.expectEqual(@as(usize, 2), servers.len);

    var files: ?Server = null;
    var off: ?Server = null;
    for (servers) |server| {
        if (std.mem.eql(u8, server.name, "files")) files = server;
        if (std.mem.eql(u8, server.name, "off")) off = server;
    }

    const stdio = files.?.transport.stdio;
    try testing.expectEqualStrings("npx", stdio.command);
    try testing.expectEqual(@as(usize, 3), stdio.args.len);
    try testing.expectEqualStrings("server-filesystem", stdio.args[1]);
    try testing.expectEqualStrings("/work", stdio.cwd.?);
    try testing.expectEqual(@as(usize, 1), stdio.env.len);
    try testing.expectEqualStrings("TOKEN", stdio.env[0].name);
    try testing.expectEqualStrings("abc", stdio.env[0].value);
    try testing.expect(files.?.enabled);

    try testing.expect(!off.?.enabled);
}

test "an absent or unusable mcp block is no servers, not an error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "{}", "{\"servers\":[]}", "\"nonsense\"", "null" }) |raw| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
        try testing.expectEqual(@as(usize, 0), (try serversFromJson(arena, value)).len);
    }
}

test "the report names what connected and what did not" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    const quiet = try host.report(allocator);
    defer allocator.free(quiet);
    try testing.expectEqualStrings("", quiet);

    try host.connectAll(&registry, &.{.{
        .name = "broken",
        .transport = .{ .stdio = .{ .command = "definitely-not-a-real-program-xyz" } },
    }}, .{ .name = "synth", .version = "test" });

    const noisy = try host.report(allocator);
    defer allocator.free(noisy);
    try testing.expect(std.mem.indexOf(u8, noisy, "broken FAILED") != null);
}

test "a url makes a remote server, a command makes a local one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"servers":{
        \\"remote":{"url":"https://mcp.example/mcp","headers":{"X-Api-Key":"secret"}},
        \\"local":{"command":"npx"},
        \\"empty-url":{"url":""},
        \\"neither":{"enabled":true}
        \\}}
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const servers = try serversFromJson(arena, value);

    try testing.expectEqual(@as(usize, 2), servers.len);

    var remote: ?Server = null;
    var local: ?Server = null;
    for (servers) |server| {
        if (std.mem.eql(u8, server.name, "remote")) remote = server;
        if (std.mem.eql(u8, server.name, "local")) local = server;
    }

    const http = remote.?.transport.http;
    try testing.expectEqualStrings("https://mcp.example/mcp", http.url);
    try testing.expectEqual(@as(usize, 1), http.headers.len);
    try testing.expectEqualStrings("X-Api-Key", http.headers[0].name);
    try testing.expectEqualStrings("secret", http.headers[0].value);

    try testing.expectEqualStrings("npx", local.?.transport.stdio.command);
}

test "a url wins over a command on the same entry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"servers":{"both":{"url":"https://mcp.example/mcp","command":"npx"}}}
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const servers = try serversFromJson(arena, value);

    try testing.expectEqual(@as(usize, 1), servers.len);
    try testing.expect(servers[0].transport == .http);
}

test "a server turned off in the state file is not started" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var store: mcp.Auth = .init(allocator);
    defer store.deinit();
    try store.setEnabled("off", false);

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();
    host.auth = &store;

    try host.connectAll(&registry, &.{.{
        .name = "off",
        .transport = .{ .stdio = .{ .command = "definitely-not-a-real-program-xyz" } },
    }}, .{ .name = "synth", .version = "test" });

    try testing.expect(!host.any());
    try testing.expectEqual(@as(usize, 0), host.failures.items.len);
}

test "connecting on a worker registers nothing until it is installed" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    const before = registry.tools.count();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    const argv = [_][]const u8{ "sh", "-c", "exit 1" };
    try host.beginConnectAll(&.{.{
        .name = "broken",
        .transport = .{ .stdio = .{ .command = argv[0], .args = argv[1..] } },
    }}, .{ .name = "synth", .version = "test" });

    try testing.expect(host.connecting());

    while (!host.settled()) {
        std.Io.sleep(testing.io, .fromMilliseconds(2), .awake) catch break;
    }

    try testing.expect(!host.connecting());
    try testing.expectEqual(before, registry.tools.count());
    try testing.expectEqual(@as(usize, 0), try host.install(&registry));
}

test "installing twice does not register a server's tools twice" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    const arena = host.arena.allocator();
    const connection = try arena.create(Host.Connection);
    connection.* = .{
        .name = try arena.dupe(u8, "files"),
        .client = undefined,
        .offered = try arena.dupe(mcp.Tool, &.{.{
            .name = "read",
            .description = "read a file",
            .input_schema = "{}",
        }}),
    };
    try host.connections.append(allocator, connection);

    try testing.expectEqual(@as(usize, 1), try host.install(&registry));
    try testing.expectEqual(@as(usize, 0), try host.install(&registry));

    host.connections.clearRetainingCapacity();
}

test "a call to a server that stops answering is given up on, not waited out" {
    const allocator = testing.allocator;

    const argv = comptime scriptedServer(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]}}"},
    });

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    host.connectAll(&registry, &.{.{
        .name = "files",
        .transport = .{ .stdio = .{ .command = argv[0], .args = argv[1..] } },
    }}, .{ .name = "synth", .version = "test" }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    if (!host.any()) return error.SkipZigTest;

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    var arguments = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer arguments.deinit();

    var cancelled: std.atomic.Value(bool) = .init(true);

    const started = tool.monotonicMilliseconds(testing.io);
    const output = try registry.execute(.{
        .allocator = allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
        .cancelled = &cancelled,
    }, "mcp__files__read_file", arguments.value);
    defer allocator.free(output.content);

    try testing.expect(output.is_error);
    try testing.expect(std.mem.indexOf(u8, output.content, "cancelled") != null);
    try testing.expect(tool.monotonicMilliseconds(testing.io) - started < 10_000);
}

test "a call that runs past its deadline is given up on" {
    const allocator = testing.allocator;

    const argv = comptime scriptedServer(&.{
        &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersions\":[\"2026-07-28\"]}}"},
        &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]}}"},
    });

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    host.connectAll(&registry, &.{.{
        .name = "files",
        .transport = .{ .stdio = .{ .command = argv[0], .args = argv[1..] } },
    }}, .{ .name = "synth", .version = "test" }) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    if (!host.any()) return error.SkipZigTest;

    var reads: tool.ReadLog = .init(allocator);
    defer reads.deinit();

    var arguments = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    defer arguments.deinit();

    const started = tool.monotonicMilliseconds(testing.io);
    const output = try registry.execute(.{
        .allocator = allocator,
        .io = testing.io,
        .project_root = ".",
        .reads = &reads,
        .deadline_ms = started + 300,
    }, "mcp__files__read_file", arguments.value);
    defer allocator.free(output.content);

    try testing.expect(output.is_error);
    try testing.expect(std.mem.indexOf(u8, output.content, "timed out") != null);
    try testing.expect(tool.monotonicMilliseconds(testing.io) - started < 10_000);
}

test "a server that fails twice is one failure, not two" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    const servers: []const Server = &.{.{
        .name = "broken",
        .transport = .{ .stdio = .{ .command = "definitely-not-a-real-program-xyz" } },
    }};

    for (0..4) |_| {
        try host.connectAll(&registry, servers, .{ .name = "synth", .version = "test" });
    }

    try testing.expectEqual(@as(usize, 1), host.failures.items.len);
    try testing.expectEqualStrings("broken", host.failures.items[0].server);
}

test "turning off a server that never connected takes its failure with it" {
    const allocator = testing.allocator;

    var registry = try Registry.init(allocator);
    defer registry.deinit();

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    try host.connectAll(&registry, &.{.{
        .name = "broken",
        .transport = .{ .stdio = .{ .command = "definitely-not-a-real-program-xyz" } },
    }}, .{ .name = "synth", .version = "test" });

    try testing.expectEqual(@as(usize, 1), host.failures.items.len);

    try testing.expect(!host.disconnect(&registry, "broken"));
    try testing.expectEqual(@as(usize, 0), host.failures.items.len);
}

test "a later attempt replaces what was said about an earlier one" {
    const allocator = testing.allocator;

    var host: Host = .init(allocator, testing.io);
    defer host.deinit();

    try host.recordFailure("files", "not signed in");
    try host.recordFailure("files", "could not be reached");
    try host.recordFailure("other", "not signed in");

    try testing.expectEqual(@as(usize, 2), host.failures.items.len);
    try testing.expectEqualStrings("could not be reached", host.failures.items[0].reason);
}
