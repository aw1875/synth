//! Asking a provider what it offers, off the UI thread and through a client of
//! its own. Each is a network round trip, and the model picker should be up
//! before the slowest of them answers.

const std = @import("std");

const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const Provider = @import("../provider/provider.zig");

const ModelListing = @This();

pub const Offered = struct {
    name: []const u8,
    efforts: Provider.Efforts,
};

/// Copied by `start`.
pub const Reach = struct {
    host: []const u8,
    api_key: ?[]const u8,
    chatgpt: ?*chatgpt_auth.Store,
};

allocator: std.mem.Allocator,
io: std.Io,
/// Holds the copied reach and everything listed; touched only by the worker
/// until `isFinished`.
arena: std.heap.ArenaAllocator,
entry: catalog.Entry,
reach: Reach,
future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
/// Null when the provider could not be asked, which is not the same as
/// offering nothing. Only read once `isFinished`.
models: ?[]const Offered = null,

pub fn start(allocator: std.mem.Allocator, io: std.Io, entry: catalog.Entry, reach: Reach) !*ModelListing {
    const self = try allocator.create(ModelListing);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .arena = .init(allocator), .entry = entry, .reach = undefined };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();
    self.reach = .{
        .host = try arena.dupe(u8, reach.host),
        .api_key = if (reach.api_key) |key| try arena.dupe(u8, key) else null,
        .chatgpt = reach.chatgpt,
    };
    self.future = try io.concurrent(run, .{self});
    return self;
}

fn run(self: *ModelListing) void {
    defer self.done.store(true, .release);
    self.models = self.list() catch null;
}

fn list(self: *ModelListing) ![]const Offered {
    const arena = self.arena.allocator();
    var backend: Backend = .init(self.entry.kind, .{
        .allocator = arena,
        .io = self.io,
        .host = self.reach.host,
        .label = self.entry.label,
        .api_key = self.reach.api_key,
        .chatgpt = self.reach.chatgpt,
    });
    defer backend.deinit();
    try backend.start();
    return offeredBy(arena, backend.provider());
}

fn offeredBy(arena: std.mem.Allocator, provider: Provider) ![]const Offered {
    const names = try provider.models(arena);
    const offered = try arena.alloc(Offered, names.len);
    for (names, offered) |name, *model| {
        model.* = .{ .name = name, .efforts = try copyEfforts(arena, provider.effortsFor(name)) };
    }
    return offered;
}

/// The levels are borrowed from a backend that dies with the listing.
fn copyEfforts(arena: std.mem.Allocator, efforts: Provider.Efforts) !Provider.Efforts {
    const levels = try arena.alloc([]const u8, efforts.levels.len);
    for (efforts.levels, levels) |level, *copy| copy.* = try arena.dupe(u8, level);
    return .{ .levels = levels, .default = try arena.dupe(u8, efforts.default) };
}

pub fn isFinished(self: *ModelListing) bool {
    return self.done.load(.acquire);
}

/// Only call once `isFinished`. `models` then lives until `destroy`.
pub fn join(self: *ModelListing) void {
    self.future.await(self.io);
}

/// For quitting before the provider answered. Waits for the worker to reach a
/// cancelation point, so only for when blocking no longer matters.
pub fn abandon(self: *ModelListing) void {
    self.future.cancel(self.io);
    self.destroy();
}

pub fn destroy(self: *ModelListing) void {
    self.arena.deinit();
    self.allocator.destroy(self);
}

test "a provider that cannot be reached lists nothing" {
    const testing = std.testing;
    const listing = try start(testing.allocator, testing.io, catalog.findOrDefault(catalog.default_id), .{
        .host = "http://127.0.0.1:1",
        .api_key = null,
        .chatgpt = null,
    });
    listing.join();
    defer listing.destroy();
    try testing.expect(listing.models == null);
}
