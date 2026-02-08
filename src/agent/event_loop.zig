/// Generic Async Event Loop using threads
/// Provides concurrent task processing with efficient scheduling
const std = @import("std");
const Config = @import("../config.zig").Config;

/// Event types that can be scheduled in the event loop
pub const EventType = enum {
    custom,
    shutdown,
};

/// An event with its execution time
pub const Event = struct {
    type: EventType,
    expires: i64,  // Using nanoseconds from std.time.nanoTimestamp()
    
    // Generic event data - can hold any type of payload
    payload: ?[]const u8 = null,
    
    fn compare(context: void, a: Event, b: Event) std.math.Order {
        _ = context;
        return std.math.order(a.expires, b.expires);
    }
};

/// Generic task structure for immediate processing
pub const Task = struct {
    id: []const u8,
    data: []const u8,
    source: []const u8,
    timestamp: i64,
};

/// Global event loop pointer for signal handler access
var global_event_loop: ?*AsyncEventLoop = null;

/// Global shutdown flag for signal handling
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Signal handler for SIGINT (Ctrl+C) and SIGTERM
/// Sets the global shutdown flag and requests event loop shutdown
fn signalHandler(sig: i32) callconv(.c) void {
    _ = sig;
    std.debug.print("\n🛑 Shutdown signal received, stopping event loop...\n", .{});
    shutdown_requested.store(true, .seq_cst);
    if (global_event_loop) |el| {
        el.requestShutdown();
    }
}

/// Callback function type for handling immediate tasks
pub const TaskHandler = *const fn (allocator: std.mem.Allocator, task: Task) anyerror!void;

/// Callback function type for handling scheduled events
pub const EventHandler = *const fn (allocator: std.mem.Allocator, event: Event) anyerror!void;

