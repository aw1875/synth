//! The providers a session server answers through: the credentials it holds,
//! and the client each new session's own is spawned from. Every session's
//! worker and every client thread reaches these, so they sit behind one lock.

const std = @import("std");

const wire = @import("wire.zig");
const Auth = @import("../core/auth.zig");
const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const Backend = @import("../provider/backend.zig");
const catalog = @import("../provider/catalog.zig");
const chatgpt_auth = @import("../provider/chatgpt_auth.zig");
const Provider = @import("../provider/provider.zig");

const Providers = @This();

io: std.Io,
auth: *Auth,
chatgpt: ?*chatgpt_auth.Store,
/// What new sessions start on. Its strings are borrowed by every spawn.
template: *Backend,
mutex: std.Io.Mutex = .init,
/// Catalog id of the provider `template` points at.
active_id: []const u8,
/// Nothing usable has been chosen: a session asks for a provider before its
/// first turn.
missing: bool,

pub fn init(io: std.Io, auth: *Auth, chatgpt: ?*chatgpt_auth.Store, template: *Backend, active_id: []const u8, missing: bool) Providers {
    return .{
        .io = io,
        .auth = auth,
        .chatgpt = chatgpt,
        .template = template,
        .active_id = catalog.findOrDefault(active_id).id,
        .missing = missing,
    };
}

/// A client of its own for a new session, on the provider in use, and that
/// provider's catalog id.
/// The model sessions start on. Caller owns the result.
pub fn model(self: *Providers, allocator: std.mem.Allocator) ![]const u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return allocator.dupe(u8, self.template.model());
}

pub fn spawn(self: *Providers, allocator: std.mem.Allocator) !struct { *Backend.Spawned, []const u8 } {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return .{ try self.template.spawn(allocator), self.active_id };
}

/// Whether a session on provider `id` has nothing to answer it: none was
/// chosen, or the ChatGPT sign-in it runs on has ended.
pub fn isMissing(self: *Providers, id: []const u8) bool {
    self.mutex.lockUncancelable(self.io);
    const missing = self.missing;
    self.mutex.unlock(self.io);
    if (missing) return true;
    if (!std.mem.eql(u8, id, catalog.chatgpt_id)) return false;
    const store = self.chatgpt orelse return true;
    return !store.isUsable();
}

/// Each provider in the catalog: where it is, whether it has what it needs,
/// and whether it is the one `active_id` names.
pub fn states(self: *Providers, arena: std.mem.Allocator, db: *Database, active_id: []const u8) ![]const wire.ProviderState {
    const missing = self.isMissing(active_id);
    const out = try arena.alloc(wire.ProviderState, catalog.all.len);
    for (catalog.all, out) |entry, *state| state.* = .{
        .id = entry.id,
        .host = try hostOf(arena, db, entry),
        .connected = self.isConnected(entry),
        .active = !missing and std.mem.eql(u8, entry.id, active_id),
    };
    return out;
}

/// Whether a provider has what it needs to be asked anything.
pub fn isConnected(self: *Providers, entry: catalog.Entry) bool {
    if (entry.key == .oauth) return self.isReady(entry);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.auth.key(entry.id) != null;
}

pub fn isReady(self: *Providers, entry: catalog.Entry) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return entry.ready(self.auth, self.chatgpt);
}

/// Where a provider is reached: the host last connected for one whose host
/// is the person's to set, or the catalog's.
pub fn hostOf(arena: std.mem.Allocator, db: *Database, entry: catalog.Entry) ![]const u8 {
    if (!entry.host_editable) return entry.host;
    const remembered = try db.providerHost(arena, entry.id);
    return if (remembered.len > 0) remembered else entry.host;
}

/// Store `key` when one is given, point `session` at the provider, and make it
/// what sessions to come start on. Returns what `session` now answers as.
pub fn connect(self: *Providers, session: *Backend, entry: catalog.Entry, host: []const u8, key: ?[]const u8) !Provider {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (key) |secret| {
        try self.auth.set(entry.id, secret);
        try self.auth.save(self.io, self.auth.path);
    }
    const provider = try session.connect(entry, host, self.auth.key(entry.id));
    _ = try self.template.connect(entry, host, self.auth.key(entry.id));
    self.active_id = entry.id;
    self.missing = false;
    return provider;
}

/// ChatGPT was signed out of: sessions on it have nothing to answer them.
pub fn signedOut(self: *Providers) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (std.mem.eql(u8, self.active_id, catalog.chatgpt_id)) self.missing = true;
}

/// The models every connected provider offers, with their efforts and the
/// level last chosen for each. The one `session` is on answers through it;
/// the rest get a client of their own just for the asking.
pub fn offered(self: *Providers, arena: std.mem.Allocator, db: *Database, session: Provider, session_id: []const u8) ![]const wire.Offered {
    var out: std.ArrayList(wire.Offered) = .empty;
    for (catalog.all) |entry| {
        if (!self.isConnected(entry)) continue;
        if (std.mem.eql(u8, entry.id, session_id)) {
            try appendOffered(arena, db, &out, entry.id, entry.label, session);
            continue;
        }
        const key = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk if (self.auth.key(entry.id)) |secret| try arena.dupe(u8, secret) else null;
        };
        var backend: Backend = .init(entry.kind, .{
            .allocator = arena,
            .io = self.io,
            .host = try hostOf(arena, db, entry),
            .label = entry.label,
            .api_key = key,
            .chatgpt = self.chatgpt,
        });
        defer backend.deinit();
        backend.start() catch continue;
        try appendOffered(arena, db, &out, entry.id, entry.label, backend.provider());
    }
    return out.items;
}

/// What one provider offers, for a server whose sessions all answer through it.
pub fn offeredBy(arena: std.mem.Allocator, db: *Database, id: []const u8, label: []const u8, provider: Provider) ![]const wire.Offered {
    var out: std.ArrayList(wire.Offered) = .empty;
    try appendOffered(arena, db, &out, id, label, provider);
    return out.items;
}

fn appendOffered(arena: std.mem.Allocator, db: *Database, out: *std.ArrayList(wire.Offered), id: []const u8, label: []const u8, provider: Provider) !void {
    const names = provider.models(arena) catch return;
    for (names) |name| {
        const efforts = provider.effortsFor(name);
        const levels = try arena.alloc([]const u8, efforts.levels.len);
        for (efforts.levels, levels) |level, *copy| copy.* = try arena.dupe(u8, level);
        const remembered = db.rememberedEffort(arena, id, name) catch "";
        try out.append(arena, .{
            .name = name,
            .provider = label,
            .provider_id = id,
            .efforts = levels,
            .effort = try arena.dupe(u8, efforts.pick(remembered)),
        });
    }
}

/// A provider someone chose, and that has what it needs; or, with nothing
/// chosen, a local server that actually answers. Defaulting to one that is not
/// there would only surface as an error on the first prompt.
pub fn usable(arena: std.mem.Allocator, db: *Database, config: *const Config, active: catalog.Active, auth: *const Auth, chatgpt: ?*chatgpt_auth.Store, backend: *Backend) !bool {
    if (!active.entry.ready(auth, chatgpt)) return false;
    const chosen = try db.activeProvider(arena);
    const was_chosen = chosen.len > 0 or config.provider_override.len > 0 or config.host_override.len > 0;
    if (was_chosen) return true;
    const models = backend.listModels(arena) catch return false;
    return models.len > 0;
}
