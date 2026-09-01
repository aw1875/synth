//! The `/` command picker, shown above the prompt while a slash command is
//! being typed.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fuzzy = @import("../core/fuzzy.zig");
const skill = @import("../core/skill.zig");
const theme = @import("theme.zig");
const w = @import("widgets.zig");

const Slash = @This();

/// Rows shown at once.
pub const max_rows: u16 = 8;

pub const Command = struct {
    /// Without the slash.
    name: []const u8,
    /// What it does, one line, lowercase.
    description: []const u8,
    /// Argument hint, or "" when it takes none. A command with an argument
    /// completes with a trailing space so typing can continue.
    argument: []const u8 = "",
    /// Whether this came from a skill directory rather than the table below.
    /// What tells the dispatcher to load instructions instead of running a verb.
    is_skill: bool = false,
};

/// Ranked fuzzy matches kept when nothing matched by prefix. A ceiling on the
/// ranking buffer, not on what can be typed: a project with two hundred skills
/// still completes them all by prefix.
const max_ranked: usize = 32;

/// What a skill offers when it has no description of its own.
const unlabelled_skill = "run this skill";

/// Everything `/` offers. Kept in the order it should be read, not
/// alphabetically: the ones that change what the model sees come first.
pub const commands: []const Command = &.{
    .{ .name = "compact", .description = "summarise the conversation so far, freeing context" },
    .{ .name = "model", .description = "switch the model this session runs on", .argument = "[name]" },
    .{ .name = "sessions", .description = "switch to another session" },
    .{ .name = "providers", .description = "connect a provider, or switch to another" },
    .{ .name = "agent", .description = "switch mode: build, plan or review", .argument = "[name]" },
    .{ .name = "mcp", .description = "turn MCP servers on and off" },
    .{ .name = "skills", .description = "list the skills on offer, and where they came from" },
    .{ .name = "theme", .description = "change the color theme", .argument = "[name]" },
    .{ .name = "rename", .description = "name this session", .argument = "[name]" },
    .{ .name = "prune", .description = "shrink the database, dropping old stored tool output" },
    .{ .name = "search", .description = "find text in this project's transcripts", .argument = "<text>" },
    .{ .name = "help", .description = "list these commands" },
};

/// The project's skills, offered after the built-in commands. Borrowed, and
/// empty where nothing discovered any.
skills: []const skill.Skill = &.{},

/// Indices into everything on offer, matching what has been typed, best first.
matches: std.ArrayList(usize) = .empty,
selected: usize = 0,
/// Whether the draft currently is a slash command being typed.
active: bool = false,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Slash {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Slash) void {
    self.matches.deinit(self.allocator);
}

/// How many entries `/` can offer: the fixed table, then the skills.
pub fn total(self: *const Slash) usize {
    return commands.len + self.skills.len;
}

/// One entry by index, wherever it came from. A skill takes an argument
/// because a skill is usually invoked against something.
pub fn at(self: *const Slash, index: usize) Command {
    if (index < commands.len) return commands[index];

    const found = self.skills[index - commands.len];
    return .{
        .name = found.id,
        .description = if (found.description.len > 0) found.description else unlabelled_skill,
        .argument = "[input]",
        .is_skill = true,
    };
}

pub fn isOpen(self: *const Slash) bool {
    return self.active and self.matches.items.len > 0;
}

pub fn close(self: *Slash) void {
    self.active = false;
    self.selected = 0;
    self.matches.clearRetainingCapacity();
}

/// Recompute from the draft. Open only while the cursor is inside the first
/// word and that word starts with `/`: once the arguments begin, the picker has
/// nothing left to offer.
pub fn update(self: *Slash, text: []const u8, cursor: usize) !void {
    if (cursor > text.len or text.len == 0 or text[0] != '/') {
        self.close();
        return;
    }
    const word_end = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
    if (cursor > word_end) {
        self.close();
        return;
    }

    self.active = true;
    try self.filter(text[1..word_end]);
    if (self.selected >= self.matches.items.len) self.selected = 0;
}

