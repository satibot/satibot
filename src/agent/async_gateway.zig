/// Async Gateway that uses the event loop for efficient management of multiple ChatIDs and cron jobs.
/// This replaces the synchronous polling approach with async/await for better scalability.
const std = @import("std");
const Config = @import("../config.zig").Config;
const AsyncEventLoop = @import("event_loop.zig").AsyncEventLoop;
const TelegramBot = @import("telegram_bot.zig").TelegramBot;
const http = @import("../http.zig");

/// Async Gateway with event-driven architecture
pub const AsyncGateway = struct {
    allocator: std.mem.Allocator,
    config: Config,
    event_loop: AsyncEventLoop,
    telegram_bot: ?TelegramBot = null,
    
    pub fn init(allocator: std.mem.Allocator, config: Config) !AsyncGateway {
        var event_loop = try AsyncEventLoop.init(allocator, config);
        
        const telegram_bot = if (config.tools.telegram != null) 
            try TelegramBot.init(allocator, config) 
        else 
            null;
        
        return .{
            .allocator = allocator,
            .config = config,
            .event_loop = event_loop,
            .telegram_bot = telegram_bot,
        };
    }
    
    pub fn deinit(self: *AsyncGateway) void {
        if (self.telegram_bot) |*bot| bot.deinit();
        self.event_loop.deinit();
    }
    
    /// Run the async gateway
    pub fn run(self: *AsyncGateway) !void {
        std.debug.print("🐸 Async Gateway started\n", .{});
        if (self.telegram_bot != null) std.debug.print("✅ Telegram bot enabled (async mode)\n", .{});
        
        // Start Telegram polling in async task
        if (self.telegram_bot) |*bot| {
            _ = async self.telegramPoller(bot);
        }
        
        // Load initial cron jobs
        try self.loadCronJobs();
        
        // Run the main event loop
        try self.event_loop.run();
    }
    
    /// Async Telegram poller that fetches messages and adds them to the event loop
    fn telegramPoller(self: *AsyncGateway, bot: *TelegramBot) void {
        const tg_config = self.config.tools.telegram orelse return;
        
        while (!self.event_loop.shutdown.load(.seq_cst)) {
            // Non-blocking poll with timeout
            self.pollTelegramUpdates(bot, tg_config.botToken) catch |err| {
                std.debug.print("Telegram poll error: {any}\n", .{err});
                // Wait before retry on error
                std.Thread.sleep(std.time.ns_per_s * 5);
            };
            
            // Small delay between polls
            std.Thread.sleep(std.time.ns_per_ms * 100);
        }
    }
    
    /// Poll Telegram for updates and add messages to event loop
    fn pollTelegramUpdates(self: *AsyncGateway, bot: *TelegramBot, token: []const u8) !void {
        // Use bot's offset for proper message tracking
        const url = try std.fmt.allocPrint(
            self.allocator,
            "https://api.telegram.org/bot{s}/getUpdates?offset={d}&timeout=1",
            .{ token, bot.offset }
        );
        defer self.allocator.free(url);
        
        const response = try bot.client.get(url, &.{});
        defer @constCast(&response).deinit();
        
        const UpdateResponse = struct {
            ok: bool,
            result: []struct {
                update_id: i64,
                message: ?struct {
                    chat: struct { id: i64 },
                    text: ?[]const u8 = null,
                    voice: ?struct { file_id: []const u8 } = null,
                } = null,
            },
        };
        
        const parsed = try std.json.parseFromSlice(
            UpdateResponse,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        defer parsed.deinit();
        
        for (parsed.value.result) |update| {
            bot.offset = update.update_id + 1;
            
            if (update.message) |msg| {
                if (msg.text) |text| {
                    // Handle commands
                    if (std.mem.startsWith(u8, text, "/")) {
                        try self.handleCommand(msg.chat.id, text);
                    } else {
                        // Add message to event loop for async processing
                        try self.event_loop.addChatMessage(msg.chat.id, text);
                    }
                } else if (msg.voice) |voice| {
                    // Handle voice messages asynchronously
                    _ = async self.handleVoiceMessage(bot, msg.chat.id, voice.file_id, token);
                }
            }
        }
    }
    
    /// Handle voice message transcription asynchronously
    fn handleVoiceMessage(self: *AsyncGateway, bot: *TelegramBot, chat_id: i64, file_id: []const u8, token: []const u8) void {
        // Add small delay for async demonstration
        std.Thread.sleep(std.time.ns_per_ms * 100);
        
        if (self.config.providers.groq) |groq_cfg| {
            // Get file path
            const file_info_url = try std.fmt.allocPrint(
                self.allocator,
                "https://api.telegram.org/bot{s}/getFile?file_id={s}",
                .{ token, file_id }
            );
            defer self.allocator.free(file_info_url);
            
            const file_info_resp = bot.client.get(file_info_url, &.{}) catch |err| {
                std.debug.print("Error getting file info: {any}\n", .{err});
                return;
            };
            defer @constCast(&file_info_resp).deinit();
            
            const FileInfo = struct {
                ok: bool,
                result: ?struct { file_path: []const u8 } = null,
            };
            
            const parsed_file_info = std.json.parseFromSlice(
                FileInfo,
                self.allocator,
                file_info_resp.body,
                .{ .ignore_unknown_fields = true }
            ) catch |err| {
                std.debug.print("Error parsing file info: {any}\n", .{err});
                return;
            };
            defer parsed_file_info.deinit();
            
            if (parsed_file_info.value.result) |res| {
                // Download and transcribe
                const download_url = try std.fmt.allocPrint(
                    self.allocator,
                    "https://api.telegram.org/file/bot{s}/{s}",
                    .{ token, res.file_path }
                );
                defer self.allocator.free(download_url);
                
                const file_data_resp = bot.client.get(download_url, &.{}) catch |err| {
                    std.debug.print("Error downloading file: {any}\n", .{err});
                    return;
                };
                defer @constCast(&file_data_resp).deinit();
                
                // Transcribe
                var groq = @import("../root.zig").providers.groq.GroqProvider.init(
                    self.allocator,
                    groq_cfg.apiKey
                ) catch |err| {
                    std.debug.print("Error initializing Groq: {any}\n", .{err});
                    return;
                };
                defer groq.deinit();
                
                const transcribed = groq.transcribe(file_data_resp.body, "voice.ogg") catch |err| {
                    std.debug.print("Transcription error: {any}\n", .{err});
                    return;
                };
                defer self.allocator.free(transcribed);
                
                // Add transcribed text to event loop
                self.event_loop.addChatMessage(chat_id, transcribed) catch |err| {
                    std.debug.print("Error adding transcribed message: {any}\n", .{err});
                };
            }
        } else {
            // Send error message about missing Groq config
            const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{chat_id});
            defer self.allocator.free(chat_id_str);
            
            bot.send_message(token, chat_id_str, "🎤 Voice received but transcription not configured") catch {};
        }
    }
    
    /// Handle special commands
    fn handleCommand(self: *AsyncGateway, chat_id: i64, text: []const u8) !void {
        if (std.mem.startsWith(u8, text, "/help")) {
            const help = 
                \\🐸 Async SatiBot Commands:
                \\
                \\/help - Show this help
                \\/new - Clear conversation
                \\/status - Show bot status
                \\
                \\All other messages are processed asynchronously!
            ;
            
            if (self.telegram_bot) |bot| {
                const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{chat_id});
                defer self.allocator.free(chat_id_str);
                
                bot.send_message(
                    self.config.tools.telegram.?.botToken,
                    chat_id_str,
                    help
                ) catch {};
            }
        } else if (std.mem.startsWith(u8, text, "/status")) {
            const status = try std.fmt.allocPrint(
                self.allocator,
                "📊 Bot Status:\n" ++
                "Active chats: {d}\n" ++
                "Cron jobs: {d}\n" ++
                "Event loop: Running\n",
                .{ 
                    self.event_loop.active_chats.items.len,
                    self.event_loop.cron_jobs.count()
                }
            );
            defer self.allocator.free(status);
            
            if (self.telegram_bot) |bot| {
                const chat_id_str = try std.fmt.allocPrint(self.allocator, "{d}", .{chat_id});
                defer self.allocator.free(chat_id_str);
                
                bot.send_message(
                    self.config.tools.telegram.?.botToken,
                    chat_id_str,
                    status
                ) catch {};
            }
        } else {
            // Treat other commands as regular messages
            const trimmed = std.mem.trimLeft(u8, text[1..], " ");
            try self.event_loop.addChatMessage(chat_id, trimmed);
        }
    }
    
    /// Load cron jobs from storage and add them to event loop
    fn loadCronJobs(self: *AsyncGateway) !void {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const cron_path = try std.fs.path.join(
            self.allocator,
            &.{ home, ".bots", "cron_jobs.json" }
        );
        defer self.allocator.free(cron_path);
        
        const file = std.fs.openFileAbsolute(cron_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("No cron jobs file found, starting with empty schedule\n", .{});
                return;
            }
            return err;
        };
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 10485760);
        defer self.allocator.free(content);
        
        const CronData = struct {
            jobs: []struct {
                id: []const u8,
                name: []const u8,
                enabled: bool,
                schedule: struct {
                    kind: []const u8,
                    at_ms: ?i64 = null,
                    every_ms: ?i64 = null,
                },
                payload: struct {
                    message: []const u8,
                    deliver: bool = false,
                    channel: ?[]const u8 = null,
                    to: ?[]const u8 = null,
                },
            },
        };
        
        const parsed = std.json.parseFromSlice(
            CronData,
            self.allocator,
            content,
            .{ .ignore_unknown_fields = true }
        ) catch |err| {
            std.debug.print("Error parsing cron jobs: {any}\n", .{err});
            return;
        };
        defer parsed.deinit();
        
        for (parsed.value.jobs) |job| {
            const schedule_kind = if (std.mem.eql(u8, job.schedule.kind, "at"))
                .at
            else if (std.mem.eql(u8, job.schedule.kind, "every"))
                .every
            else
                continue;
            
            try self.event_loop.addCronJob(
                job.id,
                job.name,
                job.payload.message,
                .{
                    .kind = schedule_kind,
                    .at_ms = job.schedule.at_ms,
                    .every_ms = job.schedule.every_ms,
                }
            );
        }
        
        std.debug.print("Loaded {d} cron jobs\n", .{parsed.value.jobs.len});
    }
    
    /// Request graceful shutdown
    pub fn shutdown(self: *AsyncGateway) void {
        std.debug.print("🛑 Shutting down Async Gateway...\n", .{});
        self.event_loop.shutdown();
    }
};

// Example usage
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Load config (simplified for example)
    const config = Config{
        .agents = .{ .defaults = .{ .model = "test-model" } },
        .providers = .{},
        .tools = .{},
    };
    
    var gateway = try AsyncGateway.init(allocator, config);
    defer gateway.deinit();
    
    // Setup signal handlers for graceful shutdown
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = struct {
            fn handler(sig: i32) callconv(.c) void {
                _ = sig;
                // Would set a global shutdown flag
            }
        }.handler },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    
    try gateway.run();
}
