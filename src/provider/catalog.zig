//! The providers a harness can be pointed at, and what each one needs before
//! it will answer.

const std = @import("std");

const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");

/// What a provider needs before it will answer.
pub const Key = enum {
    /// Local server. A key is accepted - some people put one in front of it -
    /// but nothing is expected.
    optional,
    /// Hosted. Without a key every request is a 401, so the UI says so before
    /// the first turn rather than after it.
    required,
    /// Browser sign-in; no secret is typed into synth.
    oauth,
};

/// Which client answers for a provider: the wire protocol, not the vendor.
/// `openai` covers every server imitating that API, which is most of them.
pub const Kind = enum { ollama, openai, codex };

pub const Entry = struct {
    /// Stable id: the key in `auth.json` and in the config. Never shown.
    id: []const u8,
    /// What a person calls it.
    label: []const u8,
    /// One line, shown dim beside the label.
    summary: []const u8,
    /// Where it lives. For a hosted provider this is fixed; for a local one it
    /// is the default, and the config may override it.
    host: []const u8,
    /// Whether the host is the user's to change. False for a hosted provider:
    /// pointing "Ollama Cloud" at localhost would be a lie in the sidebar.
    host_editable: bool,
    key: Key,
    kind: Kind = .ollama,

    /// Whether this provider has what it needs to be used.
    pub fn ready(self: Entry, auth: *Auth) bool {
        return switch (self.key) {
            .optional => true,
            .required => (auth.key(self.id) orelse @as([]const u8, "")).len > 0,
            .oauth => auth.key(self.id) != null,
        };
    }
};

/// The provider used when nothing has been chosen: the local server, which
/// needs no credential and is what a machine with ollama on it already has.
pub const default_id: []const u8 = "ollama";

pub const all: []const Entry = &.{
    .{
        .id = "ollama",
        .label = "Ollama",
        .summary = "local server",
        .host = "http://localhost:11434",
        .host_editable = true,
        .key = .optional,
    },
    .{
        .id = "ollama-cloud",
        .label = "Ollama Cloud",
        .summary = "hosted models (API key)",
        .host = "https://ollama.com",
        .host_editable = false,
        .key = .required,
    },
    .{
        .id = "openai",
        .label = "OpenAI",
        .summary = "hosted models (API key)",
        .host = "https://api.openai.com/v1",
        .host_editable = false,
        .key = .required,
        .kind = .openai,
    },
    .{
        .id = "openai-compat",
        .label = "OpenAI-compatible",
        .summary = "any /v1/chat/completions server",
        .host = "http://localhost:8080/v1",
        .host_editable = true,
        .key = .optional,
        .kind = .openai,
    },
    .{
        .id = "codex",
        .label = "Codex Subscription",
        .summary = "ChatGPT plan (browser sign-in)",
        .host = "https://chatgpt.com/backend-api/codex",
        .host_editable = false,
        .key = .oauth,
        .kind = .codex,
    },
};

/// The entry with this id, or null. An id from a config file written by a newer
/// harness lands here, which is why callers fall back rather than fail.
pub fn find(id: []const u8) ?Entry {
    for (all) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

/// The entry with this id, or the default one. What startup wants: an unknown
/// provider should leave the harness usable, not refuse to open.
pub fn findOrDefault(id: []const u8) Entry {
    return find(id) orelse find(default_id).?;
}

/// A provider resolved down to what a backend needs to talk to it.
pub const Active = struct {
    entry: Entry,
    host: []const u8,
    model: []const u8,
    api_key: ?[]const u8,
};

/// Work out which provider to use and how to reach it.
pub fn resolve(
    arena: std.mem.Allocator,
    db: *Database,
    config: *const Config,
    auth: *Auth,
) !Active {
    const chosen = try db.activeProvider(arena);
    const entry = findOrDefault(if (config.provider_override.len > 0) config.provider_override else chosen);

    // The environment names a host and a key per protocol, not per provider, so
    // which pair applies is decided by what the entry speaks.
    const from_env: struct { host: []const u8, key: ?[]const u8 } = switch (entry.kind) {
        .ollama => .{ .host = config.host_override, .key = config.api_key },
        .openai => .{ .host = config.openai_host, .key = config.openai_api_key },
        .codex => .{ .host = "", .key = null },
    };

    var host = entry.host;
    if (entry.host_editable) {
        const remembered = try db.providerHost(arena, entry.id);
        if (remembered.len > 0) host = remembered;
        if (from_env.host.len > 0) host = from_env.host;
    }

    const key = blk: {
        if (auth.key(entry.id)) |stored| {
            if (stored.len > 0) break :blk stored;
        }
        break :blk from_env.key;
    };

    const uses_codex_managed_model = entry.kind == .codex;
    const configured_model = if (uses_codex_managed_model) "" else config.model_override;

    return .{ .entry = entry, .host = host, .model = configured_model, .api_key = key };
}

test "every provider is findable by the id it stores itself under" {
    const testing = std.testing;

    for (all) |entry| {
        try testing.expect(entry.id.len > 0);
        try testing.expectEqualStrings(entry.id, find(entry.id).?.id);
    }

    try testing.expect(find("anthropic") == null);
    try testing.expectEqualStrings(default_id, findOrDefault("anthropic").id);
    try testing.expectEqualStrings(default_id, findOrDefault("").id);
}

test "a hosted provider is not ready until it has a key" {
    const testing = std.testing;

    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    const local = find("ollama").?;
    const cloud = find("ollama-cloud").?;

    try testing.expect(local.ready(&auth));
    try testing.expect(!cloud.ready(&auth));

    try auth.set("ollama-cloud", "sk-secret");
    try testing.expect(cloud.ready(&auth));

    try auth.set("ollama-cloud", "");
    try testing.expect(!cloud.ready(&auth));
}

/// Open a database in a temporary directory, for the resolution tests.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    db: Database,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(std.testing.io, &buffer);
        const path = try std.fs.path.join(std.testing.allocator, &.{ buffer[0..n], "catalog.db" });
        defer std.testing.allocator.free(path);

        return .{ .tmp = tmp, .db = try .init(std.testing.allocator, std.testing.io, path) };
    }

    fn deinit(self: *Fixture) void {
        self.db.deinit();
        self.tmp.cleanup();
    }
};

