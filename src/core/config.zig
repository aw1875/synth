//! Harness configuration, layered lowest-precedence first:
//! built-in defaults, then `config.json`, then environment variables.

const std = @import("std");
const builtin = @import("builtin");

const pkg = @import("pkg");
const Hooks = @import("hooks.zig");

const Config = @This();

/// `$XDG_CONFIG_HOME/<name>/config.json`, or `~/.config/<name>/config.json`. A
/// debug build looks in the working directory, so a dev checkout does not read
/// the installed config. Owned by the caller.
pub fn defaultPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (builtin.mode == .Debug) return allocator.dupe(u8, "config.json");
    const base = env.get("XDG_CONFIG_HOME") orelse blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    defer if (env.get("XDG_CONFIG_HOME") == null) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, pkg.name, "config.json" });
}

/// `$XDG_DATA_HOME/<name>/<name>.db`, or `~/.local/share/<name>/<name>.db`. A
/// debug build keeps it in the working directory. Owned by the caller.
pub fn defaultDatabasePath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (builtin.mode == .Debug) return allocator.dupe(u8, database_file);
    const base = env.get("XDG_DATA_HOME") orelse blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    };
    defer if (env.get("XDG_DATA_HOME") == null) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, pkg.name, database_file });
}

/// `$XDG_DATA_HOME/<name>/mcp-auth.json`, or `~/.local/share/<name>/...`. A
/// debug build keeps it in the working directory. Owned by the caller.
///
/// Beside the database rather than the config: this is state the program
/// writes - OAuth tokens and client registrations - not anything a person
/// edits.
pub fn defaultMcpAuthPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (builtin.mode == .Debug) return allocator.dupe(u8, mcp_auth_file);
    const base = env.get("XDG_DATA_HOME") orelse blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
    };
    defer if (env.get("XDG_DATA_HOME") == null) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, pkg.name, mcp_auth_file });
}

/// What the database is called, wherever it ends up living.
const database_file = pkg.name ++ ".db";

/// Where per-server OAuth state is kept.
const mcp_auth_file = "mcp-auth.json";

/// Largest config file we will read.
const max_file_bytes: std.Io.Limit = .limited(64 * 1024);

/// Backing storage for every owned string below.
arena: std.heap.ArenaAllocator,

/// Which provider to use, from `SYNTH_PROVIDER`. The choice itself lives in
/// the database - it is written by connecting one, and a file a person edits by
/// hand should not be rewritten underneath them. Empty means "whatever was
/// chosen last".
provider_override: []const u8 = "",
/// Host, model and key from the environment or the old `ollama` block, applied
/// over what the database remembers. Empty means "not set".
host_override: []const u8 = "",
model_override: []const u8 = "",
/// A key from the old `ollama` block or from `OLLAMA_API_KEY`. `auth.json` is
/// where keys belong now; this is the fallback that keeps an existing setup
/// working.
api_key: ?[]const u8 = null,
/// The same pair from `OPENAI_BASE_URL` and `OPENAI_API_KEY`, applied only
/// when the active provider speaks that API. Kept apart from the `OLLAMA_`
/// ones so a machine with both set does not hand one server the other's
/// settings.
openai_host: []const u8 = "",
openai_api_key: ?[]const u8 = null,
/// Request reasoning output. Turn off for models that do not support it.
think: bool = true,
/// Let the preset list of read-only shell commands run without an approval
/// prompt. Off makes every command a question, however harmless.
auto_approve_safe_commands: bool = true,
/// How long one turn may run, and what it may spend, before the loop gives up
/// on it. Zero turns either off. Null means the built-in default: what a
/// runaway turn costs is the loop's business, not this file's.
max_turn_ms: ?i64 = null,
max_turn_tokens: ?u64 = null,
/// Append every request and reply to this file, for debugging.
debug_log: ?[]const u8 = null,
database_path: []const u8 = database_file,
/// The file this was loaded from, for anything that has to name it. Empty when
/// the config was built by hand rather than loaded.
path: []const u8 = "",
/// A prompt from `config.json`, replacing the built-in one. Null means the
/// built-in one: what that says is the agent's business, not this file's.
system_prompt: ?[]const u8 = null,
/// Extra directories to look for skills in, on top of the ones under the
/// project root and `$HOME`. Absolute paths, searched in the order given.
skill_paths: []const []const u8 = &.{},
/// The `mcp` block, still as JSON. Held rather than parsed because what a
/// server entry means is the MCP adapter's business, and this file would only
/// be repeating its shape. Borrowed from this config's arena.
mcp: ?std.json.Value = null,
hooks: Hooks.Set = .{},
hook_timeout_ms: u64 = Hooks.default_timeout_ms,

