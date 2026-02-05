const std = @import("std");

pub fn main() !void {
    if (@hasDecl(std, "Io")) {
        std.debug.print("std.Io exists\n", .{});
    } else {
        std.debug.print("std.Io does not exist\n", .{});
    }

    const net = std.net;
    if (@hasDecl(net, "Stream")) {
        std.debug.print("std.net.Stream exists\n", .{});
    }
}
