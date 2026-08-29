//! Reaching the web: a search tool and a page fetcher.

const std = @import("std");

const tool = @import("tool.zig");
const Context = tool.Context;
const Input = tool.Input;
const Output = tool.Output;

/// Most results one search may return, whatever the model asked for.
const max_results: i64 = 10;
const default_results: i64 = 5;
const max_query_bytes: usize = 2048;

/// Ceiling on a fetched body, and what a call that does not say gets. The
/// ceiling is what a page cannot talk its way past; the default is what keeps
/// an ordinary page from filling the context window.
const max_fetch_bytes: i64 = 256 * 1024;
const default_fetch_bytes: i64 = 50_000;
const read_chunk_bytes: usize = 16 * 1024;

/// How many `Location` hops to follow before giving up.
const max_redirects: usize = 5;

/// How long a web call may run. Shorter than the tool default, because a server
/// that has not answered in half a minute is not going to.
const request_timeout_ms: u64 = 30_000;

/// DuckDuckGo has no API worth using - the instant-answer endpoint only covers
/// encyclopedic subjects - so the keyless backend reads their HTML page. Brave
/// is a proper search API and wants a key, so a configured one picks it.
const duckduckgo_host = "https://html.duckduckgo.com";
const duckduckgo_path = "/html/";
const brave_host = "https://api.search.brave.com";
const brave_path = "/res/v1/web/search";

/// A browser's user agent rather than an honest one. Sites that serve a bot a
/// consent wall or a 403 are common enough that the honest string makes the
/// tool useless on a good fraction of the web.
const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

/// What the web tools need from configuration. Installed by whoever assembled
/// the registry, and must outlive it.
pub const Settings = struct {
    /// Brave Search API key. Without one the search reads DuckDuckGo's HTML
    /// page instead, which needs no key and no account.
    search_api_key: ?[]const u8 = null,
    /// Where search requests go. Null takes the chosen backend's own host; a
    /// test points it at itself.
    search_host: ?[]const u8 = null,
};

/// Stands in when nobody called `install`, so the keyless backend still works.
const unconfigured: Settings = .{};

const Backend = enum { duckduckgo, brave };

pub const all: []const tool.Tool = &.{
    .{
        .name = "web_search",
        .description = "Search the web for current information. Returns a small set of relevant results with titles, URLs, and text snippets. Use this when information may be current or is not available in the project.",
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","description":"Natural-language search query"},"domains":{"type":"array","items":{"type":"string"},"description":"Optional domains to restrict results to, e.g. [\"ziglang.org\"]"},"recency_days":{"type":"integer","description":"Only return results from approximately this many days; omit for no date restriction"},"max_results":{"type":"integer","description":"Maximum results to return; defaults to 5"}},"required":["query"]}
        ,
        .handler = search,
        .read_only = true,
        .parallel = true,
        .timeout_ms = request_timeout_ms,
    },
    .{
        .name = "web_fetch",
        .description = "Fetch a webpage and return its readable text. Use this after web_search when the search snippet is insufficient.",
        .schema =
        \\{"type":"object","properties":{"url":{"type":"string","description":"HTTP or HTTPS URL to fetch"},"format":{"type":"string","description":"'text' strips the markup, 'markdown' keeps headings, lists and links, 'html' returns the page as sent. Defaults to 'text'","enum":["markdown","text","html"]},"max_bytes":{"type":"integer","description":"Maximum response size returned; defaults to 50000"}},"required":["url"]}
        ,
        .handler = fetch,
        .read_only = true,
        .parallel = true,
        .timeout_ms = request_timeout_ms,
    },
};

/// Give the web tools their configuration. `registry` is `anytype` so this file
/// never has to import the registry that imports it.
pub fn install(registry: anytype, settings: *const Settings) !void {
    for (all) |t| {
        var configured = t;
        configured.userdata = @ptrCast(@constCast(settings));
        try registry.register(configured);
    }
}

