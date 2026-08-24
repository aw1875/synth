//! The MCP messages this client sends and the shapes it reads back.
//!
//! Two revisions are supported at once. `2026-07-28` deleted the `initialize`
//! handshake and protocol-level sessions, moving the protocol version and the
//! client's identity into a `_meta` object on every request. `2025-11-25` is
//! what most deployed servers still speak. The difference is confined to three
//! things - whether there is a handshake, whether `_meta` rides along, and
//! whether a result declares its `resultType` - so both live here rather than
//! spreading through the client.
//!
//! Parsing is deliberately loose. A server may send fields from a revision we
//! do not implement, and none of them are a reason to fail a call.

const std = @import("std");
const testing = std.testing;

/// A protocol revision, newest first in `all`.
pub const Revision = enum {
    /// Stateless: no handshake, `_meta` on every request, `resultType` on every
    /// result, `server/discover` required.
    v2026_07_28,
    /// Session-based: `initialize` then `notifications/initialized`.
    v2025_11_25,

    pub const all: []const Revision = &.{ .v2026_07_28, .v2025_11_25 };

    pub fn string(self: Revision) []const u8 {
        return switch (self) {
            .v2026_07_28 => "2026-07-28",
            .v2025_11_25 => "2025-11-25",
        };
    }

    pub fn parse(text: []const u8) ?Revision {
        for (all) |revision| {
            if (std.mem.eql(u8, revision.string(), text)) return revision;
        }
        return null;
    }

    /// Whether this revision expects `initialize` before anything else.
    pub fn handshakes(self: Revision) bool {
        return self == .v2025_11_25;
    }

    /// Whether every request carries the version and client identity inline.
    pub fn carriesMeta(self: Revision) bool {
        return self == .v2026_07_28;
    }
};

/// Who we say we are. Sent in `initialize` on the old revision and in `_meta`
/// on the new one.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

/// `_meta` keys, spelled once. Every one of them is a reverse-DNS name in the
/// spec and easy to mistype into silence, since an unknown key is ignored
/// rather than rejected.
pub const meta_key = struct {
    pub const protocol_version = "io.modelcontextprotocol/protocolVersion";
    pub const client_capabilities = "io.modelcontextprotocol/clientCapabilities";
    pub const client_info = "io.modelcontextprotocol/clientInfo";
};

/// What a result says about itself in `2026-07-28`. A server on an earlier
/// revision omits the field, and the spec says to read that as `complete`.
pub const ResultType = enum {
    complete,
    /// The server needs something from us before it can finish, and the call
    /// has to be retried carrying the answers. Not yet implemented: reported to
    /// the caller as an error rather than silently treated as an answer.
    input_required,

    pub fn parse(text: ?[]const u8) ResultType {
        const value = text orelse return .complete;
        if (std.mem.eql(u8, value, "input_required")) return .input_required;
        return .complete;
    }
};

/// One tool a server offers. Strings borrow from the arena they were parsed
/// into.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for the arguments, as text, ready to hand to a model.
    input_schema: []const u8,
};

/// What `tools/list` returned, plus the cursor for the rest of it.
pub const ToolList = struct {
    tools: []const Tool,
    next_cursor: ?[]const u8 = null,
};

/// What `tools/call` returned, flattened to the text a model can read.
pub const CallResult = struct {
    /// Every text block joined by blank lines. Non-text blocks are named rather
    /// than dropped, so a model is told an image came back instead of seeing
    /// nothing.
    text: []const u8,
    /// The server ran the tool and it failed. Distinct from a JSON-RPC error,
    /// which means the call itself was refused.
    is_error: bool = false,
    result_type: ResultType = .complete,
};

/// Write the params for `initialize`. Old revision only.
pub fn writeInitializeParams(
    w: *std.Io.Writer,
    revision: Revision,
    client: Implementation,
) !void {
    try w.writeAll("{\"protocolVersion\":");
    try std.json.Stringify.encodeJsonString(revision.string(), .{}, w);
    try w.writeAll(",\"capabilities\":{},\"clientInfo\":");
    try writeImplementation(w, client);
    try w.writeByte('}');
}

fn writeImplementation(w: *std.Io.Writer, client: Implementation) !void {
    try w.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(client.name, .{}, w);
    try w.writeAll(",\"version\":");
    try std.json.Stringify.encodeJsonString(client.version, .{}, w);
    try w.writeByte('}');
}

