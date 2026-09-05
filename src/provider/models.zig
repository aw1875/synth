//! One catalog snapshot per endpoint/account per launch. Shared by the picker,
//! live backend and subagents; disk is a last-good fallback, never the authority.
const std = @import("std");
const Config = @import("../core/config.zig");
const Models = @This();

pub const Info = struct {
    id: []const u8,
    context_limit: u32 = 0,
    vision: ?bool = null,
    tools: ?bool = null,
    thinking: ?bool = null,
    visible: bool = true,
};

allocator: std.mem.Allocator,
io: std.Io,
cache_directory: []const u8,
catalogs: std.AutoHashMapUnmanaged([32]u8, anyerror![]const Info) = .empty,
catalogs_mutex: std.Io.Mutex = .init,
fetch_timeout: std.Io.Duration = .fromSeconds(5),

pub fn init(allocator: std.mem.Allocator, io: std.Io, state_file_path: []const u8) !Models {
    var self: Models = .{ .allocator = allocator, .io = io, .cache_directory = "" };
    errdefer self.deinit();
    const has_state_file = state_file_path.len > 0;
    if (has_state_file) {
        const state_directory = std.fs.path.dirname(state_file_path) orelse ".";
        self.cache_directory = try std.fs.path.join(allocator, &.{ state_directory, "model-cache" });
    }
    return self;
}

pub fn deinit(self: *Models) void {
    var catalog_results = self.catalogs.valueIterator();
    while (catalog_results.next()) |catalog_result| {
        const catalog = catalog_result.* catch continue;
        for (catalog) |model| self.allocator.free(model.id);
        self.allocator.free(catalog);
    }
    self.catalogs.deinit(self.allocator);
    self.allocator.free(self.cache_directory);
}

/// An explicit reconnect can retry an unavailable endpoint. Successful
/// snapshots still last the whole launch, including switches in the picker.
pub fn forgetFailedCatalogs(self: *Models) void {
    self.catalogs_mutex.lockUncancelable(self.io);
    defer self.catalogs_mutex.unlock(self.io);
    var catalog_entries = self.catalogs.iterator();
    while (catalog_entries.next()) |catalog_entry| {
        _ = catalog_entry.value_ptr.* catch |catalog_error| {
            const discovery_is_running = catalog_error == error.CatalogLoading;
            if (discovery_is_running) continue;
            _ = self.catalogs.remove(catalog_entry.key_ptr.*);
            catalog_entries = self.catalogs.iterator();
        };
    }
}

/// fetcher.fetchModels returns normalized metadata allocated in the supplied
/// arena. Snapshots stay alive until shutdown, even across provider switches.
pub fn getOrFetchCatalog(self: *Models, catalog_namespace: []const u8, endpoint: []const u8, account_identity: []const u8, source: anytype) ![]const Info {
    return self.loadCatalog(catalog_namespace, endpoint, account_identity, source, true);
}

fn loadCatalog(self: *Models, catalog_namespace: []const u8, endpoint: []const u8, account_identity: []const u8, source: anytype, refresh_from_source: bool) ![]const Info {
    const catalog_key = catalogCacheKey(catalog_namespace, endpoint, account_identity);
    {
        self.catalogs_mutex.lockUncancelable(self.io);
        defer self.catalogs_mutex.unlock(self.io);
        const existing_catalog = self.catalogs.get(catalog_key);
        if (existing_catalog) |catalog| return catalog;
        // Other callers can use ready catalogs without waiting on this network call.
        try self.catalogs.put(self.allocator, catalog_key, error.CatalogLoading);
    }
    return self.fetchOrRestoreCatalog(catalog_key, source, refresh_from_source) catch |catalog_error| {
        self.catalogs_mutex.lockUncancelable(self.io);
        defer self.catalogs_mutex.unlock(self.io);
        const catalog_result = self.catalogs.getPtr(catalog_key).?;
        catalog_result.* = catalog_error;
        return catalog_error;
    };
}