fn settingsFrom(ctx: Context) ?*const Settings {
    const ptr = ctx.userdata orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn fail(ctx: Context, comptime format: []const u8, args: anytype) std.mem.Allocator.Error!Output {
    return Output.err(try std.fmt.allocPrint(ctx.allocator, format, args));
}

fn search(ctx: Context, input: Input) !Output {
    var scratch: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const query = std.mem.trim(u8, input.string("query") orelse "", " \t\r\n");
    if (query.len == 0) return fail(ctx, "web_search: 'query' is required", .{});
    if (query.len > max_query_bytes) {
        return fail(ctx, "web_search: query is {d} bytes, the limit is {d}", .{ query.len, max_query_bytes });
    }

    const settings = settingsFrom(ctx) orelse &unconfigured;
    const backend: Backend = if (settings.search_api_key != null) .brave else .duckduckgo;

    const asked = input.integer("max_results") orelse default_results;
    const limit: usize = @intCast(std.math.clamp(asked, 1, max_results));

    var headers: std.ArrayList(std.http.Header) = .empty;
    switch (backend) {
        .brave => {
            try headers.append(arena, .{ .name = "Accept", .value = "application/json" });
            try headers.append(arena, .{ .name = "X-Subscription-Token", .value = settings.search_api_key.? });
        },
        .duckduckgo => {
            try headers.append(arena, .{ .name = "Accept", .value = "text/html" });
            try headers.append(arena, .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" });
            try headers.append(arena, .{ .name = "Referer", .value = "https://duckduckgo.com/" });
        },
    }

    const url = try searchUrl(arena, settings, backend, query, input, limit);
    const reply = get(ctx, arena, url, headers.items, @intCast(max_fetch_bytes)) catch |err|
        return httpFailure(ctx, "web_search", url, err);

    switch (reply.status) {
        .ok => {},
        // DuckDuckGo answers a request it thinks is automated with 202 and a
        // page that has no results on it, rather than an error status.
        .accepted => if (backend == .duckduckgo) return fail(ctx, throttled_message, .{}),
        .unauthorized, .forbidden => return fail(ctx, "web_search: the search key was rejected", .{}),
        .too_many_requests => return fail(ctx, "web_search: rate limited by the search backend", .{}),
        else => return fail(ctx, "web_search: the search backend returned {d}", .{@intFromEnum(reply.status)}),
    }

    return switch (backend) {
        .brave => braveResults(ctx, arena, reply.body, limit),
        .duckduckgo => duckDuckGoResults(ctx, arena, reply.body, limit),
    };
}

fn searchUrl(
    arena: std.mem.Allocator,
    settings: *const Settings,
    backend: Backend,
    query: []const u8,
    input: Input,
    limit: usize,
) ![]u8 {
    var terms: std.Io.Writer.Allocating = .init(arena);
    defer terms.deinit();
    try terms.writer.writeAll(query);
    try appendDomains(&terms.writer, input, backend);

    var url: std.Io.Writer.Allocating = .init(arena);
    switch (backend) {
        .brave => try url.writer.print("{s}{s}?q=", .{ settings.search_host orelse brave_host, brave_path }),
        .duckduckgo => try url.writer.print("{s}{s}?q=", .{ settings.search_host orelse duckduckgo_host, duckduckgo_path }),
    }
    try std.Uri.Component.percentEncode(&url.writer, terms.writer.buffered(), isQuerySafe);

    switch (backend) {
        .brave => {
            try url.writer.print("&count={d}", .{limit});
            if (freshness(input.integer("recency_days"))) |window| {
                try url.writer.print("&freshness={s}", .{window});
            }
        },
        // The HTML page takes neither a count nor a date, so the cap is applied
        // to what comes back instead.
        .duckduckgo => {},
    }
    return url.toOwnedSlice();
}

/// Neither backend has a domain parameter, so a domain restriction becomes part
/// of the query the way a person would type it. DuckDuckGo spells the operator
/// `|`; Brave spells it `OR`.
fn appendDomains(w: *std.Io.Writer, input: Input, backend: Backend) !void {
    const separator = switch (backend) {
        .brave => " OR site:",
        .duckduckgo => " | site:",
    };
    const list = switch (input.get("domains") orelse return) {
        .array => |array| array,
        else => return,
    };

    var wrote = false;
    for (list.items) |item| {
        const domain = switch (item) {
            .string => |text| text,
            else => continue,
        };
        if (domain.len == 0) continue;
        try w.writeAll(if (wrote) separator else " (site:");
        try w.writeAll(domain);
        wrote = true;
    }
    if (wrote) try w.writeByte(')');
}

/// Brave takes a coarse window rather than a day count, so round up to the
/// smallest one that covers what was asked for.
fn freshness(days: ?i64) ?[]const u8 {
    const asked = days orelse return null;
    if (asked <= 0) return null;
    if (asked <= 1) return "pd";
    if (asked <= 7) return "pw";
    if (asked <= 31) return "pm";
    if (asked <= 365) return "py";
    return null;
}

fn isQuerySafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

const BraveReply = struct {
    web: ?struct {
        results: []const Result = &.{},
    } = null,

    const Result = struct {
        title: []const u8 = "",
        url: []const u8 = "",
        description: []const u8 = "",
        age: ?[]const u8 = null,
    };
};

fn braveResults(ctx: Context, arena: std.mem.Allocator, body: []const u8, limit: usize) !Output {
    const parsed = std.json.parseFromSlice(BraveReply, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return fail(ctx, unreadable_reply, .{});
    defer parsed.deinit();

    const found = if (parsed.value.web) |web| web.results else &[_]BraveReply.Result{};

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    var n: usize = 0;
    for (found) |result| {
        if (n >= limit) break;
        try entry(
            &out.writer,
            &n,
            try plain(arena, result.title),
            result.url,
            try plain(arena, result.description),
        );
        if (result.age) |age| try out.writer.print("   {s}\n", .{age});
    }

    if (n == 0) return Output.ok(try ctx.allocator.dupe(u8, "No results."));
    return Output.ok(try ctx.allocator.dupe(u8, out.writer.buffered()));
}

/// DuckDuckGo's HTML results page. Each result is an `<a class="result__a">`
/// holding the title and a redirect to the real URL, followed by an
/// `<a class="result__snippet">` holding the summary.
fn duckDuckGoResults(ctx: Context, arena: std.mem.Allocator, html: []const u8, limit: usize) !Output {
    var hits: std.ArrayList(Hit) = .empty;

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "<a ")) |open| {
        const close = std.mem.indexOfScalarPos(u8, html, open, '>') orelse break;
        i = close + 1;

        const tag = Tag.parse(html[open + 1 .. close]);
        const classes = attribute(tag.attributes, "class") orelse continue;
        const title = hasClass(classes, "result__a");
        const snippet = hasClass(classes, "result__snippet");
        if (!title and !snippet) continue;

        const body = std.mem.indexOfPos(u8, html, i, "</a>") orelse break;
        const text = try plain(arena, html[i..body]);
        i = body + "</a>".len;

        if (title) {
            if (hits.items.len >= limit) break;
            const url = try resultLink(arena, attribute(tag.attributes, "href") orelse "") orelse continue;
            try hits.append(arena, .{ .title = text, .url = url });
        } else if (hits.items.len > 0) {
            const last = &hits.items[hits.items.len - 1];
            if (last.snippet.len == 0) last.snippet = text;
        }
    }

    if (hits.items.len == 0) return Output.ok(try ctx.allocator.dupe(u8, "No results."));

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    var n: usize = 0;
    for (hits.items) |hit| try entry(&out.writer, &n, hit.title, hit.url, hit.snippet);
    return Output.ok(try ctx.allocator.dupe(u8, out.writer.buffered()));
}

const Hit = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8 = "",
};

