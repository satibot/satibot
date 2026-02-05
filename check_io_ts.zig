const std = @import("std");

pub fn main() !void {
    const Io = std.Io;
    const info = @typeInfo(Io.Timestamp);
    std.debug.print("Io.Timestamp type: {any}\n", .{info});

    // Check how to get now
    // In tls.zig it was opt.now.toSeconds()
    // Let's see if Io.Clock exists
    if (@hasDecl(Io, "Clock")) {
        std.debug.print("std.Io.Clock exists\n", .{});
    }
}
