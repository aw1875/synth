//! Asking a provider that is not in use what it offers, off the UI thread. Each
//! one is a client of its own and a network round trip, and the model picker
//! should be up before the slowest of them answers.

const std = @import("std");

const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const Provider = @import("../provider/provider.zig");

const ModelListing = @This();

/// One model on offer, and the effort levels it accepts.
pub const Offered = struct {
    name: []const u8,
    efforts: Provider.Efforts,
};

/// Where to reach the provider. Copied by `start`.
pub const Reach = struct {
    host: []const u8,
    api_key: ?[]const u8,
    chatgpt: ?*chatgpt_auth.Store,
};

allocator: std.mem.Allocator,
io: std.Io,
/// Holds the copied reach and everything listed.
arena: std.heap.ArenaAllocator,
entry: catalog.Entry,
reach: Reach,
future: std.Io.Future(void) = undefined,
done: std.atomic.Value(bool) = .init(false),
/// Empty when the provider could not be reached. Only read once `isFinished`.
models: []const Offered = &.{},

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
    self.models = self.list() catch &.{};
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

    const provider = backend.provider();
    const names = try provider.models(arena);
    const offered = try arena.alloc(Offered, names.len);
    for (names, offered) |name, *model| {
        const efforts = provider.effortsFor(name);
        model.* = .{ .name = name, .efforts = .{
            .levels = try dupeLevels(arena, efforts.levels),
            .default = try arena.dupe(u8, efforts.default),
        } };
    }
    return offered;
}

/// Copied because the levels are borrowed from a backend that dies with the
/// listing.
fn dupeLevels(arena: std.mem.Allocator, levels: []const []const u8) ![]const []const u8 {
    const copies = try arena.alloc([]const u8, levels.len);
    for (levels, copies) |level, *copy| copy.* = try arena.dupe(u8, level);
    return copies;
}

pub fn isFinished(self: *ModelListing) bool {
    return self.done.load(.acquire);
}

/// Only call once `isFinished`; `models` dies with this.
pub fn finish(self: *ModelListing) void {
    self.future.await(self.io);
    self.destroy();
}

/// For a picker that closed or reopened: stop at the next cancelation point
/// rather than wait on the network.
pub fn abandon(self: *ModelListing) void {
    self.future.cancel(self.io);
    self.destroy();
}

fn destroy(self: *ModelListing) void {
    self.arena.deinit();
    self.allocator.destroy(self);
}
