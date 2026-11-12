//! The file `debug_log` names. Only ever appended to: every session process
//! writes to the same one, and a log that loses what came before is no log.

const std = @import("std");
const testing = std.testing;

const Provider = @import("provider.zig");

pub fn append(io: std.Io, path: []const u8, entry: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive });
    defer file.close(io);
    try file.writePositionalAll(io, entry, try file.length(io));
}

pub fn writeUsage(w: *std.Io.Writer, usage: Provider.Usage) !void {
    try w.print("usage: input {d} (cached {d}, cache written {d}), output {d} (reasoning {d})\n", .{
        usage.prompt_tokens,
        usage.cached_tokens,
        usage.cache_write_tokens,
        usage.completion_tokens,
        usage.reasoning_tokens,
    });
}

test "entries are added after what the file already holds, however large" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "debug.log" });
    defer testing.allocator.free(path);

    const large = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    try append(testing.io, path, large);
    try append(testing.io, path, "first\n");
    try append(testing.io, path, "second\n");

    const written = try tmp.dir.readFileAlloc(testing.io, "debug.log", testing.allocator, .unlimited);
    defer testing.allocator.free(written);
    try testing.expectEqual(large.len + "first\nsecond\n".len, written.len);
    try testing.expect(std.mem.endsWith(u8, written, "xfirst\nsecond\n"));
}