/// Write the `_meta` member a `2026-07-28` request carries, inside an object
/// the caller opened and will close. `after` says whether a member has already
/// been written, and so whether this one needs a comma in front of it. Nothing
/// at all on the old revision.
pub fn writeMeta(
    w: *std.Io.Writer,
    revision: Revision,
    client: Implementation,
    after: bool,
) !void {
    if (!revision.carriesMeta()) return;

    if (after) try w.writeByte(',');
    try w.writeAll("\"" ++ meta_key.protocol_version ++ "\":");
    try std.json.Stringify.encodeJsonString(revision.string(), .{}, w);
    try w.writeAll(",\"" ++ meta_key.client_capabilities ++ "\":{}");
    try w.writeAll(",\"" ++ meta_key.client_info ++ "\":");
    try writeImplementation(w, client);
}

/// Write the params for `tools/list`.
pub fn writeListParams(
    w: *std.Io.Writer,
    revision: Revision,
    client: Implementation,
    cursor: ?[]const u8,
) !void {
    try w.writeByte('{');

    var written = false;
    if (cursor) |value| {
        try w.writeAll("\"cursor\":");
        try std.json.Stringify.encodeJsonString(value, .{}, w);
        written = true;
    }

    if (revision.carriesMeta()) {
        if (written) try w.writeByte(',');
        try w.writeAll("\"_meta\":{");
        try writeMeta(w, revision, client, false);
        try w.writeByte('}');
    }

    try w.writeByte('}');
}

/// Write the params for `tools/call`. `arguments` is the raw JSON object the
/// model produced, passed through untouched.
pub fn writeCallParams(
    w: *std.Io.Writer,
    revision: Revision,
    client: Implementation,
    name: []const u8,
    arguments: []const u8,
) !void {
    try w.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, w);
    try w.writeAll(",\"arguments\":");
    try w.writeAll(if (arguments.len == 0) "{}" else arguments);

    if (revision.carriesMeta()) {
        try w.writeAll(",\"_meta\":{");
        try writeMeta(w, revision, client, false);
        try w.writeByte('}');
    }

    try w.writeByte('}');
}

/// Read a `tools/list` result. Tools are allocated in `arena`.
pub fn parseToolList(arena: std.mem.Allocator, result: std.json.Value) !ToolList {
    const object = switch (result) {
        .object => |o| o,
        else => return error.MalformedResult,
    };

    const listed = switch (object.get("tools") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        else => return error.MalformedResult,
    };

    var tools: std.ArrayList(Tool) = .empty;
    for (listed) |entry| {
        const fields = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const name = string(fields.get("name")) orelse continue;
        if (name.len == 0) continue;

        const schema = fields.get("inputSchema") orelse std.json.Value{ .null = {} };
        try tools.append(arena, .{
            .name = name,
            .description = string(fields.get("description")) orelse "",
            .input_schema = try stringify(arena, schema),
        });
    }

    return .{
        .tools = try tools.toOwnedSlice(arena),
        .next_cursor = string(object.get("nextCursor")),
    };
}

