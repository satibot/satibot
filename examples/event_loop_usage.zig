/// Example usage of the Async Event Loop
/// Demonstrates how to use the event loop for various scenarios
const std = @import("std");
const event_loop = @import("src/agent/event_loop.zig");

// Example config (in real usage, load from file)
const config = event_loop.Config{
    .agents = .{ .defaults = .{ .model = "test-model" } },
    .providers = .{},
    .tools = .{},
};

/// Example 1: Simple task processing
pub fn simpleTaskExample() !void {
    const allocator = std.heap.page_allocator;
    
    var loop = try event_loop.AsyncEventLoop.init(allocator, config);
    defer loop.deinit();
    
    // Set up task handler
    loop.setTaskHandler(struct {
        fn handler(allocator: std.mem.Allocator, task: event_loop.Task) !void {
            std.debug.print("Processing task: {s} from {s}\n", .{ task.id, task.source });
            
            // Simulate processing time
            std.Thread.sleep(100 * std.time.ns_per_ms);
            
            std.debug.print("Completed task: {s}\n", .{task.id});
        }
    }.handler);
    
    // Add some tasks
    try loop.addTask("task_1", "Process user input", "ui");
    try loop.addTask("task_2", "Handle API request", "api");
    try loop.addTask("task_3", "Send notification", "notification");
    
    // Run for 5 seconds then shutdown
    const shutdown_thread = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) void {
            std.Thread.sleep(5 * std.time.ns_per_s);
            event_loop.requestShutdown();
        }
    }.run, .{&loop});
    shutdown_thread.detach();
    
    try loop.run();
}

/// Example 2: Event scheduling
pub fn scheduledEventExample() !void {
    const allocator = std.heap.page_allocator;
    
    var loop = try event_loop.AsyncEventLoop.init(allocator, config);
    defer loop.deinit();
    
    // Set up event handler
    loop.setEventHandler(struct {
        fn handler(allocator: std.mem.Allocator, event: event_loop.Event) !void {
            if (event.payload) |payload| {
                std.debug.print("Scheduled event triggered: {s}\n", .{payload});
            }
        }
    }.handler);
    
    // Schedule events at different times
    try loop.scheduleEvent("Reminder: Take break", 2 * 1000); // 2 seconds
    try loop.scheduleEvent("Check email", 4 * 1000); // 4 seconds
    try loop.scheduleEvent("Daily backup", 6 * 1000); // 6 seconds
    
    // Run for 8 seconds then shutdown
    const shutdown_thread = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) void {
            std.Thread.sleep(8 * std.time.ns_per_s);
            event_loop.requestShutdown();
        }
    }.run, .{&loop});
    shutdown_thread.detach();
    
    try loop.run();
}

/// Example 3: Mixed tasks and events
pub fn mixedExample() !void {
    const allocator = std.heap.page_allocator;
    
    var loop = try event_loop.AsyncEventLoop.init(allocator, config);
    defer loop.deinit();
    
    // Task handler for immediate processing
    loop.setTaskHandler(struct {
        fn handler(allocator: std.mem.Allocator, task: event_loop.Task) !void {
            if (std.mem.eql(u8, task.source, "http_api")) {
                std.debug.print("🌐 Processing API request: {s}\n", .{task.data});
                
                // Parse JSON and respond
                const response = try std.fmt.allocPrint(allocator, 
                    "{{\"status\":\"ok\",\"processed\":\"{s}\"}}", .{task.data});
                defer allocator.free(response);
                
                std.debug.print("📤 API Response: {s}\n", .{response});
            } else if (std.mem.eql(u8, task.source, "websocket")) {
                std.debug.print("🔌 WebSocket message: {s}\n", .{task.data});
            } else {
                std.debug.print("📝 Task from {s}: {s}\n", .{ task.source, task.data });
            }
        }
    }.handler);
    
    // Event handler for scheduled operations
    loop.setEventHandler(struct {
        fn handler(allocator: std.mem.Allocator, event: event_loop.Event) !void {
            if (event.payload) |payload| {
                std.debug.print("⏰ Scheduled event: {s}\n", .{payload});
                
                // Could trigger other tasks based on events
                if (std.mem.startsWith(u8, payload, "reminder")) {
                    // Send reminder notification
                    std.debug.print("🔔 Sending reminder notification\n");
                }
            }
        }
    }.handler);
    
    // Simulate external API requests
    const api_simulator = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) !void {
            var i: u32 = 0;
            while (i < 3) : (i += 1) {
                std.Thread.sleep(1500 * std.time.ns_per_ms);
                
                const request_data = try std.fmt.allocPrint(
                    event_loop.allocator, 
                    "{{\"action\":\"process\",\"id\":{d}}}", 
                    .{i}
                );
                defer event_loop.allocator.free(request_data);
                
                try event_loop.addTask("api_req", request_data, "http_api");
            }
        }
    }.run, .{&loop});
    api_simulator.detach();
    
    // Simulate WebSocket messages
    const ws_simulator = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) !void {
            var i: u32 = 0;
            while (i < 2) : (i += 1) {
                std.Thread.sleep(2000 * std.time.ns_per_ms);
                
                const message = try std.fmt.allocPrint(
                    event_loop.allocator, 
                    "WebSocket message {d}", 
                    .{i}
                );
                defer event_loop.allocator.free(message);
                
                try event_loop.addTask("ws_msg", message, "websocket");
            }
        }
    }.run, .{&loop});
    ws_simulator.detach();
    
    // Schedule periodic events
    try loop.scheduleEvent("System health check", 3 * 1000);
    try loop.scheduleEvent("reminder: Check notifications", 5 * 1000);
    try loop.scheduleEvent("Cleanup temporary files", 7 * 1000);
    
    // Run for 10 seconds then shutdown
    const shutdown_thread = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) void {
            std.Thread.sleep(10 * std.time.ns_per_s);
            event_loop.requestShutdown();
        }
    }.run, .{&loop});
    shutdown_thread.detach();
    
    try loop.run();
}

