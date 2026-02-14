const std = @import("std");
const main = @import("main.zig");

test "Main: debug flag parsing" {
    const allocator = std.testing.allocator;
    
    // Test debug flag detection
    const args_with_debug = &[_][]const u8{ "satibot", "--debug", "status" };
    
    // Create a mock main function to test debug parsing
    // Since we can't directly test the main function, we'll test the parsing logic
    var debug_detected = false;
    var filtered_len: usize = 0;
    var filtered_args = try allocator.alloc([]const u8, args_with_debug.len);
    defer allocator.free(filtered_args);
    
    // Simulate the debug flag parsing logic from main.zig
    for (args_with_debug) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-D")) {
            debug_detected = true;
        } else {
            filtered_args[filtered_len] = arg;
            filtered_len += 1;
        }
    }
    
    try std.testing.expect(debug_detected);
    try std.testing.expectEqual(@as(usize, 2), filtered_len);
    try std.testing.expectEqualStrings("satibot", filtered_args[0]);
    try std.testing.expectEqualStrings("status", filtered_args[1]);
}

test "Main: short debug flag parsing" {
    const allocator = std.testing.allocator;
    
    // Test short debug flag detection
    const args_with_short_debug = &[_][]const u8{ "satibot", "-D", "help" };
    
    var debug_detected = false;
    var filtered_len: usize = 0;
    var filtered_args = try allocator.alloc([]const u8, args_with_short_debug.len);
    defer allocator.free(filtered_args);
    
    // Simulate the debug flag parsing logic
    for (args_with_short_debug) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-D")) {
            debug_detected = true;
        } else {
            filtered_args[filtered_len] = arg;
            filtered_len += 1;
        }
    }
    
    try std.testing.expect(debug_detected);
    try std.testing.expectEqual(@as(usize, 2), filtered_len);
    try std.testing.expectEqualStrings("satibot", filtered_args[0]);
    try std.testing.expectEqualStrings("help", filtered_args[1]);
}

test "Main: no debug flag parsing" {
    const allocator = std.testing.allocator;
    
    // Test without debug flag
    const args_without_debug = &[_][]const u8{ "satibot", "status" };
    
    var debug_detected = false;
    var filtered_len: usize = 0;
    var filtered_args = try allocator.alloc([]const u8, args_without_debug.len);
    defer allocator.free(filtered_args);
    
    // Simulate the debug flag parsing logic
    for (args_without_debug) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-D")) {
            debug_detected = true;
        } else {
            filtered_args[filtered_len] = arg;
            filtered_len += 1;
        }
    }
    
    try std.testing.expect(!debug_detected);
    try std.testing.expectEqual(@as(usize, 2), filtered_len);
    try std.testing.expectEqualStrings("satibot", filtered_args[0]);
    try std.testing.expectEqualStrings("status", filtered_args[1]);
}

test "Main: multiple debug flags" {
    const allocator = std.testing.allocator;
    
    // Test multiple debug flags (should only set debug once)
    const args_with_multiple_debug = &[_][]const u8{ "satibot", "--debug", "-D", "status" };
    
    var debug_detected = false;
    var filtered_len: usize = 0;
    var filtered_args = try allocator.alloc([]const u8, args_with_multiple_debug.len);
    defer allocator.free(filtered_args);
    
    // Simulate the debug flag parsing logic
    for (args_with_multiple_debug) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-D")) {
            debug_detected = true;
        } else {
            filtered_args[filtered_len] = arg;
            filtered_len += 1;
        }
    }
    
    try std.testing.expect(debug_detected);
    try std.testing.expectEqual(@as(usize, 2), filtered_len);
    try std.testing.expectEqualStrings("satibot", filtered_args[0]);
    try std.testing.expectEqualStrings("status", filtered_args[1]);
}

test "Main: debug flag in middle of arguments" {
    const allocator = std.testing.allocator;
    
    // Test debug flag in middle of command
    const args_with_debug_middle = &[_][]const u8{ "satibot", "agent", "--debug", "-m", "hello" };
    
    var debug_detected = false;
    var filtered_len: usize = 0;
    var filtered_args = try allocator.alloc([]const u8, args_with_debug_middle.len);
    defer allocator.free(filtered_args);
    
    // Simulate the debug flag parsing logic
    for (args_with_debug_middle) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-D")) {
            debug_detected = true;
        } else {
            filtered_args[filtered_len] = arg;
            filtered_len += 1;
        }
    }
    
    try std.testing.expect(debug_detected);
    try std.testing.expectEqual(@as(usize, 4), filtered_len);
    try std.testing.expectEqualStrings("satibot", filtered_args[0]);
    try std.testing.expectEqualStrings("agent", filtered_args[1]);
    try std.testing.expectEqualStrings("-m", filtered_args[2]);
    try std.testing.expectEqualStrings("hello", filtered_args[3]);
}
