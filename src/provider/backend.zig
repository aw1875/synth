//! The one place that knows which client a catalog entry needs.
//!
//! Every caller that used to name `OllamaProvider` names this instead, so
//! adding a protocol is a variant here rather than a branch at each site. It
//! also owns the thing the erased `Provider` cannot do: switching *protocols*
//! at runtime, which is a different client, not a different host.

const std = @import("std");

const Auth = @import("../core/auth.zig");
const catalog = @import("catalog.zig");
const codex_auth = @import("codex_auth.zig");
const CodexProvider = @import("codex.zig");
const OllamaProvider = @import("ollama.zig");
const OpenAIProvider = @import("openai.zig");
const Provider = @import("provider.zig");
const Models = @import("models.zig");

const Backend = @This();

/// What a client is built from. Kept so a switch to another protocol can build
/// its replacement with the same settings.
pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Base URL. Borrowed; a `connect` copies its own.
    host: []const u8,
    /// The catalog provider's label, e.g. "Ollama Cloud".
    label: []const u8,
    /// Model to start on, or "" to take whatever the server offers.
    model: []const u8 = "",
    api_key: ?[]const u8 = null,
    auth: ?*Auth = null,
    models: ?*Models = null,
    /// Ask the model to reason before answering. Ollama only; the OpenAI API
    /// has no field for it.
    want_think: bool = true,
    /// Window to ask ollama to load the model with. Null takes the model's
    /// advertised maximum; zero leaves the choice to the server.
    num_ctx: ?u32 = null,
    debug_log: ?[]const u8 = null,
};

options: Options,
client: Client,
owns_models: bool = false,
model_warmup: std.Io.Group = .init,
models_pending: std.atomic.Value(usize) = .init(0),
warmup_started: bool = false,

pub const Client = union(catalog.Kind) {
    ollama: OllamaProvider,
    openai: OpenAIProvider,
    codex: CodexProvider,
};

pub fn init(kind: catalog.Kind, options: Options) Backend {
    return .{ .options = options, .client = build(kind, options) };
}

fn build(kind: catalog.Kind, options: Options) Client {
    return switch (kind) {
        .ollama => .{
            .ollama = .{
                .allocator = options.allocator,
                .io = options.io,
                .host = options.host,
                .label = options.label,
                .model = options.model,
                .api_key = options.api_key,
                .want_think = options.want_think,
                .num_ctx = options.num_ctx,
                .debug_log = options.debug_log,
                .models = options.models,
            },
        },
        .openai => .{
            .openai = .{
                .allocator = options.allocator,
                .io = options.io,
                .host = options.host,
                .label = options.label,
                .model = options.model,
                .api_key = options.api_key,
                .debug_log = options.debug_log,
                .models = options.models,
            },
        },
        .codex => .{
            .codex = .{
                .allocator = options.allocator,
                .io = options.io,
                .auth = options.auth orelse @panic("Codex requires auth"),
                .model = options.model,
                .debug_log = options.debug_log,
                .models = options.models,
            },
        },
    };
}

/// Connect, and read what the model on the other end can do. Must run once the
/// struct is at its final address: a client borrows its own fields.
pub fn start(self: *Backend) !void {
    try self.prepareModels();
    switch (self.client) {
        inline else => |*client| try client.start(),
    }
}

pub fn deinit(self: *Backend) void {
    self.model_warmup.cancel(self.options.io);
    switch (self.client) {
        inline else => |*client| client.deinit(),
    }
    if (self.owns_models) {
        const models = self.options.models.?;
        models.deinit();
        self.options.allocator.destroy(models);
    }
}

fn prepareModels(self: *Backend) !void {
    if (self.options.models == null) {
        const models = try self.options.allocator.create(Models);
        errdefer self.options.allocator.destroy(models);
        const state_path = if (self.options.auth) |auth| auth.path else "";
        models.* = try .init(self.options.allocator, self.options.io, state_path);
        self.options.models = models;
        self.owns_models = true;
    }
    switch (self.client) {
        inline else => |*client| client.models = self.options.models,
    }
}