/// Ready snapshots only: never wait for discovery or start network I/O.
pub fn cachedCatalog(self: *Models, catalog_namespace: []const u8, endpoint: []const u8, account_identity: []const u8) ?[]const Info {
    self.catalogs_mutex.lockUncancelable(self.io);
    defer self.catalogs_mutex.unlock(self.io);
    const catalog_key = catalogCacheKey(catalog_namespace, endpoint, account_identity);
    const catalog_result = self.catalogs.get(catalog_key) orelse return null;
    return catalog_result catch null;
}

fn catalogCacheKey(catalog_namespace: []const u8, endpoint: []const u8, account_identity: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ catalog_namespace, endpoint, account_identity }) |identity_part| {
        hasher.update(identity_part);
        hasher.update(&.{0});
    }
    return hasher.finalResult();
}

fn fetchOrRestoreCatalog(self: *Models, catalog_key: [32]u8, source: anytype, refresh_from_source: bool) ![]const Info {
    var scratch_arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const cache_filename = std.fmt.bytesToHex(catalog_key, .lower);
    const cache_path = try std.fmt.allocPrint(scratch, "{s}/{s}.json", .{ self.cache_directory, cache_filename });
    const should_read_disk_first = !refresh_from_source;
    if (should_read_disk_first) {
        const disk_catalog = try self.readCatalogFromDisk(scratch, cache_path);
        if (disk_catalog) |catalog| return self.storeOwnedCatalog(catalog_key, catalog);
    }
    const fetched_catalog = self.fetchCatalogBeforeTimeout(source, scratch) catch |fetch_error| {
        const fetch_was_canceled = fetch_error == error.Canceled;
        if (fetch_was_canceled) return fetch_error;
        const disk_catalog = try self.readCatalogFromDisk(scratch, cache_path) orelse return fetch_error;
        return self.storeOwnedCatalog(catalog_key, disk_catalog);
    };
    const owned_catalog = try self.storeOwnedCatalog(catalog_key, fetched_catalog);
    self.writeCatalogToDisk(cache_path, owned_catalog) catch {}; // A read-only disk must not break discovery.
    return owned_catalog;
}

fn storeOwnedCatalog(self: *Models, catalog_key: [32]u8, catalog: []const Info) ![]const Info {
    const owned_catalog = try self.allocator.dupe(Info, catalog);
    var copied_model_count: usize = 0;
    errdefer {
        for (owned_catalog[0..copied_model_count]) |model| self.allocator.free(model.id);
        self.allocator.free(owned_catalog);
    }
    for (owned_catalog) |*model| {
        model.id = try self.allocator.dupe(u8, model.id);
        copied_model_count += 1;
    }
    self.catalogs_mutex.lockUncancelable(self.io);
    defer self.catalogs_mutex.unlock(self.io);
    const catalog_result = self.catalogs.getPtr(catalog_key).?;
    catalog_result.* = owned_catalog;
    return owned_catalog;
}

fn fetchCatalogBeforeTimeout(self: *Models, source: anytype, scratch: std.mem.Allocator) ![]const Info {
    const CatalogFetch = struct {
        fn fetchAndValidate(catalog_source: @TypeOf(source), allocator: std.mem.Allocator) anyerror![]const Info {
            const catalog = try catalog_source.fetchModels(allocator);
            try validateCatalog(catalog);
            return catalog;
        }
    };
    const FirstCompleted = union(enum) { catalog: anyerror![]const Info, timeout: std.Io.Cancelable!void };
    var completed_operations: [2]FirstCompleted = undefined;
    var first_completed = std.Io.Select(FirstCompleted).init(self.io, &completed_operations);
    defer first_completed.cancelDiscard(); // All fetched data belongs to the caller's scratch arena.
    try first_completed.concurrent(.catalog, CatalogFetch.fetchAndValidate, .{ source, scratch });
    try first_completed.concurrent(.timeout, std.Io.sleep, .{ self.io, self.fetch_timeout, .awake });
    return switch (try first_completed.await()) {
        .catalog => |catalog_result| catalog_result,
        .timeout => |timeout_result| {
            try timeout_result;
            return error.CatalogTimeout;
        },
    };
}