fn filter(self: *Slash, query: []const u8) !void {
    self.matches.clearRetainingCapacity();

    for (0..self.total()) |i| {
        if (std.ascii.startsWithIgnoreCase(self.at(i).name, query)) {
            try self.matches.append(self.allocator, i);
        }
    }
    if (query.len == 0) return;

    var top: fuzzy.Top(max_ranked) = .{};
    for (0..self.total()) |i| {
        const command = self.at(i);
        if (std.ascii.startsWithIgnoreCase(command.name, query)) continue;
        top.consider(i, command.name, query, .{});
    }
    for (top.ranked()) |entry| try self.matches.append(self.allocator, entry.index);
}

pub fn moveSelection(self: *Slash, delta: i32) void {
    if (self.matches.items.len == 0) return;
    const count: i32 = @intCast(self.matches.items.len);
    const current: i32 = @intCast(self.selected);
    self.selected = @intCast(@mod(current + delta + count, count));
}

/// The highlighted command, if the picker is open.
pub fn selectedCommand(self: *const Slash) ?Command {
    if (!self.isOpen()) return null;
    return self.at(self.matches.items[self.selected]);
}

/// What the draft becomes when the highlighted command is accepted.
pub fn completion(self: *const Slash, arena: std.mem.Allocator) !?[]const u8 {
    const command = self.selectedCommand() orelse return null;
    if (command.argument.len == 0) return try std.fmt.allocPrint(arena, "/{s}", .{command.name});
    return try std.fmt.allocPrint(arena, "/{s} ", .{command.name});
}

/// Keys that are not discoverable by typing, so `/help` names them. Kept here
/// beside the command table for the same reason: one place to read, one place
/// to add to.
pub const shortcuts: []const struct { keys: []const u8, description: []const u8 } = &.{
    .{ .keys = "tab", .description = "cycle mode: build, plan, review" },
    .{ .keys = "ctrl+o", .description = "switch model" },
    .{ .keys = "ctrl+s", .description = "switch session" },
    .{ .keys = "ctrl+p", .description = "switch provider" },
    .{ .keys = "ctrl+r", .description = "rename this session" },
    .{ .keys = "ctrl+t", .description = "collapse or expand the plan" },
    .{ .keys = "ctrl+v", .description = "paste an image from the clipboard" },
    .{ .keys = "ctrl+c", .description = "clear the draft, interrupt a turn, then quit" },
    .{ .keys = "ctrl+z", .description = "suspend to the shell" },
    .{ .keys = "esc", .description = "cancel the turn, or close what is open" },
};

/// Commands, skills and keys, for `/help`.
pub fn helpText(arena: std.mem.Allocator, available: []const skill.Skill) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(arena, "**Commands**\n\n");
    for (commands) |command| {
        try out.print(arena, "- `/{s}{s}{s}` - {s}\n", .{
            command.name,
            if (command.argument.len > 0) " " else "",
            command.argument,
            command.description,
        });
    }

    if (available.len > 0) {
        try out.appendSlice(arena, "\n**Skills**\n\n");
        for (available) |entry| {
            try out.print(arena, "- `/{s}` - {s}\n", .{
                entry.id,
                if (entry.description.len > 0) entry.description else unlabelled_skill,
            });
        }
    }

    try out.appendSlice(arena, "\n**Keys**\n\n");
    for (shortcuts) |shortcut| {
        try out.print(arena, "- `{s}` - {s}\n", .{ shortcut.keys, shortcut.description });
    }

    return out.toOwnedSlice(arena);
}

test "help names every command and every key" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const skills: []const skill.Skill = &.{
        .{ .id = "release", .name = "Release", .description = "cut a release", .dir = "/p/release", .body = "b" },
    };

    const text = try helpText(arena_state.allocator(), skills);
    for (commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command.name) != null);
    }
    for (shortcuts) |shortcut| {
        try std.testing.expect(std.mem.indexOf(u8, text, shortcut.keys) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "/release") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cut a release") != null);
}