/// Example 4: Real-world bot integration pattern
pub fn botIntegrationExample() !void {
    const allocator = std.heap.page_allocator;
    
    var loop = try event_loop.AsyncEventLoop.init(allocator, config);
    defer loop.deinit();
    
    // Task handler for bot messages
    loop.setTaskHandler(struct {
        fn handler(allocator: std.mem.Allocator, task: event_loop.Task) !void {
            if (std.mem.eql(u8, task.source, "telegram")) {
                std.debug.print("🤖 Telegram message: {s}\n", .{task.data});
                
                // Process with AI agent
                const response = try processWithAgent(allocator, task.data);
                defer allocator.free(response);
                
                std.debug.print("💬 Bot response: {s}\n", .{response});
                
                // In real implementation, send response back to Telegram
                // sendTelegramMessage(task.chat_id, response);
                
            } else if (std.mem.eql(u8, task.source, "discord")) {
                std.debug.print("🎮 Discord message: {s}\n", .{task.data});
                // Handle Discord messages
                
            } else if (std.mem.eql(u8, task.source, "api")) {
                std.debug.print("🌐 API request: {s}\n", .{task.data});
                // Handle HTTP API requests
            }
        }
        
        fn processWithAgent(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
            // Simulate AI processing
            return try std.fmt.allocPrint(allocator, 
                "I understand you said: {s}", .{message});
        }
    }.handler);
    
    // Event handler for bot maintenance
    loop.setEventHandler(struct {
        fn handler(allocator: std.mem.Allocator, event: event_loop.Event) !void {
            if (event.payload) |payload| {
                std.debug.print("🔧 Bot maintenance: {s}\n", .{payload});
                
                if (std.mem.startsWith(u8, payload, "backup")) {
                    // Perform bot data backup
                    std.debug.print("💾 Backing up bot data...\n");
                } else if (std.mem.startsWith(u8, payload, "cleanup")) {
                    // Clean up old data
                    std.debug.print("🧹 Cleaning up old data...\n");
                }
            }
        }
    }.handler);
    
    // Simulate incoming messages from different platforms
    const message_simulator = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) !void {
            const messages = [_][]const u8{
                "Hello bot!",
                "How are you?",
                "Tell me a joke",
                "What's the weather?",
            };
            
            const sources = [_][]const u8{ "telegram", "discord", "api" };
            
            var i: u32 = 0;
            while (i < messages.len) : (i += 1) {
                std.Thread.sleep(1000 * std.time.ns_per_ms);
                
                const source = sources[i % sources.len];
                const message = messages[i];
                
                try event_loop.addTask(
                    try std.fmt.allocPrint(event_loop.allocator, "msg_{d}", .{i}),
                    message,
                    source
                );
            }
        }
    }.run, .{&loop});
    message_simulator.detach();
    
    // Schedule maintenance tasks
    try loop.scheduleEvent("backup user data", 3 * 1000);
    try loop.scheduleEvent("cleanup old sessions", 6 * 1000);
    try loop.scheduleEvent("update bot status", 8 * 1000);
    
    // Run for 12 seconds then shutdown
    const shutdown_thread = try std.Thread.spawn(.{}, struct {
        fn run(event_loop: *event_loop.AsyncEventLoop) void {
            std.Thread.sleep(12 * std.time.ns_per_s);
            event_loop.requestShutdown();
        }
    }.run, .{&loop});
    shutdown_thread.detach();
    
    try loop.run();
}

/// Main function to run all examples
pub fn main() !void {
    std.debug.print("=== Async Event Loop Examples ===\n\n");
    
    std.debug.print("1. Simple Task Processing:\n");
    try simpleTaskExample();
    
    std.debug.print("\n2. Scheduled Events:\n");
    try scheduledEventExample();
    
    std.debug.print("\n3. Mixed Tasks and Events:\n");
    try mixedExample();
    
    std.debug.print("\n4. Bot Integration Pattern:\n");
    try botIntegrationExample();
    
    std.debug.print("\n=== All Examples Completed ===\n");
}
