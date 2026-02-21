# OpenTelemetry (OTEL) Tracing

SatiBot includes built-in OpenTelemetry tracing support for distributed observability. The `OtelObserver` sends traces to any OTEL-compliant backend via the OTLP HTTP protocol.

## Supported Backends

- [Jaeger](https://www.jaegertracing.io/)
- [Zipkin](https://zipkin.io/)
- [Datadog](https://www.datadoghq.com/)
- [Grafana Tempo](https://grafana.com/oss/tempo/)
- [AWS X-Ray](https://aws.amazon.com/xray/)
- Any OTEL-compliant collector

## Configuration

Configure via environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTEL collector endpoint | `http://localhost:4318/v1/traces` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Additional headers (comma-separated `key=value` pairs) | - |
| `OTEL_SERVICE_NAME` | Service name for traces | `satibot` |
| `OTEL_SERVICE_VERSION` | Service version | Build version |
| `OTEL_RESOURCE_ATTRIBUTES` | Resource attributes (comma-separated `key=value` pairs) | - |

## Usage

### Basic Setup

```zig
const agent = @import("agent");

// Initialize OTEL observer
var otel = try agent.otel.OtelObserver.init(allocator, .{});
defer otel.deinit();

// Get the observer interface
const observer = otel.observer();

// Use with Agent
var my_agent = try agent.Agent.init(allocator, config, session_id);
defer my_agent.deinit();

// Record events - these are automatically sent as OTEL spans
my_agent.run("Hello!");
```

### With Jaeger (Local Development)

1. Start Jaeger:

```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

1. Run satibot with OTEL:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318/v1/traces
export OTEL_SERVICE_NAME=satibot-dev
sati console
```

1. View traces at <http://localhost:16686>

### With Datadog

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=https://trace.agent.datadoghq.com/api/v0.2/traces
export OTEL_EXPORTER_OTLP_HEADERS="DD-API-KEY=your_api_key"
export OTEL_SERVICE_NAME=satibot-prod
sati telegram
```

## Traced Events

The following agent lifecycle events are automatically traced:

| Event | OTEL Span Name | Attributes |
|-------|---------------|------------|
| Agent start | `agent.run` | provider, model |
| LLM request | `llm.request` | provider, model, messages.count |
| LLM response | `llm.response` | provider, model, duration_ms, success, error.message (if failed) |
| Agent end | `agent.end` | duration_ms, tokens.used |
| Tool call start | `tool.call.start` | tool.name |
| Tool call | `tool.call` | tool.name, duration_ms, success |
| Turn complete | `turn.complete` | - |
| Channel message | `channel.message` | channel, direction |

## Architecture

The OTEL integration uses:

- **OTLP HTTP Protocol**: Sends traces in JSON format over HTTP
- **Batching**: Spans are batched (default 100) before sending for efficiency
- **VTable Pattern**: Implements the `Observer` interface for type-erased polymorphism
- **Async HTTP Client**: Uses the `http` module for non-blocking requests

## Code Location

- `libs/agent/src/otel.zig` - OTEL observer implementation
- `libs/agent/src/observability.zig` - Observer interface and re-exports

## Troubleshooting

### No traces appearing

1. Check endpoint URL:

```bash
curl $OTEL_EXPORTER_OTLP_ENDPOINT
```

1. Enable verbose logging:

```bash
export OTEL_LOG_LEVEL=debug
```

1. Verify the collector is receiving traces:

```bash
# For Jaeger
docker logs jaeger
```

### High memory usage

Reduce batch size:

```zig
var otel = try agent.otel.OtelObserver.init(allocator, .{
    .max_batch_size = 10, // Default is 100
});
```

### Connection errors

The observer logs warnings on failed sends:

```text
[warn] OTEL collector returned status 404
```

Check your endpoint configuration and network connectivity.

## Future Enhancements

- [ ] Metrics export via OTLP metrics endpoint
- [ ] gRPC protocol support
- [ ] Automatic context propagation
- [ ] Custom span attributes
