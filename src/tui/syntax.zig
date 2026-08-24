//! Syntax highlighting for fenced code blocks.

const std = @import("std");

const vaxis = @import("vaxis");
const Cell = vaxis.Cell;

const theme = @import("theme.zig");

/// A run of characters sharing one style.
pub const Span = struct {
    text: []const u8,
    kind: Kind,
};

pub const Kind = enum {
    plain,
    comment,
    string,
    number,
    keyword,
    /// A built-in type or function: `usize`, `println!`, `len`.
    builtin,
    /// An identifier immediately followed by `(`.
    call,

    /// The style for this kind, over `base` so the code panel's background
    /// carries through.
    pub fn style(self: Kind, base: Cell.Style) Cell.Style {
        var out = base;
        switch (self) {
            .plain => return out,
            .comment => {
                out.fg = theme.fg_dim;
                out.italic = true;
            },
            .string => out.fg = theme.success,
            .number => out.fg = theme.warning,
            .keyword => out.fg = theme.accent,
            .builtin => out.fg = theme.accent_alt,
            .call => out.fg = theme.accent_alt,
        }
        return out;
    }
};

/// What carries across lines. A block comment opened on one line colours the
/// lines under it, so the caller keeps one of these for the whole fence.
pub const State = struct {
    in_block_comment: bool = false,
};

/// Split `line` into styled spans. Spans borrow from `line`; the slice itself
/// is allocated in `arena`. `state` is advanced, so lines must be highlighted
/// in order.
pub fn highlight(
    arena: std.mem.Allocator,
    language: ?Language,
    line: []const u8,
    state: *State,
) ![]const Span {
    const lang = language orelse return one(arena, line, .plain);
    if (line.len == 0) return &.{};

    var spans: std.ArrayList(Span) = .empty;
    var plain_start: usize = 0;
    var i: usize = 0;

    const flush = struct {
        fn call(a: std.mem.Allocator, list: *std.ArrayList(Span), text: []const u8, from: usize, at: usize) !void {
            if (at > from) try list.append(a, .{ .text = text[from..at], .kind = .plain });
        }
    }.call;

    if (state.in_block_comment) {
        const block = lang.block.?;
        if (std.mem.indexOf(u8, line, block.close)) |at| {
            const end = at + block.close.len;
            try spans.append(arena, .{ .text = line[0..end], .kind = .comment });
            state.in_block_comment = false;
            i = end;
            plain_start = end;
        } else {
            return one(arena, line, .comment);
        }
    }

    while (i < line.len) {
        const rest = line[i..];

        if (lang.lineCommentAt(rest)) {
            try flush(arena, &spans, line, plain_start, i);
            try spans.append(arena, .{ .text = rest, .kind = .comment });
            return spans.toOwnedSlice(arena);
        }

        if (lang.block) |block| {
            if (std.mem.startsWith(u8, rest, block.open)) {
                try flush(arena, &spans, line, plain_start, i);
                const from = i + block.open.len;
                if (std.mem.indexOfPos(u8, line, from, block.close)) |at| {
                    const end = at + block.close.len;
                    try spans.append(arena, .{ .text = line[i..end], .kind = .comment });
                    i = end;
                } else {
                    try spans.append(arena, .{ .text = rest, .kind = .comment });
                    state.in_block_comment = true;
                    return spans.toOwnedSlice(arena);
                }
                plain_start = i;
                continue;
            }
        }

        if (std.mem.indexOfScalar(u8, lang.quotes, line[i]) != null) {
            try flush(arena, &spans, line, plain_start, i);
            const end = stringEnd(line, i, lang.escapes);
            try spans.append(arena, .{ .text = line[i..end], .kind = .string });
            i = end;
            plain_start = i;
            continue;
        }

        if (std.ascii.isDigit(line[i]) and !isWordByte(prevByte(line, i))) {
            try flush(arena, &spans, line, plain_start, i);
            const end = numberEnd(line, i);
            try spans.append(arena, .{ .text = line[i..end], .kind = .number });
            i = end;
            plain_start = i;
            continue;
        }

        if (isWordStart(line[i]) or (lang.at_builtins and line[i] == '@')) {
            const end = wordEnd(line, i, lang);
            const word = line[i..end];
            const kind = lang.classify(word, nextMeaningful(line, end));
            if (kind != .plain) {
                try flush(arena, &spans, line, plain_start, i);
                try spans.append(arena, .{ .text = word, .kind = kind });
                plain_start = end;
            }
            i = end;
            continue;
        }

        i += 1;
    }

    try flush(arena, &spans, line, plain_start, line.len);
    return spans.toOwnedSlice(arena);
}

fn one(arena: std.mem.Allocator, text: []const u8, kind: Kind) ![]const Span {
    const spans = try arena.alloc(Span, 1);
    spans[0] = .{ .text = text, .kind = kind };
    return spans;
}

