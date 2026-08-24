//! Loading a skill's instructions on demand.
//!
//! The system prompt carries one line per skill; this is how the rest of it
//! arrives. Registered only when the project has skills at all, so a model
//! working somewhere without them is never told about a tool that has nothing
//! to load.

const std = @import("std");

const skills = @import("../core/skill.zig");
const tool = @import("tool.zig");

pub const name = "skill";

const description =
    \\Load a skill's full instructions. The skills available are listed in the
    \\system prompt with a line each on what they are for; call this before
    \\starting work one of them covers, and follow what it says.
;

const schema =
    \\{"type":"object","properties":{"name":{"type":"string","description":"The skill to load, as named in <skills>"}},"required":["name"]}
;

/// Make `skill` callable, backed by `set`. The set is borrowed and must outlive
/// the registry.
pub fn install(registry: anytype, set: *const skills.Set) !void {
    if (!set.any()) return;
    try registry.register(.{
        .name = name,
        .description = description,
        .schema = schema,
        .handler = handler,
        .userdata = @constCast(@ptrCast(set)),
        .read_only = true,
    });
}

fn handler(ctx: tool.Context, input: tool.Input) !tool.Output {
    const raw = ctx.userdata orelse return tool.Output.err(
        try ctx.allocator.dupe(u8, "no skills are loaded"),
    );
    const set: *const skills.Set = @ptrCast(@alignCast(raw));

    const wanted = input.string("name") orelse return tool.Output.err(
        try ctx.allocator.dupe(u8, "skill: 'name' is required"),
    );
    const trimmed = std.mem.trim(u8, std.mem.trimStart(u8, wanted, "/"), " \t\r\n");

    const found = set.find(trimmed) orelse return tool.Output.err(
        try unknown(ctx.allocator, set, trimmed),
    );

    return tool.Output.ok(try render(ctx.allocator, found));
}

/// A skill as the model reads it. The directory is named because a skill's
/// instructions routinely point at a script or a template beside them, and
/// without it those paths resolve against the project root instead.
pub fn render(allocator: std.mem.Allocator, found: skills.Skill) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "# {s}\nSkill directory: {s}\nPaths in these instructions are relative to it.\n\n{s}\n",
        .{ found.name, found.dir, found.body },
    );
}

fn unknown(allocator: std.mem.Allocator, set: *const skills.Set, wanted: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("no skill called '{s}'. Available: ", .{wanted});
    for (set.skills, 0..) |entry, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(entry.id);
    }
    if (set.skills.len == 0) try out.writer.writeAll("none");

    return out.toOwnedSlice();
}

const testing = std.testing;

/// A set built by hand, so the tests here do not need a filesystem.
fn fixture() !skills.Set {
    var set: skills.Set = .{ .arena = .init(testing.allocator) };
    const arena = set.arena.allocator();

    const built = try arena.alloc(skills.Skill, 2);
    built[0] = .{
        .id = "commit",
        .name = "Commit style",
        .description = "how commits are written here",
        .dir = "/p/.agents/skills/commit",
        .body = "One line, lowercase.",
    };
    built[1] = .{
        .id = "release",
        .name = "release",
        .description = "",
        .dir = "/p/.agents/skills/release",
        .body = "Tag, then push.",
    };
    set.skills = built;
    return set;
}

fn call(ctx: tool.Context, arguments: []const u8) !tool.Output {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, arguments, .{});
    defer parsed.deinit();
    return handler(ctx, .{ .arguments = parsed.value });
}

fn context(set: *const skills.Set, reads: *tool.ReadLog) tool.Context {
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = "/p",
        .reads = reads,
        .userdata = @constCast(@ptrCast(set)),
    };
}

test "a loaded skill comes back with its instructions and where they live" {
    var set = try fixture();
    defer set.deinit();

    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const out = try call(context(&set, &reads), "{\"name\":\"commit\"}");
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "Commit style") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "/p/.agents/skills/commit") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "One line, lowercase.") != null);
}

test "a leading slash is forgiven, since that is how a person names one" {
    var set = try fixture();
    defer set.deinit();

    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const out = try call(context(&set, &reads), "{\"name\":\"/release\"}");
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "Tag, then push.") != null);
}

test "asking for one that is not there lists the ones that are" {
    var set = try fixture();
    defer set.deinit();

    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const out = try call(context(&set, &reads), "{\"name\":\"nope\"}");
    defer testing.allocator.free(out.content);

    try testing.expect(out.is_error);
    try testing.expect(std.mem.indexOf(u8, out.content, "commit") != null);
    try testing.expect(std.mem.indexOf(u8, out.content, "release") != null);

    const missing = try call(context(&set, &reads), "{}");
    defer testing.allocator.free(missing.content);
    try testing.expect(missing.is_error);
}
