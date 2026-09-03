//! The one place that knows which client a catalog entry needs.
//!
//! Every caller that used to name `OllamaProvider` names this instead, so
//! adding a protocol is a variant here rather than a branch at each site. It
//! also owns the thing the erased `Provider` cannot do: switching *protocols*
//! at runtime, which is a different client, not a different host.

const std = @import("std");

const catalog = @import("catalog.zig");
const OllamaProvider = @import("ollama.zig");
const OpenAIProvider = @import("openai.zig");
const Provider = @import("provider.zig");

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

pub const Client = union(catalog.Kind) {
    ollama: OllamaProvider,
    openai: OpenAIProvider,
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
            },
        },
    };
}

/// Connect, and read what the model on the other end can do. Must run once the
/// struct is at its final address: a client borrows its own fields.
pub fn start(self: *Backend) !void {
    switch (self.client) {
        inline else => |*client| try client.start(),
    }
}

pub fn deinit(self: *Backend) void {
    switch (self.client) {
        inline else => |*client| client.deinit(),
    }
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
    const child = try allocator.create(Spawned);
    errdefer allocator.destroy(child);

    child.arena = .init(allocator);
    errdefer child.arena.deinit();
    const arena = child.arena.allocator();

    var options = self.options;
    options.host = try arena.dupe(u8, self.currentHost());
    options.label = try arena.dupe(u8, self.options.label);
    options.model = try arena.dupe(u8, self.model());
    if (self.currentKey()) |value| options.api_key = try arena.dupe(u8, value);

    child.backend = .init(std.meta.activeTag(self.client), options);
    switch (child.backend.client) {
        .ollama => |*client| try client.startLike(&self.client.ollama),
        .openai => |*client| try client.startLike(&self.client.openai),
    }
    return child;
}

/// The host this is pointed at, which a runtime connect may have replaced.
pub fn currentHost(self: *Backend) []const u8 {
    return switch (self.client) {
        inline else => |*client| client.host,
    };
}

fn currentKey(self: *Backend) ?[]const u8 {
    return switch (self.client) {
        inline else => |*client| client.api_key,
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
    const connection: Provider.Connection = .{
        .label = entry.label,
        .host = host,
        .api_key = api_key,
    };

    if (entry.kind != std.meta.activeTag(self.client)) {
        self.deinit();
        // Built empty and then reconnected, rather than built with these
        // strings: `connection` borrows the caller's, and only `reconnect`
        // takes copies the client can keep.
        self.client = build(entry.kind, .{
            .allocator = self.options.allocator,
            .io = self.options.io,
            .host = "",
            .label = "",
            .want_think = self.options.want_think,
            .num_ctx = self.options.num_ctx,
            .debug_log = self.options.debug_log,
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

    for (catalog.all) |entry| {
        var backend: Backend = .init(entry.kind, .{
            .allocator = testing.allocator,
            .io = testing.io,
            .host = entry.host,
            .label = entry.label,
        });
        defer backend.deinit();

        try testing.expectEqual(entry.kind, std.meta.activeTag(backend.client));
        try testing.expectEqualStrings(entry.label, backend.provider().name);
        try testing.expectEqualStrings("", backend.model());
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