/// Index just past the closing quote, or the end of the line for a string that
/// runs off it - which is what a wrapped or truncated line looks like.
fn stringEnd(line: []const u8, at: usize, escapes: bool) usize {
    const quote = line[at];
    var i = at + 1;
    while (i < line.len) : (i += 1) {
        if (escapes and line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) return i + 1;
    }
    return line.len;
}

/// Index just past a numeric literal. Deliberately loose: `0x1f`, `1_000`,
/// `1.5e-3` and `10u8` all read as one number, and nothing here has to be a
/// valid literal in the language it came from.
fn numberEnd(line: []const u8, at: usize) usize {
    var i = at;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
        if ((c == '-' or c == '+') and i > at and (line[i - 1] == 'e' or line[i - 1] == 'E')) continue;
        break;
    }
    if (i > at and line[i - 1] == '.') i -= 1;
    return i;
}

fn wordEnd(line: []const u8, at: usize, lang: Language) usize {
    var i = at;
    if (lang.at_builtins and line[i] == '@') i += 1;
    while (i < line.len and isWordByte(line[i])) i += 1;
    if (lang.bang_macros and i < line.len and line[i] == '!') i += 1;
    return i;
}

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

fn prevByte(line: []const u8, at: usize) u8 {
    return if (at == 0) 0 else line[at - 1];
}

/// The next character that is not a space, or 0 at the end of the line. Used to
/// tell a call from a plain identifier.
fn nextMeaningful(line: []const u8, at: usize) u8 {
    var i = at;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return if (i < line.len) line[i] else 0;
}

pub const Language = struct {
    /// Everything from one of these to the end of the line is a comment.
    line_comments: []const []const u8,
    block: ?struct { open: []const u8, close: []const u8 } = null,
    /// Characters that open a string.
    quotes: []const u8 = "\"'",
    /// Whether `\` escapes the next character inside a string.
    escapes: bool = true,
    keywords: []const []const u8,
    /// Built-in types and functions, coloured apart from keywords.
    builtins: []const []const u8 = &.{},
    /// `@import`, `@intCast` - Zig's builtins are part of the identifier.
    at_builtins: bool = false,
    /// `println!` - Rust macros keep their `!`.
    bang_macros: bool = false,

    fn lineCommentAt(self: Language, rest: []const u8) bool {
        for (self.line_comments) |marker| {
            if (std.mem.startsWith(u8, rest, marker)) return true;
        }
        return false;
    }

    fn classify(self: Language, word: []const u8, next: u8) Kind {
        for (self.keywords) |keyword| {
            if (std.mem.eql(u8, keyword, word)) return .keyword;
        }
        for (self.builtins) |builtin| {
            if (std.mem.eql(u8, builtin, word)) return .builtin;
        }
        if (self.at_builtins and word.len > 1 and word[0] == '@') return .builtin;
        if (self.bang_macros and word.len > 1 and word[word.len - 1] == '!') return .builtin;
        if (next == '(') return .call;
        return .plain;
    }
};

const c_like_keywords: []const []const u8 = &.{
    "if",    "else",     "for",    "while",  "do",     "switch", "case",     "default",
    "break", "continue", "return", "goto",   "struct", "union",  "enum",     "typedef",
    "const", "static",   "extern", "inline", "sizeof", "void",   "unsigned", "signed",
};

const c_types: []const []const u8 = &.{
    "int", "char", "long", "short", "float", "double", "bool", "size_t", "uint8_t", "uint32_t", "uint64_t", "int32_t", "int64_t", "NULL", "true", "false",
};

const zig_language: Language = .{
    .line_comments = &.{"//"},
    .keywords = &.{
        "const",   "var",    "fn",          "pub",      "return",    "if",             "else",    "while",
        "for",     "switch", "break",       "continue", "defer",     "errdefer",       "try",     "catch",
        "struct",  "enum",   "union",       "error",    "test",      "comptime",       "inline",  "export",
        "extern",  "orelse", "unreachable", "and",      "or",        "usingnamespace", "align",   "threadlocal",
        "noalias", "asm",    "suspend",     "resume",   "nosuspend", "opaque",         "anytype",
    },
    .builtins = &.{
        "u8",   "u16",       "u32",  "u64",   "usize",     "i8",       "i16",  "i32",
        "i64",  "isize",     "f32",  "f64",   "bool",      "void",     "type", "anyerror",
        "null", "undefined", "true", "false", "anyopaque", "noreturn",
    },
    .at_builtins = true,
};