fn validateCatalog(catalog: []const Info) !void {
    for (catalog) |model| {
        const model_id_is_missing = model.id.len == 0;
        if (model_id_is_missing) return error.InvalidModelCatalog;
    }
}

fn readCatalogFromDisk(self: *Models, scratch: std.mem.Allocator, cache_path: []const u8) !?[]const Info {
    const disk_cache_is_disabled = self.cache_directory.len == 0;
    if (disk_cache_is_disabled) return null;
    const cache_contents = std.Io.Dir.cwd().readFileAlloc(self.io, cache_path, scratch, .limited(16 * 1024 * 1024)) catch |read_error| switch (read_error) {
        error.Canceled => return read_error,
        else => return null,
    };
    const disk_catalog = std.json.parseFromSliceLeaky([]const Info, scratch, cache_contents, .{}) catch return null;
    validateCatalog(disk_catalog) catch return null;
    return disk_catalog;
}

fn writeCatalogToDisk(self: *Models, cache_path: []const u8, catalog: []const Info) !void {
    const disk_cache_is_disabled = self.cache_directory.len == 0;
    if (disk_cache_is_disabled) return;
    try Config.ensureDir(self.io, cache_path);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(self.io, cache_path, .{ .replace = true });
    defer atomic_file.deinit(self.io);
    var write_buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(self.io, &write_buffer);
    try std.json.Stringify.value(catalog, .{}, &file_writer.interface);
    try file_writer.interface.flush();
    try atomic_file.file.sync(self.io);
    try atomic_file.replace(self.io);
}

pub fn findModel(catalog: []const Info, model_id: []const u8) ?Info {
    for (catalog) |model| {
        const model_id_matches = std.mem.eql(u8, model.id, model_id);
        if (model_id_matches) return model;
    }
    return null;
}

pub fn containsString(candidates: []const []const u8, expected: []const u8) bool {
    for (candidates) |candidate| {
        const candidate_matches = std.mem.eql(u8, candidate, expected);
        if (candidate_matches) return true;
    }
    return false;
}

/// Like OpenCode, use models.dev only to fill metadata an endpoint omits.
/// Matching includes the API root: a custom server's "gpt-5" is not OpenAI's.
pub fn referenceMetadataFor(self: *Models, scratch: std.mem.Allocator, api_root: []const u8, model_id: []const u8) !?Info {
    const reference_catalog = self.cachedCatalog("models.dev", "https://models.dev/api.json", "") orelse return null;
    const normalized_api_root = std.mem.trimEnd(u8, api_root, "/");
    const qualified_model_id = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ normalized_api_root, model_id });
    return findModel(reference_catalog, qualified_model_id);
}

/// Interactive boots refresh in the background; one-shot runs prefer disk.
pub fn loadReferenceCatalog(self: *Models, refresh_from_source: bool) !void {
    var reference_source: Reference = .{ .io = self.io };
    _ = try self.loadCatalog("models.dev", "https://models.dev/api.json", "", &reference_source, refresh_from_source);
}

