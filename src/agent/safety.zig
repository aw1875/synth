//! Which shell commands are safe enough to run without asking.
//!
//! The approval prompt earns its keep on anything that writes, installs or
//! sends. It does not earn it on `ls`, and a prompt shown for every `grep` is a
//! prompt that gets answered without reading. So a command whose every segment
//! is a known read-only program, invoked without the flags that make it write,
//! runs on its own.
//!
//! The list is deliberately short and the parse deliberately timid: anything
//! this file cannot account for - a substitution, a redirect to a file, an
//! environment prefix, a program not on the list - is a question for the user,
//! not a judgement call made here.

const std = @import("std");
const testing = std.testing;

pub const Verdict = enum { safe, ask };

/// One command in a pipeline or `&&` chain.
pub const Segment = struct {
    /// The program, without the directory it was invoked through.
    program: []const u8,
    /// Everything after it, as written.
    arguments: []const u8,
};

/// A program that only reads, and the arguments that would make that untrue.
const Rule = struct {
    program: []const u8,
    /// Arguments that turn the program into one that writes, runs something
    /// else, or never returns. A single-letter flag (`-i`) also matches inside
    /// a cluster (`-ni`) and a value stuck to it (`-i.bak`); a longer one
    /// matches a whole argument, or the head of `--flag=value`.
    forbidden: []const []const u8 = &.{},
    /// When set, the first argument that is not a flag has to be one of these.
    /// For a program whose subcommands are the difference between reading the
    /// repository and rewriting it.
    subcommands: []const []const u8 = &.{},
};

/// Every program that runs without asking. Ordered by what it is for, since
/// that is how it gets read when someone wonders why they were prompted.
const rules: []const Rule = &.{
    .{ .program = "ls" },
    .{ .program = "cat" },
    .{ .program = "bat", .forbidden = &.{"--pager"} },
    .{ .program = "head" },
    .{ .program = "tail", .forbidden = &.{ "-f", "-F", "--follow" } },
    .{ .program = "wc" },
    .{ .program = "nl" },
    .{ .program = "tac" },
    .{ .program = "file" },
    .{ .program = "stat" },
    .{ .program = "du" },
    .{ .program = "df" },
    .{ .program = "tree" },
    .{ .program = "realpath" },
    .{ .program = "readlink" },
    .{ .program = "basename" },
    .{ .program = "dirname" },

    .{ .program = "grep" },
    .{ .program = "egrep" },
    .{ .program = "fgrep" },
    .{ .program = "rg" },
    .{ .program = "ag" },
    .{ .program = "ack" },
    .{ .program = "find", .forbidden = &.{
        "-delete", "-exec",    "-execdir", "-ok",  "-okdir",
        "-fprint", "-fprint0", "-fprintf", "-fls",
    } },
    .{ .program = "fd", .forbidden = &.{ "-x", "-X", "--exec", "--exec-batch" } },
    .{ .program = "locate" },

    .{ .program = "sed", .forbidden = &.{ "-i", "--in-place" } },
    .{ .program = "sort", .forbidden = &.{ "-o", "--output" } },
    .{ .program = "uniq" },
    .{ .program = "cut" },
    .{ .program = "tr" },
    .{ .program = "rev" },
    .{ .program = "fold" },
    .{ .program = "column" },
    .{ .program = "comm" },
    .{ .program = "join" },
    .{ .program = "paste" },
    .{ .program = "diff" },
    .{ .program = "cmp" },
    .{ .program = "jq" },
    .{ .program = "echo" },
    .{ .program = "printf" },
    .{ .program = "seq" },

    .{ .program = "pwd" },
    .{ .program = "date" },
    .{ .program = "whoami" },
    .{ .program = "hostname" },
    .{ .program = "uname" },
    .{ .program = "which" },
    .{ .program = "true" },
    .{ .program = "false" },
    .{ .program = "md5sum" },
    .{ .program = "sha1sum" },
    .{ .program = "sha256sum" },
    .{ .program = "cksum" },

    .{
        // `-c` and `-C` can hand git a pager or a diff filter to run, which is
        // any command at all.
        .program = "git",
        .forbidden = &.{ "-c", "-C", "--exec-path", "--upload-pack", "--receive-pack" },
        .subcommands = &.{
            "status",    "log",         "diff",     "show",
            "blame",     "ls-files",    "ls-tree",  "rev-parse",
            "describe",  "shortlog",    "cat-file", "grep",
            "diff-tree", "whatchanged",
        },
    },
};