const unreadable_reply = "web_search: the search backend sent a reply this tool could not read";

const throttled_message = "web_search: DuckDuckGo is throttling this machine and returned no results. Wait a minute and try again, or set BRAVE_API_KEY to use a search API that does not throttle.";

const redirect_marker = "/l/?uddg=";

/// The real target behind a result link, which DuckDuckGo wraps in a redirect
/// through its own host with the destination percent-encoded in `uddg`.
///
/// Null for a link that is not a result: their sponsored slots point at
/// duckduckgo.com itself and carry no destination.
fn resultLink(arena: std.mem.Allocator, href: []const u8) !?[]const u8 {
    if (href.len == 0) return null;

    const at = std.mem.indexOf(u8, href, redirect_marker) orelse {
        if (std.ascii.indexOfIgnoreCase(href, "duckduckgo.com") != null) return null;
        if (std.mem.startsWith(u8, href, "//")) return try std.fmt.allocPrint(arena, "https:{s}", .{href});
        return try arena.dupe(u8, href);
    };

    var encoded = href[at + redirect_marker.len ..];
    // The destination is percent-encoded, so the first `&` ends it whether the
    // page wrote the next parameter as `&` or as `&amp;`.
    if (std.mem.indexOfScalar(u8, encoded, '&')) |cut| encoded = encoded[0..cut];
    if (encoded.len == 0) return null;

    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, encoded));
}

fn hasClass(classes: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, classes, " \t\r\n");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, name)) return true;
    }
    return false;
}

fn entry(w: *std.Io.Writer, n: *usize, title: []const u8, url: []const u8, text: []const u8) !void {
    n.* += 1;
    if (n.* > 1) try w.writeByte('\n');
    try w.print("{d}. {s}\n", .{ n.*, title });
    if (url.len > 0) try w.print("   {s}\n", .{url});
    if (text.len > 0) try w.print("   {s}\n", .{text});
}

fn fetch(ctx: Context, input: Input) !Output {
    var scratch: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const url = std.mem.trim(u8, input.string("url") orelse "", " \t\r\n");
    if (url.len == 0) return fail(ctx, "web_fetch: 'url' is required", .{});

    const format = std.meta.stringToEnum(Format, input.string("format") orelse "text") orelse .text;
    const asked = input.integer("max_bytes") orelse default_fetch_bytes;
    const limit: usize = @intCast(std.math.clamp(asked, 1, max_fetch_bytes));

    const reply = get(ctx, arena, url, &.{
        .{ .name = "Accept", .value = acceptHeader(format) },
        .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" },
    }, limit) catch |err| return httpFailure(ctx, "web_fetch", url, err);

    if (reply.status.class() != .success) {
        return fail(ctx, "web_fetch: {s} returned {d} {s}", .{
            url,
            @intFromEnum(reply.status),
            reply.status.phrase() orelse "",
        });
    }

    if (!textual(reply.content_type)) {
        return fail(ctx, "web_fetch: {s} is {s}, which is not text this tool can read", .{ url, reply.content_type });
    }

    const readable = if (format != .html and isHtml(reply.content_type))
        try render(arena, reply.body, format)
    else
        reply.body;

    if (readable.len == 0) return Output.ok(try ctx.allocator.dupe(u8, "(the page had no readable text)"));
    if (!reply.truncated) return Output.ok(try ctx.allocator.dupe(u8, readable));

    return Output.ok(try std.fmt.allocPrint(
        ctx.allocator,
        "{s}\n\n[cut off at {d} bytes; ask again with a larger max_bytes for the rest]",
        .{ readable, limit },
    ));
}