const Reference = struct {
    io: std.Io,

    pub fn fetchModels(self: *Reference, scratch: std.mem.Allocator) ![]const Info {
        var http_client: std.http.Client = .{ .allocator = scratch, .io = self.io };
        defer http_client.deinit();
        const uri = try std.Uri.parse("https://models.dev/api.json");
        var request = try http_client.request(.GET, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer request.deinit();
        try request.sendBodiless();
        var header_buffer: [4096]u8 = undefined;
        var response = try request.receiveHead(&header_buffer);
        const request_succeeded = response.head.status.class() == .success;
        if (!request_succeeded) return error.CatalogUnavailable;
        const transfer_buffer = try scratch.alloc(u8, 64 * 1024);
        const response_body = try response.reader(transfer_buffer).allocRemaining(scratch, .limited(16 * 1024 * 1024));
        return parseCatalogResponse(scratch, response_body);
    }

    fn parseCatalogResponse(scratch: std.mem.Allocator, response_body: []const u8) ![]const Info {
        const ModelMetadata = struct {
            limit: struct { context: u32, input: ?u32 = null },
            tool_call: ?bool = null,
            modalities: ?struct { input: []const []const u8 } = null,
        };
        const ProviderCatalog = struct { api: ?[]const u8 = null, models: std.json.ArrayHashMap(ModelMetadata) };
        const response_catalog = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(ProviderCatalog), scratch, response_body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        var reference_models: std.ArrayList(Info) = .empty;
        var provider_catalogs = response_catalog.map.iterator();
        while (provider_catalogs.next()) |provider_entry| {
            const provider_catalog = provider_entry.value_ptr.*;
            // models.dev omits the API root for SDK-native providers.
            const is_openai_catalog = std.mem.eql(u8, provider_entry.key_ptr.*, "openai");
            const api_root = provider_catalog.api orelse if (is_openai_catalog) "https://api.openai.com/v1" else continue;
            const normalized_api_root = std.mem.trimEnd(u8, api_root, "/");
            var model_entries = provider_catalog.models.map.iterator();
            while (model_entries.next()) |model_entry| {
                const metadata = model_entry.value_ptr.*;
                const max_input_tokens = metadata.limit.input orelse metadata.limit.context;
                const supports_vision = if (metadata.modalities) |modalities| containsString(modalities.input, "image") else null;
                try reference_models.append(scratch, .{
                    .id = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ normalized_api_root, model_entry.key_ptr.* }),
                    .context_limit = @min(max_input_tokens, metadata.limit.context),
                    .tools = metadata.tool_call,
                    .vision = supports_vision,
                });
            }
        }
        const catalog_is_empty = reference_models.items.len == 0;
        if (catalog_is_empty) return error.InvalidModelCatalog;
        return reference_models.toOwnedSlice(scratch);
    }
};

test "reference metadata respects input limits and endpoint identity" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const reference_catalog = try Reference.parseCatalogResponse(arena_state.allocator(),
        \\{"openai":{"models":{"new-model":{"limit":{"context":400000,"input":272000,"output":128000},"tool_call":true,"modalities":{"input":["text","image"]}}}},"custom":{"api":"http://localhost:8080/v1","models":{"new-model":{"limit":{"context":8192,"output":2048}}}}}
    );
    const openai_model = findModel(reference_catalog, "https://api.openai.com/v1/new-model").?;
    try std.testing.expectEqual(@as(u32, 272000), openai_model.context_limit);
    try std.testing.expect(openai_model.vision.?);
    try std.testing.expect(openai_model.tools.?);
    const custom_model = findModel(reference_catalog, "http://localhost:8080/v1/new-model").?;
    try std.testing.expectEqual(@as(u32, 8192), custom_model.context_limit);
    const unrelated_model = findModel(reference_catalog, "http://unrelated/v1/new-model");
    try std.testing.expect(unrelated_model == null);
}

pub fn copyVisibleModelNames(allocator: std.mem.Allocator, catalog: []const Info) ![][]const u8 {
    var visible_model_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (visible_model_names.items) |model_name| allocator.free(model_name);
        visible_model_names.deinit(allocator);
    }
    for (catalog) |model| {
        const model_is_hidden = !model.visible;
        if (model_is_hidden) continue;
        const owned_model_name = try allocator.dupe(u8, model.id);
        errdefer allocator.free(owned_model_name);
        try visible_model_names.append(allocator, owned_model_name);
    }
    return visible_model_names.toOwnedSlice(allocator);
}

