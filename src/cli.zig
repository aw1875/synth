//! Command line parsing.

const std = @import("std");

const clap = @import("clap");
const pkg = @import("pkg");

/// What the user asked for. Strings are duped into the allocator passed to
/// `parse`, so they outlive clap's own arena.
pub const Command = union(enum) {
    tui: Tui,
    run: Run,
    session: Session,
    mcp: Mcp,
    db: Db,
    skills,
    models,
    prompt,
    /// Null for the whole menu, or the subcommand whose `-h` asked.
    help: ?Topic,
    version,

    pub const Tui = struct {
        /// Directory to start in, or null for the current one.
        project: ?[]const u8 = null,
        /// Resume the most recent session in this project.
        continue_last: bool = false,
        /// Resume this specific session handle.
        session: ?[]const u8 = null,
        /// Override the configured model.
        model: ?[]const u8 = null,
    };

    pub const Run = struct {
        message: []const u8,
        /// Approve calls that would otherwise prompt. Without it a headless
        /// turn denies them, so it can read but not write or run commands.
        allow: bool = false,
    };

    /// Managing MCP servers: what is configured, and what this machine is
    /// signed in to.
    pub const Mcp = union(enum) {
        list,
        auth: []const u8,
        logout: []const u8,
        debug: []const u8,
        enable: []const u8,
        disable: []const u8,
    };

    pub const Session = union(enum) {
        list,
        show: []const u8,
        remove: []const u8,
        search: []const u8,
    };

    /// Looking after the database the transcripts live in.
    pub const Db = union(enum) {
        status,
        /// Shed sessions idle this many days, or null for the configured
        /// policy.
        prune: ?u32,
        vacuum,
    };
};

const main_params = clap.parseParamsComptime(
    \\-h, --help              show this help and exit
    \\-v, --version           show the version and exit
    \\-c, --continue          resume the most recent session in this project
    \\-s, --session <str>     resume a session by handle, e.g. ses_7k3f9a2b
    \\-m, --model <str>       override the configured model
    \\<str>                   a subcommand, or the directory to start in
    \\
);

const db_params = clap.parseParamsComptime(
    \\-h, --help    show this help and exit
    \\<str>         status, prune, or vacuum
    \\<str>         for prune: shed sessions idle this many days
    \\
);

const mcp_params = clap.parseParamsComptime(
    \\-h, --help    show this help and exit
    \\<str>         list, auth, logout, debug, enable, or disable
    \\<str>         the server name, for everything but list
    \\
);

const session_params = clap.parseParamsComptime(
    \\-h, --help    show this help and exit
    \\<str>         list, show <id>, rm <id>, or search <text>
    \\<str>         the session handle, or the text to search for
    \\
);

const run_params = clap.parseParamsComptime(
    \\-h, --help     show this help and exit
    \\--allow        approve tool calls that would otherwise be denied
    \\<str>...       the prompt
    \\
);

/// Flags that belong to one subcommand. Passed before it - `synth --allow` -
/// clap only says the argument is invalid, which is true and useless.
const subcommand_flags = std.StaticStringMap([]const u8).initComptime(.{
    .{ "--allow", "run" },
});

/// Subcommand names. Anything else in the first position is a directory.
const known = std.StaticStringMap(void).initComptime(.{
    .{"session"}, .{"run"}, .{"models"}, .{"prompt"}, .{"mcp"}, .{"skills"}, .{"db"},
});