/// Discover inactive providers and optional metadata without holding up the first frame. Each job
/// owns its client and settings; only the catalog and locked auth are shared.
pub fn warmModels(self: *Backend, db: *@import("../core/database.zig")) !void {
    if (self.warmup_started) return;
    try self.prepareModels();
    const auth = self.options.auth orelse return;
    for (catalog.all) |entry| {
        if (!entry.ready(auth)) continue;
        // The active endpoint may have an environment override.
        const is_active = std.meta.activeTag(self.client) == entry.kind and std.mem.eql(u8, self.current().name, entry.label);
        const needs_background_metadata = is_active and entry.kind == .openai;
        if (is_active and !needs_background_metadata) continue;

        const child = try self.options.allocator.create(Spawned);
        errdefer self.options.allocator.destroy(child);
        child.arena = .init(self.options.allocator);
        errdefer child.arena.deinit();
        const arena = child.arena.allocator();
        var host = entry.host;
        if (is_active) {
            host = try arena.dupe(u8, self.currentHost());
        } else if (entry.host_editable) {
            const remembered = try db.providerHost(arena, entry.id);
            if (remembered.len > 0) host = remembered;
        }
        child.backend = .init(entry.kind, .{
            .allocator = self.options.allocator,
            .io = self.options.io,
            .host = host,
            .label = entry.label,
            .api_key = if (is_active) self.currentKey() else auth.key(entry.id),
            .auth = auth,
            .models = self.options.models,
        });
        _ = self.models_pending.fetchAdd(1, .monotonic);
        errdefer _ = self.models_pending.fetchSub(1, .release);
        try self.model_warmup.concurrent(self.options.io, warmModelCatalog, .{ self, child });
        self.warmup_started = true;
    }
}

fn warmModelCatalog(self: *Backend, child: *Spawned) std.Io.Cancelable!void {
    defer _ = self.models_pending.fetchSub(1, .release);
    defer child.deinit();
    _ = child.backend.listModels(child.arena.allocator()) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return,
    };
    child.backend.warmReferenceMetadata(true) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

/// Headless startup can wait here; interactive callers use the discovery group.
pub fn warmReferenceMetadata(self: *Backend, refresh: bool) !void {
    switch (self.client) {
        .openai => |*client| {
            try client.warmReferenceMetadata(refresh);
            client.refreshMetadata();
        },
        else => {},
    }
}

pub fn modelsWarming(self: *Backend) bool {
    return self.warmup_started;
}

/// Join completed jobs and apply metadata. Call only between turns.
pub fn pollModels(self: *Backend) bool {
    const finished = self.warmup_started and self.models_pending.load(.acquire) == 0;
    if (!finished) return false;
    self.model_warmup.await(self.options.io) catch {};
    self.warmup_started = false;
    switch (self.client) {
        .openai => |*client| client.refreshMetadata(),
        else => {},
    }
    return true;
}

