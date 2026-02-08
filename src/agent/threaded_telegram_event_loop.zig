/// Thread-based Event Loop for managing Telegram bot operations efficiently.
/// Uses threads instead of async/await for Zig 0.15.2+ compatibility.
const std = @import("std");
const satibot = @import("../root.zig");

/// Get monotonic time for accurate timing
var timer: ?std.time.Timer = null;
fn nanoTime() u64 {
    if (timer == null) {
        timer = std.time.Timer.start() catch unreachable;
    }
    return timer.?.read();
}

/// Chat message structure
const ChatMessage = struct {
    chat_id: i64,
    text: []const u8,
    session_id: []const u8,
    timestamp: u64,
};

/// Cron job structure
const CronJobEvent = struct {
    id: []const u8,
    name: []const u8,
    message: []const u8,
    schedule: struct {
        kind: enum { at, every },
        at_ms: ?i64 = null,
        every_ms: ?i64 = null,
    },
    enabled: bool = true,
    last_run: ?u64 = null,
    next_run: u64,
};

/// Callback function type for sending messages to Telegram
const MessageSender = *const fn (allocator: std.mem.Allocator, bot_token: []const u8, chat_id: i64, text: []const u8) anyerror!void;

/// Thread-based Event Loop that manages all bot operations
pub const ThreadedTelegramEventLoop = struct {
    allocator: std.mem.Allocator,
    config: satibot.config.Config,
    bot_token: []const u8,
    message_sender: MessageSender,

    // Chat message queue (thread-safe)
    message_queue: std.ArrayList(ChatMessage),
    message_mutex: std.Thread.Mutex,
    message_cond: std.Thread.Condition,

    // Cron jobs storage (thread-safe)
    cron_jobs: std.StringHashMap(CronJobEvent),
    cron_mutex: std.Thread.Mutex,

    // Shutdown flag
    shutdown_flag: std.atomic.Value(bool),

    // Active chat tracking
    active_chats: std.ArrayList(i64),
    chats_mutex: std.Thread.Mutex,

    // Worker threads
    message_workers: []std.Thread,
    cron_thread: ?std.Thread,
    heartbeat_thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, config: satibot.config.Config, bot_token: []const u8, message_sender: MessageSender) !ThreadedTelegramEventLoop {
        return .{
            .allocator = allocator,
            .config = config,
            .bot_token = bot_token,
            .message_sender = message_sender,
            .message_queue = std.ArrayList(ChatMessage).initCapacity(allocator, 0) catch unreachable,
            .message_mutex = .{},
            .message_cond = .{},
            .cron_jobs = std.StringHashMap(CronJobEvent).init(allocator),
            .cron_mutex = .{},
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .active_chats = std.ArrayList(i64).initCapacity(allocator, 0) catch unreachable,
            .chats_mutex = .{},
            .message_workers = &[_]std.Thread{},
            .cron_thread = null,
            .heartbeat_thread = null,
        };
    }

    pub fn deinit(self: *ThreadedTelegramEventLoop) void {
        self.requestShutdown();
        
        // Wake up all waiting threads
        self.message_cond.broadcast();

        // Join all worker threads
        for (self.message_workers) |worker| {
            worker.join();
        }
        if (self.cron_thread) |thread| {
            thread.join();
        }
        if (self.heartbeat_thread) |thread| {
            thread.join();
        }

        self.message_queue.deinit(self.allocator);

        // Free cron jobs
        var cron_iter = self.cron_jobs.iterator();
        while (cron_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.id);
            self.allocator.free(entry.value_ptr.*.name);
            self.allocator.free(entry.value_ptr.*.message);
        }
        self.cron_jobs.deinit();

        self.active_chats.deinit(self.allocator);
    }

    /// Add a chat message to be processed
    pub fn addChatMessage(self: *ThreadedTelegramEventLoop, chat_id: i64, text: []const u8) !void {
        const session_id = try std.fmt.allocPrint(self.allocator, "tg_{d}", .{chat_id});

        self.message_mutex.lock();
        defer self.message_mutex.unlock();

        try self.message_queue.append(self.allocator, .{
            .chat_id = chat_id,
            .text = try self.allocator.dupe(u8, text),
            .session_id = session_id,
            .timestamp = nanoTime(),
        });

        // Wake up a worker thread
        self.message_cond.signal();

        // Track active chat
        self.chats_mutex.lock();
        defer self.chats_mutex.unlock();

        // Check if already tracked
        for (self.active_chats.items) |id| {
            if (id == chat_id) return;
        }
        try self.active_chats.append(self.allocator, chat_id);
    }

    /// Add or update a cron job
    pub fn addCronJob(self: *ThreadedTelegramEventLoop, id: []const u8, name: []const u8, message: []const u8, schedule: anytype) !void {
        const cron_id = try self.allocator.dupe(u8, id);
        const cron_name = try self.allocator.dupe(u8, name);
        const cron_message = try self.allocator.dupe(u8, message);

        const now = nanoTime() / std.time.ns_per_ms;
        const next_run = switch (schedule.kind) {
            .every => now + @as(u64, @intCast(schedule.every_ms orelse 0)),
            .at => @as(u64, @intCast(schedule.at_ms orelse @as(i64, @intCast(now)))),
        };

        const job = CronJobEvent{
            .id = try self.allocator.dupe(u8, cron_id),
            .name = cron_name,
            .message = cron_message,
            .schedule = .{
                .kind = @enumFromInt(@intFromEnum(schedule.kind)),
                .at_ms = schedule.at_ms,
                .every_ms = schedule.every_ms,
            },
            .next_run = next_run,
        };

        self.cron_mutex.lock();
        defer self.cron_mutex.unlock();

        try self.cron_jobs.put(cron_id, job);
    }

    /// Worker thread function for processing messages
    fn messageWorker(self: *ThreadedTelegramEventLoop) void {
        while (!self.shutdown_flag.load(.seq_cst)) {
            var msg: ?ChatMessage = null;

            // Get a message from the queue
            self.message_mutex.lock();
            while (self.message_queue.items.len == 0 and !self.shutdown_flag.load(.seq_cst)) {
                self.message_cond.wait(&self.message_mutex);
            }
            
            if (self.message_queue.items.len > 0) {
                msg = self.message_queue.orderedRemove(0);
            }
            self.message_mutex.unlock();

            // Process the message
            if (msg) |m| {
                self.processChatMessage(m.chat_id, m.text, m.session_id);
                
                // Free allocated memory
                self.allocator.free(m.text);
                self.allocator.free(m.session_id);
            }
        }
    }

    /// Process a single chat message
    fn processChatMessage(self: *ThreadedTelegramEventLoop, chat_id: i64, text: []const u8, session_id: []const u8) void {
        std.debug.print("[Chat {d}] Processing: {s}\n", .{ chat_id, text });

        var agent = satibot.agent.Agent.init(self.allocator, self.config, session_id);
        defer agent.deinit();

        agent.run(text) catch |err| {
            std.debug.print("Error processing message from chat {d}: {any}\n", .{ chat_id, err });
            return;
        };

        // Send response via Telegram
        const messages = agent.ctx.get_messages();
        if (messages.len > 0) {
            const last_msg = messages[messages.len - 1];
            if (last_msg.content) |content| {
                self.message_sender(self.allocator, self.bot_token, chat_id, content) catch |err| {
                    std.debug.print("Error sending response to chat {d}: {any}\n", .{ chat_id, err });
                };
            }
        }
    }

    /// Cron job thread function
    fn cronWorker(self: *ThreadedTelegramEventLoop) void {
        while (!self.shutdown_flag.load(.seq_cst)) {
            const now = nanoTime() / std.time.ns_per_ms;
            var next_job: ?CronJobEvent = null;
            var next_delay: u64 = 60000; // Default check every minute

            // Find next job to run
            self.cron_mutex.lock();
            var cron_iter = self.cron_jobs.iterator();
            while (cron_iter.next()) |entry| {
                const job = entry.value_ptr.*;
                if (job.enabled and job.next_run <= now) {
                    next_job = job;
                    break;
                } else if (job.enabled) {
                    const delay = job.next_run - now;
                    if (delay < next_delay) next_delay = delay;
                }
            }
            self.cron_mutex.unlock();

            // Run the job if found
            if (next_job) |job| {
                self.processCronJob(job);
            } else {
                // Sleep until next job or default timeout
                std.Thread.sleep(next_delay * std.time.ns_per_ms);
            }
        }
    }

    /// Process a cron job
    fn processCronJob(self: *ThreadedTelegramEventLoop, job: CronJobEvent) void {
        std.debug.print("[Cron {s}] Running job: {s}\n", .{ job.id, job.name });

        const session_id = std.fmt.allocPrint(self.allocator, "cron_{s}", .{job.id}) catch |err| {
            std.debug.print("Error allocating session_id: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(session_id);

        var agent = satibot.agent.Agent.init(self.allocator, self.config, session_id);
        defer agent.deinit();

        agent.run(job.message) catch |err| {
            std.debug.print("[Cron {s}] Error: {any}\n", .{ job.id, err });
        };

        // Schedule next run if it's a recurring job
        if (job.schedule.kind == .every) {
            const next_run = job.next_run + @as(u64, @intCast(job.schedule.every_ms orelse 0));
            var new_job = job;
            new_job.next_run = next_run;
            new_job.last_run = nanoTime() / std.time.ns_per_ms;

            self.cron_mutex.lock();
            defer self.cron_mutex.unlock();

            self.cron_jobs.put(job.id, new_job) catch |err| {
                std.debug.print("Error updating cron job: {any}\n", .{err});
                return;
            };
        }
    }

    /// Heartbeat thread function
    fn heartbeatWorker(self: *ThreadedTelegramEventLoop) void {
        while (!self.shutdown_flag.load(.seq_cst)) {
            std.Thread.sleep(30 * 60 * std.time.ns_per_ms); // 30 minutes

            if (self.shutdown_flag.load(.seq_cst)) break;

            std.debug.print("[Heartbeat] Checking system health...\n", .{});

            const session_id = "heartbeat";
            var agent = satibot.agent.Agent.init(self.allocator, self.config, session_id);
            defer agent.deinit();

            agent.run("Check system health and report any issues") catch |err| {
                std.debug.print("[Heartbeat] Error: {any}\n", .{err});
            };
        }
    }

    /// Start the event loop
    pub fn run(self: *ThreadedTelegramEventLoop) !void {
        std.debug.print("🚀 Threaded Telegram Event Loop started\n", .{});

        // Load cron jobs from storage if needed
        try self.loadCronJobs();

        // Start worker threads
        const num_workers = @min(4, std.Thread.getCpuCount() catch 1);
        self.message_workers = try self.allocator.alloc(std.Thread, num_workers);
        for (0..num_workers) |i| {
            self.message_workers[i] = try std.Thread.spawn(.{}, ThreadedTelegramEventLoop.messageWorker, .{self});
        }

        // Start cron worker
        self.cron_thread = try std.Thread.spawn(.{}, ThreadedTelegramEventLoop.cronWorker, .{self});

        // Start heartbeat worker
        self.heartbeat_thread = try std.Thread.spawn(.{}, ThreadedTelegramEventLoop.heartbeatWorker, .{self});

        // Wait for shutdown
        while (!self.shutdown_flag.load(.seq_cst)) {
            std.Thread.sleep(std.time.ns_per_s * 1);
        }

        std.debug.print("🛑 Event loop stopped\n", .{});
    }

    /// Request graceful shutdown
    pub fn requestShutdown(self: *ThreadedTelegramEventLoop) void {
        self.shutdown_flag.store(true, .seq_cst);

        // Send shutdown messages to active chats
        self.chats_mutex.lock();
        defer self.chats_mutex.unlock();

        std.debug.print("Sending shutdown to {d} active chats...\n", .{self.active_chats.items.len});
        for (self.active_chats.items) |chat_id| {
            self.message_sender(self.allocator, self.bot_token, chat_id, "👋 Bot is shutting down. Goodbye!") catch |err| {
                std.debug.print("Error sending shutdown message to chat {d}: {any}\n", .{ chat_id, err });
            };
        }
    }

    /// Load cron jobs from persistent storage
    fn loadCronJobs(self: *ThreadedTelegramEventLoop) !void {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const cron_path = try std.fs.path.join(self.allocator, &.{ home, ".bots", "cron_jobs.json" });
        defer self.allocator.free(cron_path);

        const file = std.fs.openFileAbsolute(cron_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10485760);
        defer self.allocator.free(content);

        // Parse and load cron jobs
        // Implementation would depend on your cron job format
        std.debug.print("Loaded {d} cron jobs\n", .{self.cron_jobs.count()});
    }
};
