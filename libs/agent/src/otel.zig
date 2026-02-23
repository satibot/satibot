const std = @import("std");
const http = @import("http");
const constants = @import("core").constants;

/// OpenTelemetry (OTEL) observer implementation.
/// Sends traces to an OTEL collector via OTLP HTTP protocol.
/// Compatible with Jaeger, Zipkin, Datadog, and other OTEL-compliant backends.
///
/// Configuration (environment variables):
/// - OTEL_EXPORTER_OTLP_ENDPOINT: The OTEL collector endpoint (default: http://localhost:4318)
/// - OTEL_EXPORTER_OTLP_HEADERS: Additional headers as comma-separated key=value pairs
/// - OTEL_SERVICE_NAME: Service name for traces (default: "satibot")
/// - OTEL_SERVICE_VERSION: Service version (default: from build info)
/// - OTEL_RESOURCE_ATTRIBUTES: Additional resource attributes as comma-separated key=value pairs
///
/// Example usage:
/// ```zig
/// var otel = try OtelObserver.init(allocator, .{});
/// defer otel.deinit();
/// const observer = otel.observer();
/// ```
pub const OtelObserver = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    endpoint: []const u8,
    headers: std.StringHashMap([]const u8),
    service_name: []const u8,
    service_version: []const u8,
    resource_attrs: std.StringHashMap([]const u8),

    /// Pending spans batch
    spans: std.ArrayList(OtelSpan),
    max_batch_size: usize,

    pub const Config = struct {
        /// OTEL collector endpoint. If null, uses OTEL_EXPORTER_OTLP_ENDPOINT env var
        endpoint: ?[]const u8 = null,
        /// Service name. If null, uses OTEL_SERVICE_NAME env var or "satibot"
        service_name: ?[]const u8 = null,
        /// Service version. If null, uses OTEL_SERVICE_VERSION env var or build version
        service_version: ?[]const u8 = null,
        /// Maximum spans to batch before sending
        max_batch_size: usize = 100,
    };

    /// Initialize the OTEL observer with configuration from environment or provided values.
    pub fn init(allocator: std.mem.Allocator, config: Config) !OtelObserver {
        var http_client = try http.Client.init(allocator);
        errdefer http_client.deinit();

        // Get endpoint from config or environment
        const endpoint = try getEnvOrDefault(allocator, "OTEL_EXPORTER_OTLP_ENDPOINT", config.endpoint, "http://localhost:4318/v1/traces");
        errdefer allocator.free(endpoint);

        // Get service info
        const service_name = try getEnvOrDefault(allocator, "OTEL_SERVICE_NAME", config.service_name, "satibot");
        errdefer allocator.free(service_name);

        const service_version = try getEnvOrDefault(allocator, "OTEL_SERVICE_VERSION", config.service_version, constants.VERSION);
        errdefer allocator.free(service_version);

        // Parse headers from OTEL_EXPORTER_OTLP_HEADERS
        var headers = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var it = headers.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            headers.deinit();
        }
        try parseKeyValueEnv(allocator, "OTEL_EXPORTER_OTLP_HEADERS", &headers);

        // Parse resource attributes
        var resource_attrs = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var it = resource_attrs.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            resource_attrs.deinit();
        }
        try parseKeyValueEnv(allocator, "OTEL_RESOURCE_ATTRIBUTES", &resource_attrs);

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .endpoint = endpoint,
            .headers = headers,
            .service_name = service_name,
            .service_version = service_version,
            .resource_attrs = resource_attrs,
            .spans = std.ArrayList(OtelSpan).init(allocator),
            .max_batch_size = config.max_batch_size,
        };
    }

    pub fn deinit(self: *OtelObserver) void {
        // Flush any pending spans
        self.flushInternal() catch |err| {
            std.log.warn("Failed to flush OTEL spans on deinit: {any}", .{err});
        };

        self.http_client.deinit();
        self.allocator.free(self.endpoint);
        self.allocator.free(self.service_name);
        self.allocator.free(self.service_version);

        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        var attr_it = self.resource_attrs.iterator();
        while (attr_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.resource_attrs.deinit();

        for (self.spans.items) |*span| {
            span.deinit(self.allocator, span);
        }
        self.spans.deinit();
        self.* = undefined;
    }

    /// Get the Observer interface for this OTEL observer.
    pub fn observer(self: *OtelObserver) Observer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .record_event = recordEvent,
                .record_metric = recordMetric,
                .flush = flush,
                .name = name,
            },
        };
    }

    /// Internal flush implementation.
    fn flushInternal(self: *OtelObserver) !void {
        if (self.spans.items.len == 0) return;

        // Build OTLP JSON payload
        const payload = try self.buildOtlpPayload();
        defer self.allocator.free(payload);

        // Send to collector
        var req_headers = std.StringHashMap([]const u8).init(self.allocator);
        defer req_headers.deinit();

        try req_headers.put("Content-Type", "application/json");

        // Add custom headers
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            try req_headers.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        const response = try self.http_client.fetch(.{
            .method = .POST,
            .url = self.endpoint,
            .headers = req_headers,
            .body = payload,
        });
        defer response.deinit();

        if (response.status < 200 or response.status >= 300) {
            std.log.warn("OTEL collector returned status {d}", .{response.status});
        }

        // Clear sent spans
        for (self.spans.items) |*span| {
            span.deinit(self.allocator, span);
        }
        self.spans.clearRetainingCapacity();
    }

    /// Build OTLP JSON payload from pending spans.
    fn buildOtlpPayload(self: *OtelObserver) ![]const u8 {
        var writer = std.ArrayList(u8).init(self.allocator);
        defer writer.deinit();

        const w = writer.writer();

        // Start JSON object
        try w.writeAll("{");

        // ResourceSpans
        try w.writeAll("\"resourceSpans\":[");
        try w.writeAll("{");

        // Resource
        try w.writeAll("\"resource\":{");
        try w.writeAll("\"attributes\":[");

        // Service name attribute
        try w.print("{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"{s}\"}}}},", .{self.service_name});

        // Service version attribute
        try w.print("{{\"key\":\"service.version\",\"value\":{{\"stringValue\":\"{s}\"}}}},", .{self.service_version});

        // Custom resource attributes
        var attr_it = self.resource_attrs.iterator();
        var first = false;
        while (attr_it.next()) |entry| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"key\":\"{s}\",\"value\":{{\"stringValue\":\"{s}\"}}}}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try w.writeAll("]}"); // Close attributes array and resource object

        // ScopeSpans
        try w.writeAll(",\"scopeSpans\":[");
        try w.writeAll("{");
        try w.writeAll("\"scope\":{");
        try w.writeAll("\"name\":\"satibot-agent\",");
        try w.writeAll("\"version\":\"1.0.0\"");
        try w.writeAll("},"); // Close scope

        // Spans array
        try w.writeAll("\"spans\":[");

        for (self.spans.items, 0..) |span, i| {
            if (i > 0) try w.writeAll(",");
            try span.toJson(w);
        }

        try w.writeAll("]"); // Close spans array
        try w.writeAll("}"); // Close scopeSpans object
        try w.writeAll("]"); // Close scopeSpans array
        try w.writeAll("}"); // Close resourceSpans object
        try w.writeAll("]"); // Close resourceSpans array
        try w.writeAll("}"); // Close root object

        return writer.toOwnedSlice();
    }

    // Observer interface implementation
    fn recordEvent(ptr: *anyopaque, event: *const ObserverEvent) void {
        const self: *OtelObserver = @ptrCast(@alignCast(ptr));

        const span = OtelSpan.fromEvent(self.allocator, event) catch |err| {
            std.log.warn("Failed to create OTEL span: {any}", .{err});
            return;
        };

        self.spans.append(span) catch |err| {
            std.log.warn("Failed to append OTEL span: {any}", .{err});
            span.deinit(self.allocator, span);
            return;
        };

        // Flush if batch is full
        if (self.spans.items.len >= self.max_batch_size) {
            self.flushInternal() catch |err| {
                std.log.warn("Failed to flush OTEL batch: {any}", .{err});
            };
        }
    }

    fn recordMetric(_: *anyopaque, _: *const ObserverMetric) void {
        // TODO: Implement metric export via OTLP metrics endpoint
    }

    fn flush(ptr: *anyopaque) void {
        const self: *OtelObserver = @ptrCast(@alignCast(ptr));
        self.flushInternal() catch |err| {
            std.log.warn("Failed to flush OTEL spans: {any}", .{err});
        };
    }

    fn name(_: *anyopaque) []const u8 {
        return "otel";
    }
};