const Format = enum { markdown, text, html };

fn acceptHeader(format: Format) []const u8 {
    return switch (format) {
        .markdown => "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1",
        .text => "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1",
        .html => "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1",
    };
}

const Fetched = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
    truncated: bool,
};

/// One GET, following redirects by hand.
///
/// The client can follow them itself, but then only the URL the model named
/// ever reaches `checkUri`, and a public URL that redirects to
/// `169.254.169.254` would already have been fetched before anything objected.
fn get(
    ctx: Context,
    arena: std.mem.Allocator,
    url: []const u8,
    extra: []const std.http.Header,
    limit: usize,
) !Fetched {
    var client: std.http.Client = .{ .allocator = arena, .io = ctx.io };
    defer client.deinit();

    const transfer_buffer = try arena.alloc(u8, read_chunk_bytes);
    const decompress_buffer = try arena.alloc(u8, std.compress.flate.max_window_len);
    const chunk = try arena.alloc(u8, read_chunk_bytes);

    var target = try arena.dupe(u8, url);
    var hops: usize = 0;

    while (true) {
        if (ctx.shouldStop()) return error.Cancelled;

        const uri = std.Uri.parse(target) catch return error.BadUrl;
        try checkUri(uri);

        var request = try client.request(.GET, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .extra_headers = extra,
        });
        defer request.deinit();

        try request.sendBodiless();

        var redirect_buffer: [1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const status = response.head.status;

        if (status.class() == .redirect) {
            hops += 1;
            if (hops > max_redirects) return error.TooManyRedirects;
            const location = response.head.location orelse return error.RedirectWithoutLocation;
            target = try resolve(arena, target, location);
            continue;
        }

        // Copied before the reader is built: `readerDecompressing` invalidates
        // every string the head points at.
        const content_type = try arena.dupe(u8, mediaType(response.head.content_type orelse ""));

        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(transfer_buffer, &decompress, decompress_buffer);

        var body: std.ArrayList(u8) = .empty;
        while (body.items.len < limit) {
            if (ctx.shouldStop()) return error.Cancelled;
            const want = @min(chunk.len, limit - body.items.len);
            const n = try reader.readSliceShort(chunk[0..want]);
            try body.appendSlice(arena, chunk[0..n]);
            if (n < want) break;
        }

        const truncated = body.items.len == limit and (reader.readSliceShort(chunk[0..1]) catch 0) > 0;

        return .{
            .status = status,
            .content_type = content_type,
            .body = body.items,
            .truncated = truncated,
        };
    }
}

fn resolve(arena: std.mem.Allocator, base_text: []const u8, location: []const u8) ![]u8 {
    const base = std.Uri.parse(base_text) catch return error.BadUrl;

    // `resolveInPlace` merges into the buffer it is handed and wants the new
    // location sitting at the front of it.
    const buffer = try arena.alloc(u8, location.len + base_text.len + 1);
    @memcpy(buffer[0..location.len], location);

    var aux: []u8 = buffer;
    const merged = std.Uri.resolveInPlace(base, location.len, &aux) catch return error.BadUrl;

    var out: std.Io.Writer.Allocating = .init(arena);
    try merged.writeToStream(&out.writer, .{
        .scheme = true,
        .authority = true,
        .path = true,
        .query = true,
    });
    return out.toOwnedSlice();
}

fn checkUri(uri: std.Uri) !void {
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return error.UnsupportedScheme;
    }
    const host = uri.host orelse return error.MissingHost;
    const text = switch (host) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
    if (blockedHost(text)) return error.BlockedHost;
}

/// Whether a host is one this machine's own network would answer for.
///
/// `web_fetch` needs no approval, so without this a page can talk the model
/// into reading a cloud metadata service or something bound to loopback and
/// handing back what it said.
///
/// Literal addresses only. A name that resolves to a private address still gets
/// through, which would take checking the resolved address rather than the text.
fn blockedHost(host: []const u8) bool {
    var text = host;
    if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') text = text[1 .. text.len - 1];
    if (text.len == 0) return true;

    if (std.ascii.eqlIgnoreCase(text, "localhost")) return true;
    for ([_][]const u8{ ".localhost", ".local", ".internal", ".home.arpa" }) |suffix| {
        if (std.ascii.endsWithIgnoreCase(text, suffix)) return true;
    }

    if (std.mem.indexOfScalar(u8, text, ':') != null) return blockedIp6(text);
    if (parseIp4(text)) |octets| return blockedIp4(octets);
    return false;
}

fn parseIp4(text: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&octets) |*octet| {
        const part = parts.next() orelse return null;
        if (part.len == 0 or part.len > 3) return null;
        octet.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return octets;
}

fn blockedIp4(octets: [4]u8) bool {
    return switch (octets[0]) {
        0, 10, 127 => true,
        100 => octets[1] >= 64 and octets[1] <= 127,
        169 => octets[1] == 254,
        172 => octets[1] >= 16 and octets[1] <= 31,
        192 => octets[1] == 168 or (octets[1] == 0 and octets[2] == 0),
        198 => octets[1] == 18 or octets[1] == 19,
        else => octets[0] >= 224,
    };
}

