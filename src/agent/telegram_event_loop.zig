/// Async Event Loop for managing Telegram bot operations efficiently.
/// Based on Zig's async/await pattern with priority queues for timed events.
const std = @import("std");
const Config = @import("../config.zig").Config;
const Agent = @import("../agent.zig").Agent;
const providers = @import("../root.zig").providers;
const base = @import("providers/base.zig");
const tools = @import("agent/tools.zig");
const session = @import("agent/session.zig");
const http = @import("../http.zig");

/// Get monotonic time for accurate timing
var timer: ?std.time.Timer = null;
fn nanoTime() u64 {
    if (timer == null) {
        timer = std.time.Timer.start() catch unreachable;
    }
    return timer.?.read();
}

/// Event types that can be scheduled in the event loop
pub const EventType = enum {
    message,
    cron_job,
    heartbeat,
    shutdown,
};

/// An event with its execution time and frame
const Event = struct {
    type: EventType,
    expires: u64,
    frame: anyframe,

    // Event-specific data
    chat_id: ?i64 = null,
    message: ?[]const u8 = null,
    cron_id: ?[]const u8 = null,

    fn compare(context: void, a: Event, b: Event) std.math.Order {
        _ = context;
        return std.math.order(a.expires, b.expires);
    }
};

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

/// Async Event Loop that manages all bot operations
pub const TelegramEventLoop = struct {
    allocator: std.mem.Allocator,
    config: Config,
    bot_token: []const u8,
    message_sender: MessageSender,

    // Priority queue for timed events
    event_queue: std.PriorityQueue(Event, void, Event.compare),

    // Chat message queue (immediate processing)
    message_queue: std.ArrayList(ChatMessage),
    message_mutex: std.Thread.Mutex,

    // Cron jobs storage
    cron_jobs: std.StringHashMap(CronJobEvent),
    cron_mutex: std.Thread.Mutex,

    // Shutdown flag
    shutdown: std.atomic.Value(bool),

    // Active chat tracking
    active_chats: std.ArrayList(i64),
    chats_mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: Config, bot_token: []const u8, message_sender: MessageSender) !TelegramEventLoop {
        return .{
            .allocator = allocator,
            .config = config,
            .bot_token = bot_token,
            .message_sender = message_sender,
            .event_queue = std.PriorityQueue(Event, void, Event.compare).init(allocator, undefined),
            .message_queue = std.ArrayList(ChatMessage).init(allocator),
            .message_mutex = .{},
            .cron_jobs = std.StringHashMap(CronJobEvent).init(allocator),
            .cron_mutex = .{},
            .shutdown = std.atomic.Value(bool).init(false),
            .active_chats = std.ArrayList(i64).init(allocator),
            .chats_mutex = .{},
        };
    }

    pub fn deinit(self: *TelegramEventLoop) void {
        self.event_queue.deinit();
        self.message_queue.deinit();

        // Free cron jobs
        var cron_iter = self.cron_jobs.iterator();
        while (cron_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.id);
            self.allocator.free(entry.value_ptr.*.name);
            self.allocator.free(entry.value_ptr.*.message);
        }
        self.cron_jobs.deinit();

        self.active_chats.deinit();
    }

    /// Schedule an event to be executed at a specific time
    fn scheduleEvent(self: *TelegramEventLoop, event_type: EventType, delay_ms: u64, frame: anyframe) !void {
        const event = Event{
            .type = event_type,
            .expires = nanoTime() + (delay_ms * std.time.ns_per_ms),
            .frame = frame,
        };
        try self.event_queue.add(event);
    }

    /// Add a chat message to be processed immediately
    pub fn addChatMessage(self: *TelegramEventLoop, chat_id: i64, text: []const u8) !void {
        const session_id = try std.fmt.allocPrint(self.allocator, "tg_{d}", .{chat_id});

        self.message_mutex.lock();
        defer self.message_mutex.unlock();

        try self.message_queue.append(.{
            .chat_id = chat_id,
            .text = try self.allocator.dupe(u8, text),
            .session_id = session_id,
            .timestamp = nanoTime(),
        });

        // Track active chat
        self.chats_mutex.lock();
        defer self.chats_mutex.unlock();

        // Check if already tracked
        for (self.active_chats.items) |id| {
            if (id == chat_id) return;
        }
        try self.active_chats.append(chat_id);
    }

    /// Add or update a cron job
    pub fn addCronJob(self: *TelegramEventLoop, id: []const u8, name: []const u8, message: []const u8, schedule: anytype) !void {
        const cron_id = try self.allocator.dupe(u8, id);
        const cron_name = try self.allocator.dupe(u8, name);
        const cron_message = try self.allocator.dupe(u8, message);

        const now = nanoTime() / std.time.ns_per_ms;
        const next_run = switch (schedule.kind) {
            .every => now + (schedule.every_ms orelse 0),
            .at => @as(u64, @intCast(schedule.at_ms orelse now)),
        };

        const job = CronJobEvent{
            .id = try self.allocator.dupe(u8, cron_id),
            .name = cron_name,
            .message = cron_message,
            .schedule = schedule,
            .next_run = next_run,
        };

        self.cron_mutex.lock();
        defer self.cron_mutex.unlock();

        try self.cron_jobs.put(cron_id, job);
    }

    /// Suspend current frame until specified time passes
    fn waitForTime(self: *TelegramEventLoop, delay_ms: u64) void {
        suspend {
            self.scheduleEvent(.message, delay_ms, @frame()) catch unreachable;
        }
    }

    /// Process a single chat message asynchronously
    fn processChatMessage(self: *TelegramEventLoop, chat_id: i64, text: []const u8, session_id: []const u8) void {
        std.debug.print("[Chat {d}] Processing: {s}\n", .{ chat_id, text });

        var agent = Agent.init(self.allocator, self.config, session_id);
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

    /// Process a cron job asynchronously
    fn processCronJob(self: *TelegramEventLoop, job: CronJobEvent) void {
        std.debug.print("[Cron {s}] Running job: {s}\n", .{ job.id, job.name });

        const session_id = std.fmt.allocPrint(self.allocator, "cron_{s}", .{job.id}) catch |err| {
            std.debug.print("Error allocating session_id: {any}\n", .{err});
            return;
        };
        defer self.allocator.free(session_id);

        var agent = Agent.init(self.allocator, self.config, session_id);
        defer agent.deinit();

        agent.run(job.message) catch |err| {
            std.debug.print("[Cron {s}] Error: {any}\n", .{ job.id, err });
        };

        // Schedule next run if it's a recurring job
        if (job.schedule.kind == .every) {
            const next_run = job.next_run + (job.schedule.every_ms orelse 0);
            var new_job = job;
            new_job.next_run = next_run;
            new_job.last_run = nanoTime() / std.time.ns_per_ms;

            self.cron_mutex.lock();
            defer self.cron_mutex.unlock();

            self.cron_jobs.put(job.id, new_job) catch |err| {
                std.debug.print("Error updating cron job: {any}\n", .{err});
                return;
            };

            // Schedule the next execution
            const delay_ms = next_run - (nanoTime() / std.time.ns_per_ms);
            self.scheduleCronExecution(job.id, delay_ms);
        }
    }

    /// Schedule a cron job execution
    fn scheduleCronExecution(self: *TelegramEventLoop, cron_id: []const u8, delay_ms: u64) void {
        self.waitForTime(@max(0, delay_ms));

        self.cron_mutex.lock();
        const job = self.cron_jobs.get(cron_id);
        self.cron_mutex.unlock();

        if (job) |j| {
            if (j.enabled) {
                self.processCronJob(j);
            }
        }
    }

    /// Heartbeat check task
    fn heartbeatTask(self: *TelegramEventLoop) void {
        while (!self.shutdown.load(.seq_cst)) {
            self.waitForTime(30 * 60 * 1000); // 30 minutes

            if (self.shutdown.load(.seq_cst)) break;

            std.debug.print("[Heartbeat] Checking system health...\n", .{});

            // Could check system health, send notifications, etc.
            const session_id = "heartbeat";
            var agent = Agent.init(self.allocator, self.config, session_id);
            defer agent.deinit();

            agent.run("Check system health and report any issues") catch |err| {
                std.debug.print("[Heartbeat] Error: {any}\n", .{err});
            };
        }
    }

    /// Main event loop runner
    fn eventLoopRunner(self: *TelegramEventLoop) void {
        // Start heartbeat task
        const heartbeat_frame = async self.heartbeatTask();
        _ = heartbeat_frame;

        // Schedule initial cron jobs
        self.cron_mutex.lock();
        var cron_iter = self.cron_jobs.iterator();
        while (cron_iter.next()) |entry| {
            const job = entry.value_ptr.*;
            const delay_ms = job.next_run - (nanoTime() / std.time.ns_per_ms);
            const cron_frame = async self.scheduleCronExecution(job.id, @max(0, delay_ms));
            _ = cron_frame;
        }
        self.cron_mutex.unlock();

        // Main event loop
        while (!self.shutdown.load(.seq_cst)) {
            // Process immediate messages first
            self.message_mutex.lock();
            if (self.message_queue.items.len > 0) {
                const msg = self.message_queue.orderedRemove(0);
                self.message_mutex.unlock();

                // Process message asynchronously
                const msg_frame = async self.processChatMessage(msg.chat_id, msg.text, msg.session_id);
                _ = msg_frame;

                // Free allocated memory
                self.allocator.free(msg.text);
                self.allocator.free(msg.session_id);
                continue;
            }
            self.message_mutex.unlock();

            // Process timed events
            if (self.event_queue.removeOrNull()) |event| {
                const now = nanoTime();
                if (now < event.expires) {
                    // Sleep until event is due
                    std.time.sleep(event.expires - now);
                }

                // Resume the suspended frame
                resume event.frame;
            } else {
                // No events, small sleep to prevent CPU spinning
                std.Thread.sleep(std.time.ns_per_ms * 10);
            }
        }
    }

    /// Start the event loop
    pub fn run(self: *TelegramEventLoop) !void {
        std.debug.print("🚀 Telegram Event Loop started\n", .{});

        // Load cron jobs from storage if needed
        try self.loadCronJobs();

        // Start the main event loop
        var main_task = async self.eventLoopRunner();

        // Wait for shutdown
        while (!self.shutdown.load(.seq_cst)) {
            std.Thread.sleep(std.time.ns_per_s * 1);
        }

        // Clean shutdown
        nosuspend await main_task;
        std.debug.print("🛑 Event loop stopped\n", .{});
    }

    /// Request graceful shutdown
    pub fn shutdown(self: *TelegramEventLoop) void {
        self.shutdown.store(true, .seq_cst);

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
    fn loadCronJobs(self: *TelegramEventLoop) !void {
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
