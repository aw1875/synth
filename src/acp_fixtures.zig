const std = @import("std");
const rpc = @import("acp/rpc.zig");
const synth = @import("acp/synth.zig");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout.interface;
    const session = "ses_fixture";
    try rpc.notify(writer, synth.method.snapshot, synth.Snapshot{
        .sessionId = session,
        .status = .{ .state = .thinking, .handle = session, .request = 3, .root = "/fixture" },
        .messages = &.{.{ .seq = 1, .role = .user, .text = "Hello" }},
    });
    for ([_][]const u8{ "Hé", "llo" }) |text| {
        try rpc.notify(writer, synth.method.stream, synth.StreamUpdate{
            .sessionId = session,
            .stream = .{ .request = 3, .text = text, .closed = true },
        });
    }
    try rpc.notify(writer, synth.method.appended, synth.Appended{
        .sessionId = session,
        .message = .{ .seq = 2, .role = .assistant, .text = "Héllo" },
    });
    try rpc.notify(writer, synth.method.status, synth.StatusUpdate{
        .sessionId = session,
        .status = .{ .handle = session, .finished = 1, .root = "/fixture", .outcome = .done },
    });
    try writer.flush();
}