fn blockedIp6(text: []const u8) bool {
    var head = text;
    if (std.mem.indexOfScalar(u8, head, '%')) |zone| head = head[0..zone];
    if (std.mem.eql(u8, head, "::1") or std.mem.eql(u8, head, "::")) return true;

    if (std.ascii.startsWithIgnoreCase(head, "::ffff:")) {
        if (parseIp4(head["::ffff:".len..])) |octets| return blockedIp4(octets);
    }

    // fc00::/7 unique-local, fe80::/10 link-local, ff00::/8 multicast. Matching
    // on the first two nibbles takes the deprecated site-local range with it,
    // which is the safe direction to be wrong in.
    if (head.len < 2 or std.ascii.toLower(head[0]) != 'f') return false;
    return switch (std.ascii.toLower(head[1])) {
        'c', 'd', 'e', 'f' => true,
        else => false,
    };
}

fn mediaType(content_type: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[0..end], " \t");
}

fn isHtml(content_type: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(content_type, "html") != null;
}

/// Whether a body is worth putting in front of a model at all. A PDF or an
/// image would arrive as bytes that cost tokens and say nothing.
fn textual(content_type: []const u8) bool {
    if (content_type.len == 0) return true;
    if (std.ascii.startsWithIgnoreCase(content_type, "text/")) return true;
    if (std.ascii.endsWithIgnoreCase(content_type, "+json")) return true;
    if (std.ascii.endsWithIgnoreCase(content_type, "+xml")) return true;
    for ([_][]const u8{
        "application/json",
        "application/xml",
        "application/javascript",
        "application/x-ndjson",
        "application/x-yaml",
    }) |name| {
        if (std.ascii.eqlIgnoreCase(content_type, name)) return true;
    }
    return false;
}

fn httpFailure(ctx: Context, name: []const u8, url: []const u8, err: anyerror) !Output {
    return switch (err) {
        error.UnsupportedScheme => fail(ctx, "{s}: only http and https URLs can be fetched", .{name}),
        error.BadUrl => fail(ctx, "{s}: '{s}' is not a URL", .{ name, url }),
        error.MissingHost => fail(ctx, "{s}: '{s}' names no host", .{ name, url }),
        error.BlockedHost => fail(ctx, "{s}: '{s}' points at this machine or a private network, which this tool will not reach", .{ name, url }),
        error.TooManyRedirects => fail(ctx, "{s}: '{s}' redirected more than {d} times", .{ name, url, max_redirects }),
        error.RedirectWithoutLocation => fail(ctx, "{s}: '{s}' redirected without saying where to", .{ name, url }),
        error.Cancelled => fail(ctx, "{s}: cancelled", .{name}),
        else => fail(ctx, "{s}: '{s}' could not be reached ({s})", .{ name, url, @errorName(err) }),
    };
}

fn plain(arena: std.mem.Allocator, html: []const u8) ![]u8 {
    return render(arena, html, .text);
}

/// Turn a page into something worth spending context on: script and style
/// bodies gone, markup gone, entities decoded, and a blank line wherever the
/// block structure had one.
fn render(arena: std.mem.Allocator, html: []const u8, format: Format) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var link: Link = .{};
    var i: usize = 0;

    while (i < html.len) {
        if (html[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            try writeText(&out.writer, html[i..end]);
            i = end;
            continue;
        }

        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, html, i, "-->")) |at| at + 3 else html.len;
            continue;
        }

        const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
        const tag = Tag.parse(html[i + 1 .. close]);
        i = close + 1;
        if (tag.name.len == 0) continue;

        if (!tag.closing and isRawText(tag.name)) {
            i = skipPast(html, i, tag.name);
            continue;
        }

        try decorate(&out.writer, tag, format, &link);
    }

    return tidy(arena, out.writer.buffered());
}

const Tag = struct {
    name: []const u8,
    closing: bool,
    attributes: []const u8,

    fn parse(inner: []const u8) Tag {
        var body = inner;
        if (body.len > 0 and body[body.len - 1] == '/') body = body[0 .. body.len - 1];

        const closing = body.len > 0 and body[0] == '/';
        if (closing) body = body[1..];

        const end = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
        return .{ .name = body[0..end], .closing = closing, .attributes = body[end..] };
    }

    fn is(self: Tag, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }
};

fn isRawText(name: []const u8) bool {
    for ([_][]const u8{ "script", "style", "noscript", "svg", "template" }) |raw| {
        if (std.ascii.eqlIgnoreCase(name, raw)) return true;
    }
    return false;
}

fn skipPast(html: []const u8, from: usize, name: []const u8) usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |at| {
        if (at + 1 < html.len and html[at + 1] == '/' and
            std.ascii.startsWithIgnoreCase(html[at + 2 ..], name))
        {
            const close = std.mem.indexOfScalarPos(u8, html, at, '>') orelse return html.len;
            return close + 1;
        }
        i = at + 1;
    }
    return html.len;
}

