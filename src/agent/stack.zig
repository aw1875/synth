//! One agent session, assembled: the project it runs in, the tools it may call,
//! and the loop that drives them, configured the way `config.json` says.
//!
//! Everything here points at everything else, so it lives on the heap and is
//! built and torn down in one place.

const std = @import("std");

const pkg = @import("pkg");
const mcp = @import("mcp");

const Backend = @import("../provider/backend.zig");
const Provider = @import("../provider/provider.zig");
const Config = @import("../core/config.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const Hooks = @import("../core/hooks.zig");
const Project = @import("../core/project.zig");
const skill = @import("../core/skill.zig");
const mcp_tools = @import("../tools/mcp.zig");
const Registry = @import("../tools/registry.zig");
const skill_tool = @import("../tools/skill.zig");
const tool = @import("../tools/tool.zig");
const web = @import("../tools/web.zig");
const agents = @import("agent.zig");
const Loop = @import("loop.zig");
const subagent = @import("subagent.zig");

const Stack = @This();

allocator: std.mem.Allocator,
/// The parsed MCP server list, which the host borrows.
arena: std.heap.ArenaAllocator,
project: Project,
skills: skill.Set,
registry: Registry,
web_settings: web.Settings,
mcp_host: mcp_tools.Host,
reads: tool.ReadLog,
convo: Conversation,
hooks: Hooks.Runner,
runner: subagent.Runner,
loop: Loop,

pub const Options = struct {
    config: *const Config,
    /// What this session's turns go through. Never shared with another
    /// session: a client is single-writer.
    provider: Provider,
    /// Where subagents get clients of their own. Null leaves them on
    /// `provider`.
    backend: ?*Backend = null,
    /// Where the session runs; the project is whatever repository holds it.
    cwd: []const u8,
    home: ?[]const u8 = null,
    db: ?*Database = null,
    mcp_auth: ?*mcp.Auth = null,
    mcp_stderr: mcp.Transport.Stderr = .ignore,
    /// Wait for the MCP servers, so their tools are offered from the first
    /// turn, or leave them connecting for the owner to `install` once
    /// `mcp_host` has settled.
    mcp_connect: enum { wait, background } = .wait,
};

/// Build a session, reaching its MCP servers as `options.mcp_connect` says.
pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Stack {
    const config = options.config;

    const self = try allocator.create(Stack);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.arena = .init(allocator);
    errdefer self.arena.deinit();

    self.project = try Project.detect(allocator, io, options.cwd);
    errdefer self.project.deinit(allocator);

    self.skills = try skill.load(allocator, io, self.project.root, config.skill_paths, options.home);
    errdefer self.skills.deinit();

    self.registry = try Registry.init(allocator);
    errdefer self.registry.deinit();
    try skill_tool.install(&self.registry, &self.skills);
    self.web_settings = .{ .search_api_key = config.search_api_key };
    try web.install(&self.registry, &self.web_settings);

    self.mcp_host = .init(allocator, io);
    errdefer self.mcp_host.deinit();
    self.mcp_host.auth = options.mcp_auth;
    self.mcp_host.stderr = options.mcp_stderr;
    if (config.mcp) |block| {
        const servers = try mcp_tools.serversFromJson(self.arena.allocator(), block);
        const client: mcp.Implementation = .{ .name = pkg.name, .version = pkg.version };
        switch (options.mcp_connect) {
            .wait => try self.mcp_host.connectAll(&self.registry, servers, client),
            .background => try self.mcp_host.beginConnectAll(servers, client),
        }
    }

    self.reads = .init(allocator);
    errdefer self.reads.deinit();
    self.convo = .init(allocator);
    errdefer self.convo.deinit();

    self.loop = .init(allocator, io, options.provider, &self.registry, &self.convo, &self.reads, self.project.root);
    self.runner = .{ .parent = &self.loop, .backend = options.backend };
    self.loop.delegate = self.runner.delegate();
    errdefer {
        self.loop.deinit();
        self.runner.deinit();
    }

    self.hooks = .{
        .io = io,
        .root = self.project.root,
        .set = config.hooks,
        .timeout_ms = config.hook_timeout_ms,
    };
    self.loop.hooks = &self.hooks;
    self.loop.auto_approve_safe = config.auto_approve_safe_commands;
    self.loop.auto_approve_all = config.auto_approve_all;
    if (config.max_turn_ms) |ms| self.loop.max_turn_ms = ms;
    if (config.max_stall_ms) |ms| self.loop.max_stall_ms = ms;
    if (config.max_turn_tokens) |tokens| self.loop.max_turn_tokens = tokens;
    if (config.system_prompt) |text| self.loop.system_prompt = text;
    self.loop.project = &self.project;
    self.loop.skills = self.skills.skills;
    try self.loop.useAgent(agents.default_id);

    if (options.db) |db| {
        try self.loop.attachDatabase(db, self.project.name(), self.project.cwd, options.provider.model);
    }
    return self;
}

pub fn destroy(self: *Stack) void {
    // Ordered: the loop joins workers writing to the runner; MCP tools point into the host.
    self.loop.deinit();
    self.runner.deinit();
    self.convo.deinit();
    self.reads.deinit();
    self.registry.deinit();
    self.mcp_host.deinit();
    self.skills.deinit();
    self.project.deinit(self.allocator);
    self.arena.deinit();
    self.allocator.destroy(self);
}

test "a stack assembles a loop ready for its first turn" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.arena.deinit();
    var backend: Backend = .init(.ollama, .{
        .allocator = testing.allocator,
        .io = io,
        .host = "http://127.0.0.1:9",
        .label = "test",
    });
    defer backend.deinit();

    const stack = try create(testing.allocator, io, .{ .config = &config, .provider = backend.provider(), .backend = &backend, .cwd = cwd });
    defer stack.destroy();

    try testing.expectEqualStrings(cwd, stack.project.cwd);
    try testing.expect(!stack.loop.isBusy());
    try testing.expectEqualStrings(agents.default_id, stack.loop.agent.id);
    try testing.expect(stack.registry.get("read") != null);
    try testing.expect(stack.loop.delegate != null);
}
