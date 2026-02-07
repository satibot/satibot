# Testing Guide

## Overview

This document describes the testing strategy for the Async Event Loop implementation in SatiBot.

## Test Structure

### Unit Tests

#### Event Loop Tests (`src/agent/event_loop_test.zig`)

Tests for the core `AsyncEventLoop` functionality:

1. **Initialization Tests**
   - `AsyncEventLoop.init` - Verifies proper initialization
   - Checks initial state of all internal data structures

2. **Message Handling Tests**
   - `AsyncEventLoop.addChatMessage` - Tests message queuing and chat tracking
   - `AsyncEventLoop.messageProcessing` - Verifies FIFO ordering
   - `AsyncEventLoop.concurrentMessages` - Tests thread safety

3. **Cron Job Tests**
   - `AsyncEventLoop.addCronJob` - Tests job creation and scheduling
   - `AsyncEventLoop.cronNextRun` - Verifies next run calculation
   - `AsyncEventLoop.scheduleCronExecution` - Tests async scheduling

4. **Event Scheduling Tests**
   - `AsyncEventLoop.scheduleEvent` - Tests priority queue operations
   - `AsyncEventLoop.shutdown` - Verifies graceful shutdown

5. **Utility Tests**
   - `nanoTime` - Tests monotonic time function
   - `AsyncEventLoop.errorHandling` - Tests error scenarios

#### Async Gateway Tests (`src/agent/async_gateway_test.zig`)

Tests for the `AsyncGateway` that integrates the event loop with bot services:

1. **Initialization Tests**
   - `AsyncGateway.init` - With and without Telegram
   - Service initialization verification

2. **Command Handling Tests**
   - `AsyncGateway.handleCommand` - Tests /help, /status, /new commands
   - Command routing and processing

3. **Message Processing Tests**
   - `AsyncGateway.messageFlow` - End-to-end message flow
   - `AsyncGateway.handleVoiceMessage` - Voice message handling

4. **Integration Tests**
   - `AsyncGateway.loadCronJobs` - Cron job persistence
   - `AsyncGateway.telegramPoller` - Polling simulation
   - `AsyncGateway.concurrentOperations` - Thread safety

## Running Tests

### Using Zig Test

```bash
# Run all tests
zig test src/agent/event_loop_test.zig

# Run with verbose output
zig test src/agent/event_loop_test.zig --test-no-exec

# Run specific test
zig test src/agent/event_loop_test.zig --test-filter "AsyncEventLoop.init"
```

### Using Test Runner

```bash
# Run custom test runner
zig run test_async_event_loop.zig
```

### Using Build System

```bash
# Run module tests
zig build test

# Run executable tests
zig build test-exe
```

## Test Coverage

### Core Components Covered

1. **AsyncEventLoop**
   - ✅ Initialization and cleanup
   - ✅ Message queuing and processing
   - ✅ Cron job management
   - ✅ Event scheduling
   - ✅ Thread safety
   - ✅ Error handling
   - ✅ Shutdown procedures

2. **AsyncGateway**
   - ✅ Initialization with/without services
   - ✅ Command handling
   - ✅ Message routing
   - ✅ Voice message processing
   - ✅ Cron job loading
   - ✅ Concurrent operations
   - ✅ Integration scenarios

### Test Scenarios

1. **Happy Path**
   - Normal message processing
   - Successful cron job execution
   - Proper initialization

2. **Edge Cases**
   - Empty messages
   - Duplicate chat IDs
   - Shutdown during operation
   - Concurrent access

3. **Error Conditions**
   - Network errors
   - Memory allocation failures
   - Invalid configurations

## Performance Testing

### Benchmarks

The test suite includes performance benchmarks for:

1. **Message Throughput**
   - Messages per second
   - Queue depth impact
   - Concurrent message handling

2. **Cron Job Performance**
   - Scheduling overhead
   - Job execution time
   - Memory usage

3. **Resource Utilization**
   - Memory allocation patterns
   - CPU usage under load
   - Thread contention

### Running Benchmarks

```bash
# Run with release mode for performance
zig test src/agent/event_loop_test.zig -Doptimize=ReleaseFast
```

## Mock Strategy

### Configuration Mock

```zig
fn createTestConfig() Config {
    return Config{
        .agents = .{ .defaults = .{ .model = "test-model" } },
        .providers = .{},
        .tools = .{},
    };
}
```

### Service Mocks

- **HTTP Client**: Mocked for API calls
- **Telegram Bot**: Mocked for message handling
- **Groq Provider**: Mocked for transcription

## Integration Testing

### End-to-End Scenarios

1. **Multi-Chat Processing**
   - Simulate messages from multiple chats
   - Verify concurrent processing
   - Check response ordering

2. **Cron Job Execution**
   - Schedule recurring jobs
   - Verify execution timing
   - Test job persistence

3. **Service Integration**
   - Telegram polling
   - Voice transcription
   - Command handling

## Test Data Management

### Fixtures

Common test data defined as constants:

```zig
const testMessages = [_]struct { id: i64, text: []const u8 }{
    .{ .id = 1001, .text = "Message 1" },
    .{ .id = 1002, .text = "Message 2" },
};
```

### Cleanup

All tests properly clean up:

```zig
defer {
    // Free allocated memory
    for (event_loop.message_queue.items) |msg| {
        allocator.free(msg.text);
        allocator.free(msg.session_id);
    }
    event_loop.deinit();
}
```

## Continuous Integration

### GitHub Actions

```yaml
name: Test Async Event Loop
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.2
      - run: zig test src/agent/event_loop_test.zig
      - run: zig test src/agent/async_gateway_test.zig
```

### Coverage Reports

```bash
# Generate coverage report
kcov --include-pattern=src/agent/ \
      target/coverage/ \
      zig test src/agent/event_loop_test.zig
```

## Debugging Tests

### Common Issues

1. **Async Test Timing**
   - Use `std.Thread.sleep` for timing
   - Avoid race conditions
   - Use proper synchronization

2. **Memory Leaks**
   - Check all allocations are freed
   - Use `defer` for cleanup
   - Run with sanitizers

3. **Thread Safety**
   - Use mutexes properly
   - Avoid deadlocks
   - Test with multiple threads

### Debug Commands

```bash
# Run with debug info
zig test src/agent/event_loop_test.zig -Ddebug

# Run with thread sanitizer
zig test src/agent/event_loop_test.zig -fsanitize=thread

# Run with address sanitizer
zig test src/agent/event_loop_test.zig -fsanitize=address
```

## Future Test Enhancements

1. **Property-Based Testing**
   - Use `zig-fuzz` for random inputs
   - Test invariants automatically

2. **Mock Framework**
   - Implement mocking utilities
   - Reduce test coupling

3. **Performance Regression**
   - Automated performance benchmarks
   - CI performance tracking

4. **Stress Testing**
   - High-load scenarios
   - Long-running stability tests

## Best Practices

1. **Test Isolation**
   - Each test independent
   - No shared state
   - Clean setup/teardown

2. **Clear Assertions**
   - Descriptive error messages
   - Check specific values
   - Use appropriate matchers

3. **Comprehensive Coverage**
   - Test all public APIs
   - Cover error paths
   - Include edge cases

4. **Maintainable Tests**
   - Simple and readable
   - Well-documented
   - Regularly updated