/// Whether `command` may run without asking.
pub fn verdict(arena: std.mem.Allocator, command: []const u8) Verdict {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return .ask;

    const parts = segments(arena, trimmed) catch return .ask;
    const found = parts orelse return .ask;
    for (found) |part| {
        if (!isSafeSegment(part)) return .ask;
    }
    return .safe;
}

fn isSafeSegment(part: Segment) bool {
    const rule = ruleFor(part.program) orelse return false;

    var seen_subcommand = false;
    var args = arguments(part.arguments);
    while (args.next()) |raw| {
        const argument = unquote(raw);
        if (argument.len == 0) continue;

        for (rule.forbidden) |bad| {
            if (argumentMatches(argument, bad)) return false;
        }

        if (rule.subcommands.len > 0 and !seen_subcommand and argument[0] != '-') {
            seen_subcommand = true;
            if (!contains(rule.subcommands, argument)) return false;
        }
    }

    if (rule.subcommands.len > 0 and !seen_subcommand) return false;
    return true;
}

fn ruleFor(program: []const u8) ?Rule {
    for (rules) |rule| {
        if (std.mem.eql(u8, rule.program, program)) return rule;
    }
    return null;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

/// Whether `argument` is the forbidden flag `bad`, allowing for the shapes a
/// flag comes in.
fn argumentMatches(argument: []const u8, bad: []const u8) bool {
    if (std.mem.eql(u8, argument, bad)) return true;

    if (std.mem.startsWith(u8, bad, "--")) {
        if (std.mem.startsWith(u8, argument, bad) and
            argument.len > bad.len and argument[bad.len] == '=') return true;
        return false;
    }

    if (bad.len == 2 and bad[0] == '-') {
        if (argument.len < 2 or argument[0] != '-') return false;
        if (argument[1] == '-') return false;
        return std.mem.indexOfScalar(u8, argument[1..], bad[1]) != null;
    }

    return false;
}

/// Quotes are stripped before a flag is compared, so `sed '-i'` is the `-i` it
/// is trying not to look like.
fn unquote(argument: []const u8) []const u8 {
    var out = argument;
    while (out.len > 0 and (out[0] == '\'' or out[0] == '"')) out = out[1..];
    while (out.len > 0 and (out[out.len - 1] == '\'' or out[out.len - 1] == '"')) out = out[0 .. out.len - 1];
    return out;
}

/// Split a segment's arguments on whitespace, keeping quoted runs whole.
fn arguments(text: []const u8) ArgumentIterator {
    return .{ .text = text };
}

const ArgumentIterator = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *ArgumentIterator) ?[]const u8 {
        while (self.at < self.text.len and isSpace(self.text[self.at])) self.at += 1;
        if (self.at >= self.text.len) return null;

        const start = self.at;
        while (self.at < self.text.len and !isSpace(self.text[self.at])) {
            const c = self.text[self.at];
            if (c == '\'' or c == '"') {
                self.at = skipQuoted(self.text, self.at) orelse self.text.len;
                continue;
            }
            self.at += 1;
        }
        return self.text[start..self.at];
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// The commands `command` runs, in the order they appear, or null when the line
/// uses something this splitter will not vouch for. A `cd` is not a command
/// anything can be decided about, so it is left out rather than refused.
pub fn segments(arena: std.mem.Allocator, command: []const u8) !?[]Segment {
    var found: std.ArrayList(Segment) = .empty;

    var start: usize = 0;
    var i: usize = 0;
    while (i < command.len) {
        switch (command[i]) {
            '\'', '"' => i = skipQuoted(command, i) orelse return null,
            '`' => return null,
            '$' => {
                if (i + 1 < command.len and command[i + 1] == '(') return null;
                i += 1;
            },
            '(', ')' => return null,
            '<' => return null,
            '>' => i = skipRedirect(command, i) orelse return null,
            '&' => {
                if (i + 1 >= command.len or command[i + 1] != '&') return null;
                if (!try append(arena, &found, command[start..i])) return null;
                i += 2;
                start = i;
            },
            '|', ';', '\n' => {
                if (!try append(arena, &found, command[start..i])) return null;
                const double = command[i] == '|' and i + 1 < command.len and command[i + 1] == '|';
                i += if (double) 2 else 1;
                start = i;
            },
            else => i += 1,
        }
    }
    if (!try append(arena, &found, command[start..])) return null;
    return found.items;
}

/// Record what a segment runs. Returns false when the segment hides it:
/// `VAR=x cmd` runs `cmd` under a changed environment, which is the kind of
/// thing neither an allowance nor the safe list should wave through.
fn append(arena: std.mem.Allocator, found: *std.ArrayList(Segment), segment: []const u8) !bool {
    const trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return true;

    if (std.mem.eql(u8, trimmed, "cd")) return true;
    if (std.mem.startsWith(u8, trimmed, "cd ") or std.mem.startsWith(u8, trimmed, "cd\t")) return true;

    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const first = trimmed[0..end];
    if (first.len == 0) return false;
    if (std.mem.indexOfScalar(u8, first, '=') != null) return false;

    const slash = std.mem.lastIndexOfScalar(u8, first, '/');
    const base = if (slash) |at| first[at + 1 ..] else first;
    if (base.len == 0) return false;

    try found.append(arena, .{ .program = base, .arguments = trimmed[end..] });
    return true;
}

/// Step over a quoted run, returning the index just past the closing quote.
/// Null for an unterminated quote, or for a substitution inside a double-quoted
/// string, which the caller treats as un-splittable.
fn skipQuoted(command: []const u8, at: usize) ?usize {
    const quote = command[at];
    var i = at + 1;
    while (i < command.len) : (i += 1) {
        if (quote == '"') {
            if (command[i] == '\\') {
                i += 1;
                continue;
            }
            if (command[i] == '`') return null;
            if (command[i] == '$' and i + 1 < command.len and command[i + 1] == '(') return null;
        }
        if (command[i] == quote) return i + 1;
    }
    return null;
}

/// Step over a redirect, returning the index just past it. Only `/dev/null` and
/// the descriptor forms are allowed: a redirect anywhere else writes a file.
fn skipRedirect(command: []const u8, at: usize) ?usize {
    var i = at + 1;
    if (i < command.len and command[i] == '>') i += 1;

    if (i < command.len and command[i] == '&') {
        i += 1;
        while (i < command.len and (std.ascii.isDigit(command[i]) or command[i] == '-')) i += 1;
        return i;
    }

    while (i < command.len and (command[i] == ' ' or command[i] == '\t')) i += 1;
    const end = std.mem.indexOfAnyPos(u8, command, i, " \t|&;<>\n") orelse command.len;
    if (std.mem.eql(u8, command[i..end], "/dev/null")) return end;
    return null;
}

fn check(command: []const u8) Verdict {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    return verdict(arena_state.allocator(), command);
}

test "reading runs, writing asks" {
    try testing.expectEqual(Verdict.safe, check("ls -la src"));
    try testing.expectEqual(Verdict.safe, check("cat build.zig"));
    try testing.expectEqual(Verdict.safe, check("grep -rn ollama src"));
    try testing.expectEqual(Verdict.safe, check("wc -l src/tui/app.zig"));

    try testing.expectEqual(Verdict.ask, check("rm -rf build"));
    try testing.expectEqual(Verdict.ask, check("zig build test"));
    try testing.expectEqual(Verdict.ask, check("curl https://example.com"));
    try testing.expectEqual(Verdict.ask, check("npm install"));
    try testing.expectEqual(Verdict.ask, check(""));
}

test "a pipeline is as safe as its least safe part" {
    try testing.expectEqual(Verdict.safe, check("grep -rn foo src | head -20"));
    try testing.expectEqual(Verdict.safe, check("cat x.json | jq .name | sort | uniq -c"));
    try testing.expectEqual(Verdict.safe, check("cd src && ls"));

    try testing.expectEqual(Verdict.ask, check("find . | xargs rm"));
    try testing.expectEqual(Verdict.ask, check("ls; rm -rf /"));
    try testing.expectEqual(Verdict.ask, check("ls && sudo reboot"));
}

test "the flag is what separates reading a file from writing it" {
    try testing.expectEqual(Verdict.safe, check("sed -n '1,20p' src/tui/app.zig"));
    try testing.expectEqual(Verdict.ask, check("sed -i 's/a/b/' src/tui/app.zig"));
    try testing.expectEqual(Verdict.ask, check("sed -ni 's/a/b/' file"));
    try testing.expectEqual(Verdict.ask, check("sed -i.bak 's/a/b/' file"));
    try testing.expectEqual(Verdict.ask, check("sed '-i' 's/a/b/' file"));
    try testing.expectEqual(Verdict.ask, check("sed --in-place=.bak 's/a/b/' file"));

    try testing.expectEqual(Verdict.safe, check("find . -name '*.zig'"));
    try testing.expectEqual(Verdict.ask, check("find . -name '*.zig' -delete"));
    try testing.expectEqual(Verdict.ask, check("find . -exec rm {} ;"));

    try testing.expectEqual(Verdict.safe, check("tail -20 log.txt"));
    try testing.expectEqual(Verdict.ask, check("tail -f log.txt"));

    try testing.expectEqual(Verdict.safe, check("sort names.txt"));
    try testing.expectEqual(Verdict.ask, check("sort -o names.txt names.txt"));
}

test "git reads without asking and writes with" {
    try testing.expectEqual(Verdict.safe, check("git status --short"));
    try testing.expectEqual(Verdict.safe, check("git log --oneline -20"));
    try testing.expectEqual(Verdict.safe, check("git diff -- src/tui/input.zig"));
    try testing.expectEqual(Verdict.safe, check("git show HEAD~2"));

    try testing.expectEqual(Verdict.ask, check("git commit -m x"));
    try testing.expectEqual(Verdict.ask, check("git push"));
    try testing.expectEqual(Verdict.ask, check("git checkout master"));
    try testing.expectEqual(Verdict.ask, check("git stash"));
    try testing.expectEqual(Verdict.ask, check("git tag v1"));
    try testing.expectEqual(Verdict.ask, check("git branch -D old"));
    try testing.expectEqual(Verdict.ask, check("git -c core.pager=sh log"));
    try testing.expectEqual(Verdict.ask, check("git"));
}

test "anything the splitter cannot account for asks" {
    try testing.expectEqual(Verdict.ask, check("echo $(rm -rf /)"));
    try testing.expectEqual(Verdict.ask, check("echo `rm -rf /`"));
    try testing.expectEqual(Verdict.ask, check("cat < secrets"));
    try testing.expectEqual(Verdict.ask, check("ls > listing.txt"));
    try testing.expectEqual(Verdict.ask, check("VAR=x ls"));
    try testing.expectEqual(Verdict.ask, check("sleep 1 & rm x"));
    try testing.expectEqual(Verdict.ask, check("(ls)"));
    try testing.expectEqual(Verdict.ask, check("./configure"));
    try testing.expectEqual(Verdict.ask, check("cat 'unterminated"));

    try testing.expectEqual(Verdict.safe, check("grep -rn foo src 2>/dev/null"));
    try testing.expectEqual(Verdict.safe, check("ls nope 2>&1 | head"));

    try testing.expectEqual(Verdict.safe, check("/bin/ls -la"));
    try testing.expectEqual(Verdict.ask, check("/bin/rm -rf x"));
}