/// The shape `config.json` is parsed into. Every field is optional so an
/// absent key falls through to whatever the previous layer set.
const File = struct {
    database_path: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    think: ?bool = null,
    auto_approve_safe_commands: ?bool = null,
    debug_log: ?[]const u8 = null,
    max_turn_ms: ?i64 = null,
    max_turn_tokens: ?u64 = null,
    skill_paths: ?[]const []const u8 = null,
    mcp: ?std.json.Value = null,
    hooks: ?Hooks.File = null,
    hook_timeout_ms: ?u64 = null,
    /// The single-provider shape this file used to have. Still read, so an
    /// existing `config.json` keeps working; nothing writes it any more, and
    /// where a provider lives is the database's business now.
    ollama: ?struct {
        host: ?[]const u8 = null,
        model: ?[]const u8 = null,
        api_key: ?[]const u8 = null,
        think: ?bool = null,
        debug_log: ?[]const u8 = null,
    } = null,
};

pub fn deinit(self: *Config) void {
    self.arena.deinit();
}

/// The config file written for a first run.
const starter_file = .{
    .@"$schema" = "https://raw.githubusercontent.com/aw1875/synth/master/config.schema.json",
    .think = true,
};

/// Create the directory `path` sits in, if it names one.
pub fn ensureDir(io: std.Io, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, dir);
}

/// Make sure a config file exists at `path`, creating its directory and a
/// starter file if not. Leaves an existing file alone, whatever is in it.
pub fn ensureFile(io: std.Io, path: []const u8) !void {
    try ensureDir(io, path);

    const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.close(io);

    var buffer: [512]u8 = undefined;
    var writer = file.writer(io, &buffer);

    var json: std.json.Stringify = .{
        .writer = &writer.interface,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(starter_file);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

/// Resolve where the config and the database live, make sure both are ready to
/// be used, and load. The one way in: every command that reads config goes
/// through here, so the paths are resolved once and in one place.
pub fn open(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !Config {
    const config_path = try defaultPath(allocator, env);
    defer allocator.free(config_path);

    const db_path = try defaultDatabasePath(allocator, env);
    defer allocator.free(db_path);

    ensureFile(io, config_path) catch {};

    return load(allocator, io, env, config_path, db_path);
}

/// Read the config file if present, then apply environment overrides. A missing
/// file is not an error; a malformed one is.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    path: []const u8,
    db_path: []const u8,
) !Config {
    var self: Config = .{ .arena = .init(allocator) };
    errdefer self.arena.deinit();

    self.database_path = try self.arena.allocator().dupe(u8, db_path);
    self.path = try self.arena.allocator().dupe(u8, path);
    try self.applyFile(io, path);
    try self.applyEnv(env);

    return self;
}

fn applyFile(self: *Config, io: std.Io, path: []const u8) !void {
    const arena = self.arena.allocator();

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const parsed = try std.json.parseFromSliceLeaky(File, arena, source, .{
        .ignore_unknown_fields = true,
    });

    if (parsed.database_path) |value| self.database_path = value;
    if (parsed.system_prompt) |value| self.system_prompt = value;
    if (parsed.think) |value| self.think = value;
    if (parsed.auto_approve_safe_commands) |value| self.auto_approve_safe_commands = value;
    if (parsed.debug_log) |value| self.debug_log = value;
    if (parsed.max_turn_ms) |value| self.max_turn_ms = value;
    if (parsed.max_turn_tokens) |value| self.max_turn_tokens = value;
    if (parsed.skill_paths) |value| self.skill_paths = value;
    if (parsed.mcp) |value| self.mcp = value;
    if (parsed.hooks) |value| self.hooks = value.set();
    if (parsed.hook_timeout_ms) |value| self.hook_timeout_ms = value;

    if (parsed.ollama) |ollama| {
        if (ollama.host) |value| self.host_override = value;
        if (ollama.model) |value| self.model_override = value;
        if (ollama.api_key) |value| self.api_key = value;
        if (ollama.think) |value| self.think = value;
        if (ollama.debug_log) |value| self.debug_log = value;
    }
}

fn applyEnv(self: *Config, env: *std.process.Environ.Map) !void {
    if (env.get("SYNTH_PROVIDER")) |name| self.provider_override = name;
    if (env.get("SYNTH_DB")) |value| self.database_path = value;
    if (env.get("OLLAMA_HOST")) |value| self.host_override = value;
    if (env.get("OLLAMA_MODEL")) |value| self.model_override = value;
    if (env.get("OLLAMA_API_KEY")) |value| self.api_key = value;
    if (env.get("OPENAI_BASE_URL")) |value| self.openai_host = value;
    if (env.get("OPENAI_API_KEY")) |value| self.openai_api_key = value;
    if (env.get("SYNTH_DEBUG_LOG")) |value| self.debug_log = value;
    if (env.get("OLLAMA_THINK")) |value| {
        self.think = !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
    }
}

test "defaults survive a missing config file" {
    const testing = std.testing;

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();

    try config.applyFile(testing.io, "definitely-not-a-real-config.json");

    try testing.expectEqualStrings("", config.provider_override);
    try testing.expectEqualStrings("", config.host_override);
    try testing.expectEqualStrings("", config.model_override);
    try testing.expect(config.api_key == null);
    try testing.expect(config.think);
}

test "a first run gets a config file, directories and all" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];

    const path = try std.fs.path.join(testing.allocator, &.{ root, "nested", pkg.name, "config.json" });
    defer testing.allocator.free(path);

    try ensureFile(io, path);

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    try config.applyFile(io, path);

    try testing.expect(config.think);
    try testing.expectEqualStrings("", config.host_override);
}