/// Event Loop using threads for concurrent processing
pub const AsyncEventLoop = struct {
    allocator: std.mem.Allocator,
    config: Config,
    
    // Thread-safe task queue for immediate processing
    task_queue: std.ArrayList(Task),
    // Mutex for thread-safe access to task queue
    task_mutex: std.Thread.Mutex,
    // Condition variable for task queue
    task_condition: std.Thread.Condition,
    
    // Priority queue for scheduled events
    event_queue: std.PriorityQueue(Event, void, Event.compare),
    
    // Event queue mutex for thread safety
    event_mutex: std.Thread.Mutex,

    // Handlers
    task_handler: ?TaskHandler,
    event_handler: ?EventHandler,

    // Shutdown flag
    shutdown: std.atomic.Value(bool),
    
    // Worker threads
    worker_threads: std.ArrayList(std.Thread),
    
    // Generic offset tracking for polling APIs (atomic for thread safety)
    offset: std.atomic.Value(i64),

    pub fn init(allocator: std.mem.Allocator, config: Config) !AsyncEventLoop {
        const event_loop = AsyncEventLoop{
            .allocator = allocator,
            .config = config,
            .task_queue = std.ArrayList(Task).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .task_mutex = .{},
            .task_condition = .{},
            .event_queue = std.PriorityQueue(Event, void, Event.compare).init(allocator, {}),
            .event_mutex = .{},
            .task_handler = null,
            .event_handler = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .worker_threads = std.ArrayList(std.Thread).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .offset = std.atomic.Value(i64).init(0),
        };
        return event_loop;
    }

    /// Set task handler callback
    pub fn setTaskHandler(self: *AsyncEventLoop, handler: TaskHandler) void {
        self.task_handler = handler;
    }

    /// Set event handler callback
    pub fn setEventHandler(self: *AsyncEventLoop, handler: EventHandler) void {
        self.event_handler = handler;
    }

    /// Get current offset for polling
    pub fn getOffset(self: *AsyncEventLoop) i64 {
        return self.offset.load(.seq_cst);
    }

    /// Update offset for polling (thread-safe)
    pub fn updateOffset(self: *AsyncEventLoop, new_offset: i64) void {
        // Use atomic compare-and-swap to ensure thread safety
        _ = self.offset.fetchMax(new_offset, .seq_cst);
    }

    pub fn deinit(self: *AsyncEventLoop) void {
        std.debug.print("EventLoop deinit: Starting shutdown...\n", .{});
        
        // Shutdown all worker threads
        self.shutdown.store(true, .seq_cst);
        self.task_condition.broadcast();
        std.debug.print("EventLoop deinit: Shutdown flag set, broadcasting to workers\n", .{});
        
        // Wait for all threads to finish
        for (self.worker_threads.items) |thread| {
            thread.join();
        }
        std.debug.print("EventLoop deinit: All worker threads joined\n", .{});
        self.worker_threads.deinit(self.allocator);
        
        // Free remaining tasks
        self.task_mutex.lock();
        for (self.task_queue.items) |task| {
            self.allocator.free(task.id);
            self.allocator.free(task.data);
            self.allocator.free(task.source);
        }
        self.task_queue.deinit(self.allocator);
        self.task_mutex.unlock();
        
        // Free any remaining events
        self.event_mutex.lock();
        while (self.event_queue.removeOrNull()) |event| {
            if (event.payload) |payload| {
                self.allocator.free(payload);
            }
        }
        self.event_queue.deinit();
        self.event_mutex.unlock();
    }

    /// Schedule a custom event to be executed at a specific time
    pub fn scheduleEvent(self: *AsyncEventLoop, payload: ?[]const u8, delay_ms: u64) !void {
        const event = Event{
            .type = .custom,
            .expires = std.time.nanoTimestamp() + (@as(i64, @intCast(delay_ms)) * std.time.ns_per_ms),
            .payload = if (payload) |p| try self.allocator.dupe(u8, p) else null,
        };
        
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        try self.event_queue.add(event);
    }

    /// Schedule shutdown event
    fn scheduleShutdown(self: *AsyncEventLoop, delay_ms: u64) !void {
        const event = Event{
            .type = .shutdown,
            .expires = std.time.nanoTimestamp() + (@as(i64, @intCast(delay_ms)) * std.time.ns_per_ms),
        };
        
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        try self.event_queue.add(event);
    }

    /// Add a task to be processed immediately (thread-safe)
    pub fn addTask(self: *AsyncEventLoop, id: []const u8, data: []const u8, source: []const u8) !void {
        const task = Task{
            .id = try self.allocator.dupe(u8, id),
            .data = try self.allocator.dupe(u8, data),
            .source = try self.allocator.dupe(u8, source),
            .timestamp = @intCast(std.time.nanoTimestamp()),
        };
        
        self.task_mutex.lock();
        defer self.task_mutex.unlock();
        
        try self.task_queue.append(self.allocator, task);
        self.task_condition.signal();
    }


    /// Worker thread function for processing tasks
    fn taskWorker(self: *AsyncEventLoop) void {
        const thread_id = std.Thread.getCurrentId();
        std.debug.print("Worker thread {d} started\n", .{thread_id});
        
        while (!self.shutdown.load(.seq_cst)) {
            self.task_mutex.lock();
            
            // Wait for tasks or shutdown
            while (self.task_queue.items.len == 0 and !self.shutdown.load(.seq_cst)) {
                self.task_condition.wait(&self.task_mutex);
            }
            
            if (self.shutdown.load(.seq_cst)) {
                self.task_mutex.unlock();
                break;
            }
            
            // Get next task
            const task = self.task_queue.orderedRemove(0);
            std.debug.print("Worker {d}: Got task {s} from {s}\n", .{ thread_id, task.id, task.source });
            self.task_mutex.unlock();
            
            // Process task
            self.processTask(task);
        }
        
        std.debug.print("Worker thread {d} shutting down\n", .{thread_id});
    }




    /// Process a single task using the registered handler
    fn processTask(self: *AsyncEventLoop, task: Task) void {
        defer {
            // Free allocated memory
            self.allocator.free(task.id);
            self.allocator.free(task.data);
            self.allocator.free(task.source);
        }
        
        if (self.task_handler) |handler| {
            handler(self.allocator, task) catch |err| {
                std.debug.print("Error processing task from {s}: {any}\n", .{ task.source, err });
            };
        } else {
            std.debug.print("[Task {s}] {s}: {s}\n", .{ task.id, task.source, task.data });
        }
    }

    /// Main event loop runner (in main thread)
    fn eventLoopRunner(self: *AsyncEventLoop) void {
        // Start worker threads for task processing
        const num_workers = @max(1, std.Thread.getCpuCount() catch 1);
        
        for (0..num_workers) |_| {
            const worker = std.Thread.spawn(.{}, struct {
                fn run(ctx: *AsyncEventLoop) void {
                    ctx.taskWorker();
                }
            }.run, .{self}) catch |err| {
                std.debug.print("Failed to spawn worker thread: {any}\n", .{err});
                continue;
            };
            
            self.worker_threads.append(self.allocator, worker) catch |err| {
                std.debug.print("Failed to track worker thread: {any}\n", .{err});
                worker.detach();
            };
        }
        
        // Main thread handles scheduled events
        while (!self.shutdown.load(.seq_cst)) {
            // Check for scheduled events
            self.event_mutex.lock();
            const next_event = self.event_queue.peek();
            self.event_mutex.unlock();
            
            if (next_event) |event| {
                const now = std.time.nanoTimestamp();
                
                if (now < event.expires) {
                    // Sleep until the next event is due, but check shutdown periodically
                    const delay_ms = @as(u64, @intCast(@divTrunc(event.expires - now, std.time.ns_per_ms)));
                    const sleep_chunks = @max(1, delay_ms / 10); // Check every 10ms max
                    const chunk_delay = delay_ms / sleep_chunks;
                    
                    for (0..sleep_chunks) |_| {
                        if (self.shutdown.load(.seq_cst)) break;
                        std.Thread.sleep(chunk_delay * std.time.ns_per_ms);
                    }
                    
                    if (self.shutdown.load(.seq_cst)) break;
                }
                
                // Remove and process the event
                self.event_mutex.lock();
                const ready_event = self.event_queue.removeOrNull().?;
                self.event_mutex.unlock();
                
                // Handle event based on type
                switch (ready_event.type) {
                    .custom => {
                        if (self.event_handler) |handler| {
                            handler(self.allocator, ready_event) catch |err| {
                                std.debug.print("Error handling custom event: {any}\n", .{err});
                            };
                        } else {
                            if (ready_event.payload) |payload| {
                                std.debug.print("[Custom Event] {s}\n", .{payload});
                            }
                        }
                        
                        // Free event payload
                        if (ready_event.payload) |payload| {
                            self.allocator.free(payload);
                        }
                    },
                    .shutdown => {
                        break;
                    },
                }
            } else {
                // No events, short sleep to prevent CPU spinning
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
        
        std.debug.print("EventLoop: Main event loop exiting\n", .{});
    }

    /// Start the event loop
    pub fn run(self: *AsyncEventLoop) !void {
        std.debug.print("🚀 Async Event Loop started\n", .{});
        
        // Set up signal handlers
        global_event_loop = self;
        _ = std.posix.sigaction(std.posix.SIG.INT, &.{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        _ = std.posix.sigaction(std.posix.SIG.TERM, &.{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        
        // Start the event loop
        self.eventLoopRunner();
        
        // Clean shutdown
        std.debug.print("🛑 Event loop stopped\n", .{});
    }

    /// Request graceful shutdown
    pub fn requestShutdown(self: *AsyncEventLoop) void {
        self.shutdown.store(true, .seq_cst);
        
        // Wake up all worker threads
        self.task_condition.broadcast();
        
        std.debug.print("Shutdown requested\n", .{});
    }
};
