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

1. Start Jaeger with OTLP receiver enabled:

```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest
```

- **Port 16686**: Jaeger UI (view traces here)
- **Port 4318**: OTLP HTTP receiver (app sends traces here)

1. Run satibot with OTEL environment variables:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318/v1/traces
export OTEL_SERVICE_NAME=satibot-dev
# Run any command that uses the observer
sati console
```

1. View traces at <http://localhost:16686>. Select the Service `satibot-dev` and click "Find Traces".

## Testing in a Real App

When deploying or testing in a real application, follow this checklist to ensure traces are flowing correctly:

### 1. Verification Checklist

- [ ] **Connectivity**: The app can reach `OTEL_EXPORTER_OTLP_ENDPOINT`.
- [ ] **Service Name**: `OTEL_SERVICE_NAME` is set to distinguish environments (e.g., `satibot-staging`).
- [ ] **Batching**: Spans are batched by default (100). In low-traffic apps, it may take time for the first batch to send. For immediate results during testing, reduce `max_batch_size` to `1`.

### 2. Manual Verification

You can manually send a trace to your collector using `curl` to verify it's working:

```bash
curl -X POST http://localhost:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{
    "resourceSpans": [{
      "resource": { "attributes": [{ "key": "service.name", "value": { "stringValue": "curl-test" } }] },
      "scopeSpans": [{
        "spans": [{
          "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
          "spanId": "00f067aa0ba902b7",
          "name": "test-span",
          "startTimeUnixNano": "'$(date +%s%N)'",
          "endTimeUnixNano": "'$(date +%s%N)'"
        }]
      }]
    }]
  }'
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

### Inspect Raw Payloads

If you suspect the JSON format is incorrect, you can use `nc` (netcat) to act as a mock collector and print the raw JSON sent by the app:

```bash
# In one terminal, listen on port 4318
nc -l 4318

# In another terminal, run the app pointing to localhost:4318
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318/v1/traces
sati console
```

### High memory usage

Reduce batch size if the app stores too many spans in memory:

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