/// A backend of its own, pointed at the same server as this one.
///
/// A nested run cannot share a client: the feature flags a provider flips
/// mid-request and the rejection it leaves behind are single-writer, and two
/// turns at once would tear them.
pub const Spawned = struct {
    /// Holds the settings the child borrows, since the parent is free to switch
    /// model or host while the child is still running.
    arena: std.heap.ArenaAllocator,
    backend: Backend,

    pub fn deinit(self: *Spawned) void {
        const allocator = self.arena.child_allocator;
        self.backend.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn provider(self: *Spawned) Provider {
        return self.backend.provider();
    }
};

/// Build one, on the heap because a client borrows its own fields.
pub fn spawn(self: *Backend, allocator: std.mem.Allocator) !*Spawned {
    try self.prepareModels();
    const child = try allocator.create(Spawned);
    errdefer allocator.destroy(child);

    child.arena = .init(allocator);
    errdefer child.arena.deinit();
    const arena = child.arena.allocator();

    var options = self.options;
    options.host = try arena.dupe(u8, self.currentHost());
    options.label = try arena.dupe(u8, self.current().name);
    options.model = try arena.dupe(u8, self.model());
    if (self.currentKey()) |value| options.api_key = try arena.dupe(u8, value);

    child.backend = .init(std.meta.activeTag(self.client), options);
    switch (child.backend.client) {
        .ollama => |*client| try client.startLike(&self.client.ollama),
        .openai => |*client| try client.startLike(&self.client.openai),
        .codex => |*client| try client.startLike(&self.client.codex),
    }
    return child;
}

/// The host this is pointed at, which a runtime connect may have replaced.
pub fn currentHost(self: *Backend) []const u8 {
    return switch (self.client) {
        .ollama => |*client| client.host,
        .openai => |*client| client.host,
        .codex => codex_auth.backend_url,
    };
}

fn currentKey(self: *Backend) ?[]const u8 {
    return switch (self.client) {
        .ollama => |*client| client.api_key,
        .openai => |*client| client.api_key,
        .codex => null,
    };
}

pub fn provider(self: *Backend) Provider {
    return switch (self.client) {
        inline else => |*client| client.provider(),
    };
}

/// The model this is pointed at. Borrowed from the client, and stale after a
/// model switch, so read it rather than keeping a copy.
pub fn model(self: *Backend) []const u8 {
    return switch (self.client) {
        inline else => |*client| client.model,
    };
}

pub fn listModels(self: *Backend, allocator: std.mem.Allocator) ![][]const u8 {
    try self.prepareModels();
    return switch (self.client) {
        inline else => |*client| client.listModels(allocator),
    };
}

/// Settle on a model the server will actually answer for, where the client has
/// a way to tell.
pub fn ensureModel(self: *Backend) !void {
    return switch (self.client) {
        inline else => |*client| client.ensureModel(),
    };
}

pub fn describeError(self: *Backend, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    return switch (self.client) {
        inline else => |*client| client.describeError(err, allocator),
    };
}

/// Whether a listed model is the one that was asked for. Ollama lists
/// `qwen3:latest` for what a config calls `qwen3`; everywhere else an id is an
/// id.
pub fn sameModel(self: *Backend, listed: []const u8, wanted: []const u8) bool {
    return switch (self.client) {
        .ollama => OllamaProvider.sameModel(listed, wanted),
        .openai => std.mem.eql(u8, listed, wanted),
        .codex => std.mem.eql(u8, listed, wanted),
    };
}

/// Point this at a catalog provider: another host and credential, and where the
/// entry speaks a different protocol, another client entirely.
///
/// The returned `Provider` is the one to use from here. A same-protocol connect
/// leaves it unchanged, but a switch replaces the client the vtable points at,
/// so a caller holding the old one would be calling into freed memory.
pub fn connect(
    self: *Backend,
    entry: catalog.Entry,
    host: []const u8,
    api_key: ?[]const u8,
) !Provider {
    try self.prepareModels();
    // A selection must not see an unfinished warmup as an unavailable catalog.
    self.model_warmup.cancel(self.options.io);
    self.warmup_started = false;
    self.options.models.?.forgetFailedCatalogs();
    const connection: Provider.Connection = .{
        .label = entry.label,
        .host = host,
        .api_key = api_key,
    };

    if (entry.kind != std.meta.activeTag(self.client)) {
        switch (self.client) {
            inline else => |*client| client.deinit(),
        }
        // Built empty then reconnected: only `reconnect` copies the strings.
        self.client = build(entry.kind, .{
            .allocator = self.options.allocator,
            .io = self.options.io,
            .host = "",
            .label = "",
            .want_think = self.options.want_think,
            .num_ctx = self.options.num_ctx,
            .debug_log = self.options.debug_log,
            .auth = self.options.auth,
            .models = self.options.models,
        });
    }

    switch (self.client) {
        inline else => |*client| {
            try client.reconnect(connection);
            client.ensureModel() catch {};
        },
    }
    return self.provider();
}

/// What the client is pointed at now, for a caller refreshing its own copy.
pub fn current(self: *Backend) Provider.Current {
    return switch (self.client) {
        inline else => |*client| client.current(),
    };
}

test "a catalog entry chooses the client that speaks its protocol" {
    const testing = std.testing;
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();

    for (catalog.all) |entry| {
        var backend: Backend = .init(entry.kind, .{
            .allocator = testing.allocator,
            .io = testing.io,
            .host = entry.host,
            .label = entry.label,
            .auth = &auth,
        });
        defer backend.deinit();

        try testing.expectEqual(entry.kind, std.meta.activeTag(backend.client));
        try testing.expectEqualStrings(entry.label, backend.provider().name);
        try testing.expectEqualStrings("", backend.model());
    }
}

test "background discovery deadlines and shutdown close stalled HTTP connections" {
    const testing = std.testing;
    const Database = @import("../core/database.zig");
    const Endpoint = struct {
        server: std.Io.net.Server,
        waiting: std.Io.Event = .unset,
        closed: std.Io.Event = .unset,

        fn stall(self: *@This()) !void {
            const stream = try self.server.accept(testing.io);
            defer stream.close(testing.io);
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(testing.io, &buffer);
            // Never respond: the client must give up and close its socket.
            self.waiting.set(testing.io);
            _ = try reader.interface.discardRemaining();
            self.closed.set(testing.io);
        }
    };
    for ([_]catalog.Kind{ .ollama, .openai }) |kind| {
        for ([_]bool{ false, true }) |quit_early| {
            const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
            var endpoint: Endpoint = .{ .server = try address.listen(testing.io, .{ .mode = .stream }) };
            defer endpoint.server.deinit(testing.io);
            var server_task = try testing.io.concurrent(Endpoint.stall, .{&endpoint});
            defer server_task.cancel(testing.io) catch {};
            const host = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{endpoint.server.socket.address.getPort()});
            defer testing.allocator.free(host);
            var db = try Database.init(testing.allocator, testing.io, ":memory:");
            defer db.deinit();
            const provider_id = if (kind == .ollama) "ollama" else "openai-compat";
            try db.setProviderHost(provider_id, host);
            var auth = Auth.init(testing.allocator, testing.io);
            defer auth.deinit();
            var models = try Models.init(testing.allocator, testing.io, "");
            defer models.deinit();
            models.fetch_timeout = .fromMilliseconds(200);
            {
                // Mark the other optional provider active so only this endpoint warms.
                const active = catalog.find(if (kind == .ollama) "openai-compat" else "ollama").?;
                var backend = Backend.init(active.kind, .{
                    .allocator = testing.allocator,
                    .io = testing.io,
                    .host = "http://127.0.0.1:1",
                    .label = active.label,
                    .auth = &auth,
                    .models = &models,
                });
                defer backend.deinit();
                try backend.warmModels(&db);
                try endpoint.waiting.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
                try testing.expect(!backend.pollModels());
                if (!quit_early) {
                    try endpoint.closed.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
                    while (!backend.pollModels()) try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
                    try testing.expect(!backend.modelsWarming());
                }
            }
            try endpoint.closed.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
            try server_task.await(testing.io);
        }
    }
}