const Link = struct {
    target: ?[]const u8 = null,
    /// Where the anchor's text begins. An anchor that turns out to have no text
    /// is taken back out at the close rather than left as an empty `[]`.
    start: usize = 0,
};

fn decorate(w: *std.Io.Writer, tag: Tag, format: Format, link: *Link) !void {
    if (tag.is("br") or tag.is("hr")) return w.writeByte('\n');

    if (headingLevel(tag.name)) |level| {
        try w.writeAll("\n\n");
        if (format == .markdown and !tag.closing) {
            for (0..level) |_| try w.writeByte('#');
            try w.writeByte(' ');
        }
        return;
    }

    if (tag.is("li")) {
        if (tag.closing) return;
        try w.writeByte('\n');
        if (format == .markdown) try w.writeAll("- ");
        return;
    }

    if (tag.is("a")) {
        if (format != .markdown) return;
        if (tag.closing) {
            const target = link.target orelse return;
            link.target = null;
            if (w.end == link.start) {
                w.end = link.start - 1;
                return;
            }
            try w.print("]({s})", .{target});
        } else if (linkTarget(tag.attributes)) |target| {
            try w.writeByte('[');
            link.* = .{ .target = target, .start = w.end };
        }
        return;
    }

    if (isBlock(tag.name)) try w.writeAll("\n\n");
}

fn linkTarget(attributes: []const u8) ?[]const u8 {
    const target = attribute(attributes, "href") orelse return null;
    if (target.len == 0) return null;
    if (std.ascii.startsWithIgnoreCase(target, "javascript:")) return null;
    return target;
}

fn headingLevel(name: []const u8) ?usize {
    if (name.len != 2) return null;
    if (name[0] != 'h' and name[0] != 'H') return null;
    if (name[1] < '1' or name[1] > '6') return null;
    return name[1] - '0';
}

fn isBlock(name: []const u8) bool {
    for ([_][]const u8{
        "p",      "div",    "section",    "article",    "header",
        "footer", "main",   "aside",      "nav",        "ul",
        "ol",     "dl",     "dt",         "dd",         "table",
        "tr",     "thead",  "tbody",      "form",       "fieldset",
        "pre",    "figure", "figcaption", "blockquote", "title",
        "body",
    }) |block| {
        if (std.ascii.eqlIgnoreCase(name, block)) return true;
    }
    return false;
}

fn writeText(w: *std.Io.Writer, text: []const u8) !void {
    var scratch: [4]u8 = undefined;
    var pending_space = false;
    var i: usize = 0;

    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            pending_space = true;
            i += 1;
            continue;
        }
        if (pending_space) {
            try w.writeByte(' ');
            pending_space = false;
        }
        if (c == '&') {
            if (entityAt(text, i, &scratch)) |entity| {
                try w.writeAll(entity.text);
                i = entity.end;
                continue;
            }
        }
        try w.writeByte(c);
        i += 1;
    }

    if (pending_space) try w.writeByte(' ');
}

const Entity = struct {
    text: []const u8,
    end: usize,
};

fn entityAt(text: []const u8, at: usize, scratch: *[4]u8) ?Entity {
    const semi = std.mem.indexOfScalarPos(u8, text, at, ';') orelse return null;
    if (semi - at > 10) return null;

    const name = text[at + 1 .. semi];
    if (name.len == 0) return null;

    if (name[0] == '#') {
        const digits = name[1..];
        if (digits.len == 0) return null;
        const hex = digits[0] == 'x' or digits[0] == 'X';
        const code = std.fmt.parseInt(u21, if (hex) digits[1..] else digits, if (hex) 16 else 10) catch return null;
        const n = std.unicode.utf8Encode(code, scratch) catch return null;
        return .{ .text = scratch[0..n], .end = semi + 1 };
    }

    for (named_entities) |entity| {
        if (std.mem.eql(u8, name, entity[0])) return .{ .text = entity[1], .end = semi + 1 };
    }
    return null;
}

/// The handful worth spelling out. Anything else is left as it was written,
/// which reads better than dropping it.
const named_entities = [_][2][]const u8{
    .{ "amp", "&" },
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "quot", "\"" },
    .{ "apos", "'" },
    .{ "nbsp", " " },
    .{ "ensp", " " },
    .{ "emsp", " " },
    .{ "hellip", "..." },
    .{ "mdash", "-" },
    .{ "ndash", "-" },
    .{ "lsquo", "'" },
    .{ "rsquo", "'" },
    .{ "ldquo", "\"" },
    .{ "rdquo", "\"" },
    .{ "bull", "-" },
    .{ "middot", "-" },
    .{ "copy", "(c)" },
    .{ "reg", "(r)" },
    .{ "trade", "(tm)" },
};

