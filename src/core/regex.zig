//! A small backtracking regular expression engine.
//!
//! Enough of the syntax to be worth reaching for and no more: literals, `.`,
//! character classes, the `\d \w \s` shorthands and their negations, anchors,
//! `\b`, groups, alternation, and the `* + ? {n,m}` quantifiers with lazy
//! variants. No captures, no backreferences, no lookaround.
//!
//! The pattern comes from a model, so neither a bad pattern nor a pathological
//! one may take the process with it: compilation returns an error, and matching
//! runs against a step budget and a bounded backtrack stack. Exhausting either
//! reports "no match" rather than hanging, which is the one place this trades
//! correctness for a guarantee.

const std = @import("std");
const testing = std.testing;

pub const Options = struct {
    /// Compare letters without regard to case, in classes as well as literals.
    ignore_case: bool = false,
};

pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Error = error{
    UnbalancedParenthesis,
    UnterminatedClass,
    TrailingBackslash,
    NothingToRepeat,
    BadRepeat,
    PatternTooComplex,
} || std.mem.Allocator.Error;

/// Ceiling on compiled instructions. A pattern that needs more than this has
/// almost certainly asked for `a{1000}{1000}` rather than anything useful.
const max_program = 8192;
/// Ceiling on a counted repetition, before it is expanded into copies.
const max_repeat = 1000;
/// Backtrack points held at once. One is pushed per alternative still open, so
/// this is the real limit on how far a greedy quantifier can run.
const max_backtrack = 16 * 1024;
/// Instructions executed per `find` call, across every starting position.
const max_steps = 1_000_000;

const unbounded: u32 = std.math.maxInt(u32);

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    program: []const Inst,
    classes: []const Class,
    /// Scratch for the matcher, sized once at compile time rather than per
    /// call: a grep runs one of these over every line in the project.
    stack: []Frame,
    ignore_case: bool,

    const Frame = struct { pc: usize, sp: usize };

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    /// The leftmost match at or after `from`, or null. Preferring the earliest
    /// start over the longest overall match is what every line-oriented search
    /// tool does.
    pub fn find(self: *Regex, input: []const u8, from: usize) ?Match {
        var budget: usize = max_steps;
        var start = from;
        while (start <= input.len) : (start += 1) {
            if (self.run(input, start, &budget)) |end| {
                return .{ .start = start, .end = end };
            }
            if (budget == 0) return null;
        }
        return null;
    }

    pub fn matches(self: *Regex, input: []const u8) bool {
        return self.find(input, 0) != null;
    }

    /// Run the program from `start`, returning where the match ended.
    ///
    /// Iterative rather than recursive: a greedy quantifier over a long line
    /// pushes one backtrack point per character, and a recursive matcher would
    /// put that on the call stack.
    fn run(self: *Regex, input: []const u8, start: usize, budget: *usize) ?usize {
        var depth: usize = 0;
        var pc: usize = 0;
        var sp: usize = start;

        while (true) {
            if (budget.* == 0) return null;
            budget.* -= 1;

            const advance: bool = switch (self.program[pc]) {
                .match => return sp,
                .jmp => |target| {
                    pc = target;
                    continue;
                },
                .split => |branch| {
                    if (depth == self.stack.len) return null;
                    self.stack[depth] = .{ .pc = branch.second, .sp = sp };
                    depth += 1;
                    pc = branch.first;
                    continue;
                },
                .start => sp == 0,
                .end => sp == input.len,
                .word_boundary => |wanted| atBoundary(input, sp) == wanted,
                .char => |want| sp < input.len and self.equal(input[sp], want),
                .any => sp < input.len and input[sp] != '\n',
                .class => |index| sp < input.len and self.inClass(index, input[sp]),
            };

            if (advance) {
                switch (self.program[pc]) {
                    .char, .any, .class => sp += 1,
                    else => {},
                }
                pc += 1;
                continue;
            }

            if (depth == 0) return null;
            depth -= 1;
            pc = self.stack[depth].pc;
            sp = self.stack[depth].sp;
        }
    }

    fn equal(self: *const Regex, a: u8, b: u8) bool {
        if (a == b) return true;
        if (!self.ignore_case) return false;
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }

    fn inClass(self: *const Regex, index: usize, c: u8) bool {
        const class = self.classes[index];
        var hit = class.contains(c);
        if (!hit and self.ignore_case) {
            const swapped = if (std.ascii.isUpper(c))
                std.ascii.toLower(c)
            else if (std.ascii.isLower(c))
                std.ascii.toUpper(c)
            else
                c;
            hit = swapped != c and class.contains(swapped);
        }
        return hit != class.negated;
    }
};

