//! What an "allow always" on a shell command stores, and what a stored one
//! covers.
//!
//! An allowance is a list of words. Ending in `*`, it covers any command that
//! starts with the words before it: `git commit *` covers `git commit -m x`
//! and not `git push`. Without the `*` the words have to match exactly. Words
//! are split the way the shell would before expansion, quoted runs whole. A
//! program named bare matches it run from any directory; one named by path
//! matches only that path.

const std = @import("std");
const testing = std.testing;

const safety = @import("safety.zig");

/// How much of a command an allowance reaches, narrowest first.
pub const Breadth = enum {
    /// This command, with these arguments.
    command,
    /// Its subcommand, with any arguments: `git commit *`. A program without
    /// one falls back to the exact command.
    subcommand,
    /// Every use of the program: `git *`.
    program,
};

/// Programs whose first argument picks what they do, so that naming it is the
/// difference between `git status` and `git push`.
const with_subcommands: []const []const u8 = &.{
    "git",       "gh",         "npm",     "pnpm",   "yarn",    "bun",     "deno",
    "npx",       "cargo",      "rustup",  "go",     "zig",     "uv",      "pip",
    "pip3",      "poetry",     "docker",  "podman", "kubectl", "helm",    "terraform",
    "make",      "just",       "nix",     "brew",   "apt",     "apt-get", "dnf",
    "systemctl", "journalctl", "dotnet",  "mvn",    "gradle",  "swift",   "mix",
    "bundle",    "rake",       "flutter", "aws",    "gcloud",  "az",
};

/// Subcommands that run something named by the next word, which is then what
/// the allowance is really about: `npm run *` would be every script.
const runners: []const []const u8 = &.{ "run", "exec", "x", "dlx" };

/// The allowance that covers `segment` at `breadth`.
pub fn pattern(arena: std.mem.Allocator, segment: safety.Segment, breadth: Breadth) ![]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    try words.append(arena, segment.program);
    var arguments = safety.arguments(segment.arguments);
    while (arguments.next()) |word| try words.append(arena, word);

    const kept: ?usize = switch (breadth) {
        .command => null,
        .subcommand => subcommandLength(words.items),
        .program => 1,
    };
    if (kept) |count| return join(arena, words.items[0..count], true);
    words.items[0] = segment.invoked;
    return join(arena, words.items, false);
}

/// How many leading words name what the command does, or null when it has no
/// subcommand to name: `git -C dir commit` starts with a flag, and is better
/// approved exactly than guessed at.
fn subcommandLength(words: []const []const u8) ?usize {
    if (!contains(with_subcommands, words[0])) return null;
    if (words.len < 2 or !isPlainWord(words[1])) return null;
    if (words.len > 2 and contains(runners, words[1]) and isPlainWord(words[2])) return 3;
    return 2;
}

fn isPlainWord(word: []const u8) bool {
    if (word.len == 0 or !std.ascii.isAlphabetic(word[0])) return false;
    for (word) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') return false;
    }
    return true;
}

/// A word of the command that is itself `*`, or starts with a backslash, is
/// stored behind one more backslash, so the trailing wildcard is the only bare
/// `*` an allowance can hold.
fn join(arena: std.mem.Allocator, words: []const []const u8, wildcard: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, i| {
        if (i > 0) try out.append(arena, ' ');
        if (std.mem.eql(u8, word, "*") or std.mem.startsWith(u8, word, "\\")) try out.append(arena, '\\');
        try out.appendSlice(arena, word);
    }
    if (wildcard) try out.appendSlice(arena, " *");
    return out.toOwnedSlice(arena);
}

/// Whether the allowance `allowed` covers `segment`.
pub fn covers(allowed: []const u8, segment: safety.Segment) bool {
    if (std.mem.eql(u8, allowed, "*")) return true;

    var wanted = safety.arguments(allowed);
    const program = unescape(wanted.next() orelse return false);
    const named = if (std.mem.indexOfScalar(u8, program, '/') == null) segment.program else segment.invoked;
    if (!std.mem.eql(u8, program, named)) return false;

    var given = safety.arguments(segment.arguments);
    while (wanted.next()) |word| {
        if (std.mem.eql(u8, word, "*")) return wanted.next() == null;
        const actual = given.next() orelse return false;
        if (!std.mem.eql(u8, unescape(word), actual)) return false;
    }
    return given.next() == null;
}

