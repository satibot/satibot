//! Centralized logging system for satibot
//!
//! This module provides a unified logging interface with debug flag support,
//! scoped logging, and configurable log levels. It replaces the inline logging
//! configuration in main.zig for better code organization.
//!
//! Usage:
//!
//! const log = std.log.scoped(.your_module);
//! log.info("Your message: {s}", .{value});
//! log.debug("Debug info: {any}", .{debug_data});

const std = @import("std");

/// Global debug flag - set when --debug or -D is passed
pub var debug_enabled: bool = false;

/// Log scopes used throughout the application
pub const Scope = enum {
    main,
    telegram_bot,
    agent,
    heartbeat,
    console,
    gateway,
    vector_db,
    config,
    http,
    providers,
};

/// Override default log function to control debug output
pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

/// Custom log function that filters debug logs based on debug_enabled flag
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Only show debug logs if debug flag is enabled
    if (level == .debug and !debug_enabled) return;

    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    // Use std.debug.print for consistent output
    std.debug.print(prefix ++ format ++ "\n", args);
}

/// Initialize logging system
/// Call this early in main() to set up logging configuration
pub fn init() void {
    // Initialize any logging subsystem here
    // Currently just sets up the global debug flag through command line parsing
}

/// Enable debug mode
/// Call this when --debug or -D flag is detected
pub fn enableDebug() void {
    debug_enabled = true;
}

/// Check if debug mode is enabled
pub fn isDebugEnabled() bool {
    return debug_enabled;
}

/// Create a scoped logger for a specific module
pub fn scoped(comptime scope: Scope) std.log.Scope {
    return std.log.scoped(scope);
}

/// Convenience functions for common logging patterns
pub const Logger = struct {
    /// Log debug message with module scope
    pub fn debug(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        if (debug_enabled) {
            const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
            const prefix = "[debug] " ++ scope_prefix;
            std.debug.print(prefix ++ format ++ "\n", args);
        }
    }

    /// Log info message with module scope
    pub fn info(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
        const prefix = "[info] " ++ scope_prefix;
        std.debug.print(prefix ++ format ++ "\n", args);
    }

    /// Log warning message with module scope
    pub fn warn(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
        const prefix = "[warn] " ++ scope_prefix;
        std.debug.print(prefix ++ format ++ "\n", args);
    }

    /// Log error message with module scope
    pub fn err(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
        const prefix = "[err] " ++ scope_prefix;
        std.debug.print(prefix ++ format ++ "\n", args);
    }
};

/// Performance timing helper
pub const Timer = struct {
    start_time: u64,

    pub fn start() Timer {
        return Timer{ .start_time = std.time.nanoTimestamp() };
    }

    pub fn elapsed(self: Timer) u64 {
        const now = std.time.nanoTimestamp();
        return now - self.start_time;
    }

    pub fn logElapsed(self: Timer, comptime scope: Scope, comptime operation: []const u8, args: anytype) void {
        const elapsed_us = self.elapsed();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_us)) / 1000.0;
        Logger.info(scope, "{s} completed in {d:.2}ms", .{ operation, elapsed_ms });
        _ = args;
    }
};

/// Memory usage tracking helper
pub const MemoryTracker = struct {
    initial_memory: usize,

    pub fn start() MemoryTracker {
        return MemoryTracker{ .initial_memory = getMemoryUsage() };
    }

    pub fn current(self: MemoryTracker) usize {
        _ = self;
        return getMemoryUsage();
    }

    pub fn delta(self: MemoryTracker) isize {
        return @as(isize, @intCast(self.current())) - @as(isize, @intCast(self.initial_memory));
    }

    pub fn logDelta(self: MemoryTracker, comptime scope: Scope, comptime operation: []const u8, args: anytype) void {
        _ = args;
        const memory_delta = self.delta();
        const sign = if (memory_delta >= 0) "+" else "";
        Logger.info(scope, "{s} memory delta: {s}{d} bytes", .{ operation, sign, memory_delta });
    }

    fn getMemoryUsage() usize {
        // This is a placeholder - in a real implementation you might use
        // platform-specific APIs to get actual memory usage
        return 0;
    }
};

/// Common logging macros for convenience
pub const log = struct {
    pub fn debug(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        Logger.debug(scope, format, args);
    }

    pub fn info(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        Logger.info(scope, format, args);
    }

    pub fn warn(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        Logger.warn(scope, format, args);
    }

    pub fn err(comptime scope: Scope, comptime format: []const u8, args: anytype) void {
        Logger.err(scope, format, args);
    }
};