/// Whether position `at` sits on a word boundary, which is what `\b` asserts.
fn atBoundary(input: []const u8, at: usize) bool {
    const before = at > 0 and isWord(input[at - 1]);
    const after = at < input.len and isWord(input[at]);
    return before != after;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Range = struct { lo: u8, hi: u8 };

const Class = struct {
    negated: bool,
    ranges: []const Range,

    /// Membership before negation, which the caller applies: `[^a]` still must
    /// not match a letter that only differs by case.
    fn contains(self: Class, c: u8) bool {
        for (self.ranges) |range| {
            if (c >= range.lo and c <= range.hi) return true;
        }
        return false;
    }
};

const Inst = union(enum) {
    char: u8,
    any,
    class: usize,
    /// Try `first`; on failure resume at `second`.
    split: struct { first: usize, second: usize },
    jmp: usize,
    start,
    end,
    /// True for `\b`, false for `\B`.
    word_boundary: bool,
    match,
};

const Node = union(enum) {
    empty,
    literal: u8,
    any,
    class: usize,
    seq: []const Node,
    alt: []const Node,
    repeat: Repeat,
    start,
    end,
    word_boundary: bool,

    const Repeat = struct {
        child: *const Node,
        min: u32,
        max: u32,
        greedy: bool,
    };
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, options: Options) Error!Regex {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const scratch = arena.allocator();

    var classes: std.ArrayList(Class) = .empty;
    var parser: Parser = .{ .arena = scratch, .pattern = pattern, .classes = &classes };

    const root = try parser.parseAlternation();
    if (parser.at < pattern.len) return error.UnbalancedParenthesis;

    var program: std.ArrayList(Inst) = .empty;
    var emitter: Emitter = .{ .arena = scratch, .program = &program };
    try emitter.emit(root);
    _ = try emitter.add(.match);

    // Allocated before the struct literal, not inside it: fields evaluate in
    // order, so a copy of the arena taken first would not know about anything
    // allocated into it afterwards, and that memory would never be freed.
    const code = try program.toOwnedSlice(scratch);
    const table = try classes.toOwnedSlice(scratch);
    const stack = try scratch.alloc(Regex.Frame, max_backtrack);

    return .{
        .arena = arena,
        .program = code,
        .classes = table,
        .stack = stack,
        .ignore_case = options.ignore_case,
    };
}

const Parser = struct {
    arena: std.mem.Allocator,
    pattern: []const u8,
    at: usize = 0,
    classes: *std.ArrayList(Class),

    fn parseAlternation(self: *Parser) Error!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(self.arena, try self.parseSequence());
        while (self.eat('|')) {
            try branches.append(self.arena, try self.parseSequence());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = try branches.toOwnedSlice(self.arena) };
    }

    fn parseSequence(self: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (self.at < self.pattern.len) {
            const c = self.pattern[self.at];
            if (c == '|' or c == ')') break;
            try items.append(self.arena, try self.parseQuantified());
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .seq = try items.toOwnedSlice(self.arena) };
    }

    fn parseQuantified(self: *Parser) Error!Node {
        var node = try self.parseAtom();

        while (self.at < self.pattern.len) {
            var min: u32 = 0;
            var max: u32 = 0;
            switch (self.pattern[self.at]) {
                '*' => {
                    min = 0;
                    max = unbounded;
                    self.at += 1;
                },
                '+' => {
                    min = 1;
                    max = unbounded;
                    self.at += 1;
                },
                '?' => {
                    min = 0;
                    max = 1;
                    self.at += 1;
                },
                '{' => {
                    const counted = try self.parseCounted() orelse break;
                    min = counted.min;
                    max = counted.max;
                },
                else => break,
            }

            const greedy = !self.eat('?');
            const child = try self.arena.create(Node);
            child.* = node;
            node = .{ .repeat = .{ .child = child, .min = min, .max = max, .greedy = greedy } };
        }

        return node;
    }

    /// `{n}`, `{n,}` or `{n,m}`. Null when the brace does not open a repeat, in
    /// which case it stays a literal: `{` is common enough in code that a
    /// pattern like `fn foo() {` should not be an error.
    fn parseCounted(self: *Parser) Error!?struct { min: u32, max: u32 } {
        const close = std.mem.indexOfScalarPos(u8, self.pattern, self.at, '}') orelse return null;
        const body = self.pattern[self.at + 1 .. close];
        if (body.len == 0) return null;

        const comma = std.mem.indexOfScalar(u8, body, ',');
        const min_text = if (comma) |c| body[0..c] else body;
        const max_text = if (comma) |c| body[c + 1 ..] else body;

        const min = std.fmt.parseInt(u32, min_text, 10) catch return null;
        const max = if (max_text.len == 0)
            unbounded
        else
            std.fmt.parseInt(u32, max_text, 10) catch return null;

        if (min > max) return error.BadRepeat;
        if (min > max_repeat or (max != unbounded and max > max_repeat)) return error.BadRepeat;

        self.at = close + 1;
        return .{ .min = min, .max = max };
    }

    fn parseAtom(self: *Parser) Error!Node {
        const c = self.pattern[self.at];
        switch (c) {
            '(' => {
                self.at += 1;
                // `(?:` and `(?i` are accepted and ignored: nothing here
                // captures, so a non-capturing group is every group.
                if (self.at + 1 < self.pattern.len and self.pattern[self.at] == '?') {
                    self.at += 1;
                    if (self.pattern[self.at] == ':') self.at += 1;
                }
                const inner = try self.parseAlternation();
                if (!self.eat(')')) return error.UnbalancedParenthesis;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.at += 1;
                return .any;
            },
            '^' => {
                self.at += 1;
                return .start;
            },
            '$' => {
                self.at += 1;
                return .end;
            },
            '\\' => return self.parseEscape(),
            '*', '+', '?' => return error.NothingToRepeat,
            else => {
                self.at += 1;
                return .{ .literal = c };
            },
        }
    }

    fn parseEscape(self: *Parser) Error!Node {
        self.at += 1;
        if (self.at >= self.pattern.len) return error.TrailingBackslash;

        const c = self.pattern[self.at];
        self.at += 1;

        return switch (c) {
            'd' => try self.shorthand(digits, false),
            'D' => try self.shorthand(digits, true),
            'w' => try self.shorthand(word, false),
            'W' => try self.shorthand(word, true),
            's' => try self.shorthand(space, false),
            'S' => try self.shorthand(space, true),
            'b' => .{ .word_boundary = true },
            'B' => .{ .word_boundary = false },
            'n' => .{ .literal = '\n' },
            't' => .{ .literal = '\t' },
            'r' => .{ .literal = '\r' },
            '0' => .{ .literal = 0 },
            else => .{ .literal = c },
        };
    }

    fn shorthand(self: *Parser, ranges: []const Range, negated: bool) Error!Node {
        try self.classes.append(self.arena, .{ .negated = negated, .ranges = ranges });
        return .{ .class = self.classes.items.len - 1 };
    }

    fn parseClass(self: *Parser) Error!Node {
        self.at += 1;
        const negated = self.eat('^');

        var ranges: std.ArrayList(Range) = .empty;
        var first = true;

        while (true) {
            if (self.at >= self.pattern.len) return error.UnterminatedClass;
            const c = self.pattern[self.at];

            // A `]` straight after `[` or `[^` is the character, not the end.
            if (c == ']' and !first) {
                self.at += 1;
                break;
            }
            first = false;

            if (c == '\\') {
                self.at += 1;
                if (self.at >= self.pattern.len) return error.TrailingBackslash;
                const escaped = self.pattern[self.at];
                self.at += 1;
                switch (escaped) {
                    'd' => try ranges.appendSlice(self.arena, digits),
                    'w' => try ranges.appendSlice(self.arena, word),
                    's' => try ranges.appendSlice(self.arena, space),
                    'n' => try ranges.append(self.arena, .{ .lo = '\n', .hi = '\n' }),
                    't' => try ranges.append(self.arena, .{ .lo = '\t', .hi = '\t' }),
                    'r' => try ranges.append(self.arena, .{ .lo = '\r', .hi = '\r' }),
                    else => try ranges.append(self.arena, .{ .lo = escaped, .hi = escaped }),
                }
                continue;
            }

            self.at += 1;

            const dash = self.at + 1 < self.pattern.len and
                self.pattern[self.at] == '-' and
                self.pattern[self.at + 1] != ']';
            if (dash) {
                const hi = self.pattern[self.at + 1];
                self.at += 2;
                try ranges.append(self.arena, .{ .lo = c, .hi = @max(c, hi) });
            } else {
                try ranges.append(self.arena, .{ .lo = c, .hi = c });
            }
        }

        try self.classes.append(self.arena, .{
            .negated = negated,
            .ranges = try ranges.toOwnedSlice(self.arena),
        });
        return .{ .class = self.classes.items.len - 1 };
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.at < self.pattern.len and self.pattern[self.at] == c) {
            self.at += 1;
            return true;
        }
        return false;
    }
};