const rust_language: Language = .{
    .line_comments = &.{"//"},
    .block = .{ .open = "/*", .close = "*/" },
    .keywords = &.{
        "fn",    "let",  "mut",   "const",  "static", "struct",   "enum",  "impl",
        "trait", "pub",  "use",   "mod",    "match",  "if",       "else",  "loop",
        "while", "for",  "in",    "return", "break",  "continue", "where", "async",
        "await", "move", "ref",   "dyn",    "unsafe", "as",       "crate", "self",
        "super", "type", "yield",
    },
    .builtins = &.{
        "u8",   "u16", "u32",  "u64",  "usize", "i8",     "i16", "i32",    "i64",    "isize",
        "f32",  "f64", "bool", "char", "str",   "String", "Vec", "Option", "Result", "Some",
        "None", "Ok",  "Err",  "true", "false",
    },
    .bang_macros = true,
};

const go_language: Language = .{
    .line_comments = &.{"//"},
    .block = .{ .open = "/*", .close = "*/" },
    .quotes = "\"'`",
    .keywords = &.{
        "func",   "var",   "const", "type",   "struct", "interface", "package",  "import",
        "return", "if",    "else",  "for",    "range",  "switch",    "case",     "default",
        "go",     "defer", "chan",  "select", "map",    "break",     "continue", "fallthrough",
    },
    .builtins = &.{
        "string",  "int",     "int8", "int32", "int64", "uint", "uint8", "uint64", "byte", "rune",
        "float32", "float64", "bool", "error", "nil",   "true", "false", "make",   "len",  "cap",
        "append",
    },
};

const python_language: Language = .{
    .line_comments = &.{"#"},
    .keywords = &.{
        "def",    "class", "return", "if",       "elif", "else",   "for",      "while",
        "import", "from",  "as",     "with",     "try",  "except", "finally",  "raise",
        "lambda", "yield", "global", "nonlocal", "pass", "break",  "continue", "assert",
        "async",  "await", "del",    "in",       "is",   "not",    "and",      "or",
    },
    .builtins = &.{
        "True", "False", "None", "self",  "print", "len",  "range",     "str", "int",   "float",
        "list", "dict",  "set",  "tuple", "bool",  "open", "enumerate", "zip", "super",
    },
};

const js_language: Language = .{
    .line_comments = &.{"//"},
    .block = .{ .open = "/*", .close = "*/" },
    .quotes = "\"'`",
    .keywords = &.{
        "const",     "let",      "var",     "function",   "return",  "if",      "else",     "for",
        "while",     "class",    "extends", "new",        "import",  "export",  "from",     "default",
        "async",     "await",    "try",     "catch",      "finally", "throw",   "switch",   "case",
        "break",     "continue", "typeof",  "instanceof", "delete",  "in",      "of",       "yield",
        "interface", "type",     "enum",    "implements", "public",  "private", "readonly",
    },
    .builtins = &.{
        "true",    "false",  "null",    "undefined", "this",   "console", "document", "window",
        "Promise", "Array",  "Object",  "String",    "Number", "Boolean", "Math",     "JSON",
        "string",  "number", "boolean", "any",       "void",   "never",   "unknown",
    },
};

const shell_language: Language = .{
    .line_comments = &.{"#"},
    .keywords = &.{
        "if",     "then",   "else", "elif",  "fi",    "for",      "while",  "until",
        "do",     "done",   "case", "esac",  "in",    "function", "return", "local",
        "export", "source", "set",  "unset", "shift", "trap",     "exit",
    },
    .builtins = &.{
        "echo", "cd",    "ls",    "grep", "sed", "awk", "cat",  "printf", "read", "test",
        "true", "false", "mkdir", "rm",   "cp",  "mv",  "find", "xargs",  "curl", "git",
    },
};

const json_language: Language = .{
    .line_comments = &.{"//"},
    .quotes = "\"",
    .keywords = &.{},
    .builtins = &.{ "true", "false", "null" },
};

const sql_language: Language = .{
    .line_comments = &.{"--"},
    .block = .{ .open = "/*", .close = "*/" },
    .keywords = &.{
        "SELECT", "FROM",   "WHERE", "INSERT", "INTO",    "VALUES", "UPDATE",  "SET",
        "DELETE", "CREATE", "TABLE", "INDEX",  "DROP",    "ALTER",  "JOIN",    "LEFT",
        "INNER",  "OUTER",  "ON",    "GROUP",  "ORDER",   "BY",     "LIMIT",   "OFFSET",
        "AND",    "OR",     "NOT",   "NULL",   "PRIMARY", "KEY",    "FOREIGN", "REFERENCES",
        "select", "from",   "where", "insert", "into",    "values", "update",  "set",
        "delete", "create", "table", "join",   "on",      "group",  "order",   "by",
        "limit",
    },
    .builtins = &.{ "INTEGER", "TEXT", "REAL", "BLOB", "PRIMARY", "AUTOINCREMENT" },
};