pub fn parse(init: std.process.Init, allocator: std.mem.Allocator) !Command {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    if (try misplacedFlag(init)) return error.InvalidArgument;

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &main_params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return .{ .help = null };
    if (res.args.version != 0) return .version;

    const first = res.positionals[0];
    if (first) |word| {
        if (known.has(word)) {
            if (std.mem.eql(u8, word, "session")) return parseSession(init, allocator, &iter);
            if (std.mem.eql(u8, word, "mcp")) return parseMcp(init, allocator, &iter);
            if (std.mem.eql(u8, word, "db")) return parseDb(init, &iter);
            if (std.mem.eql(u8, word, "run")) return parseRun(init, allocator, &iter);
            if (std.mem.eql(u8, word, "models")) return .models;
            if (std.mem.eql(u8, word, "skills")) return .skills;
            return .prompt;
        }
    }

    return .{ .tui = .{
        .project = try dupeOptional(allocator, first),
        .continue_last = res.args.@"continue" != 0,
        .session = try dupeOptional(allocator, res.args.session),
        .model = try dupeOptional(allocator, res.args.model),
    } };
}

/// Report a subcommand's flag used before the subcommand, and say where it
/// belongs. Only the flags ahead of the first positional are checked: past
/// that, the subcommand's own parser has them.
fn misplacedFlag(init: std.process.Init) !bool {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    while (iter.next()) |arg| {
        if (arg.len == 0 or arg[0] != '-') return false;
        const command = subcommand_flags.get(arg) orelse continue;

        var buffer: [256]u8 = undefined;
        var out = std.Io.File.stderr().writer(init.io, &buffer);
        try out.interface.print(
            "{0s} belongs to `{1s} {2s}`. Try: {1s} {2s} {0s} <message>\n",
            .{ arg, pkg.name, command },
        );
        try out.interface.flush();
        return true;
    }
    return false;
}

fn parseMcp(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Command {
    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &mcp_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return .{ .help = .mcp };

    const verb = res.positionals[0] orelse return .{ .mcp = .list };
    if (std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "ls")) return .{ .mcp = .list };

    const name = res.positionals[1] orelse return error.MissingServerName;
    const owned = try allocator.dupe(u8, name);

    if (std.mem.eql(u8, verb, "auth") or std.mem.eql(u8, verb, "login")) return .{ .mcp = .{ .auth = owned } };
    if (std.mem.eql(u8, verb, "logout")) return .{ .mcp = .{ .logout = owned } };
    if (std.mem.eql(u8, verb, "debug")) return .{ .mcp = .{ .debug = owned } };
    if (std.mem.eql(u8, verb, "enable")) return .{ .mcp = .{ .enable = owned } };
    if (std.mem.eql(u8, verb, "disable")) return .{ .mcp = .{ .disable = owned } };

    return error.UnknownSubcommand;
}

fn parseSession(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Command {
    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &session_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return .{ .help = .session };

    const verb = res.positionals[0] orelse return .{ .session = .list };
    if (std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "ls")) return .{ .session = .list };

    const handle = res.positionals[1] orelse return error.MissingSessionHandle;
    if (std.mem.eql(u8, verb, "show")) {
        return .{ .session = .{ .show = try allocator.dupe(u8, handle) } };
    }
    if (std.mem.eql(u8, verb, "rm") or std.mem.eql(u8, verb, "delete")) {
        return .{ .session = .{ .remove = try allocator.dupe(u8, handle) } };
    }
    if (std.mem.eql(u8, verb, "search") or std.mem.eql(u8, verb, "grep")) {
        return .{ .session = .{ .search = try allocator.dupe(u8, handle) } };
    }
    return error.UnknownSessionCommand;
}

fn parseDb(init: std.process.Init, iter: *std.process.Args.Iterator) !Command {
    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &db_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return .{ .help = .db };

    const verb = res.positionals[0] orelse return .{ .db = .status };
    if (std.mem.eql(u8, verb, "status")) return .{ .db = .status };
    if (std.mem.eql(u8, verb, "vacuum")) return .{ .db = .vacuum };
    if (std.mem.eql(u8, verb, "prune")) {
        const days = res.positionals[1] orelse return .{ .db = .{ .prune = null } };
        return .{ .db = .{ .prune = std.fmt.parseInt(u32, days, 10) catch return error.BadPruneDays } };
    }
    return error.UnknownDbCommand;
}