const digits: []const Range = &.{.{ .lo = '0', .hi = '9' }};
const word: []const Range = &.{
    .{ .lo = 'a', .hi = 'z' },
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = '0', .hi = '9' },
    .{ .lo = '_', .hi = '_' },
};
const space: []const Range = &.{
    .{ .lo = ' ', .hi = ' ' },
    .{ .lo = '\t', .hi = '\t' },
    .{ .lo = '\n', .hi = '\n' },
    .{ .lo = '\r', .hi = '\r' },
    .{ .lo = 11, .hi = 12 },
};

const Emitter = struct {
    arena: std.mem.Allocator,
    program: *std.ArrayList(Inst),

    fn add(self: *Emitter, inst: Inst) Error!usize {
        if (self.program.items.len >= max_program) return error.PatternTooComplex;
        try self.program.append(self.arena, inst);
        return self.program.items.len - 1;
    }

    fn here(self: *Emitter) usize {
        return self.program.items.len;
    }

    fn emit(self: *Emitter, node: Node) Error!void {
        switch (node) {
            .empty => {},
            .literal => |c| _ = try self.add(.{ .char = c }),
            .any => _ = try self.add(.any),
            .class => |index| _ = try self.add(.{ .class = index }),
            .start => _ = try self.add(.start),
            .end => _ = try self.add(.end),
            .word_boundary => |wanted| _ = try self.add(.{ .word_boundary = wanted }),
            .seq => |items| for (items) |item| try self.emit(item),
            .alt => |branches| try self.emitAlternation(branches),
            .repeat => |repeat| try self.emitRepeat(repeat),
        }
    }

    fn emitAlternation(self: *Emitter, branches: []const Node) Error!void {
        var exits: std.ArrayList(usize) = .empty;

        for (branches, 0..) |branch, index| {
            if (index + 1 == branches.len) {
                try self.emit(branch);
                break;
            }
            const split = try self.add(.{ .split = .{ .first = 0, .second = 0 } });
            self.program.items[split].split.first = self.here();
            try self.emit(branch);
            try exits.append(self.arena, try self.add(.{ .jmp = 0 }));
            self.program.items[split].split.second = self.here();
        }

        for (exits.items) |at| self.program.items[at].jmp = self.here();
    }

    /// Counted repetition is expanded into copies, which is why `max_repeat`
    /// and `max_program` both exist: `(ab){500}` is a thousand instructions.
    fn emitRepeat(self: *Emitter, repeat: Node.Repeat) Error!void {
        var count: u32 = 0;
        while (count < repeat.min) : (count += 1) try self.emit(repeat.child.*);

        if (repeat.max == unbounded) {
            const loop = self.here();
            const split = try self.add(.{ .split = .{ .first = 0, .second = 0 } });
            const body = self.here();
            try self.emit(repeat.child.*);
            _ = try self.add(.{ .jmp = loop });
            self.patch(split, body, self.here(), repeat.greedy);
            return;
        }

        var exits: std.ArrayList(usize) = .empty;
        while (count < repeat.max) : (count += 1) {
            const split = try self.add(.{ .split = .{ .first = 0, .second = 0 } });
            try exits.append(self.arena, split);
            const body = self.here();
            try self.emit(repeat.child.*);
            self.patch(split, body, 0, repeat.greedy);
        }

        const end = self.here();
        for (exits.items) |at| {
            if (repeat.greedy) {
                self.program.items[at].split.second = end;
            } else {
                self.program.items[at].split.first = end;
            }
        }
    }

    /// Point a split at the body and at what follows it. Greedy tries the body
    /// first, lazy tries the way out first; that is the whole difference.
    fn patch(self: *Emitter, split: usize, body: usize, out: usize, greedy: bool) void {
        const inst = &self.program.items[split];
        if (greedy) {
            inst.split = .{ .first = body, .second = out };
        } else {
            inst.split = .{ .first = out, .second = body };
        }
    }
};

