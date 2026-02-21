# SatiBot Architecture

SatiBot is built in **Zig** (version 0.15.2), focusing on performance, memory safety, and explicit controlflow. It uses a **ReAct** (Reason+Action) loop for agentic behavior.

## Monorepo Structure

This project uses a Zig monorepo structure:

```text
libs/
  ├── core/src/         - Config and constants (shared across all modules)
  ├── http/src/         - HTTP client module
  ├── providers/src/   - LLM provider implementations (OpenRouter, Anthropic, Groq)
  ├── db/src/          - Database and session modules
  ├── utils/src/       - Shared utilities (xev_event_loop)
  ├── agent/src/       - Core agent logic
  └── web/src/         - HTTP API endpoints (zap web framework)

apps/
  ├── console/src/     - Console applications (sync + async)
  └── telegram/src/    - Telegram bot
```

Modules are defined in `build.zig` with proper dependency management to avoid circular dependencies. The `core` module provides shared config and constants used by all other modules.

## Observability

### OpenTelemetry Tracing (`libs/agent/src/otel.zig`)

SatiBot includes built-in OpenTelemetry (OTEL) tracing support for distributed observability.

- **OTLP HTTP Protocol**: Sends traces in JSON format over HTTP to any OTEL-compliant backend
- **Supported Backends**: Jaeger, Zipkin, Datadog, Grafana Tempo, AWS X-Ray
- **Configuration**: Via environment variables (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_SERVICE_NAME, etc.)
- **Auto-traced Events**: Agent lifecycle (start, LLM requests, tool calls, etc.)

See [docs/OPENTELEMETRY.md](OPENTELEMETRY.md) for detailed setup instructions.

### Observer Interface (`libs/agent/src/observability.zig`)

A type-erased interface for recording events and metrics using VTable pattern:

- `NoopObserver` - Discards all events (zero-cost default)
- `LogObserver` - Logs to stderr
- `VerboseObserver` - Human-readable indicators for CLI
- `MultiObserver` - Broadcasts to multiple observers
- `OtelObserver` - Sends to OTEL collector

## Core Components

### 1. `Agent` (`libs/agent/src/agent.zig`)

The central struct that manages:

- **Context**: Conversation history (messages, tool results).
- **ToolRegistry**: Available capabilities.
- **Provider**: Connection to the LLM (OpenRouter, etc.).

### 2. `Gateway` (`libs/agent/src/agent/gateway.zig`)

A multi-threaded supervisor that runs background services:

- **Telegram Thread**: Long-polling loop for fetching updates.
- **Cron Thread**: Ticks every second to check for scheduled jobs.
- **Heartbeat Thread**: Ticks periodically to process the heartbeat file.

#### `XevEventLoop` (`libs/utils/src/xev_event_loop.zig`)

A high-performance asynchronous event loop based on **libxev**. It handles non-blocking I/O and task scheduling using platform-native APIs (io_uring, kqueue, epoll).

- **Task Handler**: Centralized processing for background tasks.
- **HTTP Integration**: HTTP requests are processed asynchronously as event loop tasks.
- **Offset Management**: Tracks the polling state for Telegram.

### 3. `ToolRegistry` (`libs/agent/src/agent/tools.zig`)

A dynamic dispatch system for tools. Tools are defined as Zig functions matching the signature:

```zig
fn(ctx: ToolContext, args: []const u8) ![]const u8
```

This allows tools to be statically compiled but dynamically invoked by the LLM's string output.

### 4. Memory & persistence

- **Session API**: JSON-based storage in `~/.bots/sessions/`.
- **VectorDB**: Simple cosine-similarity search for long-term memory retrieval.
- **GraphDB**: Node-Edge storage for mapping relationships (e.g., User -> likes -> Zig).

---

## The Agent Loop (ReAct)

The core loop in `Agent.run()` follows this pattern:

1. **Input**: Receive user message.
2. **Context**: Append message to chat history.
3. **Think**: Send history to LLM.
4. **Decide**:
    - **Text content?** -> Display/Send to user.
    - **Tool call?** ->
        1. Parse arguments (JSON).
        2. **Execute**: Look up tool in Registry and run it.
        3. **Observe**: Append tool result to context.
        4. **Loop**: Go back to Step 3 (Think) with new information.
    - **Done?** -> Break loop (or max iterations reached).
5. **Persist**: Save updated session state to disk.

---

## Component Diagram

```mermaid
graph TD
    User((User))
    
    subgraph "Gateway Process"
        Telegram[Telegram Bot]
        Cron[Cron Scheduler]
        Heart[Heartbeat Service]
    end
    
    subgraph "Agent Core"
        Agent[Agent Struct]
        Context[Context / History]
        Registry[Tool Registry]
    end
    
    subgraph "External"
        LLM[LLM Provider]
        Groq[Groq API]
        Web[Web Search]
    end

    User -- Message/Voice --> Telegram
    Telegram -- Voice File --> Groq
    Groq -- Text --> Agent
    
    Cron -- Trigger --> Agent
    Heart -- Trigger --> Agent
    
    Agent -- Prompt --> LLM
    LLM -- Tool Call --> Registry
    Registry -- Execute --> Web
    Registry -- Result --> Agent
    
    Agent --> Context
    Context --> Disk[(JSON Files)]
```