const c_language: Language = .{
    .line_comments = &.{"//"},
    .block = .{ .open = "/*", .close = "*/" },
    .keywords = c_like_keywords,
    .builtins = c_types,
};

/// The language a fence label names, or null when it names none we know. Labels
/// are matched case-insensitively, and the usual aliases are accepted since a
/// model writes whichever one it learned.
pub fn fromLabel(label: []const u8) ?Language {
    if (label.len == 0) return null;

    var buffer: [16]u8 = undefined;
    if (label.len > buffer.len) return null;
    const name = std.ascii.lowerString(&buffer, label);

    const table = .{
        .{ &[_][]const u8{"zig"}, zig_language },
        .{ &[_][]const u8{ "rust", "rs" }, rust_language },
        .{ &[_][]const u8{"go"}, go_language },
        .{ &[_][]const u8{ "python", "py" }, python_language },
        .{ &[_][]const u8{ "javascript", "js", "jsx", "typescript", "ts", "tsx" }, js_language },
        .{ &[_][]const u8{ "bash", "sh", "shell", "zsh", "console" }, shell_language },
        .{ &[_][]const u8{ "json", "jsonc" }, json_language },
        .{ &[_][]const u8{ "sql", "sqlite" }, sql_language },
        .{ &[_][]const u8{ "c", "h", "cpp", "c++", "cc", "hpp", "java", "kotlin", "kt", "cs" }, c_language },
    };

    inline for (table) |entry| {
        for (entry[0]) |alias| {
            if (std.mem.eql(u8, alias, name)) return entry[1];
        }
    }
    return null;
}

test "a line splits into comments, strings, numbers and keywords" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state: State = .{};
    const spans = try highlight(
        arena,
        fromLabel("zig"),
        "const x: u8 = 42; // note",
        &state,
    );

    const wanted = [_]struct { []const u8, Kind }{
        .{ "const", .keyword },
        .{ " x: ", .plain },
        .{ "u8", .builtin },
        .{ " = ", .plain },
        .{ "42", .number },
        .{ "; ", .plain },
        .{ "// note", .comment },
    };
    try std.testing.expectEqual(wanted.len, spans.len);
    for (wanted, spans) |want, got| {
        try std.testing.expectEqualStrings(want[0], got.text);
        try std.testing.expectEqual(want[1], got.kind);
    }
}

test "strings swallow what would otherwise be syntax" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state: State = .{};
    const spans = try highlight(arena, fromLabel("js"), "const s = \"// not a comment\";", &state);

    try std.testing.expectEqual(@as(usize, 4), spans.len);
    try std.testing.expectEqual(Kind.string, spans[2].kind);
    try std.testing.expectEqualStrings("\"// not a comment\"", spans[2].text);

    const escaped = try highlight(arena, fromLabel("js"), "\"a\\\"b\"", &state);
    try std.testing.expectEqual(@as(usize, 1), escaped.len);
    try std.testing.expectEqualStrings("\"a\\\"b\"", escaped[0].text);
}

test "a block comment colours the lines it spans" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rust = fromLabel("rust");
    var state: State = .{};

    const opened = try highlight(arena, rust, "let x = 1; /* start", &state);
    try std.testing.expect(state.in_block_comment);
    try std.testing.expectEqual(Kind.comment, opened[opened.len - 1].kind);

    const inside = try highlight(arena, rust, "still comment", &state);
    try std.testing.expectEqual(@as(usize, 1), inside.len);
    try std.testing.expectEqual(Kind.comment, inside[0].kind);
    try std.testing.expect(state.in_block_comment);

    const closed = try highlight(arena, rust, "done */ let y = 2;", &state);
    try std.testing.expect(!state.in_block_comment);
    try std.testing.expectEqual(Kind.comment, closed[0].kind);
    try std.testing.expectEqualStrings("done */", closed[0].text);
    try std.testing.expectEqual(Kind.keyword, closed[2].kind);
    try std.testing.expectEqualStrings("let", closed[2].text);
}

test "identifiers before a paren read as calls" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state: State = .{};
    const spans = try highlight(arena, fromLabel("python"), "value = compute(x)", &state);

    try std.testing.expectEqual(Kind.call, spans[1].kind);
    try std.testing.expectEqualStrings("compute", spans[1].text);
    try std.testing.expectEqual(Kind.plain, spans[0].kind);
}

test "an unknown or missing label leaves the line plain" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(fromLabel("brainfuck") == null);
    try std.testing.expect(fromLabel("") == null);

    var state: State = .{};
    const spans = try highlight(arena, null, "const x = 1;", &state);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(Kind.plain, spans[0].kind);
}

test "labels are matched however the model cased them" {
    try std.testing.expect(fromLabel("Zig") != null);
    try std.testing.expect(fromLabel("TSX") != null);
    try std.testing.expect(fromLabel("Bash") != null);
}