fn expectFind(pattern: []const u8, input: []const u8, want: ?[]const u8) !void {
    var re = try compile(testing.allocator, pattern, .{});
    defer re.deinit();

    const found = re.find(input, 0);
    if (want) |text| {
        try testing.expect(found != null);
        try testing.expectEqualStrings(text, input[found.?.start..found.?.end]);
    } else {
        try testing.expect(found == null);
    }
}

test "literals, dots and classes" {
    try expectFind("abc", "xxabcxx", "abc");
    try expectFind("abc", "xxabxx", null);
    try expectFind("a.c", "abc", "abc");
    try expectFind("a.c", "a\nc", null);
    try expectFind("[abc]+", "xxbcabxx", "bcab");
    try expectFind("[^abc]+", "aaxyzbb", "xyz");
    try expectFind("[a-f0-9]+", "zz3faz", "3fa");
    try expectFind("[]]", "]", "]");
    try expectFind("[a-]", "-", "-");
}

test "quantifiers, greedy and lazy" {
    try expectFind("a*", "aaa", "aaa");
    try expectFind("a*", "bbb", "");
    try expectFind("a+", "bbb", null);
    try expectFind("ab?c", "ac", "ac");
    try expectFind("<.*>", "<a><b>", "<a><b>");
    try expectFind("<.*?>", "<a><b>", "<a>");
    try expectFind("a{2}", "aaa", "aa");
    try expectFind("a{2,}", "aaaa", "aaaa");
    try expectFind("a{2,3}", "aaaa", "aaa");
    try expectFind("a{4}", "aaa", null);
}