fn attribute(attributes: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attributes.len) {
        while (i < attributes.len and std.ascii.isWhitespace(attributes[i])) i += 1;
        if (i >= attributes.len) return null;

        const start = i;
        while (i < attributes.len and attributes[i] != '=' and !std.ascii.isWhitespace(attributes[i])) i += 1;
        const key = attributes[start..i];

        while (i < attributes.len and std.ascii.isWhitespace(attributes[i])) i += 1;
        if (i >= attributes.len or attributes[i] != '=') {
            if (key.len == 0) i += 1;
            continue;
        }
        i += 1;
        while (i < attributes.len and std.ascii.isWhitespace(attributes[i])) i += 1;
        if (i >= attributes.len) return null;

        var value: []const u8 = undefined;
        if (attributes[i] == '"' or attributes[i] == '\'') {
            const quote = attributes[i];
            i += 1;
            const from = i;
            while (i < attributes.len and attributes[i] != quote) i += 1;
            value = attributes[from..i];
            if (i < attributes.len) i += 1;
        } else {
            const from = i;
            while (i < attributes.len and !std.ascii.isWhitespace(attributes[i])) i += 1;
            value = attributes[from..i];
        }

        if (std.ascii.eqlIgnoreCase(key, name)) return value;
    }
    return null;
}

/// Squeeze the decorated text down: no leading blank lines, no trailing spaces,
/// and never more than one blank line in a row.
fn tidy(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var newlines: usize = 0;
    var spaces: usize = 0;
    var started = false;

    for (text) |c| {
        switch (c) {
            '\n' => {
                newlines += 1;
                spaces = 0;
            },
            ' ', '\t', '\r' => spaces += 1,
            else => {
                if (started) {
                    if (newlines > 0) {
                        for (0..@min(newlines, 2)) |_| try out.writer.writeByte('\n');
                    } else if (spaces > 0) {
                        try out.writer.writeByte(' ');
                    }
                }
                newlines = 0;
                spaces = 0;
                started = true;
                try out.writer.writeByte(c);
            },
        }
    }

    return out.toOwnedSlice();
}

const testing = std.testing;

test "a page becomes readable text" {
    const html =
        \\<html><head><title>Zig</title><style>body{color:red}</style></head>
        \\<body><script>var x = 1 < 2;</script>
        \\<h1>Hello</h1><p>Some   text &amp; more.</p>
        \\<ul><li>one</li><li>two</li></ul></body></html>
    ;

    const text = try render(testing.allocator, html, .text);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        \\Zig
        \\
        \\Hello
        \\
        \\Some text & more.
        \\
        \\one
        \\two
    , text);
}

test "markdown keeps headings, lists and links" {
    const html = "<h2>Title</h2><ul><li><a href=\"https://ziglang.org\">Zig</a></li></ul>";

    const text = try render(testing.allocator, html, .markdown);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings(
        \\## Title
        \\
        \\- [Zig](https://ziglang.org)
    , text);
}

test "numeric and named entities decode" {
    const html = "<p>caf&#233; &#x2014; a&nbsp;b &unknown; &lt;tag&gt;</p>";

    const text = try render(testing.allocator, html, .text);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("caf\u{e9} \u{2014} a b &unknown; <tag>", text);
}

test "an unclosed script swallows the rest rather than leaking source" {
    const text = try render(testing.allocator, "<p>before</p><script>alert(1)", .text);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("before", text);
}

test "hosts on this machine or a private network are refused" {
    for ([_][]const u8{
        "localhost",
        "LOCALHOST",
        "api.localhost",
        "printer.local",
        "metadata.internal",
        "127.0.0.1",
        "127.1.2.3",
        "10.0.0.1",
        "172.16.0.1",
        "172.31.255.255",
        "192.168.1.1",
        "169.254.169.254",
        "100.64.0.1",
        "0.0.0.0",
        "[::1]",
        "[fe80::1]",
        "[fd00::1]",
        "[::ffff:127.0.0.1]",
    }) |host| {
        try testing.expect(blockedHost(host));
    }
}

test "public hosts are allowed" {
    for ([_][]const u8{
        "ziglang.org",
        "api.search.brave.com",
        "8.8.8.8",
        "172.32.0.1",
        "192.169.0.1",
        "100.128.0.1",
        "[2606:4700::1111]",
    }) |host| {
        try testing.expect(!blockedHost(host));
    }
}

test "only http and https are fetchable" {
    try testing.expectError(error.UnsupportedScheme, checkUri(try std.Uri.parse("file:///etc/passwd")));
    try testing.expectError(error.BlockedHost, checkUri(try std.Uri.parse("http://169.254.169.254/latest/meta-data/")));
    try checkUri(try std.Uri.parse("https://ziglang.org/download/"));
}

test "a relative redirect resolves against the page it came from" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "https://example.com/b/c",
        try resolve(arena.allocator(), "https://example.com/a/page", "../b/c"),
    );
    try testing.expectEqualStrings(
        "http://elsewhere.test/x",
        try resolve(arena.allocator(), "https://example.com/a/page", "http://elsewhere.test/x"),
    );
}

test "a brave search url carries the query, the count and the domain filter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        \\{"domains":["ziglang.org","github.com"],"max_results":99,"recency_days":3}
    ,
        .{},
    );

    const settings: Settings = .{ .search_api_key = "k", .search_host = "https://search.test" };
    const url = try searchUrl(arena.allocator(), &settings, .brave, "zig io", .{ .arguments = parsed.value }, 10);

    try testing.expectEqualStrings(
        "https://search.test/res/v1/web/search" ++
            "?q=zig%20io%20%28site%3Aziglang.org%20OR%20site%3Agithub.com%29&count=10&freshness=pw",
        url,
    );
}

