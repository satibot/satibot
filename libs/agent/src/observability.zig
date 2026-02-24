const std = @import("std");

/// Represents an observable event in the agent's lifecycle.
/// Used for tracing, logging, and metrics collection during an agent's run.
pub const ObserverEvent = union(enum) {
    agent_start: struct { provider: []const u8, model: []const u8 },
    llm_request: struct { provider: []const u8, model: []const u8, messages_count: usize },
    llm_response: struct { provider: []const u8, model: []const u8, duration_ms: u64, success: bool, error_message: ?[]const u8 },
    agent_end: struct { duration_ms: u64, tokens_used: ?u64 },
    tool_call_start: struct { tool: []const u8 },
    tool_call: struct { tool: []const u8, duration_ms: u64, success: bool },
    turn_complete: void,
    channel_message: struct { channel: []const u8, direction: []const u8 },
};

/// Represents a measurable metric recorded during agent execution.
/// Used for performance monitoring and resource usage tracking.
pub const ObserverMetric = union(enum) {
    request_latency_ms: u64,
    tokens_used: u64,
    active_sessions: u64,
};

/// A type-erased interface for recording events and metrics.
/// Uses a dynamic dispatch (VTable) pattern to allow runtime polymorphism
/// without requiring generic parameters on the structs that use it,
/// keeping the core API simple and decoupled.
pub const Observer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        record_event: *const fn (ptr: *anyopaque, event: *const ObserverEvent) void,
        record_metric: *const fn (ptr: *anyopaque, metric: *const ObserverMetric) void,
        flush: *const fn (ptr: *anyopaque) void,
        name: *const fn (ptr: *anyopaque) []const u8,
    };

    pub fn recordEvent(self: Observer, event: *const ObserverEvent) void {
        self.vtable.record_event(self.ptr, event);
    }

    pub fn recordMetric(self: Observer, metric: *const ObserverMetric) void {
        self.vtable.record_metric(self.ptr, metric);
    }

    pub fn flush(self: Observer) void {
        self.vtable.flush(self.ptr);
    }

    pub fn getName(self: Observer) []const u8 {
        return self.vtable.name(self.ptr);
    }
};

/// A dummy observer implementation that discards all events and metrics.
/// Useful as a zero-cost default to avoid null checks throughout the codebase
/// when observability is disabled.
pub const NoopObserver = struct {
    const vtable: Observer.VTable = .{
        .record_event = noopRecordEvent,
        .record_metric = noopRecordMetric,
        .flush = noopFlush,
        .name = noopName,
    };

    pub fn observer(self: *const NoopObserver) Observer {
        return .{
            .ptr = @constCast(@ptrCast(self)),
            .vtable = &vtable,
        };
    }

    fn noopRecordEvent(_: *anyopaque, _: *const ObserverEvent) void {}
    fn noopRecordMetric(_: *anyopaque, _: *const ObserverMetric) void {}
    fn noopFlush(_: *anyopaque) void {}
    fn noopName(_: *anyopaque) []const u8 {
        return "noop";
    }
};