test "optional metadata stays off the interactive path and updates the selected model after discovery" {
    const testing = std.testing;
    const Database = @import("../core/database.zig");
    const Source = struct {
        entries: []const Models.Info,
        pub fn fetchModels(self: *@This(), arena: std.mem.Allocator) ![]const Models.Info {
            return arena.dupe(Models.Info, self.entries);
        }
    };
    const Reference = struct {
        started: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        pub fn fetchModels(self: *@This(), arena: std.mem.Allocator) ![]const Models.Info {
            self.started.set(testing.io);
            try self.released.wait(testing.io);
            return arena.dupe(Models.Info, &.{
                .{ .id = "http://127.0.0.1:1/v1/first", .context_limit = 123000 },
                .{ .id = "http://127.0.0.1:1/v1/second", .context_limit = 456000, .vision = true },
            });
        }
        fn fetch(self: *@This(), models: *Models) !void {
            _ = try models.getOrFetchCatalog("models.dev", "https://models.dev/api.json", "", self);
        }
    };
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();
    var models = try Models.init(testing.allocator, testing.io, "");
    defer models.deinit();
    const host = "http://127.0.0.1:1/v1";
    var listing: Source = .{ .entries = &.{ .{ .id = "first" }, .{ .id = "second", .vision = false } } };
    _ = try models.getOrFetchCatalog("openai", host, "", &listing);
    var empty: Source = .{ .entries = &.{} };
    _ = try models.getOrFetchCatalog("ollama", catalog.find("ollama").?.host, "", &empty);
    var backend = Backend.init(.openai, .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = host,
        .label = catalog.find("openai-compat").?.label,
        .model = "first",
        .auth = &auth,
        .models = &models,
    });
    defer backend.deinit();
    try backend.start();
    try testing.expectEqual(@as(u32, 0), backend.current().context_limit);

    // The first probe must leave optional discovery to the worker. If it
    // already fetched models.dev, this source will never be entered.
    var reference: Reference = .{};
    var reference_task = try testing.io.concurrent(Reference.fetch, .{ &reference, &models });
    defer reference_task.cancel(testing.io) catch {};
    defer reference.released.set(testing.io);
    try reference.started.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try backend.warmModels(&db);
    const offered = try backend.listModels(testing.allocator);
    defer {
        for (offered) |name| testing.allocator.free(name);
        testing.allocator.free(offered);
    }
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "first", "second" }), offered);
    const provider_value = backend.provider();
    const selection = try provider_value.set_model.?(provider_value.userdata, "second");
    try testing.expectEqualStrings("second", selection.model);
    try testing.expectEqual(@as(u32, 0), selection.context_limit);

    reference.released.set(testing.io);
    try reference_task.await(testing.io);
    while (!backend.pollModels()) try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    try testing.expectEqualStrings("second", backend.model());
    try testing.expectEqual(@as(u32, 456000), backend.current().context_limit);
    // Endpoint capabilities take precedence over the reference database.
    try testing.expect(!backend.current().supports_vision);
    const child = try backend.spawn(testing.allocator);
    defer child.deinit();
    try testing.expectEqual(@as(u32, 456000), child.provider().context_limit);
}

