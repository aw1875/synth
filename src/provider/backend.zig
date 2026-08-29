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
