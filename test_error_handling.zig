const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

test "proper error handling for initCapacity" {
    const allocator = std.testing.allocator;
    
    // This should work without panicking
    const list = std.ArrayList(u32).initCapacity(allocator, 10) catch |err| {
        // Properly handle the error instead of unreachable
        std.debug.print("Failed to initialize list: {}\n", .{err});
        return err;
    };
    defer list.deinit();
    
    // Verify the list works
    try list.append(42);
    try expect(list.items.len == 1);
    try expect(list.items[0] == 42);
}

test "function should propagate errors correctly" {
    const allocator = std.testing.allocator;
    
    const MyStruct = struct {
        list: std.ArrayList(u32),
        
        pub fn init(allocator: Allocator) !@This() {
            return @This(){
                .list = std.ArrayList(u32).initCapacity(allocator, 10) catch return error.OutOfMemory,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.list.deinit();
        }
    };
    
    // This should work without panicking
    var my_struct = try MyStruct.init(allocator);
    defer my_struct.deinit();
    
    try my_struct.list.append(100);
    try expect(my_struct.list.items[0] == 100);
}

test "demonstrate the wrong way" {
    const allocator = std.testing.allocator;
    
    // This is what NOT to do - commented out to avoid panic
    // const bad_list = std.ArrayList(u32).initCapacity(allocator, 0) catch unreachable;
    
    // Instead, do this:
    const good_list = std.ArrayList(u32).initCapacity(allocator, 0) catch {
        // Handle the error gracefully
        return error.OutOfMemory;
    };
    defer good_list.deinit();
    
    // The list should still work even with 0 initial capacity
    try good_list.append(1);
    try expect(good_list.items.len == 1);
}