/// Render the match list. The caller positions it above the prompt.
pub fn draw(self: *Slash, ctx: vxfw.DrawContext, widget: vxfw.Widget, width: u16) !vxfw.Surface {
    const rows: u16 = @intCast(@min(self.matches.items.len, max_rows));
    const surface = try w.surfaceClamped(ctx.arena, widget, .{ .width = width, .height = rows });
    w.fill(surface, theme.card.cell);

    for (self.matches.items[0..rows], 0..) |index, row| {
        const command = self.at(index);
        const chosen = row == self.selected;
        const y: u16 = @intCast(row);

        if (chosen) {
            w.fillRow(surface, y, 0, width, theme.on_card(theme.fg).cell);
            _ = w.writeText(surface, 0, y, "▌", theme.on_card(theme.accent).cell);
        }

        const name_style = if (chosen)
            theme.on_card(theme.fg).bold().cell
        else
            theme.on_card(theme.fg_muted).cell;

        var x = w.writeText(surface, 2, y, "/", theme.on_card(theme.fg_dim).cell);
        x = w.writeText(surface, x, y, command.name, name_style);
        if (command.argument.len > 0) {
            x = w.writeText(surface, x + 1, y, command.argument, theme.on_card(theme.fg_dim).cell);
        }

        const column = 24;
        if (width > column + 8) {
            _ = w.writeText(surface, column, y, command.description, theme.on_card(theme.fg_dim).cell);
        }
    }

    return surface;
}

test "the picker opens on a slash and closes once arguments start" {
    var slash: Slash = .init(std.testing.allocator);
    defer slash.deinit();

    try slash.update("", 0);
    try std.testing.expect(!slash.isOpen());

    try slash.update("/", 1);
    try std.testing.expect(slash.isOpen());
    try std.testing.expectEqual(commands.len, slash.matches.items.len);
    try std.testing.expect(!slash.selectedCommand().?.is_skill);

    try slash.update("/co", 3);
    try std.testing.expectEqualStrings("compact", slash.selectedCommand().?.name);

    try slash.update("/rename my session", 18);
    try std.testing.expect(!slash.isOpen());

    try slash.update("what is /compact", 16);
    try std.testing.expect(!slash.isOpen());
}

test "completion leaves room for an argument" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var slash: Slash = .init(std.testing.allocator);
    defer slash.deinit();

    try slash.update("/comp", 5);
    try std.testing.expectEqualStrings("/compact", (try slash.completion(arena)).?);

    try slash.update("/ren", 4);
    try std.testing.expectEqualStrings("/rename ", (try slash.completion(arena)).?);
}

test "a half-remembered command still lands" {
    var slash: Slash = .init(std.testing.allocator);
    defer slash.deinit();

    try slash.filter("comp");
    try std.testing.expectEqualStrings("compact", commands[slash.matches.items[0]].name);

    try slash.filter("prvdrs");
    try std.testing.expectEqualStrings("providers", commands[slash.matches.items[0]].name);

    try slash.filter("zzz");
    try std.testing.expectEqual(@as(usize, 0), slash.matches.items.len);
}

test "a skill is offered like any other command, and says it is one" {
    var slash: Slash = .init(std.testing.allocator);
    defer slash.deinit();

    slash.skills = &.{
        .{ .id = "release", .name = "Release", .description = "cut a release", .dir = "/p/release", .body = "b" },
        .{ .id = "commit-style", .name = "commit-style", .description = "", .dir = "/p/commit", .body = "b" },
    };

    try slash.update("/", 1);
    try std.testing.expectEqual(commands.len + 2, slash.matches.items.len);

    try slash.update("/rel", 4);
    const chosen = slash.selectedCommand().?;
    try std.testing.expectEqualStrings("release", chosen.name);
    try std.testing.expect(chosen.is_skill);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("/release ", (try slash.completion(arena_state.allocator())).?);

    try slash.update("/commit-style", 13);
    try std.testing.expectEqualStrings("run this skill", slash.selectedCommand().?.description);

    try slash.filter("cmtstyl");
    try std.testing.expectEqualStrings("commit-style", slash.at(slash.matches.items[0]).name);
}

test "a name a skill shares with a command still reaches the command" {
    var slash: Slash = .init(std.testing.allocator);
    defer slash.deinit();

    slash.skills = &.{
        .{ .id = "compact", .name = "compact", .description = "not the built-in", .dir = "/p/compact", .body = "b" },
    };

    try slash.update("/compact", 8);
    try std.testing.expect(!slash.selectedCommand().?.is_skill);
}