/// An observer that logs events and metrics using Zig's standard log facility (`std.log`).
/// Best suited for debugging and persistent structured logging.
pub const LogObserver = struct {
    const vtable: Observer.VTable = .{
        .record_event = logRecordEvent,
        .record_metric = logRecordMetric,
        .flush = logFlush,
        .name = logName,
    };

    pub fn observer(self: *LogObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn logRecordEvent(_: *anyopaque, event: *const ObserverEvent) void {
        switch (event.*) {
            .agent_start => |e| std.log.info("agent.start provider={s} model={s}", .{ e.provider, e.model }),
            .llm_request => |e| std.log.info("llm.request provider={s} model={s} messages={d}", .{ e.provider, e.model, e.messages_count }),
            .llm_response => |e| std.log.info("llm.response provider={s} model={s} duration_ms={d} success={}", .{ e.provider, e.model, e.duration_ms, e.success }),
            .agent_end => |e| std.log.info("agent.end duration_ms={d}", .{e.duration_ms}),
            .tool_call_start => |e| std.log.info("tool.start tool={s}", .{e.tool}),
            .tool_call => |e| std.log.info("tool.call tool={s} duration_ms={d} success={}", .{ e.tool, e.duration_ms, e.success }),
            .turn_complete => std.log.info("turn.complete", .{}),
            .channel_message => |e| std.log.info("channel.message channel={s} direction={s}", .{ e.channel, e.direction }),
        }
    }

    fn logRecordMetric(_: *anyopaque, metric: *const ObserverMetric) void {
        switch (metric.*) {
            .request_latency_ms => |v| std.log.info("metric.request_latency latency_ms={d}", .{v}),
            .tokens_used => |v| std.log.info("metric.tokens_used tokens={d}", .{v}),
            .active_sessions => |v| std.log.info("metric.active_sessions sessions={d}", .{v}),
        }
    }

    fn logFlush(_: *anyopaque) void {}
    fn logName(_: *anyopaque) []const u8 {
        return "log";
    }
};

/// An observer that prints simple, human-readable indicators to stderr.
/// Designed to provide immediate visual feedback in CLI environments
/// (e.g., `> Send`, `< Receive`) without the verbosity of full logs.
pub const VerboseObserver = struct {
    const vtable: Observer.VTable = .{
        .record_event = verboseRecordEvent,
        .record_metric = verboseRecordMetric,
        .flush = verboseFlush,
        .name = verboseName,
    };

    pub fn observer(self: *VerboseObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn verboseRecordEvent(_: *anyopaque, event: *const ObserverEvent) void {
        var buf: [4096]u8 = undefined;
        var bw = std.fs.File.stderr().writer(&buf);
        const stderr = &bw.interface;
        switch (event.*) {
            .llm_request => |e| {
                stderr.print("> Send (provider={s}, model={s}, messages={d})\n", .{ e.provider, e.model, e.messages_count }) catch |err| std.debug.print("warn: verbose: {}\n", .{err});
            },
            .llm_response => |e| {
                stderr.print("< Receive (success={}, duration_ms={d})\n", .{ e.success, e.duration_ms }) catch |err| std.debug.print("warn: verbose: {}\n", .{err});
            },
            .tool_call_start => |e| {
                stderr.print("> Tool {s}\n", .{e.tool}) catch |err| std.debug.print("warn: verbose: {}\n", .{err});
            },
            .tool_call => |e| {
                stderr.print("< Tool {s} (success={}, duration_ms={d})\n", .{ e.tool, e.success, e.duration_ms }) catch |err| std.debug.print("warn: verbose: {}\n", .{err});
            },
            .turn_complete => {
                stderr.print("< Complete\n", .{}) catch |err| std.debug.print("warn: verbose: {}\n", .{err});
            },
            else => {},
        }
    }

    fn verboseRecordMetric(_: *anyopaque, _: *const ObserverMetric) void {}
    fn verboseFlush(_: *anyopaque) void {}
    fn verboseName(_: *anyopaque) []const u8 {
        return "verbose";
    }
};

/// An observer that broadcasts events and metrics to a list of child observers.
/// Allows composing different observation strategies (e.g., LogObserver + MetricObserver)
/// behind a single Observer interface.
pub const MultiObserver = struct {
    observers: []Observer,

    const vtable: Observer.VTable = .{
        .record_event = multiRecordEvent,
        .record_metric = multiRecordMetric,
        .flush = multiFlush,
        .name = multiName,
    };

    pub fn observer(s: *MultiObserver) Observer {
        return .{
            .ptr = @ptrCast(s),
            .vtable = &vtable,
        };
    }

    fn resolve(ptr: *anyopaque) *MultiObserver {
        return @ptrCast(@alignCast(ptr));
    }

    fn multiRecordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        for (resolve(ptr).observers) |obs| {
            obs.vtable.record_event(obs.ptr, event);
        }
    }

    fn multiRecordMetric(ptr: *anyopaque, metric: *const ObserverMetric) void {
        for (resolve(ptr).observers) |obs| {
            obs.vtable.record_metric(obs.ptr, metric);
        }
    }

    fn multiFlush(ptr: *anyopaque) void {
        for (resolve(ptr).observers) |obs| {
            obs.vtable.flush(obs.ptr);
        }
    }

    fn multiName(_: *anyopaque) []const u8 {
        return "multi";
    }
};

test "NoopObserver name" {
    const noop: NoopObserver = .{};
    const obs = noop.observer();
    try std.testing.expectEqualStrings("noop", obs.getName());
}

test "NoopObserver does not panic" {
    const noop: NoopObserver = .{};
    const obs = noop.observer();
    const event: ObserverEvent = .{ .turn_complete = {} };
    obs.recordEvent(&event);
    const metric: ObserverMetric = .{ .tokens_used = 42 };
    obs.recordMetric(&metric);
    obs.flush();
}

test "LogObserver name" {
    var log_obs: LogObserver = .{};
    const obs = log_obs.observer();
    try std.testing.expectEqualStrings("log", obs.getName());
}

test "VerboseObserver name" {
    var verbose: VerboseObserver = .{};
    const obs = verbose.observer();
    try std.testing.expectEqualStrings("verbose", obs.getName());
}

test "MultiObserver name" {
    var multi: MultiObserver = .{ .observers = &.{} };
    const obs = multi.observer();
    try std.testing.expectEqualStrings("multi", obs.getName());
}

test "MultiObserver fans out" {
    const noop1: NoopObserver = .{};
    const noop2: NoopObserver = .{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi: MultiObserver = .{ .observers = &observers_arr };
    const obs = multi.observer();
    const event: ObserverEvent = .{ .turn_complete = {} };
    obs.recordEvent(&event);
}

test "ObserverEvent: agent_start fields" {
    const event: ObserverEvent = .{ .agent_start = .{ .provider = "openrouter", .model = "claude-sonnet" } };
    switch (event) {
        .agent_start => |e| {
            try std.testing.expectEqualStrings("openrouter", e.provider);
            try std.testing.expectEqualStrings("claude-sonnet", e.model);
        },
        else => unreachable,
    }
}

test "ObserverEvent: llm_request fields" {
    const event: ObserverEvent = .{ .llm_request = .{ .provider = "anthropic", .model = "claude-3", .messages_count = 5 } };
    switch (event) {
        .llm_request => |e| {
            try std.testing.expectEqualStrings("anthropic", e.provider);
            try std.testing.expectEqualStrings("claude-3", e.model);
            try std.testing.expectEqual(@as(usize, 5), e.messages_count);
        },
        else => unreachable,
    }
}

test "ObserverEvent: llm_response success fields" {
    const event: ObserverEvent = .{ .llm_response = .{
        .provider = "openrouter",
        .model = "gpt-4",
        .duration_ms = 1500,
        .success = true,
        .error_message = null,
    } };
    switch (event) {
        .llm_response => |e| {
            try std.testing.expectEqualStrings("openrouter", e.provider);
            try std.testing.expectEqualStrings("gpt-4", e.model);
            try std.testing.expectEqual(@as(u64, 1500), e.duration_ms);
            try std.testing.expectEqual(true, e.success);
            try std.testing.expectEqual(null, e.error_message);
        },
        else => unreachable,
    }
}

test "ObserverEvent: llm_response failure fields" {
    const event: ObserverEvent = .{ .llm_response = .{
        .provider = "openrouter",
        .model = "gpt-4",
        .duration_ms = 500,
        .success = false,
        .error_message = "rate_limit",
    } };
    switch (event) {
        .llm_response => |e| {
            try std.testing.expectEqual(false, e.success);
            try std.testing.expect(e.error_message != null);
            try std.testing.expectEqualStrings("rate_limit", e.error_message.?);
        },
        else => unreachable,
    }
}

test "ObserverEvent: agent_end fields" {
    const event: ObserverEvent = .{ .agent_end = .{ .duration_ms = 3000, .tokens_used = 1500 } };
    switch (event) {
        .agent_end => |e| {
            try std.testing.expectEqual(@as(u64, 3000), e.duration_ms);
            try std.testing.expectEqual(@as(?u64, 1500), e.tokens_used);
        },
        else => unreachable,
    }
}

test "ObserverEvent: agent_end without tokens" {
    const event: ObserverEvent = .{ .agent_end = .{ .duration_ms = 1000, .tokens_used = null } };
    switch (event) {
        .agent_end => |e| {
            try std.testing.expectEqual(@as(?u64, null), e.tokens_used);
        },
        else => unreachable,
    }
}

test "ObserverEvent: tool_call_start fields" {
    const event: ObserverEvent = .{ .tool_call_start = .{ .tool = "vector_search" } };
    switch (event) {
        .tool_call_start => |e| {
            try std.testing.expectEqualStrings("vector_search", e.tool);
        },
        else => unreachable,
    }
}

test "ObserverEvent: tool_call success fields" {
    const event: ObserverEvent = .{ .tool_call = .{ .tool = "read_file", .duration_ms = 50, .success = true } };
    switch (event) {
        .tool_call => |e| {
            try std.testing.expectEqualStrings("read_file", e.tool);
            try std.testing.expectEqual(@as(u64, 50), e.duration_ms);
            try std.testing.expectEqual(true, e.success);
        },
        else => unreachable,
    }
}

test "ObserverEvent: tool_call failure fields" {
    const event: ObserverEvent = .{ .tool_call = .{ .tool = "http_request", .duration_ms = 200, .success = false } };
    switch (event) {
        .tool_call => |e| {
            try std.testing.expectEqual(false, e.success);
        },
        else => unreachable,
    }
}

test "ObserverEvent: turn_complete" {
    const event: ObserverEvent = .{ .turn_complete = {} };
    switch (event) {
        .turn_complete => {},
        else => unreachable,
    }
}

test "ObserverEvent: channel_message fields" {
    const event: ObserverEvent = .{ .channel_message = .{ .channel = "telegram", .direction = "inbound" } };
    switch (event) {
        .channel_message => |e| {
            try std.testing.expectEqualStrings("telegram", e.channel);
            try std.testing.expectEqualStrings("inbound", e.direction);
        },
        else => unreachable,
    }
}

test "ObserverMetric: request_latency_ms" {
    const metric: ObserverMetric = .{ .request_latency_ms = 100 };
    switch (metric) {
        .request_latency_ms => |v| try std.testing.expectEqual(@as(u64, 100), v),
        else => unreachable,
    }
}

test "ObserverMetric: tokens_used" {
    const metric: ObserverMetric = .{ .tokens_used = 500 };
    switch (metric) {
        .tokens_used => |v| try std.testing.expectEqual(@as(u64, 500), v),
        else => unreachable,
    }
}

test "ObserverMetric: active_sessions" {
    const metric: ObserverMetric = .{ .active_sessions = 3 };
    switch (metric) {
        .active_sessions => |v| try std.testing.expectEqual(@as(u64, 3), v),
        else => unreachable,
    }
}

test "MultiObserver: fans out events to multiple observers" {
    const noop1: NoopObserver = .{};
    const noop2: NoopObserver = .{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi: MultiObserver = .{ .observers = &observers_arr };
    const obs = multi.observer();

    const event: ObserverEvent = .{ .turn_complete = {} };
    obs.recordEvent(&event);
    obs.recordEvent(&event);
    obs.recordEvent(&event);
}

test "MultiObserver: fans out metrics to multiple observers" {
    const noop1: NoopObserver = .{};
    const noop2: NoopObserver = .{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi: MultiObserver = .{ .observers = &observers_arr };
    const obs = multi.observer();

    const metric: ObserverMetric = .{ .request_latency_ms = 500 };
    obs.recordMetric(&metric);
    obs.recordMetric(&metric);
}

test "MultiObserver: fans out flush to multiple observers" {
    const noop1: NoopObserver = .{};
    const noop2: NoopObserver = .{};
    var observers_arr = [_]Observer{ noop1.observer(), noop2.observer() };
    var multi: MultiObserver = .{ .observers = &observers_arr };
    const obs = multi.observer();

    obs.flush();
    obs.flush();
}

test "MultiObserver: empty observers list does not panic" {
    var multi: MultiObserver = .{ .observers = @constCast(&[_]Observer{}) };
    const obs = multi.observer();

    obs.recordEvent(&ObserverEvent{ .turn_complete = {} });
    obs.recordMetric(&ObserverMetric{ .tokens_used = 0 });
    obs.flush();
}

test "MultiObserver: single observer works correctly" {
    const noop: NoopObserver = .{};
    var observers_arr = [_]Observer{noop.observer()};
    var multi: MultiObserver = .{ .observers = &observers_arr };
    const obs = multi.observer();

    try std.testing.expectEqualStrings("multi", obs.getName());

    const event: ObserverEvent = .{ .agent_start = .{ .provider = "p", .model = "m" } };
    obs.recordEvent(&event);
}

// ═══════════════════════════════════════════════════════════════════════════
// Observer Interface Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Observer: dispatches to NoopObserver" {
    var noop: NoopObserver = .{};
    const obs = noop.observer();
    try std.testing.expectEqualStrings("noop", obs.getName());

    // All these should be no-ops
    obs.recordEvent(&ObserverEvent{ .turn_complete = {} });
    obs.recordMetric(&ObserverMetric{ .tokens_used = 0 });
    obs.flush();
}

test "Observer: dispatches to LogObserver" {
    var log_obs: LogObserver = .{};
    const obs = log_obs.observer();
    try std.testing.expectEqualStrings("log", obs.getName());

    obs.recordEvent(&ObserverEvent{ .agent_start = .{ .provider = "test", .model = "test" } });
    obs.flush();
}

test "Observer: dispatches to VerboseObserver" {
    var verbose: VerboseObserver = .{};
    const obs = verbose.observer();
    try std.testing.expectEqualStrings("verbose", obs.getName());

    obs.recordEvent(&ObserverEvent{ .turn_complete = {} });
    obs.flush();
}

// ═══════════════════════════════════════════════════════════════════════════
// NoopObserver Tests
// ═══════════════════════════════════════════════════════════════════════════

test "NoopObserver: handles all event types without panic" {
    var noop: NoopObserver = .{};
    const obs = noop.observer();

    const events = [_]ObserverEvent{
        .{ .agent_start = .{ .provider = "p", .model = "m" } },
        .{ .llm_request = .{ .provider = "p", .model = "m", .messages_count = 1 } },
        .{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 100, .success = true, .error_message = null } },
        .{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } },
        .{ .turn_complete = {} },
        .{ .channel_message = .{ .channel = "cli", .direction = "inbound" } },
    };

    for (&events) |*event| {
        obs.recordEvent(event);
    }
}

test "NoopObserver: handles all metric types without panic" {
    var noop: NoopObserver = .{};
    const obs = noop.observer();

    const metrics = [_]ObserverMetric{
        .{ .request_latency_ms = 0 },
        .{ .request_latency_ms = std.math.maxInt(u64) },
        .{ .tokens_used = 0 },
        .{ .tokens_used = 1000000 },
        .{ .active_sessions = 0 },
        .{ .active_sessions = 999 },
    };

    for (&metrics) |*metric| {
        obs.recordMetric(metric);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// LogObserver Tests
// ═══════════════════════════════════════════════════════════════════════════

test "LogObserver: handles all event types without panic" {
    var log_obs: LogObserver = .{};
    const obs = log_obs.observer();

    const events = [_]ObserverEvent{
        .{ .agent_start = .{ .provider = "p", .model = "m" } },
        .{ .llm_request = .{ .provider = "p", .model = "m", .messages_count = 1 } },
        .{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 100, .success = true, .error_message = null } },
        .{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 100, .success = false, .error_message = "err" } },
        .{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = false } },
        .{ .turn_complete = {} },
        .{ .channel_message = .{ .channel = "cli", .direction = "inbound" } },
        .{ .channel_message = .{ .channel = "telegram", .direction = "outbound" } },
    };

    for (&events) |*event| {
        obs.recordEvent(event);
    }
}

