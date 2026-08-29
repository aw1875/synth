//! Lookup and dispatch for tools, plus the JSON the model is shown.

const std = @import("std");

const ask = @import("ask.zig");
const filesystem = @import("filesystem.zig");
const shell = @import("shell.zig");
const task = @import("task.zig");
const todo = @import("todo.zig");
const tool = @import("tool.zig");
const web = @import("web.zig");
pub const Tool = tool.Tool;
pub const Context = tool.Context;
pub const Input = tool.Input;
pub const Output = tool.Output;
pub const ReadLog = tool.ReadLog;

const Registry = @This();

allocator: std.mem.Allocator,
tools: std.StringHashMapUnmanaged(Tool) = .empty,

/// Registry holding every built-in tool.
pub fn init(allocator: std.mem.Allocator) !Registry {
    var self: Registry = .{ .allocator = allocator };
    errdefer self.deinit();

    for (filesystem.all) |t| try self.register(t);
    for (shell.all) |t| try self.register(t);
    for (task.all) |t| try self.register(t);
    for (ask.all) |t| try self.register(t);
    for (todo.all) |t| try self.register(t);
    for (web.all) |t| try self.register(t);

    return self;
}

pub fn deinit(self: *Registry) void {
    var it = self.tools.valueIterator();
    while (it.next()) |t| t.deinit(self.allocator);
    self.tools.deinit(self.allocator);
}

/// Add a tool, replacing one of the same name.
///
/// A built-in borrows its strings from the binary. A tool learned at runtime -
/// from a server that had to be asked what it offers - brings its own, and says
/// so with `owned`, which is what makes it the registry's to free.
pub fn register(self: *Registry, t: Tool) !void {
    const entry = try self.tools.getOrPut(self.allocator, t.name);
    if (entry.found_existing) entry.value_ptr.deinit(self.allocator);
    entry.key_ptr.* = t.name;
    entry.value_ptr.* = t;
}

/// Take a tool back out, freeing whatever it owned. Used when the server that
/// offered it has gone away.
pub fn unregister(self: *Registry, name: []const u8) void {
    if (self.tools.fetchRemove(name)) |removed| removed.value.deinit(self.allocator);
}

pub fn get(self: *const Registry, name: []const u8) ?Tool {
    return self.tools.get(name);
}

/// Run a tool by name. A missing tool is reported to the model rather than
/// raised, because the model is the one that got it wrong and can retry.
pub fn execute(
    self: *const Registry,
    ctx: Context,
    name: []const u8,
    arguments: std.json.Value,
) !Output {
    const t = self.get(name) orelse {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "unknown tool '{s}'",
            .{name},
        ));
    };
    var scoped = ctx;
    scoped.userdata = t.userdata;
    if (scoped.deadline_ms == null) {
        const budget = t.timeout_ms orelse tool.default_timeout_ms;
        scoped.deadline_ms = tool.monotonicMilliseconds(ctx.io) + @as(i64, @intCast(budget));
    }

    return t.handler(scoped, .{ .arguments = arguments });
}

/// Parse `arguments` as a JSON object, then run. Providers hand tool call
/// arguments over as raw JSON text.
pub fn executeJson(
    self: *const Registry,
    ctx: Context,
    name: []const u8,
    arguments_json: []const u8,
) !Output {
    const source = if (arguments_json.len == 0) "{}" else arguments_json;

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, source, .{}) catch {
        return Output.err(try std.fmt.allocPrint(
            ctx.allocator,
            "{s}: arguments were not valid JSON",
            .{name},
        ));
    };
    defer parsed.deinit();

    return self.execute(ctx, name, parsed.value);
}

/// The tool list as the model sees it, in the shape Ollama expects for
/// `ChatRequest.tools`. Caller owns the result.
/// Tool definitions for the request, restricted to `allow` when it is not
/// empty. What an agent may call and what the model is told exists are the same
/// list: a tool left out here is one the model never learns about.
pub fn schemaJson(self: *const Registry, allocator: std.mem.Allocator, allow: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeByte('[');

    var it = self.tools.valueIterator();
    var first = true;
    while (it.next()) |t| {
        if (!permitted(allow, t.name)) continue;
        if (!first) try out.writer.writeByte(',');
        first = false;

        try out.writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try std.json.Stringify.encodeJsonString(t.name, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.encodeJsonString(t.description, .{}, &out.writer);
        try out.writer.writeAll(",\"parameters\":");
        try out.writer.writeAll(t.schema);
        try out.writer.writeAll("}}");
    }

    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn permitted(allow: []const []const u8, name: []const u8) bool {
    if (allow.len == 0) return true;
    for (allow) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

test "built-ins are registered and classified" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expect(registry.get("read").?.read_only);
    try std.testing.expect(registry.get("grep").?.read_only);
    try std.testing.expect(!registry.get("write").?.read_only);
    try std.testing.expect(!registry.get("edit").?.read_only);
    try std.testing.expect(!registry.get("bash").?.read_only);
    try std.testing.expect(registry.get("nope") == null);
}

test "schema is valid JSON the model can be shown" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();

    const json = try registry.schemaJson(std.testing.allocator, &.{});
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 12), parsed.value.array.items.len);
}

test "unknown tools and bad arguments come back as errors, not failures" {
    var reads: ReadLog = .init(std.testing.allocator);
    defer reads.deinit();

    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();

    const ctx: Context = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .project_root = "/tmp",
        .reads = &reads,
    };

    const missing = try registry.executeJson(ctx, "nope", "{}");
    defer std.testing.allocator.free(missing.content);
    try std.testing.expect(missing.is_error);

    const bad = try registry.executeJson(ctx, "read", "{not json");
    defer std.testing.allocator.free(bad.content);
    try std.testing.expect(bad.is_error);
}