fn parseRun(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !Command {
    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &run_params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return .{ .help = .run };

    const words = res.positionals[0];
    if (words.len == 0) return error.MissingPrompt;

    return .{
        .run = .{
            .message = try std.mem.join(allocator, " ", words),
            .allow = res.args.allow != 0,
        },
    };
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    const value = text orelse return null;
    return try allocator.dupe(u8, value);
}

/// One line of help: what you type, and what it does.
/// One subcommand's slice of the help. Rows belong to a topic by the word they
/// start with, which is also how they are invoked.
pub const Topic = enum {
    run,
    session,
    mcp,
    db,

    fn word(self: Topic) []const u8 {
        return @tagName(self);
    }
};

const Row = struct {
    left: []const u8,
    right: []const u8,
};

const Section = struct {
    title: []const u8,
    /// Whether each row's left column is a way to invoke the program, and so
    /// gets the program's name in front of it.
    invocation: bool = false,
    rows: []const Row,
};

/// The help, as data. The columns are measured and padded at compile time
/// rather than typed out, so renaming the program cannot leave them ragged.
const help_sections: []const Section = &.{
    .{
        .title = "Usage",
        .invocation = true,
        .rows = &.{
            .{ .left = "[project]", .right = "start the TUI (default)" },
            .{ .left = "run [--allow] <message>", .right = "one headless turn, no TUI" },
            .{ .left = "session list", .right = "sessions for this project, newest first" },
            .{ .left = "session show <id>", .right = "print a session's transcript" },
            .{ .left = "session rm <id>", .right = "delete a session" },
            .{ .left = "session search <text>", .right = "find messages in this project's transcripts" },
            .{ .left = "mcp list", .right = "configured MCP servers and their state" },
            .{ .left = "mcp auth <name>", .right = "sign in to a remote MCP server" },
            .{ .left = "mcp logout <name>", .right = "forget a server's credentials" },
            .{ .left = "mcp debug <name>", .right = "show what OAuth discovery finds" },
            .{ .left = "mcp enable <name>", .right = "start using a server again" },
            .{ .left = "mcp disable <name>", .right = "stop connecting to a server" },
            .{ .left = "db status", .right = "what the database holds, and what a prune would free" },
            .{ .left = "db prune [days]", .right = "shed stored tool output from idle sessions" },
            .{ .left = "db vacuum", .right = "hand freed pages back to the filesystem" },
            .{ .left = "skills", .right = "skills on offer, and where they came from" },
            .{ .left = "models", .right = "models the provider offers" },
            .{ .left = "prompt", .right = "print the system prompt" },
        },
    },
    .{
        .title = "Options",
        .rows = &.{
            .{ .left = "-c, --continue", .right = "resume the most recent session here" },
            .{ .left = "-s, --session <id>", .right = "resume a session by handle (ses_7k3f9a2b)" },
            .{ .left = "-m, --model <name>", .right = "override the configured model" },
            .{ .left = "-h, --help", .right = "show this help" },
            .{ .left = "-v, --version", .right = "show the version" },
        },
    },
    .{
        .title = "Options for run",
        .rows = &.{
            .{
                .left = "    --allow",
                .right =
                \\approve calls that would prompt. Without it
                \\they are denied, so a headless turn can read
                \\but not write or run commands
                ,
            },
        },
    },
};

pub const usage = buildUsage(null);

/// The help for one subcommand, so `synth db -h` answers about `db` rather than
/// reprinting everything.
pub fn usageFor(topic: ?Topic) []const u8 {
    const chosen = topic orelse return usage;
    return switch (chosen) {
        inline else => |t| comptime buildUsage(t),
    };
}

/// Whether a row belongs to `topic`: its left column names the subcommand, or
/// it is an option that subcommand takes.
fn inTopic(section: Section, row: Row, topic: Topic) bool {
    if (!section.invocation) return std.mem.indexOf(u8, section.title, topic.word()) != null;
    return std.mem.startsWith(u8, row.left, topic.word() ++ " ") or
        std.mem.eql(u8, row.left, topic.word());
}

/// Lay the sections out in two columns, every description starting at the same
/// one. A description may run to several lines; the rest are indented to match.
fn buildUsage(comptime topic: ?Topic) []const u8 {
    @setEvalBranchQuota(20_000);
    comptime {
        var column = 0;
        for (help_sections) |section| {
            for (section.rows) |row| {
                if (topic) |t| if (!inTopic(section, row, t)) continue;
                const width = leftOf(section, row).len;
                if (width > column) column = width;
            }
        }
        column += indent.len + gap.len;

        var out: []const u8 = pkg.name ++ " - An agent for your terminal\n";
        for (help_sections) |section| {
            var wrote_title = false;
            for (section.rows) |row| {
                if (topic) |t| if (!inTopic(section, row, t)) continue;
                if (!wrote_title) {
                    out = out ++ "\n" ++ section.title ++ ":\n";
                    wrote_title = true;
                }

                const left = leftOf(section, row);
                out = out ++ indent ++ left ++ pad(column - indent.len - left.len);

                var lines = std.mem.splitScalar(u8, row.right, '\n');
                out = out ++ lines.first() ++ "\n";
                while (lines.next()) |line| out = out ++ pad(column) ++ line ++ "\n";
            }
        }
        return out;
    }
}

const indent = "  ";
const gap = "  ";

fn leftOf(section: Section, row: Row) []const u8 {
    return if (section.invocation) pkg.name ++ " " ++ row.left else row.left;
}

fn pad(n: usize) []const u8 {
    return " " ** n;
}

test "a subcommand's help covers that subcommand and nothing else" {
    const testing = std.testing;

    inline for (comptime std.enums.values(Topic)) |topic| {
        const text = usageFor(topic);
        try testing.expect(text.len < usage.len);

        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.first();
        while (lines.next()) |line| {
            const row = std.mem.trimStart(u8, line, " ");
            const prefix = pkg.name ++ " ";
            if (!std.mem.startsWith(u8, row, prefix)) continue;
            try testing.expect(std.mem.startsWith(u8, row[prefix.len..], topic.word()));
        }
    }

    try testing.expectEqualStrings(usage, usageFor(null));
}

test "prose stays ASCII" {
    // Em dashes and curly quotes creep in from anywhere text is pasted. The
    // drawn glyphs are deliberate and stay; this catches the rest.
    const banned = [_][]const u8{ "\u{2014}", "\u{2013}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{00A0}" };
    for (banned) |bad| {
        try std.testing.expect(std.mem.indexOf(u8, usage, bad) == null);
    }
}

test "every help row fits one column" {
    const testing = std.testing;

    var lines = std.mem.splitScalar(u8, usage, '\n');
    var column: ?usize = null;
    var checked: usize = 0;

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ")) continue;
        // Past the left column's own indent: `    --allow` starts with a gap.
        const text_at = line.len - std.mem.trimStart(u8, line, " ").len;
        const at = std.mem.indexOfPos(u8, line, text_at, "  ") orelse continue;
        const rest = std.mem.trimStart(u8, line[at..], " ");
        if (rest.len == 0) continue;
        const start = line.len - rest.len;
        if (column) |first| try testing.expectEqual(first, start) else column = start;
        checked += 1;
    }

    // Usage, Options and Options for run, every row of each.
    try testing.expect(checked >= 13);
}

test "a flag in the wrong place names the subcommand it belongs to" {
    try std.testing.expectEqualStrings("run", subcommand_flags.get("--allow").?);
    try std.testing.expect(subcommand_flags.get("--model") == null);

    // Every one of them has to be a flag, or the scan would stop at it.
    for (subcommand_flags.keys()) |flag| {
        try std.testing.expect(std.mem.startsWith(u8, flag, "-"));
    }
}

test "a bare invocation is the TUI" {
    try std.testing.expect(known.has("session"));
    try std.testing.expect(known.has("models"));
    try std.testing.expect(known.has("skills"));
    try std.testing.expect(!known.has("~/code/thing"));
}
