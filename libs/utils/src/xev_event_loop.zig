const std = @import("std");
const xev = @import("xev");
pub const Config = @import("core").config.Config;

/// Task structure for work items
pub const Task = struct {
    id: []const u8,
    data: []const u8,
    source: []const u8,

    /// Free all heap-allocated fields
    pub fn deinit(self: Task, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.data);
        allocator.free(self.source);
    }
};

/// Event structure for scheduled events
pub const Event = struct {
    id: []const u8,
    type: EventType,
    payload: ?[]const u8,
    expires: i64,

    pub fn compare(_: void, a: Event, b: Event) std.math.Order {
        return std.math.order(a.expires, b.expires);
    }

    /// Free all heap-allocated fields
    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.payload) |p| {
            allocator.free(p);
        }
    }
};

pub const EventType = enum {
    custom,
    shutdown,
};

/// Callback function type for handling tasks
pub const TaskHandler = *const fn (allocator: std.mem.Allocator, task: Task) anyerror!void;

/// Callback function type for handling scheduled events
pub const EventHandler = *const fn (allocator: std.mem.Allocator, event: Event) anyerror!void;

/// Event Loop using lib-xev for high-performance async I/O
pub const XevEventLoop = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // lib-xev loop
    loop: xev.Loop,

    // Thread-safe task queue for immediate processing
    task_queue: std.ArrayList(Task),
    // Mutex for thread-safe access to task queue
    task_mutex: std.Thread.Mutex,
    // Condition variable for task queue
    task_condition: std.Thread.Condition,
    // Counter for pending tasks (atomic for lock-free checking)
    pending_tasks: std.atomic.Value(usize),

    // Priority queue for scheduled events
    event_queue: std.PriorityQueue(Event, void, Event.compare),
    // Mutex for thread-safe access to event queue
    event_mutex: std.Thread.Mutex,

    // Callback handlers
    task_handler: ?TaskHandler,
    event_handler: ?EventHandler,

    // Shutdown flag
    shutdown: std.atomic.Value(bool),

    // Worker threads
    worker_threads: std.ArrayList(std.Thread),

    // Generic offset tracking for polling APIs (atomic for thread safety)
    offset: std.atomic.Value(i64),

    // Timer for scheduled events
    timer: xev.Timer,
    timer_completion: xev.Completion,

    pub fn init(allocator: std.mem.Allocator, config: Config) !XevEventLoop {
        // Initialize lib-xev loop
        const loop = try xev.Loop.init(.{});
        const timer = try xev.Timer.init();

        const event_loop: XevEventLoop = .{
            .allocator = allocator,
            .config = config,
            .loop = loop,
            .task_queue = std.ArrayList(Task).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .task_mutex = .{},
            .task_condition = .{},
            .pending_tasks = std.atomic.Value(usize).init(0),
            .event_queue = std.PriorityQueue(Event, void, Event.compare).init(allocator, {}),
            .event_mutex = .{},
            .task_handler = null,
            .event_handler = null,
            .shutdown = std.atomic.Value(bool).init(false),
            .worker_threads = std.ArrayList(std.Thread).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .offset = std.atomic.Value(i64).init(0),
            .timer = timer,
            .timer_completion = undefined,
        };

        return event_loop;
    }

    /// Set task handler callback
    pub fn setTaskHandler(self: *XevEventLoop, handler: TaskHandler) void {
        self.task_handler = handler;
    }

    /// Set event handler callback
    pub fn setEventHandler(self: *XevEventLoop, handler: EventHandler) void {
        self.event_handler = handler;
    }

    /// Add a task to the queue for immediate processing
    pub fn addTask(self: *XevEventLoop, id: []const u8, data: []const u8, source: []const u8) !void {
        const task: Task = .{
            .id = try self.allocator.dupe(u8, id),
            .data = try self.allocator.dupe(u8, data),
            .source = try self.allocator.dupe(u8, source),
        };

        self.task_mutex.lock();
        defer self.task_mutex.unlock();

        try self.task_queue.append(self.allocator, task);
        _ = self.pending_tasks.fetchAdd(1, .seq_cst);
        self.task_condition.signal();
    }

    /// Schedule an event for future execution
    pub fn scheduleEvent(self: *XevEventLoop, id: []const u8, event_type: EventType, payload: ?[]const u8, delay_ms: u64) !void {
        const expires = std.time.nanoTimestamp() + (@as(i64, @intCast(delay_ms)) * std.time.ns_per_ms);

        var event_payload: ?[]const u8 = null;
        if (payload) |p| {
            event_payload = try self.allocator.dupe(u8, p);
        }

        const event: Event = .{
            .id = try self.allocator.dupe(u8, id),
            .type = event_type,
            .payload = event_payload,
            .expires = @intCast(expires),
        };

        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        try self.event_queue.add(event);
    }

    /// Get the current offset value
    pub fn getOffset(self: *XevEventLoop) i64 {
        return self.offset.load(.seq_cst);
    }

    /// Update the offset value
    pub fn updateOffset(self: *XevEventLoop, new_offset: i64) void {
        self.offset.store(new_offset, .seq_cst);
    }

    /// Process all pending tasks in the queue
    fn processPendingTasks(self: *XevEventLoop) void {
        var processed: usize = 0;
        while (self.pending_tasks.load(.seq_cst) > 0) {
            self.task_mutex.lock();
            if (self.task_queue.items.len == 0) {
                self.task_mutex.unlock();
                if (processed > 0) {
                    std.debug.print("Processed {d} tasks\n", .{processed});
                }
                break;
            }

            const task = self.task_queue.orderedRemove(0);
            _ = self.pending_tasks.fetchSub(1, .seq_cst);
            self.task_mutex.unlock();

            // Process task
            if (self.task_handler) |handler| {
                handler(self.allocator, task) catch |err| {
                    std.debug.print("Error processing task from {s}: {any}\n", .{ task.source, err });
                };
            } else {
                std.debug.print("[Task {s}] {s}: {s}\n", .{ task.id, task.source, task.data });
            }

            // Free task memory using deinit method
            task.deinit(self.allocator);
            processed += 1;
        }
    }

    /// Worker thread function
    fn workerThreadFn(self: *XevEventLoop, thread_id: usize) void {
        while (!self.shutdown.load(.seq_cst)) {
            self.task_mutex.lock();
            while (self.task_queue.items.len == 0 and !self.shutdown.load(.seq_cst)) {
                self.task_condition.wait(&self.task_mutex);
            }

            if (self.shutdown.load(.seq_cst)) {
                self.task_mutex.unlock();
                break;
            }

            const task = self.task_queue.orderedRemove(0);
            _ = self.pending_tasks.fetchSub(1, .seq_cst);
            self.task_mutex.unlock();

            // Process task
            if (self.task_handler) |handler| {
                handler(self.allocator, task) catch |err| {
                    std.debug.print("[Thread {d}] Error processing task from {s}: {any}\n", .{ thread_id, task.source, err });
                };
            } else {
                std.debug.print("[Thread {d}] Task {s} from {s}: {s}\n", .{ thread_id, task.id, task.source, task.data });
            }

            // Free task memory using deinit method
            task.deinit(self.allocator);
        }
    }

    /// Run the event loop
    pub fn run(self: *XevEventLoop) !void {
        // Start worker threads with reduced stack size (512KB instead of 16MB default)
        const num_workers = 4; // Default number of workers
        for (0..num_workers) |i| {
            const thread = try std.Thread.spawn(.{
                .stack_size = 524288, // 512KB stack = 512 * 1024
            }, workerThreadFn, .{ self, i });
            try self.worker_threads.append(self.allocator, thread);
        }
        defer {
            // Stop all worker threads
            self.shutdown.store(true, .seq_cst);
            self.task_condition.broadcast();
            for (self.worker_threads.items) |thread| {
                thread.join();
            }
        }

        // Main event loop - run continuously without blocking
        while (!self.shutdown.load(.seq_cst)) {
            // Process any pending tasks
            self.processPendingTasks();

            // Check for scheduled events
            const now = std.time.nanoTimestamp();
            if (self.event_queue.peek()) |next_event| {
                if (next_event.expires <= now) {
                    // Event is due, remove and process it
                    self.event_mutex.lock();
                    const event = self.event_queue.remove();
                    self.event_mutex.unlock();

                    if (self.event_handler) |handler| {
                        handler(self.allocator, event) catch |err| {
                            std.debug.print("Error processing event {s}: {any}\n", .{ event.id, err });
                        };
                    }

                    // Free event memory using deinit method
                    event.deinit(self.allocator);
                } else {
                    // Calculate dynamic delay based on next event timing
                    const delay_ns = next_event.expires - now;
                    const delay_ms: u32 = @max(1, @min(100, @as(u32, @intCast(@divTrunc(delay_ns, std.time.ns_per_ms))))); // Clamp between 1-100ms

                    self.timer.run(&self.loop, &self.timer_completion, delay_ms * std.time.ns_per_ms, XevEventLoop, self, timerCallback);

                    // Run the loop with a single iteration
                    self.loop.run(.once) catch |err| {
                        std.debug.print("Event loop error: {any}\n", .{err});
                    };
                }
            } else {
                // No events, just sleep briefly
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
        }
    }

    /// Timer callback for processing scheduled events
    fn timerCallback(userdata: ?*XevEventLoop, loop: *xev.Loop, completion: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
        _ = loop;
        _ = completion;
        const self = userdata orelse return .disarm;
        result catch |err| {
            std.debug.print("Timer error: {any}\n", .{err});
            return .disarm;
        };

        // Process any due events
        const now = std.time.nanoTimestamp();
        while (self.event_queue.peek()) |event| {
            if (event.expires <= now) {
                self.event_mutex.lock();
                const due_event = self.event_queue.remove();
                self.event_mutex.unlock();

                if (self.event_handler) |handler| {
                    handler(self.allocator, due_event) catch |err| {
                        std.debug.print("Error processing event {s}: {any}\n", .{ due_event.id, err });
                    };
                }

                // Free event memory using deinit method
                due_event.deinit(self.allocator);
            } else {
                break;
            }
        }

        return .disarm;
    }

    /// Request shutdown of the event loop
    pub fn requestShutdown(self: *XevEventLoop) void {
        self.shutdown.store(true, .seq_cst);
        self.task_condition.broadcast();
    }

    /// Clean up resources
    pub fn deinit(self: *XevEventLoop) void {
        // Free remaining tasks
        self.task_mutex.lock();
        for (self.task_queue.items) |task| {
            task.deinit(self.allocator);
        }
        self.task_queue.deinit(self.allocator);
        self.task_mutex.unlock();

        // Free remaining events
        self.event_mutex.lock();
        while (self.event_queue.removeOrNull()) |event| {
            event.deinit(self.allocator);
        }
        self.event_queue.deinit();
        self.event_mutex.unlock();

        // Clean up worker threads
        self.worker_threads.deinit(self.allocator);

        // Deinitialize libxev resources
        self.timer.deinit();
        self.loop.deinit();

        self.* = undefined;
    }
};
