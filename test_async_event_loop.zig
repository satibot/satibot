const std = @import("std");
const testing = std.testing;

// Import test modules
const event_loop_tests = @import("src/agent/event_loop_test.zig");
const async_gateway_tests = @import("src/agent/async_gateway_test.zig");

pub fn main() !void {
    // Print test header
    std.debug.print("=== Async Event Loop Unit Tests ===\n\n", .{});
    
    // Run all event loop tests
    std.debug.print("Running Event Loop Tests:\n", .{});
    try runEventLoopTests();
    
    std.debug.print("\nRunning Async Gateway Tests:\n", .{});
    try runAsyncGatewayTests();
    
    std.debug.print("\n✅ All tests passed!\n", .{});
}

fn runEventLoopTests() !void {
    // Note: In a real test runner, we would use reflection or a test framework
    // to automatically discover and run tests. For now, we'll list them manually.
    
    const tests = [_]struct {
        name: []const u8,
        ptr: *const fn () anyerror!void,
    }{
        .{ .name = "AsyncEventLoop.init", .ptr = testAsyncEventLoopInit },
        .{ .name = "AsyncEventLoop.addChatMessage", .ptr = testAsyncEventLoopAddChatMessage },
        .{ .name = "AsyncEventLoop.addCronJob", .ptr = testAsyncEventLoopAddCronJob },
        .{ .name = "AsyncEventLoop.scheduleEvent", .ptr = testAsyncEventLoopScheduleEvent },
        .{ .name = "AsyncEventLoop.scheduleCronExecution", .ptr = testAsyncEventLoopScheduleCronExecution },
        .{ .name = "nanoTime", .ptr = testNanoTime },
        .{ .name = "AsyncEventLoop.messageProcessing", .ptr = testAsyncEventLoopMessageProcessing },
        .{ .name = "AsyncEventLoop.cronNextRun", .ptr = testAsyncEventLoopCronNextRun },
        .{ .name = "AsyncEventLoop.shutdown", .ptr = testAsyncEventLoopShutdown },
        .{ .name = "AsyncEventLoop.concurrentMessages", .ptr = testAsyncEventLoopConcurrentMessages },
        .{ .name = "AsyncEventLoop.errorHandling", .ptr = testAsyncEventLoopErrorHandling },
        .{ .name = "AsyncEventLoop.integration", .ptr = testAsyncEventLoopIntegration },
    };
    
    for (tests) |test| {
        std.debug.print("  - {s}... ", .{test.name});
        test.ptr() catch |err| {
            std.debug.print("❌ FAILED: {any}\n", .{err});
            return err;
        };
        std.debug.print("✅ PASSED\n", .{});
    }
}

fn runAsyncGatewayTests() !void {
    const tests = [_]struct {
        name: []const u8,
        ptr: *const fn () anyerror!void,
    }{
        .{ .name = "AsyncGateway.init", .ptr = testAsyncGatewayInit },
        .{ .name = "AsyncGateway.initWithoutTelegram", .ptr = testAsyncGatewayInitWithoutTelegram },
        .{ .name = "AsyncGateway.handleCommand", .ptr = testAsyncGatewayHandleCommand },
        .{ .name = "AsyncGateway.handleVoiceMessage", .ptr = testAsyncGatewayHandleVoiceMessage },
        .{ .name = "AsyncGateway.loadCronJobs", .ptr = testAsyncGatewayLoadCronJobs },
        .{ .name = "AsyncGateway.telegramPoller", .ptr = testAsyncGatewayTelegramPoller },
        .{ .name = "AsyncGateway.messageFlow", .ptr = testAsyncGatewayMessageFlow },
        .{ .name = "AsyncGateway.pollTelegramUpdatesErrors", .ptr = testAsyncGatewayPollTelegramUpdatesErrors },
        .{ .name = "AsyncGateway.concurrentOperations", .ptr = testAsyncGatewayConcurrentOperations },
        .{ .name = "AsyncGateway.shutdown", .ptr = testAsyncGatewayShutdown },
        .{ .name = "AsyncGateway.integration", .ptr = testAsyncGatewayIntegration },
    };
    
    for (tests) |test| {
        std.debug.print("  - {s}... ", .{test.name});
        test.ptr() catch |err| {
            std.debug.print("❌ FAILED: {any}\n", .{err});
            return err;
        };
        std.debug.print("✅ PASSED\n", .{});
    }
}

// Wrapper functions for event loop tests
fn testAsyncEventLoopInit() !void {
    return event_loop_tests.testAsyncEventLoop.init();
}

fn testAsyncEventLoopAddChatMessage() !void {
    return event_loop_tests.testAsyncEventLoop.addChatMessage();
}

fn testAsyncEventLoopAddCronJob() !void {
    return event_loop_tests.testAsyncEventLoop.addCronJob();
}

fn testAsyncEventLoopScheduleEvent() !void {
    return event_loop_tests.testAsyncEventLoop.scheduleEvent();
}

fn testAsyncEventLoopScheduleCronExecution() !void {
    return event_loop_tests.testAsyncEventLoop.scheduleCronExecution();
}

fn testNanoTime() !void {
    return event_loop_tests.testNanoTime();
}

fn testAsyncEventLoopMessageProcessing() !void {
    return event_loop_tests.testAsyncEventLoop.messageProcessing();
}

fn testAsyncEventLoopCronNextRun() !void {
    return event_loop_tests.testAsyncEventLoop.cronNextRun();
}

fn testAsyncEventLoopShutdown() !void {
    return event_loop_tests.testAsyncEventLoop.shutdown();
}

fn testAsyncEventLoopConcurrentMessages() !void {
    return event_loop_tests.testAsyncEventLoop.concurrentMessages();
}

fn testAsyncEventLoopErrorHandling() !void {
    return event_loop_tests.testAsyncEventLoop.errorHandling();
}

fn testAsyncEventLoopIntegration() !void {
    return event_loop_tests.testAsyncEventLoop.integration();
}

// Wrapper functions for async gateway tests
fn testAsyncGatewayInit() !void {
    return async_gateway_tests.testAsyncGateway.init();
}

fn testAsyncGatewayInitWithoutTelegram() !void {
    return async_gateway_tests.testAsyncGateway.initWithoutTelegram();
}

fn testAsyncGatewayHandleCommand() !void {
    return async_gateway_tests.testAsyncGateway.handleCommand();
}

fn testAsyncGatewayHandleVoiceMessage() !void {
    return async_gateway_tests.testAsyncGateway.handleVoiceMessage();
}

fn testAsyncGatewayLoadCronJobs() !void {
    return async_gateway_tests.testAsyncGateway.loadCronJobs();
}

fn testAsyncGatewayTelegramPoller() !void {
    return async_gateway_tests.testAsyncGateway.telegramPoller();
}

fn testAsyncGatewayMessageFlow() !void {
    return async_gateway_tests.testAsyncGateway.messageFlow();
}

fn testAsyncGatewayPollTelegramUpdatesErrors() !void {
    return async_gateway_tests.testAsyncGateway.pollTelegramUpdatesErrors();
}

fn testAsyncGatewayConcurrentOperations() !void {
    return async_gateway_tests.testAsyncGateway.concurrentOperations();
}

fn testAsyncGatewayShutdown() !void {
    return async_gateway_tests.testAsyncGateway.shutdown();
}

fn testAsyncGatewayIntegration() !void {
    return async_gateway_tests.testAsyncGateway.integration();
}