test "reference metadata uses disk for one-shot runs and refreshes for interactive boots" {
    const testing = std.testing;
    const Source = struct {
        calls: usize = 0,
        pub fn fetchModels(self: *@This(), _: std.mem.Allocator) ![]const Info {
            self.calls += 1;
            return &.{.{ .id = "https://api.example/v1/model", .context_limit = 100000 }};
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];
    const state_path = try std.fs.path.join(testing.allocator, &.{ root, "auth.json" });
    defer testing.allocator.free(state_path);
    var source: Source = .{};
    // First boot fetches on a cache miss; subsequent headless boots stay local.
    for ([_]bool{ false, false, true }) |refresh| {
        var cache = try Models.init(testing.allocator, testing.io, state_path);
        defer cache.deinit();
        _ = try cache.loadCatalog("models.dev", "https://models.dev/api.json", "", &source, refresh);
        var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
        defer scratch.deinit();
        const model = (try cache.referenceMetadataFor(scratch.allocator(), "https://api.example/v1", "model")).?;
        try testing.expectEqual(@as(u32, 100000), model.context_limit);
        try testing.expectEqual(@as(usize, if (refresh) 2 else 1), source.calls);
    }
}

test "catalog refreshes once per launch, survives failure, and isolates endpoints and accounts" {
    const testing = std.testing;
    const Source = struct {
        calls: usize = 0,
        fail: bool = false,
        invalid: bool = false,
        stalled: bool = false,
        limit: u32 = 123456,
        pub fn fetchModels(self: *@This(), arena: std.mem.Allocator) ![]const Info {
            self.calls += 1;
            if (self.stalled) try std.Io.sleep(testing.io, .fromSeconds(60), .awake);
            if (self.fail) return error.Unavailable;
            const entries = try arena.alloc(Info, 1);
            entries[0] = .{ .id = if (self.invalid) "" else "new-model", .context_limit = self.limit, .vision = false };
            return entries;
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &path_buffer);
    const state_path = try std.fs.path.join(testing.allocator, &.{ path_buffer[0..length], "auth.json" });
    defer testing.allocator.free(state_path);

    var source: Source = .{};
    {
        var cache = try Models.init(testing.allocator, testing.io, state_path);
        defer cache.deinit();
        const entries = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        try testing.expectEqual(@as(u32, 123456), findModel(entries, "new-model").?.context_limit);
        _ = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        try testing.expectEqual(@as(usize, 1), source.calls);
    }
    source.fail = true;
    {
        var cache = try Models.init(testing.allocator, testing.io, state_path);
        defer cache.deinit();
        const entries = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        try testing.expectEqual(@as(u32, 123456), entries[0].context_limit);
        try testing.expectEqual(false, entries[0].vision.?);
        _ = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        try testing.expectEqual(@as(usize, 2), source.calls);
        try testing.expectError(error.Unavailable, cache.getOrFetchCatalog("codex", "host", "other-account", &source));
        try testing.expectError(error.Unavailable, cache.getOrFetchCatalog("codex", "other-host", "account", &source));
        try testing.expectError(error.Unavailable, cache.getOrFetchCatalog("openai", "host", "account", &source));
        const calls_before_retry = source.calls;
        try testing.expectError(error.Unavailable, cache.getOrFetchCatalog("openai", "host", "account", &source));
        try testing.expectEqual(calls_before_retry, source.calls);
        source.fail = false;
        cache.forgetFailedCatalogs();
        _ = try cache.getOrFetchCatalog("openai", "host", "account", &source);
        try testing.expectEqual(calls_before_retry + 1, source.calls);
    }
    source.fail = false;
    source.stalled = true;
    {
        var cache = try Models.init(testing.allocator, testing.io, state_path);
        defer cache.deinit();
        cache.fetch_timeout = .fromMilliseconds(20);
        const entries = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        try testing.expectEqual(@as(u32, 123456), entries[0].context_limit);
    }
    source.stalled = false;
    source.invalid = true;
    {
        var cache = try Models.init(testing.allocator, testing.io, state_path);
        defer cache.deinit();
        const entries = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        try testing.expectEqual(@as(u32, 123456), entries[0].context_limit);
    }
    source.invalid = false;
    source.limit = 0;
    {
        var cache = try Models.init(testing.allocator, testing.io, state_path);
        defer cache.deinit();
        const entries = try cache.getOrFetchCatalog("codex", "host", "account", &source);
        // A fresh response is authoritative; do not resurrect stale fields.
        try testing.expectEqual(@as(u32, 0), entries[0].context_limit);
    }
    source.limit = 234567;
    var cache = try Models.init(testing.allocator, testing.io, state_path);
    defer cache.deinit();
    const refreshed = try cache.getOrFetchCatalog("codex", "host", "account", &source);
    try testing.expectEqual(@as(u32, 234567), refreshed[0].context_limit);
}

test "catalog retries release downloads and retain only owned metadata" {
    const testing = std.testing;
    const Source = struct {
        fail: bool = true,
        pub fn fetchModels(self: *@This(), arena: std.mem.Allocator) ![]const Info {
            _ = try arena.alloc(u8, 1024 * 1024);
            if (self.fail) return error.Unavailable;
            return arena.dupe(Info, &.{.{ .id = try arena.dupe(u8, "available-model"), .context_limit = 123456 }});
        }
    };
    var allocations = testing.FailingAllocator.init(testing.allocator, .{});
    var cache = try Models.init(allocations.allocator(), testing.io, "");
    defer cache.deinit();
    var source: Source = .{};
    for (0..10) |_| {
        try testing.expectError(error.Unavailable, cache.getOrFetchCatalog("test", "host", "", &source));
        cache.forgetFailedCatalogs();
    }
    source.fail = false;
    const entries = try cache.getOrFetchCatalog("test", "host", "", &source);
    try testing.expectEqualStrings("available-model", entries[0].id);
    try testing.expectEqual(@as(u32, 123456), entries[0].context_limit);
    const retained_bytes = allocations.allocated_bytes - allocations.freed_bytes;
    try testing.expect(retained_bytes < 256 * 1024);
}

test "catalog allocation failures release partial snapshots" {
    const Check = struct {
        pub fn fetchModels(_: *@This(), arena: std.mem.Allocator) ![]const Info {
            return arena.dupe(Info, &.{ .{ .id = "first" }, .{ .id = "second" } });
        }
        fn run(allocator: std.mem.Allocator) !void {
            var cache = try Models.init(allocator, std.testing.io, "");
            defer cache.deinit();
            var source: @This() = .{};
            const entries = try cache.getOrFetchCatalog("test", "host", "", &source);
            try std.testing.expectEqualStrings("first", entries[0].id);
            try std.testing.expectEqualStrings("second", entries[1].id);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "slow catalogs do not block ready endpoints and are stopped at the deadline" {
    const testing = std.testing;
    const Source = struct {
        started: std.Io.Event = .unset,
        stopped: std.atomic.Value(bool) = .init(false),
        pub fn fetchModels(self: *@This(), _: std.mem.Allocator) ![]const Info {
            defer self.stopped.store(true, .release);
            self.started.set(testing.io);
            try std.Io.sleep(testing.io, .fromSeconds(60), .awake);
            return &.{};
        }
        fn discover(cache: *Models, self: *@This()) anyerror![]const Info {
            return cache.getOrFetchCatalog("test", "slow", "", self);
        }
    };
    const Ready = struct {
        pub fn fetchModels(_: *@This(), _: std.mem.Allocator) ![]const Info {
            return &.{.{ .id = "ready" }};
        }
    };
    var cache = try Models.init(testing.allocator, testing.io, "");
    defer cache.deinit();
    cache.fetch_timeout = .fromMilliseconds(200);
    var ready: Ready = .{};
    _ = try cache.getOrFetchCatalog("test", "ready", "", &ready);
    var source: Source = .{};
    var pending = try testing.io.concurrent(Source.discover, .{ &cache, &source });
    defer _ = pending.cancel(testing.io) catch {};
    try source.started.wait(testing.io);
    cache.forgetFailedCatalogs(); // Must not evict an in-flight request.
    try testing.expectError(error.CatalogLoading, cache.getOrFetchCatalog("test", "slow", "", &source));
    const entries = try cache.getOrFetchCatalog("test", "ready", "", &ready);
    try testing.expectEqualStrings("ready", entries[0].id);
    try testing.expect(!source.stopped.load(.acquire));
    try testing.expectError(error.CatalogTimeout, pending.await(testing.io));
    try testing.expect(source.stopped.load(.acquire));
}