fn unescape(word: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, word, "\\")) word[1..] else word;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn only(arena: std.mem.Allocator, command: []const u8) !safety.Segment {
    const found = (try safety.segments(arena, command)).?;
    try testing.expectEqual(@as(usize, 1), found.len);
    return found[0];
}

fn expectPattern(command: []const u8, breadth: Breadth, wanted: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(wanted, try pattern(arena, try only(arena, command), breadth));
}

fn expectCovers(allowed: []const u8, command: []const u8, wanted: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(wanted, covers(allowed, try only(arena, command)));
}

test "a subcommand is what an allowance names by default" {
    try expectPattern("git commit -m \"x y\"", .subcommand, "git commit *");
    try expectPattern("zig build test", .subcommand, "zig build *");
    try expectPattern("git status", .subcommand, "git status *");
    try expectPattern("npm run build", .subcommand, "npm run build *");
    try expectPattern("docker exec web ls", .subcommand, "docker exec web *");
    try expectPattern("cargo run --release", .subcommand, "cargo run *");
    try expectPattern("/usr/bin/git push", .subcommand, "git push *");
}

test "a command with no subcommand to name is allowed exactly" {
    try expectPattern("rm -rf build", .subcommand, "rm -rf build");
    try expectPattern("./deploy.sh prod", .subcommand, "./deploy.sh prod");
    try expectPattern("make", .subcommand, "make");
    try expectPattern("git -C src commit", .subcommand, "git -C src commit");
    try expectPattern("npm ./local", .subcommand, "npm ./local");
}

test "breadth reaches from the exact command to the whole program" {
    try expectPattern("git commit -m x", .command, "git commit -m x");
    try expectPattern("git commit -m x", .program, "git *");
    try expectPattern("rm -rf build", .program, "rm *");
    try expectPattern("/bin/rm -rf build", .command, "/bin/rm -rf build");
    try expectPattern("/bin/rm -rf build", .program, "rm *");
    try expectPattern("make", .program, "make *");
}

test "a literal star in the command is not a wildcard" {
    try expectPattern("rm *", .command, "rm \\*");
    try expectCovers("rm \\*", "rm *", true);
    try expectCovers("rm \\*", "rm -rf /", false);
    try expectPattern("echo \\n", .command, "echo \\\\n");
    try expectCovers("echo \\\\n", "echo \\n", true);
}

test "an allowance covers what starts with its words, and nothing else" {
    try expectCovers("git commit *", "git commit -m x", true);
    try expectCovers("git commit *", "git commit", true);
    try expectCovers("git commit *", "/usr/bin/git commit --amend", true);
    try expectCovers("git commit *", "git push --force", false);
    try expectCovers("git commit *", "git commitx", false);
    try expectCovers("git commit *", "git -c x commit", false);
    try expectCovers("git commit *", "gitk commit", false);

    try expectCovers("rm -rf build", "rm -rf build", true);
    try expectCovers("rm -rf build", "rm  -rf   build", true);
    try expectCovers("rm -rf build", "rm -rf build /", false);
    try expectCovers("rm -rf build", "rm -rf", false);
    try expectCovers("rm -rf build", "/bin/rm -rf build", true);

    try expectCovers("./deploy.sh prod", "./deploy.sh prod", true);
    try expectCovers("./deploy.sh prod", "/tmp/deploy.sh prod", false);
    try expectCovers("./deploy.sh prod", "deploy.sh prod", false);

    try expectCovers("git commit -m \"a b\" *", "git commit -m \"a b\" --amend", true);
    try expectCovers("git commit -m \"a b\" *", "git commit -m a b", false);

    try expectCovers("*", "anything at all", true);
    try expectCovers("", "ls", false);
    try expectCovers("git * commit", "git x commit", false);
}

test "allowances stored before word prefixes keep covering what they did" {
    try expectCovers("git *", "git push --force", true);
    try expectCovers("find *", "find", true);
    try expectCovers("find", "find", true);
    try expectCovers("find", "find .", false);
}
