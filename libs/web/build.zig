const std = @import("std");

/// Called by the root monorepo build.zig via b.dependency("web", ...).
/// Exposes the "web" module which internally imports zap.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zap is declared in libs/web/build.zig.zon — owned here, not in the root
    const zap_mod = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
    }).module("zap");

    // Expose the web module so the root build can import it
    _ = b.addModule("web", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zap", .module = zap_mod },
        },
    });
}
