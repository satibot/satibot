const std = @import("std");

/// Tool to control OpenCode from within SatiBot
pub const OpenCodeControl = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenCodeControl {
        return .{ .allocator = allocator };
    }

    /// Send a message to OpenCode and get response
    pub fn sendMessage(self: OpenCodeControl, message: []const u8) ![]const u8 {
        // Execute opencode run command
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "opencode", "run", message },
            .max_output_bytes = 1024 * 1024, // 1MB max output
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.log.err("OpenCode error: {s}", .{result.stderr});
            return error.OpenCodeFailed;
        }

        // Return the stdout (opencode's response)
        return self.allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\n"));
    }

    /// Start OpenCode server
    pub fn startServer(self: OpenCodeControl, port: ?u16) !void {
        const port_str = if (port) |p| try std.fmt.allocPrint(self.allocator, "{d}", .{p}) else null;
        defer if (port_str) |s| self.allocator.free(s);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "opencode");
        try argv.append(self.allocator, "serve");
        if (port_str) |s| {
            try argv.append(self.allocator, "--port");
            try argv.append(self.allocator, s);
        }

        // Run in background using spawn
        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
    }

    /// Check if OpenCode is available
    pub fn isAvailable() bool {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ "which", "opencode" },
            .max_output_bytes = 1024,
        }) catch return false;
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        return result.term.Exited == 0;
    }
};
