//! Masking secrets in text before it is stored, shown, or sent to a model.
//!
//! Tool output is where a key leaks: `cat .env`, `env`, a stack trace holding
//! an Authorization header. Every tool result passes through one place on its
//! way to the database, the transcript and the next request, so masking there
//! keeps a secret out of all three at once.

const std = @import("std");
const testing = std.testing;

/// What a secret is replaced with. Short, and obviously not a value, so a
/// model does not try to use it.
pub const mask = "[redacted]";

/// Shortest value still worth masking. Below this a match is far more likely
/// to be a placeholder than a key.
const min_value_len: usize = 8;

/// A secret recognised by what it starts with. `min_body` is how many token
/// characters must follow for a match to count, which is what stops `sk-` in
/// ordinary prose from being read as a key.
const Prefix = struct { text: []const u8, min_body: usize };

const prefixes: []const Prefix = &.{
    .{ .text = "sk-", .min_body = 20 },
    .{ .text = "ghp_", .min_body = 30 },
    .{ .text = "gho_", .min_body = 30 },
    .{ .text = "ghu_", .min_body = 30 },
    .{ .text = "ghs_", .min_body = 30 },
    .{ .text = "ghr_", .min_body = 30 },
    .{ .text = "github_pat_", .min_body = 20 },
    .{ .text = "glpat-", .min_body = 16 },
    .{ .text = "xoxb-", .min_body = 10 },
    .{ .text = "xoxp-", .min_body = 10 },
    .{ .text = "xoxa-", .min_body = 10 },
    .{ .text = "xoxs-", .min_body = 10 },
    .{ .text = "AKIA", .min_body = 16 },
    .{ .text = "ASIA", .min_body = 16 },
    .{ .text = "AIza", .min_body = 30 },
    .{ .text = "ya29.", .min_body = 20 },
    .{ .text = "npm_", .min_body = 30 },
    .{ .text = "hf_", .min_body = 30 },
    .{ .text = "dop_v1_", .min_body = 30 },
    .{ .text = "shpat_", .min_body = 20 },
    .{ .text = "Bearer ", .min_body = 16 },
};

/// Substrings that make a name a secret's name, compared case-insensitively.
/// Deliberately narrow: a bare `KEY` also matches `KEYWORD` and `PRIMARY_KEY`,
/// and output buried in `[redacted]` is worse than one missed value.
const secret_names: []const []const u8 = &.{
    "SECRET",
    "TOKEN",
    "PASSWORD",
    "PASSWD",
    "CREDENTIAL",
    "APIKEY",
    "API_KEY",
    "ACCESS_KEY",
    "PRIVATE_KEY",
    "SESSION_KEY",
    "AUTHORIZATION",
};

/// Values that carry no secret however they are named.
const placeholders: []const []const u8 = &.{ "undefined", "changeme", "your-key-here" };

/// A copy of `text` with anything that looks like a secret masked. Always
/// allocates: every caller wants an owned copy regardless.
pub fn scrub(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try write(&out.writer, text);
    return out.toOwnedSlice();
}

fn write(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (pemAt(text, i)) |end| {
            try w.writeAll(mask);
            i = end;
            continue;
        }
        if (atBoundary(text, i)) {
            if (jwtAt(text, i)) |end| {
                try w.writeAll(mask);
                i = end;
                continue;
            }
            if (prefixAt(text, i)) |match| {
                try w.writeAll(text[i .. i + match.keep]);
                try w.writeAll(mask);
                i = match.end;
                continue;
            }
            if (assignmentAt(text, i)) |match| {
                try w.writeAll(text[i..match.value_start]);
                try w.writeAll(mask);
                i = match.end;
                continue;
            }
        }
        try w.writeByte(text[i]);
        i += 1;
    }
}

fn isToken(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Whether a match may start at `at`: only where a token does not already run
/// through it, so `task-force` cannot be read as an `sk-` key.
fn atBoundary(text: []const u8, at: usize) bool {
    return at == 0 or !isToken(text[at - 1]);
}

fn tokenRun(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and isToken(text[i])) i += 1;
    return i - from;
}

const Match = struct { keep: usize = 0, value_start: usize = 0, end: usize };

fn prefixAt(text: []const u8, at: usize) ?Match {
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, text[at..], prefix.text)) continue;
        const body_at = at + prefix.text.len;
        const body = tokenRun(text, body_at);
        if (body < prefix.min_body) continue;
        return .{ .keep = prefix.text.len, .end = body_at + body };
    }
    return null;
}

/// A JSON Web Token: three dot-separated base64url parts, the first of which
/// is an encoded `{"` and so always begins `eyJ`.
fn jwtAt(text: []const u8, at: usize) ?usize {
    if (!std.mem.startsWith(u8, text[at..], "eyJ")) return null;

    const header = tokenRun(text, at);
    if (header < 12) return null;
    var i = at + header;
    if (i >= text.len or text[i] != '.') return null;

    i += 1;
    const payload = tokenRun(text, i);
    if (payload < 8) return null;
    i += payload;
    if (i >= text.len or text[i] != '.') return null;

    i += 1;
    return i + tokenRun(text, i);
}