/// Read a `tools/call` result, flattening its content blocks to text.
pub fn parseCallResult(arena: std.mem.Allocator, result: std.json.Value) !CallResult {
    const object = switch (result) {
        .object => |o| o,
        else => return error.MalformedResult,
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    var written: usize = 0;

    if (object.get("content")) |content| {
        if (content == .array) {
            for (content.array.items) |block| {
                const fields = switch (block) {
                    .object => |o| o,
                    else => continue,
                };
                const kind = string(fields.get("type")) orelse "";

                if (std.mem.eql(u8, kind, "text")) {
                    const text = string(fields.get("text")) orelse continue;
                    if (written > 0) try out.writer.writeAll("\n\n");
                    try out.writer.writeAll(text);
                    written += 1;
                    continue;
                }

                // Not something a model can read as text. Naming it beats
                // dropping it: "an image came back" is information.
                if (written > 0) try out.writer.writeAll("\n\n");
                try out.writer.print("<{s} content omitted>", .{
                    if (kind.len > 0) kind else "unknown",
                });
                written += 1;
            }
        }
    }

    // A server may answer with structured output and no content blocks at all.
    if (written == 0) {
        if (object.get("structuredContent")) |structured| {
            try out.writer.writeAll(try stringify(arena, structured));
        }
    }

    return .{
        .text = out.written(),
        .is_error = switch (object.get("isError") orelse std.json.Value{ .null = {} }) {
            .bool => |b| b,
            else => false,
        },
        .result_type = ResultType.parse(string(object.get("resultType"))),
    };
}

/// Read a `server/discover` result: which revisions the server will speak.
/// Unknown names are skipped, so a server offering something newer than this
/// client is simply met on the newest it also offers.
pub fn parseDiscover(arena: std.mem.Allocator, result: std.json.Value) ![]const Revision {
    const object = switch (result) {
        .object => |o| o,
        else => return error.MalformedResult,
    };

    const listed = switch (object.get("protocolVersions") orelse std.json.Value{ .null = {} }) {
        .array => |a| a.items,
        // A server may answer with a single version rather than a list.
        .string => |s| {
            const one = try arena.alloc(Revision, 1);
            one[0] = Revision.parse(s) orelse return error.NoSharedRevision;
            return one;
        },
        else => return error.MalformedResult,
    };

    var found: std.ArrayList(Revision) = .empty;
    for (listed) |entry| {
        const text = string(entry) orelse continue;
        const revision = Revision.parse(text) orelse continue;
        try found.append(arena, revision);
    }
    return found.toOwnedSlice(arena);
}

/// The revision to use with a server that offers `offered`: the newest both
/// sides know.
pub fn best(offered: []const Revision) ?Revision {
    for (Revision.all) |ours| {
        for (offered) |theirs| {
            if (ours == theirs) return ours;
        }
    }
    return null;
}

/// The protocol version an `initialize` result agreed to. A server is allowed
/// to answer with a revision other than the one asked for.
pub fn parseInitialize(result: std.json.Value) ?Revision {
    const object = switch (result) {
        .object => |o| o,
        else => return null,
    };
    return Revision.parse(string(object.get("protocolVersion")) orelse return null);
}

fn string(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |s| s,
        else => null,
    };
}

fn stringify(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

const client_for_test: Implementation = .{ .name = "synth", .version = "0.0.1" };

test "revisions round-trip and know their own shape" {
    try testing.expectEqualStrings("2026-07-28", Revision.v2026_07_28.string());
    try testing.expectEqual(Revision.v2025_11_25, Revision.parse("2025-11-25").?);
    try testing.expect(Revision.parse("2024-01-01") == null);

    try testing.expect(Revision.v2025_11_25.handshakes());
    try testing.expect(!Revision.v2026_07_28.handshakes());
    try testing.expect(Revision.v2026_07_28.carriesMeta());
    try testing.expect(!Revision.v2025_11_25.carriesMeta());
}

test "the newest shared revision wins" {
    try testing.expectEqual(Revision.v2026_07_28, best(&.{ .v2025_11_25, .v2026_07_28 }).?);
    try testing.expectEqual(Revision.v2025_11_25, best(&.{.v2025_11_25}).?);
    try testing.expect(best(&.{}) == null);
}

test "a call carries _meta on the new revision and not on the old" {
    var new: std.Io.Writer.Allocating = .init(testing.allocator);
    defer new.deinit();
    try writeCallParams(&new.writer, .v2026_07_28, client_for_test, "read", "{\"path\":\"a\"}");

    var parsed_new = try std.json.parseFromSlice(std.json.Value, testing.allocator, new.written(), .{});
    defer parsed_new.deinit();

    const meta = parsed_new.value.object.get("_meta").?.object;
    try testing.expectEqualStrings("2026-07-28", meta.get(meta_key.protocol_version).?.string);
    try testing.expectEqualStrings("synth", meta.get(meta_key.client_info).?.object.get("name").?.string);
    try testing.expectEqualStrings("read", parsed_new.value.object.get("name").?.string);
    try testing.expectEqualStrings("a", parsed_new.value.object.get("arguments").?.object.get("path").?.string);

    var old: std.Io.Writer.Allocating = .init(testing.allocator);
    defer old.deinit();
    try writeCallParams(&old.writer, .v2025_11_25, client_for_test, "read", "{\"path\":\"a\"}");

    var parsed_old = try std.json.parseFromSlice(std.json.Value, testing.allocator, old.written(), .{});
    defer parsed_old.deinit();
    try testing.expect(parsed_old.value.object.get("_meta") == null);
}

test "empty arguments are sent as an object" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCallParams(&out.writer, .v2025_11_25, client_for_test, "ping", "");
    try testing.expectEqualStrings("{\"name\":\"ping\",\"arguments\":{}}", out.written());
}

