## Development

This project is built with Zig 0.15.2.

### Important: Zig 0.15.0 Migration

This version includes significant changes from previous versions:

- **Async/Await Removed**: Zig 0.15.0 removed async/await support. The event loop has been migrated to use `std.Thread`, `std.Thread.Mutex`, and `std.Thread.Condition`.
- **ArrayList API Changes**: `init()` → `initCapacity()`, `deinit()` and `append()` now require allocator parameter.
- **Type Casting**: `@intCast` now requires explicit type with `@as(Type, @intCast(...))`.
- **Signal Handling**: `std.posix.empty_sigset` → `std.posix.sigemptyset()`.
- **Division**: Signed integer division now requires `@divTrunc`, `@divFloor`, or `@divExact`.

See [THREAD_BASED_EVENT_LOOP.md](THREAD_BASED_EVENT_LOOP.md) for details on the new architecture.

### Prerequisites

You can check your Zig version with:

```bash
zig version
# Should be 0.15.2
```

Simple way to buid:

```bash
zig build
```

Build and run tests:

```bash
zig build test
```

### Common Tasks (Makefile)

This project uses a `Makefile` to simplify common development commands.

**Note**: The `.env` file loading is currently disabled in the Makefile. Environment variables should be set via shell exports or configuration files.

To install system dependencies (Debian/Ubuntu):

```bash
make install-deps
```

For code coverage (`make coverage`), you will also need [kcov](https://github.com/SimonKagstrom/kcov) installed. See [kcov installation guide](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md).

```bash
# Show all available commands
make help

# Build the project (Debug mode)
make build

# Build for Release
make release

# Run unit tests
make test

# Generate coverage report (requires kcov)
make coverage
# Reports are generated in coverage-out/index.html

# Format code
make format

# Check code style
make lint

# Clean build artifacts
make clean

# Build for all platforms (cross-compilation)
make build-all

# Build for specific platforms
make build-macos    # macOS Intel + Apple Silicon
make build-linux    # Linux x86_64 + ARM64
make build-windows  # Windows x86_64

# Create checksums for releases
make checksums
```

See [RELEASE_GUIDE.md](RELEASE_GUIDE.md) for detailed release instructions.

### Running the Application

To run the agent with arguments, use `zig build run` or execute the binary directly:

```bash
# Build and run
zig build run -- agent -m "Hello world"

# Or run the binary directly after building
# (Binary location: ./zig-out/bin/satibot)
./zig-out/bin/satibot agent -m "Hello world"

# Build with debug info
zig build-exe src/main.zig --name satibot -femit-bin=debug/satibot
```

Test:

```bash
# Run the agent with a message
zig build run -- agent -m "Your message"
# Run with a specific session ID to persist history
zig build run -- agent -m "Follow-up message" -s my-session
# Run as a Telegram Bot (long polling)
zig build run -- telegram
# Run the GATEWAY (Telegram + Cron + Heartbeat)
zig build run -- gateway
# RAG is enabled by default to remember conversations. 
# To disable it for a specific run:
zig build run -- agent -m "Don't remember this" --no-rag
```

## Structure

- `src/main.zig`: CLI entry point
- `src/agent.zig`: Agent logic
- `src/config.zig`: Configuration
- `src/http.zig`: HTTP client
- `src/providers/base.zig`: Provider interface
- `src/providers/openrouter.zig`: OpenRouter provider
- `src/root.zig`: Library exports
- `src/agent/context.zig`: Conversation history management
- `src/agent/session.zig`: Session persistence
- `src/agent/tools.zig`: Tool system and registry
- `src/agent/vector_db.zig`: Local vector database for semantic search
- `src/agent/graph_db.zig`: Local graph database for relationship mapping

## Architecture

SatiBot uses a **ReAct** (Reason+Action) loop for agentic behavior, listening for messages from various sources (CLI, Telegram, Cron), processing them through an LLM, executing tools, and persisting state.

For a deep dive into the code structure, Agent Loop, and Gateway system, see the [Architecture Guide](docs/ARCHITECTURE.md).

**Current behavior**: The function blocks until the HTTP POST completes. This is fine for the current architecture since:

1. `tick()` processes messages sequentially anyway
2. Most calls are immediate user responses where you want confirmation of success/failure
3. The shutdown defer block uses it synchronously

**When async would help**:

- Sending multiple messages concurrently without blocking the main loop
- If you refactor to use an async event loop architecture
- For fire-and-forget scenarios where you don't care about the result

**Quick check**: Is your `http.Client` already async-capable? Let me verify:

Your `http.Client` uses **blocking I/O** (`std.net.tcpConnectToHost`, synchronous reads/writes), so making `send_message` async would have no benefit unless you also rewrite the HTTP layer to be async-capable.

**Current situation:**

- `send_message` --> `client.post()` --> blocking TCP/TLS I/O
- Sequential message processing in `tick()` - you process one message at a time anyway
- Shutdown cleanup in `run()` defer block requires synchronous execution

**When async would help:**

- Sending multiple messages concurrently without blocking the main loop
- Higher throughput scenarios (many chats, broadcast messages)
- You want fire-and-forget message sending without waiting for HTTP response

**To make it async, you'd need to:**

1. **Rewrite `http.Client`** to use `std.net.tcpConnectToHostAsync` + `std.event.Loop` or an async runtime
2. **Add async keywords** to the call chain:

   ```zig
   pub async fn send_message(...) !void {
       const response = try await async self.client.post(url, headers, body);
       // ...
   }
   ```

3. **Refactor callers** in `tick()` and `run()` to use `async`/`await` or an executor

**Alternative (simpler)**: If you just want non-blocking sends without full async, use `std.Thread.spawn()` to send messages in background threads.

**Verdict**: Keep it synchronous unless you have a specific performance need for concurrent message sending. The current architecture doesn't benefit from async.

## Configuration

The agent's configuration is stored in `~/.bots/config.json`.
See the [Configuration Guide](docs/CONFIGURATION.md) for full details on setting up Providers (OpenRouter, Groq), Tools, and Agents.

## Addition information

### Bot name meaning

TL;DR: In SatiBot, Sati means "remembering to stay aware of what is happening right now.". It comes from Pāli, where it originally meant memory, and in Buddhism evolved into the idea of mindful awareness — not forgetting the present moment.

The original meaning (language level)
In Pāli (the language of early Buddhist texts), sati literally means:

> memory + recollection + not forgetting

It comes from an ancient Indo-European root meaning “to remember”.
So at its most basic level, sati is the mental ability to keep something in mind instead of losing track of it.

How Buddhism deepened the meaning:

In Buddhist psychology, the word was expanded.

> remembering the present experience