test "every backend switches and spawns from the shared catalog without rediscovery" {
    const testing = std.testing;
    const Source = struct {
        pub fn fetchModels(_: *@This(), arena: std.mem.Allocator) ![]const Models.Info {
            return arena.dupe(Models.Info, &.{
                .{ .id = "first", .context_limit = 123000, .vision = true, .tools = true },
                .{ .id = "second", .context_limit = 456000, .vision = false, .tools = false },
            });
        }
    };
    var auth = Auth.init(testing.allocator, testing.io);
    defer auth.deinit();
    try auth.set("codex", "{\"access_token\":\"test\",\"refresh_token\":\"test\",\"account_id\":\"test-account\"}");
    var models = try Models.init(testing.allocator, testing.io, "");
    defer models.deinit();
    var source: Source = .{};
    for ([_]catalog.Kind{ .ollama, .openai, .codex }) |kind| {
        const host = if (kind == .codex) codex_auth.backend_url else "http://127.0.0.1:1/v1";
        const identity = if (kind == .codex) "test-account" else "";
        _ = try models.getOrFetchCatalog(@tagName(kind), host, identity, &source);
        if (kind == .ollama) {
            _ = try models.getOrFetchCatalog("ollama/show/first", host, identity, &source);
            _ = try models.getOrFetchCatalog("ollama/show/second", host, identity, &source);
        }
        var backend = Backend.init(kind, .{
            .allocator = testing.allocator,
            .io = testing.io,
            .host = host,
            .label = "test",
            .model = "first",
            .auth = &auth,
            .models = &models,
        });
        defer backend.deinit();
        try backend.start();
        try testing.expectEqual(@as(u32, 123000), backend.current().context_limit);
        // Rechecking the same selection must not invalidate names held by the UI.
        const selected = backend.current();
        try backend.ensureModel();
        try testing.expectEqualStrings("first", selected.model);
        const provider_value = backend.provider();
        const switched = try provider_value.set_model.?(provider_value.userdata, "second");
        try testing.expectEqual(@as(u32, 456000), switched.context_limit);
        try testing.expect(!switched.supports_vision);
        const child = try backend.spawn(testing.allocator);
        defer child.deinit();
        try testing.expectEqual(@as(u32, 456000), child.provider().context_limit);
        _ = try provider_value.set_model.?(provider_value.userdata, "first");
        try testing.expectEqualStrings("second", child.provider().model);
        const offered = try child.backend.listModels(testing.allocator);
        defer {
            for (offered) |name| testing.allocator.free(name);
            testing.allocator.free(offered);
        }
        try testing.expectEqual(@as(usize, 2), offered.len);
    }
}