test "an existing config file is never written over" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];

    const path = try std.fs.path.join(testing.allocator, &.{ root, "config.json" });
    defer testing.allocator.free(path);

    const edited =
        \\{"ollama": {"model": "chosen-by-hand", "host": "http://elsewhere:1234"}}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = edited });

    try ensureFile(io, path);
    try ensureFile(io, path);

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    try config.applyFile(io, path);

    try testing.expectEqualStrings("chosen-by-hand", config.model_override);
    try testing.expectEqualStrings("http://elsewhere:1234", config.host_override);
}

test "a bare filename has no directory to create" {
    try ensureDir(std.testing.io, "config.json");
    try ensureDir(std.testing.io, database_file);
}

test "extra skill directories are read from the file" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];

    const path = try std.fs.path.join(testing.allocator, &.{ root, "config.json" });
    defer testing.allocator.free(path);

    const edited =
        \\{"skill_paths": ["/opt/skills", "/srv/team/skills"]}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = edited });

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    try config.applyFile(io, path);

    try testing.expectEqual(@as(usize, 2), config.skill_paths.len);
    try testing.expectEqualStrings("/opt/skills", config.skill_paths[0]);
    try testing.expectEqualStrings("/srv/team/skills", config.skill_paths[1]);
}

test "lifecycle hooks are read from the file" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "config.json" });
    defer testing.allocator.free(path);

    const source =
        \\{"hook_timeout_ms":5000,"hooks":{"PreToolUse":[{"matcher":"bash","command":"./check.sh"}]}}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = source });

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.deinit();
    try config.applyFile(io, path);

    try testing.expectEqual(@as(usize, 1), config.hooks.pre_tool_use.len);
    try testing.expectEqualStrings("bash", config.hooks.pre_tool_use[0].matcher);
    try testing.expectEqualStrings("./check.sh", config.hooks.pre_tool_use[0].command);
    try testing.expectEqual(@as(u64, 5000), config.hook_timeout_ms);
}