/// OTEL Span representation.
const OtelSpan = struct {
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8,
    name: []const u8,
    kind: SpanKind,
    start_time_unix_nano: i64,
    end_time_unix_nano: i64,
    attributes: std.ArrayList(Attribute),
    status_code: StatusCode,
    status_message: ?[]const u8,

    const SpanKind = enum {
        internal,
        server,
        client,
        producer,
        consumer,

        fn toInt(self: SpanKind) u8 {
            return switch (self) {
                .internal => 1,
                .server => 2,
                .client => 3,
                .producer => 4,
                .consumer => 5,
            };
        }
    };

    const StatusCode = enum {
        unset,
        ok,
        err,

        fn toInt(self: StatusCode) u8 {
            return switch (self) {
                .unset => 0,
                .ok => 1,
                .err => 2,
            };
        }
    };

    const Attribute = struct {
        key: []const u8,
        value: union(enum) {
            string: []const u8,
            int: i64,
            double: f64,
            bool: bool,
        },

        fn deinit(allocator: std.mem.Allocator, self: *Attribute) void {
            allocator.free(self.key);
            switch (self.value) {
                .string => |s| allocator.free(s),
                else => {},
            }
            self.* = undefined;
        }

        fn toJson(self: Attribute, writer: anytype) !void {
            try writer.print("{{\"key\":\"{s}\",\"value\":", .{self.key});
            switch (self.value) {
                .string => |s| try writer.print("{{\"stringValue\":\"{s}\"}}", .{s}),
                .int => |i| try writer.print("{{\"intValue\":{d}}}", .{i}),
                .double => |d| try writer.print("{{\"doubleValue\":{d}}}", .{d}),
                .bool => |b| try writer.print("{{\"boolValue\":{}}}", .{b}),
            }
            try writer.writeAll("}");
        }
    };

    fn deinit(allocator: std.mem.Allocator, self: *OtelSpan) void {
        allocator.free(self.trace_id);
        allocator.free(self.span_id);
        if (self.parent_span_id) |ps| allocator.free(ps);
        allocator.free(self.name);
        if (self.status_message) |sm| allocator.free(sm);
        for (self.attributes.items) |*attr| {
            attr.deinit(allocator, attr);
        }
        self.attributes.deinit();
        self.* = undefined;
    }

    fn toJson(self: OtelSpan, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"traceId\":\"{s}\",", .{self.trace_id});
        try writer.print("\"spanId\":\"{s}\",", .{self.span_id});
        if (self.parent_span_id) |ps| {
            try writer.print("\"parentSpanId\":\"{s}\",", .{ps});
        }
        try writer.print("\"name\":\"{s}\",", .{self.name});
        try writer.print("\"kind\":{d},", .{self.kind.toInt()});
        try writer.print("\"startTimeUnixNano\":\"{d}\",", .{self.start_time_unix_nano});
        try writer.print("\"endTimeUnixNano\":\"{d}\",", .{self.end_time_unix_nano});

        // Attributes
        try writer.writeAll("\"attributes\":[");
        for (self.attributes.items, 0..) |attr, i| {
            if (i > 0) try writer.writeAll(",");
            try attr.toJson(writer);
        }
        try writer.writeAll("],");

        // Status
        try writer.writeAll("\"status\":{");
        try writer.print("\"code\":{d}", .{self.status_code.toInt()});
        if (self.status_message) |sm| {
            try writer.print(",\"message\":\"{s}\"", .{sm});
        }
        try writer.writeAll("}");

        try writer.writeAll("}");
    }

    fn fromEvent(allocator: std.mem.Allocator, event: *const ObserverEvent) !OtelSpan {
        const now = std.time.nanoTimestamp();
        const trace_id = try generateTraceId(allocator);
        const span_id = try generateSpanId(allocator);

        var attributes = std.ArrayList(Attribute).init(allocator);
        errdefer {
            for (attributes.items) |*attr| {
                attr.deinit(allocator, attr);
            }
            attributes.deinit();
        }

        const name: []const u8 = switch (event.*) {
            .agent_start => "agent.run",
            .llm_request => "llm.request",
            .llm_response => "llm.response",
            .agent_end => "agent.end",
            .tool_call_start => "tool.call.start",
            .tool_call => "tool.call",
            .turn_complete => "turn.complete",
            .channel_message => "channel.message",
        };

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        // Set attributes based on event type
        switch (event.*) {
            .agent_start => |e| {
                try appendStringAttr(allocator, &attributes, "provider", e.provider);
                try appendStringAttr(allocator, &attributes, "model", e.model);
            },
            .llm_request => |e| {
                try appendStringAttr(allocator, &attributes, "provider", e.provider);
                try appendStringAttr(allocator, &attributes, "model", e.model);
                try appendIntAttr(allocator, &attributes, "messages.count", @intCast(e.messages_count));
            },
            .llm_response => |e| {
                try appendStringAttr(allocator, &attributes, "provider", e.provider);
                try appendStringAttr(allocator, &attributes, "model", e.model);
                try appendIntAttr(allocator, &attributes, "duration_ms", @intCast(e.duration_ms));
                try appendBoolAttr(allocator, &attributes, "success", e.success);
                if (e.error_message) |err| {
                    try appendStringAttr(allocator, &attributes, "error.message", err);
                }
            },
            .agent_end => |e| {
                try appendIntAttr(allocator, &attributes, "duration_ms", @intCast(e.duration_ms));
                if (e.tokens_used) |tokens| {
                    try appendIntAttr(allocator, &attributes, "tokens.used", @intCast(tokens));
                }
            },
            .tool_call_start => |e| {
                try appendStringAttr(allocator, &attributes, "tool.name", e.tool);
            },
            .tool_call => |e| {
                try appendStringAttr(allocator, &attributes, "tool.name", e.tool);
                try appendIntAttr(allocator, &attributes, "duration_ms", @intCast(e.duration_ms));
                try appendBoolAttr(allocator, &attributes, "success", e.success);
            },
            .channel_message => |e| {
                try appendStringAttr(allocator, &attributes, "channel", e.channel);
                try appendStringAttr(allocator, &attributes, "direction", e.direction);
            },
            .turn_complete => {},
        }

        return .{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = null,
            .name = name_copy,
            .kind = .internal,
            .start_time_unix_nano = now,
            .end_time_unix_nano = now, // Single-point spans for events
            .attributes = attributes,
            .status_code = switch (event.*) {
                .llm_response => |e| if (e.success) .ok else .err,
                .tool_call => |e| if (e.success) .ok else .err,
                else => .unset,
            },
            .status_message = switch (event.*) {
                .llm_response => |e| if (!e.success and e.error_message != null) try allocator.dupe(u8, e.error_message.?) else null,
                else => null,
            },
        };
    }

    fn appendStringAttr(allocator: std.mem.Allocator, attrs: *std.ArrayList(Attribute), key: []const u8, value: []const u8) !void {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);
        try attrs.append(.{
            .key = key_copy,
            .value = .{ .string = value_copy },
        });
    }

    fn appendIntAttr(allocator: std.mem.Allocator, attrs: *std.ArrayList(Attribute), key: []const u8, value: i64) !void {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        try attrs.append(.{
            .key = key_copy,
            .value = .{ .int = value },
        });
    }

    fn appendBoolAttr(allocator: std.mem.Allocator, attrs: *std.ArrayList(Attribute), key: []const u8, value: bool) !void {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        try attrs.append(.{
            .key = key_copy,
            .value = .{ .bool = value },
        });
    }
};

/// Generate a random trace ID (16 bytes hex encoded = 32 chars).
fn generateTraceId(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&bytes)});
}

/// Generate a random span ID (8 bytes hex encoded = 16 chars).
fn generateSpanId(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&bytes)});
}

/// Get environment variable value or use default.
fn getEnvOrDefault(allocator: std.mem.Allocator, env_name: []const u8, config_value: ?[]const u8, default_value: []const u8) ![]const u8 {
    if (config_value) |cv| {
        return allocator.dupe(u8, cv);
    }
    const env = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try allocator.dupe(u8, default_value),
        else => return err,
    };
    return env;
}

/// Parse comma-separated key=value pairs from environment variable.
fn parseKeyValueEnv(allocator: std.mem.Allocator, env_name: []const u8, map: *std.StringHashMap([]const u8)) !void {
    const value = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(value);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (trimmed.len == 0) continue;

        const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], " ");
        const val = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " ");

        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const val_copy = try allocator.dupe(u8, val);

        try map.put(key_copy, val_copy);
    }
}

// Re-export Observer types for convenience
pub const ObserverEvent = @import("observability.zig").ObserverEvent;
pub const ObserverMetric = @import("observability.zig").ObserverMetric;
pub const Observer = @import("observability.zig").Observer;