test "list params are valid JSON with and without a cursor" {
    for ([_]Revision{ .v2025_11_25, .v2026_07_28 }) |revision| {
        for ([_]?[]const u8{ null, "page2" }) |cursor| {
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try writeListParams(&out.writer, revision, client_for_test, cursor);

            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                testing.allocator,
                out.written(),
                .{},
            );
            defer parsed.deinit();

            try testing.expect(parsed.value == .object);
            try testing.expectEqual(
                revision.carriesMeta(),
                parsed.value.object.get("_meta") != null,
            );
            if (cursor) |value| {
                try testing.expectEqualStrings(value, parsed.value.object.get("cursor").?.string);
            }
        }
    }
}

test "initialize params name the revision and the client" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeInitializeParams(&out.writer, .v2025_11_25, client_for_test);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("2025-11-25", parsed.value.object.get("protocolVersion").?.string);
    try testing.expectEqualStrings("synth", parsed.value.object.get("clientInfo").?.object.get("name").?.string);
    try testing.expect(parsed.value.object.get("capabilities") != null);
}

test "a tool list is read, and junk entries are skipped" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"tools":[
        \\{"name":"read_file","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}},
        \\{"description":"no name at all"},
        \\"not an object",
        \\{"name":"write_file"}
        \\],"nextCursor":"page2"}
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const list = try parseToolList(arena, value);

    try testing.expectEqual(@as(usize, 2), list.tools.len);
    try testing.expectEqualStrings("read_file", list.tools[0].name);
    try testing.expectEqualStrings("Read a file", list.tools[0].description);
    try testing.expect(std.mem.indexOf(u8, list.tools[0].input_schema, "\"path\"") != null);

    // A tool with no description or schema is still usable.
    try testing.expectEqualStrings("write_file", list.tools[1].name);
    try testing.expectEqualStrings("", list.tools[1].description);
    try testing.expectEqualStrings("null", list.tools[1].input_schema);

    try testing.expectEqualStrings("page2", list.next_cursor.?);
}

test "call results flatten to text, and say when they are not text" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"content":[{"type":"text","text":"first"},{"type":"image","data":"..."},{"type":"text","text":"second"}]}
    ;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const result = try parseCallResult(arena, value);

    try testing.expectEqualStrings("first\n\n<image content omitted>\n\nsecond", result.text);
    try testing.expect(!result.is_error);
    try testing.expectEqual(ResultType.complete, result.result_type);
}

test "a failed tool is not a failed call" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "{\"content\":[{\"type\":\"text\",\"text\":\"no such file\"}],\"isError\":true}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const result = try parseCallResult(arena, value);

    try testing.expect(result.is_error);
    try testing.expectEqualStrings("no such file", result.text);
}

test "structured output is used when there are no content blocks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "{\"structuredContent\":{\"count\":3},\"resultType\":\"complete\"}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const result = try parseCallResult(arena, value);

    try testing.expectEqualStrings("{\"count\":3}", result.text);
}

test "a missing resultType reads as complete, and input_required is recognised" {
    try testing.expectEqual(ResultType.complete, ResultType.parse(null));
    try testing.expectEqual(ResultType.complete, ResultType.parse("complete"));
    try testing.expectEqual(ResultType.complete, ResultType.parse("something-new"));
    try testing.expectEqual(ResultType.input_required, ResultType.parse("input_required"));
}

test "discovery reports the revisions a server offers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "{\"protocolVersions\":[\"2026-07-28\",\"2025-11-25\",\"1999-01-01\"]}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const offered = try parseDiscover(arena, value);

    try testing.expectEqual(@as(usize, 2), offered.len);
    try testing.expectEqual(Revision.v2026_07_28, best(offered).?);

    const single = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"protocolVersions\":\"2025-11-25\"}",
        .{},
    );
    try testing.expectEqual(Revision.v2025_11_25, (try parseDiscover(arena, single))[0]);
}

test "an initialize result names the revision that was agreed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "{\"protocolVersion\":\"2025-11-25\",\"serverInfo\":{\"name\":\"files\"}}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    try testing.expectEqual(Revision.v2025_11_25, parseInitialize(value).?);

    const older = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        "{\"protocolVersion\":\"2024-11-05\"}",
        .{},
    );
    try testing.expect(parseInitialize(older) == null);
}
