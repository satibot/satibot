const std = @import("std");
const xev = @import("xev");
const satibot = @import("src/root.zig");

/// Test configuration
const TestConfig = struct {
    provider: []const u8,
    model: []const u8,
    message: []const u8,
};

/// Test result structure
const TestResult = struct {
    success: bool,
    response: ?[]const u8,
    error_msg: ?[]const u8,
    duration_ms: u64,
};

/// LLM Test using xev event loop
pub const LlmTester = struct {
    allocator: std.mem.Allocator,
    loop: xev.Loop,
    timer: xev.Timer,
    completion: xev.Completion,
    results: std.ArrayList(TestResult),
    config: satibot.config.Config,

    pub fn init(allocator: std.mem.Allocator) !LlmTester {
        const loop = try xev.Loop.init(.{});
        const timer = try xev.Timer.init();

        // Load configuration from ~/.bots/config.json
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const config_path = try std.fs.path.join(allocator, &.{ home, ".bots", "config.json" });
        defer allocator.free(config_path);

        const config_file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Config file not found at {s}\n", .{config_path});
                return err;
            },
            else => return err,
        };
        defer config_file.close();

        const config_content = try config_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(config_content);

        const parsed_config = try std.json.parseFromSlice(satibot.config.Config, allocator, config_content, .{});
        defer parsed_config.deinit();

        // Copy the API key to ensure it's valid
        var config = parsed_config.value;
        if (config.providers.openrouter) |*provider| {
            provider.apiKey = try allocator.dupe(u8, provider.apiKey);
        }
        if (config.providers.anthropic) |*provider| {
            provider.apiKey = try allocator.dupe(u8, provider.apiKey);
        }
        if (config.providers.groq) |*provider| {
            provider.apiKey = try allocator.dupe(u8, provider.apiKey);
        }

        return LlmTester{
            .allocator = allocator,
            .loop = loop,
            .timer = timer,
            .completion = undefined,
            .results = std.ArrayList(TestResult).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .config = config,
        };
    }

    pub fn deinit(self: *LlmTester) void {
        // Free copied API keys
        if (self.config.providers.openrouter) |provider| {
            self.allocator.free(provider.apiKey);
        }
        if (self.config.providers.anthropic) |provider| {
            self.allocator.free(provider.apiKey);
        }
        if (self.config.providers.groq) |provider| {
            self.allocator.free(provider.apiKey);
        }

        self.results.deinit(self.allocator);
        self.timer.deinit();
        self.loop.deinit();
    }

    /// Test OpenRouter provider
    pub fn testOpenRouter(self: *LlmTester, api_key: []const u8, model: []const u8, message: []const u8) !TestResult {
        const start_time = std.time.nanoTimestamp();

        var provider = try satibot.providers.openrouter.OpenRouterProvider.init(self.allocator, api_key);
        defer provider.deinit();

        const messages = &[_]satibot.providers.base.LLMMessage{
            .{ .role = "user", .content = message },
        };

        var response = try provider.chat(messages, model, null);
        defer response.deinit();

        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(u64, @intCast(@divTrunc(end_time - start_time, std.time.ns_per_ms)));

        return TestResult{
            .success = true,
            .response = try self.allocator.dupe(u8, response.content orelse "(no content)"),
            .error_msg = null,
            .duration_ms = duration_ms,
        };
    }

    /// Test Anthropic provider
    pub fn testAnthropic(self: *LlmTester, api_key: []const u8, model: []const u8, message: []const u8) !TestResult {
        const start_time = std.time.nanoTimestamp();

        var provider = try satibot.providers.anthropic.AnthropicProvider.init(self.allocator, api_key);
        defer provider.deinit();

        const messages = &[_]satibot.providers.base.LLMMessage{
            .{ .role = "user", .content = message },
        };

        var response = try provider.chat(messages, model, null);
        defer response.deinit();

        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(u64, @intCast(@divTrunc(end_time - start_time, std.time.ns_per_ms)));

        return TestResult{
            .success = true,
            .response = try self.allocator.dupe(u8, response.content orelse "(no content)"),
            .error_msg = null,
            .duration_ms = duration_ms,
        };
    }

    /// Test Groq provider
    pub fn testGroq(self: *LlmTester, api_key: []const u8, model: []const u8, message: []const u8) !TestResult {
        const start_time = std.time.nanoTimestamp();

        var provider = try satibot.providers.groq.GroqProvider.init(self.allocator, api_key);
        defer provider.deinit();

        const messages = &[_]satibot.providers.base.LLMMessage{
            .{ .role = "user", .content = message },
        };

        var response = try provider.chat(messages, model);
        defer response.deinit();

        const end_time = std.time.nanoTimestamp();
        const duration_ms = @as(u64, @intCast(@divTrunc(end_time - start_time, std.time.ns_per_ms)));

        return TestResult{
            .success = true,
            .response = try self.allocator.dupe(u8, response.content orelse "(no content)"),
            .error_msg = null,
            .duration_ms = duration_ms,
        };
    }

    /// Run tests asynchronously using xev
    pub fn runTestsAsync(self: *LlmTester, configs: []const TestConfig) !void {
        // For simplicity, run tests synchronously for now
        // TODO: Make truly async with xev
        for (configs) |config| {
            const test_result = self.runSingleTest(config) catch |err| TestResult{
                .success = false,
                .response = null,
                .error_msg = try self.allocator.dupe(u8, @errorName(err)),
                .duration_ms = 0,
            };

            try self.results.append(self.allocator, test_result);
        }
    }

    fn runSingleTest(self: *LlmTester, config: TestConfig) !TestResult {
        std.debug.print("Testing {s} with model {s}...\n", .{ config.provider, config.model });

        if (std.mem.eql(u8, config.provider, "openrouter")) {
            if (self.config.providers.openrouter) |provider_config| {
                std.debug.print("Using OpenRouter API key: {s}\n", .{provider_config.apiKey[0..@min(provider_config.apiKey.len, 20)]});
                return self.testOpenRouter(provider_config.apiKey, config.model, config.message);
            } else {
                return error.OpenRouterNotConfigured;
            }
        } else if (std.mem.eql(u8, config.provider, "anthropic")) {
            if (self.config.providers.anthropic) |provider_config| {
                return self.testAnthropic(provider_config.apiKey, config.model, config.message);
            } else {
                return error.AnthropicNotConfigured;
            }
        } else if (std.mem.eql(u8, config.provider, "groq")) {
            if (self.config.providers.groq) |provider_config| {
                return self.testGroq(provider_config.apiKey, config.model, config.message);
            } else {
                return error.GroqNotConfigured;
            }
        } else {
            return error.UnknownProvider;
        }
    }

    /// Print all test results
    pub fn printResults(self: *LlmTester) void {
        std.debug.print("\n=== LLM Test Results ===\n\n", .{});

        for (self.results.items, 0..) |result, i| {
            std.debug.print("Test {d}:\n", .{i + 1});
            std.debug.print("  Success: {s}\n", .{if (result.success) "✅" else "❌"});
            std.debug.print("  Duration: {d}ms\n", .{result.duration_ms});

            if (result.response) |response| {
                std.debug.print("  Response: {s}\n", .{response});
            }

            if (result.error_msg) |err| {
                std.debug.print("  Error: {s}\n", .{err});
            }

            std.debug.print("\n", .{});
        }

        // Calculate statistics
        var total_duration: u64 = 0;
        var success_count: usize = 0;

        for (self.results.items) |result| {
            total_duration += result.duration_ms;
            if (result.success) success_count += 1;
        }

        const avg_duration = if (self.results.items.len > 0) total_duration / self.results.items.len else 0;
        const success_rate = if (self.results.items.len > 0) @as(f64, @floatFromInt(success_count)) / @as(f64, @floatFromInt(self.results.items.len)) * 100.0 else 0.0;

        std.debug.print("=== Statistics ===\n", .{});
        std.debug.print("Total tests: {d}\n", .{self.results.items.len});
        std.debug.print("Success rate: {d:.1}%\n", .{success_rate});
        std.debug.print("Average duration: {d}ms\n", .{avg_duration});
        std.debug.print("Total duration: {d}ms\n", .{total_duration});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tester = try LlmTester.init(allocator);
    defer tester.deinit();

    // Define test configurations
    const test_configs = &[_]TestConfig{
        .{ .provider = "openrouter", .model = "openrouter/free", .message = "Say hello from Zig!" },
        .{ .provider = "openrouter", .model = "meta-llama/llama-3.2-3b-instruct:free", .message = "What is 2+2?" },
        .{ .provider = "anthropic", .model = "claude-3-haiku-20240307", .message = "Count to 5" },
        .{ .provider = "groq", .model = "llama-3.1-8b-instant", .message = "What is the capital of France?" },
    };

    std.debug.print("Running LLM tests with xev event loop...\n\n", .{});

    // Run tests asynchronously
    try tester.runTestsAsync(test_configs);

    // Print results
    tester.printResults();

    // Clean up response strings
    for (tester.results.items) |result| {
        if (result.response) |response| {
            allocator.free(response);
        }
        if (result.error_msg) |err| {
            allocator.free(err);
        }
    }
}