/// A PEM private key, masked whole. A certificate carries the same fencing
/// and is public, so only the key headers count.
fn pemAt(text: []const u8, at: usize) ?usize {
    if (!std.mem.startsWith(u8, text[at..], "-----BEGIN ")) return null;

    const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    if (std.mem.indexOf(u8, text[at..line_end], "PRIVATE KEY") == null) return null;

    const end_at = std.mem.indexOfPos(u8, text, line_end, "-----END ") orelse return text.len;
    const close = std.mem.indexOfPos(u8, text, end_at + "-----END ".len, "-----") orelse return text.len;
    return close + "-----".len;
}

/// `API_KEY=value`, `token: value`, `"client_secret": "value"`. The name and
/// separator are kept so the shape of the output survives.
fn assignmentAt(text: []const u8, at: usize) ?Match {
    const name = tokenRun(text, at);
    if (name == 0) return null;
    if (!secretName(text[at .. at + name])) return null;

    var i = at + name;
    if (i < text.len and (text[i] == '"' or text[i] == '\'')) i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    if (i >= text.len or (text[i] != '=' and text[i] != ':')) return null;

    i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    const quote: ?u8 = if (i < text.len and (text[i] == '"' or text[i] == '\'')) text[i] else null;
    if (quote != null) i += 1;

    const start = i;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote) |q| {
            if (c == q) break;
        } else if (std.ascii.isWhitespace(c) or c == ',' or c == ';' or c == '}' or c == ')') break;
    }

    if (!looksSecret(text[start..i])) return null;
    return .{ .value_start = start, .end = i };
}

fn secretName(name: []const u8) bool {
    for (secret_names) |needle| {
        if (containsUpper(name, needle)) return true;
    }
    return false;
}

/// `haystack` contains `needle`, where `needle` is already uppercase.
fn containsUpper(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len) : (k += 1) {
            if (std.ascii.toUpper(haystack[i + k]) != needle[k]) break;
        } else return true;
    }
    return false;
}

/// Whether a value under a secret's name is worth masking. A path, a number
/// or a placeholder is configuration a model still needs to read.
fn looksSecret(value: []const u8) bool {
    if (value.len < min_value_len) return false;
    if (value[0] == '/' or value[0] == '~' or value[0] == '.') return false;

    for (placeholders) |placeholder| {
        if (std.ascii.eqlIgnoreCase(value, placeholder)) return false;
    }

    for (value) |c| {
        if (!std.ascii.isDigit(c)) return true;
    }
    return false;
}

fn expectScrub(expected: []const u8, input: []const u8) !void {
    const got = try scrub(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a prefixed token keeps its prefix and loses its body" {
    try expectScrub(
        "key is sk-[redacted] ok",
        "key is sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAA ok",
    );
    try expectScrub("ghp_[redacted]", "ghp_0123456789abcdef0123456789abcdef0123");
    try expectScrub("AKIA[redacted]", "AKIAIOSFODNN7EXAMPLE");
    try expectScrub("Bearer [redacted]", "Bearer abcdef0123456789abcdef");
}

test "a prefix inside a word or without a body is left alone" {
    try expectScrub("a task-oriented plan", "a task-oriented plan");
    try expectScrub("sk-short", "sk-short");
    try expectScrub("Bearer token auth", "Bearer token auth");
}

test "an assignment keeps its name and separator" {
    try expectScrub("API_KEY=[redacted]", "API_KEY=bx6f9a2d3e4c5b6a7");
    try expectScrub("  \"client_secret\": \"[redacted]\",", "  \"client_secret\": \"s3cr3tvaluehere\",");
    try expectScrub("password: [redacted]\nport: 5432", "password: hunter2hunter2\nport: 5432");
}

test "a name that is not a secret's name is left alone" {
    try expectScrub("KEYWORD=something", "KEYWORD=something");
    try expectScrub("PRIMARY_KEY=identifier", "PRIMARY_KEY=identifier");
}

test "a path, a number or a placeholder under a secret name survives" {
    try expectScrub("CREDENTIAL_FILE=/etc/creds.json", "CREDENTIAL_FILE=/etc/creds.json");
    try expectScrub("TOKEN_TTL=31536000", "TOKEN_TTL=31536000");
    try expectScrub("API_KEY=undefined", "API_KEY=undefined");
    try expectScrub("API_KEY=short", "API_KEY=short");
}

test "a json web token is masked whole" {
    try expectScrub(
        "auth=[redacted]",
        "auth=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r",
    );
}

test "a private key block is masked whole but a certificate is not" {
    try expectScrub(
        "before\n[redacted]\nafter",
        "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow==\n-----END RSA PRIVATE KEY-----\nafter",
    );
    const cert = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----";
    try expectScrub(cert, cert);
}

test "ordinary output passes through unchanged" {
    const source = "fn main() void {\n    const key = 12;\n}\n";
    try expectScrub(source, source);
}
