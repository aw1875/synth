const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const oauth2 = b.dependency("oauth2", .{ .target = target, .optimize = optimize });
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const mcp = b.addModule("mcp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "oauth2", .module = oauth2.module("oauth2") },
            .{ .name = "httpz", .module = httpz.module("httpz") },
        },
    });

    const test_step = b.step("test", "Run tests");
    const unit_tests = b.addTest(.{ .root_module = mcp });
    test_step.dependOn(&unit_tests.step);
}
