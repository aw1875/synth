const std = @import("std");

const pkg = @import("pkg");
const vaxis = @import("vaxis");
pub const panic = vaxis.panic_handler;

const cli = @import("cli.zig");
const commands = @import("commands.zig");

const headless = @import("headless.zig");
const remote_bridge = @import("remote/bridge.zig");
const remote_client = @import("remote/client.zig");
const remote_wire = @import("remote/wire.zig");
const remote_connect = @import("remote/connect.zig");
const remote_serve = @import("remote/serve.zig");
const remote_verbs = @import("remote/verbs.zig");
const prompt_dump = @import("prompt_dump.zig");

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
        .models => try commands.models(init),
        .skills => try commands.skills(init),
        .session => |sub| try commands.session(init, sub),
        .remote => |sub| switch (sub) {
            .serve => try remote_serve.run(init),
            .bridge => try remote_bridge.run(init),
            .list => |host| try remote_verbs.list(init, host),
            .connect => |target| try remote_connect.run(init, target.host, target.session),
            .new => |target| try remote_verbs.new(init, target.host, target.root),
            .stop => |target| try remote_verbs.stop(init, target.host, target.session),
        },
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

/// Run the TUI on a session of this machine's session server, starting the
/// server first when none is up, so the session outlives this terminal and can
/// be driven from anywhere. Returns its handle when there is anything in it to
/// come back to, in the process arena.
fn runTui(init: std.process.Init, options: cli.Command.Tui) !?[]const u8 {
    const io = init.io;
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, options.project orelse ".", arena);

    var failure: remote_client.Diagnostic = .{};
    const connection = remote_client.Connection.open(allocator, io, remote_client.here, &failure) catch |err| switch (err) {
        error.NoAnswer, error.ProtocolMismatch => {
            try complain(io, failure.message);
            return null;
        },
        else => return err,
    };
    const handle = options.session orelse open: {
        const opened = connection.call(arena, .{ .open = .{ .root = root, .latest = options.continue_last } }, &failure) catch |err| {
            connection.close();
            if (err != error.Refused) return err;
            try complain(io, failure.message);
            return null;
        };
        break :open (try remote_wire.parseResult(remote_wire.Summary, arena, opened)).handle;
    };

    const left = try remote_connect.drive(init, connection, remote_client.here, handle, .{ .model = options.model }) orelse return null;
    return if (left.spoken) left.handle else null;
}

fn complain(io: std.Io, message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buffer);
    try out.interface.print("{s}\n", .{message});
    try out.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