test "with nothing chosen, the local server is what answers" {
    const testing = std.testing;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    const active = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("ollama", active.entry.id);
    try testing.expectEqualStrings("http://localhost:11434", active.host);
    try testing.expect(active.api_key == null);
}

test "what the database remembers is what a new run connects to" {
    const testing = std.testing;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    try fixture.db.setProviderHost("ollama", "http://box:11434");
    try fixture.db.setActiveProvider("ollama");
    try auth.set("ollama", "local-key");

    const active = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("http://box:11434", active.host);
    try testing.expectEqualStrings("local-key", active.api_key.?);

    try fixture.db.setActiveProvider("ollama-cloud");
    try fixture.db.setProviderHost("ollama-cloud", "http://localhost:11434");
    config.host_override = "http://localhost:11434";

    const hosted = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("https://ollama.com", hosted.host);
    try testing.expect(hosted.api_key == null);
}

test "the environment beats the database, and a stored key beats the config" {
    const testing = std.testing;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    try fixture.db.setProviderHost("ollama", "http://box:11434");
    try fixture.db.setActiveProvider("ollama");

    config.host_override = "http://elsewhere:11434";
    config.api_key = "from-config";

    const overridden = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("http://elsewhere:11434", overridden.host);
    try testing.expectEqualStrings("from-config", overridden.api_key.?);

    try auth.set("ollama", "from-auth");
    const stored = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("from-auth", stored.api_key.?);

    config.provider_override = "ollama-cloud";
    try testing.expectEqualStrings(
        "ollama-cloud",
        (try resolve(arena_state.allocator(), &fixture.db, &config, &auth)).entry.id,
    );
    config.provider_override = "anthropic";
    try testing.expectEqualStrings(
        "ollama",
        (try resolve(arena_state.allocator(), &fixture.db, &config, &auth)).entry.id,
    );
}

test "the environment pair that applies is the one the provider speaks" {
    const testing = std.testing;

    var fixture = try Fixture.init();
    defer fixture.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    config.host_override = "http://box:11434";
    config.api_key = "from-ollama-env";
    config.openai_host = "http://localhost:1234/v1";
    config.openai_api_key = "from-openai-env";

    const local = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("http://box:11434", local.host);
    try testing.expectEqualStrings("from-ollama-env", local.api_key.?);

    try fixture.db.setActiveProvider("openai-compat");
    const compatible = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("http://localhost:1234/v1", compatible.host);
    try testing.expectEqualStrings("from-openai-env", compatible.api_key.?);

    // The hosted entry's host is not the user's to move, however the
    // environment is set.
    try fixture.db.setActiveProvider("openai");
    const hosted = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("https://api.openai.com/v1", hosted.host);
    try testing.expectEqualStrings("from-openai-env", hosted.api_key.?);

    config.model_override = "ollama-only";
    try fixture.db.setActiveProvider("codex");
    const codex = try resolve(arena_state.allocator(), &fixture.db, &config, &auth);
    try testing.expectEqualStrings("", codex.model);
}

test "an OpenAI-compatible server needs no key, and OpenAI itself does" {
    const testing = std.testing;

    var auth: Auth = .init(testing.allocator, testing.io);
    defer auth.deinit();

    const compatible = find("openai-compat").?;
    const hosted = find("openai").?;

    try testing.expectEqual(Kind.openai, compatible.kind);
    try testing.expectEqual(Kind.openai, hosted.kind);
    try testing.expect(compatible.host_editable);
    try testing.expect(!hosted.host_editable);

    try testing.expect(compatible.ready(&auth));
    try testing.expect(!hosted.ready(&auth));

    try auth.set("openai", "sk-secret");
    try testing.expect(hosted.ready(&auth));
}
