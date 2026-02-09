const std = @import("std");
const providers = @import("../src/root.zig").providers;
const AsyncEventLoop = @import("../src/agent/event_loop.zig").AsyncEventLoop;
const Config = @import("../src/config.zig").Config;

/// Example demonstrating async OpenRouter provider usage with event loop
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Initialize event loop
    const config = Config{
        .agents = .{ .defaults = .{ .model = "openrouter:gpt-3.5-turbo" } },
        .providers = .{},
        .tools = .{},
    };
    
    var event_loop = try AsyncEventLoop.init(allocator, config);
    defer event_loop.deinit();
    
    // Initialize OpenRouter provider with event loop
    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse {
        std.debug.print("Please set OPENROUTER_API_KEY environment variable\n", .{});
        return error.MissingApiKey;
    };
    
    var provider = try providers.openrouter.OpenRouterProvider.initWithEventLoop(allocator, api_key, &event_loop);
    defer provider.deinit();
    
    // Set up task handler for the event loop
    event_loop.setTaskHandler(taskHandler);
    
    // Create a test task to make async request
    const task_data = try std.json.stringifyAlloc(allocator, .{
        .type = "openrouter_chat",
        .request_id = "test-123",
        .messages = &[_]providers.base.LLMMessage{
            .{ .role = "user", .content = "Hello! Please respond with a short greeting." },
        },
        .model = "openrouter:gpt-3.5-turbo",
    }, .{});
    defer allocator.free(task_data);
    
    // Add task to event loop
    try event_loop.addTask("test-123", task_data, "example");
    
    // Schedule shutdown after 10 seconds
    try event_loop.scheduleEvent(null, 10000);
    
    std.debug.print("Starting event loop with async OpenRouter example...\n", .{});
    
    // Run the event loop
    try event_loop.run();
    
    std.debug.print("Event loop completed\n", .{});
}

/// Task handler that processes OpenRouter requests
fn taskHandler(allocator: std.mem.Allocator, task: AsyncEventLoop.Task) !void {
    std.debug.print("Processing task: {s}\n", .{task.id});
    
    // Parse task data
    const parsed = try std.json.parseFromSlice(struct {
        type: []const u8,
        request_id: []const u8,
        messages: []providers.base.LLMMessage,
        model: []const u8,
    }, allocator, task.data, .{});
    defer parsed.deinit();
    
    if (std.mem.eql(u8, parsed.value.type, "openrouter_chat")) {
        // In a real implementation, you would:
        // 1. Create an OpenRouter provider with event loop
        // 2. Call chatAsync with a callback
        // 3. Handle the response in the callback
        
        // For demonstration, we'll simulate the async behavior
        std.debug.print("Would make async OpenRouter request {s} to model {s}\n", .{ parsed.value.request_id, parsed.value.model });
        
        // Simulate async response
        std.Thread.sleep(1 * std.time.ns_per_s);
        
        std.debug.print("Simulated response received for request {s}\n", .{parsed.value.request_id});
    } else {
        std.debug.print("Unknown task type: {s}\n", .{parsed.value.type});
    }
}
