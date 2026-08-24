const std = @import("std");

const pkg = @import("build.zig.zon");

/// What `zig build release` produces, one directory each.
const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Everything the program calls itself comes from `build.zig.zon`: the
    // binary's name, the XDG directories it stores things in, and the name it
    // prints. Renaming the project is a one-line change there.
    const options = b.addOptions();
    options.addOption([]const u8, "name", @tagName(pkg.name));
    options.addOption([]const u8, "version", pkg.version);

    const exe = binary(b, target, optimize, options);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // The mcp package is its own build, compiled against `std` and `oauth2`
    // alone. Running its tests from here rather than through its own
    // `zig build test` keeps one command honest about the whole tree, and a
    // module that stopped compiling on its own is caught before the program
    // that imports it hides the breakage behind its own dependencies.
    const mcp = b.dependency("mcp", .{ .target = target, .optimize = optimize });
    const mcp_tests = b.addTest(.{ .root_module = mcp.module("mcp") });
    const run_mcp_tests = b.addRunArtifact(mcp_tests);

    const mcp_test_step = b.step("test-mcp", "Run the mcp package's tests on their own");
    mcp_test_step.dependOn(&run_mcp_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mcp_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const release_step = b.step("release", "Build every target into zig-out/<triple>");
    for (targets) |query| {
        const cross = binary(b, b.resolveTargetQuery(query), .ReleaseSafe, options);
        const installed = b.addInstallArtifact(cross, .{
            .dest_dir = .{ .override = .{ .custom = try query.zigTriple(b.allocator) } },
        });
        release_step.dependOn(&installed.step);
    }

    const archive = @tagName(pkg.name) ++ ".tar.gz";
    const tar_step = b.step("tar", "Package what `release` built into " ++ archive);

    // One archive holding every target's directory, written to the project
    // root. `-C` makes the paths inside it `<triple>/synth` rather than the
    // whole install prefix.
    var tar_argv: std.ArrayList([]const u8) = .empty;
    try tar_argv.appendSlice(b.allocator, &.{
        "tar",
        "-C",
        b.getInstallPath(.prefix, ""),
        "-czf",
        b.pathFromRoot(archive),
    });
    for (targets) |query| {
        try tar_argv.append(b.allocator, try query.zigTriple(b.allocator));
    }

    const tar_cmd = b.addSystemCommand(tar_argv.items);
    tar_cmd.step.dependOn(release_step);
    tar_step.dependOn(&tar_cmd.step);
}

/// One executable for one target. Its dependencies are resolved here rather
/// than once for the whole build: a C dependency compiled for the host and
/// linked into a binary for somewhere else fails at the linker, naming symbols
/// (`open64`, `mmap64`) that say nothing about the real mistake.
fn binary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const ollama = b.dependency("ollama", .{ .target = target, .optimize = optimize });
    const zqlite = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const mcp = b.dependency("mcp", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = @tagName(pkg.name),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
                .{ .name = "ollama", .module = ollama.module("ollama") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "mcp", .module = mcp.module("mcp") },
            },
        }),
    });

    exe.root_module.addOptions("pkg", options);
    return exe;
}
