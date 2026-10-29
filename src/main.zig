const std = @import("std");

const pkg = @import("pkg");
const vaxis = @import("vaxis");
pub const panic = vaxis.panic_handler;

const cli = @import("cli.zig");
const commands = @import("commands.zig");

const acp = @import("acp/run.zig");
const Connection = @import("acp/connection.zig");
const Mirror = @import("acp/mirror.zig");
const headless = @import("headless.zig");
const prompt_dump = @import("prompt_dump.zig");
const tui_drive = @import("tui/drive.zig");

// We don't want to see the log messages from the libraries we use
pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .ollama, .level = .warn },
        .{ .scope = .zqlite, .level = .warn },
        .{ .scope = .clap, .level = .warn },
        .{ .scope = .oauth2, .level = .warn },
        .{ .scope = .http, .level = .warn },
        .{ .scope = .websocket, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const command = try cli.parse(init, init.arena.allocator());
    switch (command) {
        .help => |topic| try writeLine(init.io, cli.usageFor(topic)),
        .version => try writeLine(init.io, pkg.name ++ " " ++ pkg.version ++ "\n"),
        .tui => |options| {
            if (try runTui(init, options)) |handle| {
                var farewell: [256]u8 = undefined;
                var out = std.Io.File.stdout().writer(init.io, &farewell);
                try out.interface.print(
                    \\
                    \\Session {1s}
                    \\  {0s} --continue               resume it here
                    \\  {0s} --session {1s}   resume it from anywhere
                    \\
                , .{ pkg.name, handle });
                try out.interface.flush();
            }
        },
        .run => |options| try headless.run(init, options.message, options.allow),
        .prompt => try prompt_dump.dump(init),
        .acp => try acp.run(init),
        .models => try commands.models(init),
        .skills => try commands.skills(init),
        .session => |sub| try commands.session(init, sub),
        .mcp => |sub| try commands.mcp_command(init, sub),
        .db => |sub| try commands.database(init, sub),
    }
}

fn writeLine(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

/// Run the TUI on a session hosted by a `synth acp` child, which has this
/// terminal's environment and ends when the TUI does. Returns the session's
/// handle when there is anything in it to come back to, in the process arena.
fn runTui(init: std.process.Init, options: cli.Command.Tui) !?[]const u8 {
    const io = init.io;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, options.project orelse ".", init.arena.allocator());

    const target: Mirror.Target = if (options.session) |handle|
        .{ .load = .{ .handle = handle, .cwd = root } }
    else if (options.continue_last)
        .{ .latest = root }
    else
        .{ .new = root };
    const connection = try Connection.spawn(init.gpa, io, root);
    const left = try tui_drive.drive(init, connection, Connection.here, target, .{ .model = options.model }) orelse return null;
    return if (left.spoken) left.handle else null;
}

test {
    std.testing.refAllDecls(@This());
}