test "a duckduckgo search url points at the html page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{}", .{});
    const settings: Settings = .{};
    const url = try searchUrl(arena.allocator(), &settings, .duckduckgo, "model context protocol", .{ .arguments = parsed.value }, 5);

    try testing.expectEqualStrings(
        "https://html.duckduckgo.com/html/?q=model%20context%20protocol",
        url,
    );
}

test "a duckduckgo results page becomes titles, urls and snippets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const ctx: Context = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = "/tmp",
        .reads = &reads,
    };

    const page =
        \\<div class="result results_links">
        \\<h2 class="result__title">
        \\<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Fdownload%2F&amp;rut=deadbeef">Zig &amp; downloads</a>
        \\</h2>
        \\<a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">Every <b>0.16</b> tarball.</a>
        \\</div>
        \\<div class="result result--ad">
        \\<a class="result__a" href="//duckduckgo.com/y.js?ad=1">An advert</a>
        \\</div>
        \\<h2 class="result__title"><a class="result__a" href="https://ziggit.dev/t/1">Ziggit</a></h2>
    ;

    const out = try duckDuckGoResults(ctx, arena.allocator(), page, 5);
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);
    try testing.expectEqualStrings(
        \\1. Zig & downloads
        \\   https://ziglang.org/download/
        \\   Every 0.16 tarball.
        \\
        \\2. Ziggit
        \\   https://ziggit.dev/t/1
        \\
    , out.content);
}

test "the parser holds up against a real results page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const ctx: Context = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = "/tmp",
        .reads = &reads,
    };

    const page = @embedFile("testdata/duckduckgo-results.html");

    const out = try duckDuckGoResults(ctx, arena.allocator(), page, 10);
    defer testing.allocator.free(out.content);

    try testing.expect(!out.is_error);

    var lines = std.mem.splitScalar(u8, out.content, '\n');
    try testing.expectEqualStrings("1. File I/O basics (0.16) - Docs - Ziggit", lines.next().?);
    try testing.expectEqualStrings("   https://ziggit.dev/t/file-i-o-basics-0-16/14968", lines.next().?);
    try testing.expect(std.mem.startsWith(u8, lines.next().?, "   (Note, this is a variation"));

    try testing.expectEqual(@as(usize, 10), std.mem.count(u8, out.content, "\n   https"));
    try testing.expect(std.mem.indexOf(u8, out.content, "duckduckgo.com") == null);
    try testing.expect(std.mem.indexOfScalar(u8, out.content, '<') == null);

    const capped = try duckDuckGoResults(ctx, arena.allocator(), page, 3);
    defer testing.allocator.free(capped.content);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, capped.content, "\n   https"));
}

test "a results page with nothing on it says so" {
    var reads: tool.ReadLog = .init(testing.allocator);
    defer reads.deinit();

    const ctx: Context = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .project_root = "/tmp",
        .reads = &reads,
    };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const out = try duckDuckGoResults(ctx, arena.allocator(), "<html><body>nothing</body></html>", 5);
    defer testing.allocator.free(out.content);

    try testing.expectEqualStrings("No results.", out.content);
}

test "a result link is unwrapped from the redirect it arrives in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "https://ziglang.org/download/?a=b",
        (try resultLink(arena.allocator(), "//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Fdownload%2F%3Fa%3Db&rut=x")).?,
    );
    try testing.expectEqualStrings(
        "https://example.com/x",
        (try resultLink(arena.allocator(), "//example.com/x")).?,
    );
    try testing.expect(try resultLink(arena.allocator(), "//duckduckgo.com/y.js?ad=1") == null);
    try testing.expect(try resultLink(arena.allocator(), "") == null);
}

test "content types this tool will and will not read" {
    try testing.expect(textual("text/html"));
    try testing.expect(textual("application/json"));
    try testing.expect(textual("application/ld+json"));
    try testing.expect(textual(""));
    try testing.expect(!textual("application/pdf"));
    try testing.expect(!textual("image/png"));

    try testing.expect(isHtml("text/html"));
    try testing.expect(isHtml("application/xhtml+xml"));
    try testing.expect(!isHtml("text/plain"));

    try testing.expectEqualStrings("text/html", mediaType("text/html; charset=utf-8"));
}

test "recency rounds up to the window that covers it" {
    try testing.expect(freshness(null) == null);
    try testing.expect(freshness(0) == null);
    try testing.expectEqualStrings("pd", freshness(1).?);
    try testing.expectEqualStrings("pw", freshness(7).?);
    try testing.expectEqualStrings("pm", freshness(30).?);
    try testing.expectEqualStrings("py", freshness(200).?);
    try testing.expect(freshness(1000) == null);
}

test "an anchor with no text does not become an empty link" {
    const text = try render(testing.allocator, "<p><a href=\"/\"></a>Home</p>", .markdown);
    defer testing.allocator.free(text);

    try testing.expectEqualStrings("Home", text);
}
