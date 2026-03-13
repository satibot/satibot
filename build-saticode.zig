//! SatiCode Standalone Build Script
//!
//! Usage:
//!   ./build.zig              # Build all targets
//!   ./build.zig saticode     # Build saticode executable
//!   ./build.zig run          # Build and run saticode
//!   ./build.zig install      # Install to system
//!   ./build.zig clean        # Clean build artifacts

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Create modules first
    createModules(b, optimize, target);

    // SatiCode executable
    const saticode_exe = b.addExecutable(.{
        .name = "saticode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/code/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add dependencies
    if (b.modules.get("agent")) |agent_mod| {
        saticode_exe.root_module.addImport("agent", agent_mod);
    }
    if (b.modules.get("core")) |core_mod| {
        saticode_exe.root_module.addImport("core", core_mod);
    }
    if (b.modules.get("db")) |db_mod| {
        saticode_exe.root_module.addImport("db", db_mod);
    }
    if (b.modules.get("providers")) |providers_mod| {
        saticode_exe.root_module.addImport("providers", providers_mod);
    }
    if (b.modules.get("utils")) |utils_mod| {
        saticode_exe.root_module.addImport("utils", utils_mod);
    }
    if (b.modules.get("http")) |http_mod| {
        saticode_exe.root_module.addImport("http", http_mod);
    }
    if (b.modules.get("tls")) |tls_mod| {
        saticode_exe.root_module.addImport("tls", tls_mod);
    }
    if (b.modules.get("xev")) |xev_mod| {
        saticode_exe.root_module.addImport("xev", xev_mod);
    }

    // Link system libraries
    saticode_exe.linkLibC();

    // Install executable
    b.installArtifact(saticode_exe);

    // Run step
    const run_cmd = b.addRunArtifact(saticode_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run SatiCode");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/code/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Clean step
    const clean_step = b.step("clean", "Clean build artifacts");
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", "zig-cache" });
    clean_step.dependOn(&clean_cmd.step);

    // Install step (system-wide installation)
    const install_step_system = b.step("install-system", "Install SatiCode to system");
    const install_cmd = b.addSystemCommand(&.{ "sudo", "cp", "zig-out/bin/saticode", "/usr/local/bin/" });
    install_step_system.dependOn(b.getInstallStep());
    install_step_system.dependOn(&install_cmd.step);

    // Development aliases
    const dev_step = b.step("dev", "Build and run in development mode");
    const dev_run = b.addRunArtifact(saticode_exe);
    dev_run.step.dependOn(b.getInstallStep());
    dev_step.dependOn(&dev_run.step);
}

// Helper function to create modules (shared with main build.zig)
fn createModules(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget) void {
    // Core module
    const core = b.createModule(.{
        .root_source_file = b.path("libs/core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("core", core) catch unreachable;

    // Agent module
    const agent = b.createModule(.{
        .root_source_file = b.path("libs/agent/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent.addImport("core", core);
    b.modules.put("agent", agent) catch unreachable;

    // Database module
    const db = b.createModule(.{
        .root_source_file = b.path("libs/db/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    db.addImport("core", core);
    b.modules.put("db", db) catch unreachable;

    // Providers module
    const providers = b.createModule(.{
        .root_source_file = b.path("libs/providers/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    providers.addImport("core", core);
    b.modules.put("providers", providers) catch unreachable;

    // Utils module
    const utils = b.createModule(.{
        .root_source_file = b.path("libs/utils/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    utils.addImport("core", core);
    b.modules.put("utils", utils) catch unreachable;

    // HTTP module
    const http = b.createModule(.{
        .root_source_file = b.path("libs/http/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    http.addImport("core", core);
    http.addImport("utils", utils);
    b.modules.put("http", http) catch unreachable;

    // TLS module
    const tls = b.createModule(.{
        .root_source_file = b.path("tls/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("tls", tls) catch unreachable;

    // XEV module
    const xev = b.createModule(.{
        .root_source_file = b.path("xev/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("xev", xev) catch unreachable;
}
