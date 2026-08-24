//! Prints the system prompt the model will receive: `synth prompt`.

const std = @import("std");

const base_prompt = @import("agent/prompt.zig");
const Context = @import("agent/context.zig");
const Config = @import("core/config.zig");
const Project = @import("core/project.zig");

/// Print the system prompt the model would receive here.
pub fn dump(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var config = try Config.open(allocator, io, init.environ_map);
    defer config.deinit();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.currentPath(io, &path_buf);

    var project = try Project.detect(allocator, io, path_buf[0..n]);
    defer project.deinit(allocator);

    const base = config.system_prompt orelse base_prompt.default;
    const prompt = try Context.build(allocator, io, base, &project);
    defer allocator.free(prompt);

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File = .stdout();
    var writer = stdout.writer(io, &buffer);
    try writer.interface.writeAll(prompt);
    try writer.interface.writeByte('\n');
    try writer.flush();
}