test "LogObserver: handles all metric types without panic" {
    var log_obs: LogObserver = .{};
    const obs = log_obs.observer();

    const metrics = [_]ObserverMetric{
        .{ .request_latency_ms = 100 },
        .{ .tokens_used = 500 },
        .{ .active_sessions = 3 },
    };

    for (&metrics) |*metric| {
        obs.recordMetric(metric);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// VerboseObserver Tests
// ═══════════════════════════════════════════════════════════════════════════

test "VerboseObserver: handles all event types without panic" {
    var verbose: VerboseObserver = .{};
    const obs = verbose.observer();

    const events = [_]ObserverEvent{
        .{ .agent_start = .{ .provider = "p", .model = "m" } },
        .{ .llm_request = .{ .provider = "p", .model = "m", .messages_count = 1 } },
        .{ .llm_response = .{ .provider = "p", .model = "m", .duration_ms = 100, .success = true, .error_message = null } },
        .{ .agent_end = .{ .duration_ms = 1000, .tokens_used = 500 } },
        .{ .tool_call_start = .{ .tool = "shell" } },
        .{ .tool_call = .{ .tool = "shell", .duration_ms = 50, .success = true } },
        .{ .turn_complete = {} },
        .{ .channel_message = .{ .channel = "cli", .direction = "inbound" } },
    };

    for (&events) |*event| {
        obs.recordEvent(event);
    }
}

test "VerboseObserver: ignores metrics" {
    var verbose: VerboseObserver = .{};
    const obs = verbose.observer();

    const metrics = [_]ObserverMetric{
        .{ .request_latency_ms = 100 },
        .{ .tokens_used = 500 },
        .{ .active_sessions = 3 },
    };

    for (&metrics) |*metric| {
        obs.recordMetric(metric);
    }
}