test "groups, alternation and anchors" {
    try expectFind("(ab)+", "ababx", "abab");
    try expectFind("(?:foo|bar)baz", "xxbarbaz", "barbaz");
    try expectFind("cat|dog|bird", "a dog here", "dog");
    try expectFind("^abc", "abc", "abc");
    try expectFind("^abc", "xabc", null);
    try expectFind("abc$", "xxabc", "abc");
    try expectFind("abc$", "abcx", null);
    try expectFind("^$", "", "");
}

test "shorthands and word boundaries" {
    try expectFind("\\d+", "abc123def", "123");
    try expectFind("\\w+", "  hello_1 ", "hello_1");
    try expectFind("\\s+", "a \t b", " \t ");
    try expectFind("\\D+", "12ab34", "ab");
    try expectFind("\\bcat\\b", "the cat sat", "cat");
    try expectFind("\\bcat\\b", "concatenate", null);
    try expectFind("[\\d.]+", "v1.2.3!", "1.2.3");
}

test "a literal brace is not a repeat" {
    try expectFind("fn foo\\(\\) \\{", "fn foo() {", "fn foo() {");
    try expectFind("a{,3}", "a{,3}", "a{,3}");
    try expectFind("a{x}", "a{x}", "a{x}");
}

test "case is folded on request, in classes too" {
    var re = try compile(testing.allocator, "[a-z]+Bar", .{ .ignore_case = true });
    defer re.deinit();

    try testing.expect(re.matches("FOOBAR"));
    try testing.expect(re.matches("fooBAR"));
    try testing.expect(!re.matches("123bar"));
}

test "a search resumes where the last match ended" {
    var re = try compile(testing.allocator, "\\d+", .{});
    defer re.deinit();

    const input = "a1bb22ccc333";
    const first = re.find(input, 0).?;
    try testing.expectEqualStrings("1", input[first.start..first.end]);

    const second = re.find(input, first.end).?;
    try testing.expectEqualStrings("22", input[second.start..second.end]);

    const third = re.find(input, second.end).?;
    try testing.expectEqualStrings("333", input[third.start..third.end]);

    try testing.expect(re.find(input, third.end) == null);
}

test "a bad pattern is an error, not a crash" {
    const cases: []const []const u8 = &.{ "(abc", "abc)", "[abc", "a\\", "*abc", "a{3,2}", "a{2000}" };
    for (cases) |pattern| {
        try testing.expect(std.meta.isError(compile(testing.allocator, pattern, .{})));
    }
}

test "a pathological pattern gives up rather than hanging" {
    var re = try compile(testing.allocator, "(a+)+b", .{});
    defer re.deinit();

    // The classic blow-up: every split of the a's has to be tried before the
    // missing `b` is admitted. The budget stops it, and stopping reads as no
    // match, which is the documented trade.
    try testing.expect(!re.matches("a" ** 40));
    try testing.expect(re.matches("aaab"));
}