test "a spawned backend shares the settings but not the client" {
    const testing = std.testing;

    var parent: Backend = .init(.openai, .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "https://api.example/v1",
        .label = "Example",
        .model = "a-model",
        .api_key = "secret",
    });
    defer parent.deinit();
    try parent.client.openai.startLike(&parent.client.openai);
    parent.client.openai.context_limit = 12345;
    parent.client.openai.supports_vision = false;

    const child = try parent.spawn(testing.allocator);
    defer child.deinit();

    try testing.expectEqualStrings(parent.model(), child.backend.model());
    try testing.expectEqualStrings(parent.currentHost(), child.backend.currentHost());

    // What the parent already learned, without asking the server again.
    try testing.expectEqual(@as(u32, 12345), child.backend.client.openai.context_limit);
    try testing.expect(!child.backend.client.openai.supports_vision);

    // Separate clients: a flag one turn flips cannot reach the other.
    try testing.expect(&child.backend.client.openai != &parent.client.openai);
    child.backend.client.openai.supports_tools = false;
    try testing.expect(parent.client.openai.supports_tools);

    // Its own copies, so the parent switching model does not dangle them.
    try testing.expect(child.backend.model().ptr != parent.model().ptr);
}

test "a spawned ollama backend carries the window its parent probed" {
    const testing = std.testing;

    var parent: Backend = .init(.ollama, .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:11434",
        .label = "Ollama",
        .model = "qwen3",
    });
    defer parent.deinit();
    try parent.client.ollama.startLike(&parent.client.ollama);
    parent.client.ollama.context_limit = 8192;
    parent.client.ollama.think = false;

    const child = try parent.spawn(testing.allocator);
    defer child.deinit();

    try testing.expectEqual(@as(u32, 8192), child.backend.client.ollama.context_limit);
    try testing.expect(!child.backend.client.ollama.think);
    try testing.expectEqualStrings("qwen3", child.backend.model());
}

test "an ollama tag matches loosely, an openai id exactly" {
    const testing = std.testing;

    var local: Backend = .init(.ollama, .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "http://localhost:11434",
        .label = "Ollama",
    });
    defer local.deinit();

    var hosted: Backend = .init(.openai, .{
        .allocator = testing.allocator,
        .io = testing.io,
        .host = "https://api.openai.com/v1",
        .label = "OpenAI",
    });
    defer hosted.deinit();

    try testing.expect(local.sameModel("qwen3:latest", "qwen3"));
    try testing.expect(!hosted.sameModel("gpt-4o-2024-08-06", "gpt-4o"));
    try testing.expect(hosted.sameModel("gpt-4o", "gpt-4o"));
}
