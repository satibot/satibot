## Development

This project is built with Zig 0.15.2.

### Important: Zig 0.15.0 Migration

This version includes significant changes from previous versions:

- **Async/Await Removed**: Zig 0.15.0 removed async/await support. The event loop has been migrated to use `std.Thread`, `std.Thread.Mutex`, and `std.Thread.Condition`.
- **ArrayList API Changes**: `init()` → `initCapacity()`, `deinit()` and `append()` now require allocator parameter.
- **Type Casting**: `@intCast` now requires explicit type with `@as(Type, @intCast(...))`.
- **Signal Handling**: `std.posix.empty_sigset` → `std.posix.sigemptyset()`.
- **Division**: Signed integer division now requires `@divTrunc`, `@divFloor`, or `@divExact`.

The event loop has been migrated to use XevEventLoop (see `src/utils/xev_event_loop.zig`).

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

Install `ziglint`:

```bash
git clone git@github.com:rockorager/ziglint.git
cd ziglint
zig build -Doptimize=ReleaseFast --prefix $HOME/.local

# run lint
ziglint
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
# (Binary location: ./zig-out/bin/sati)
./zig-out/bin/sati agent -m "Hello world"

# Build with debug info
zig build-exe src/main.zig --name sati -femit-bin=debug/sati
```

Test:

```bash
# Run the agent with a message
zig build run -- agent -m "Your message"
# Run with a specific session ID to persist history
zig build run -- agent -m "Follow-up message" -s my-session
# Run as a Telegram Bot (Xev/Asynchronous)
zig build telegram
# Run as a Console bot (Console-based, uses Xev loop)
zig build console
# Run console with RAG disabled
zig build console -- --no-rag
# Run as a Sync Console bot (simpler, smaller binary, no event loop)
# Uses separate build file for smaller binary (~3.9MB vs 4.8MB)
zig build --build-file build_console_sync.zig
# Run sync console with RAG disabled
zig build --build-file build_console_sync.zig run -- --no-rag
# Run the GATEWAY (Telegram + Cron + Heartbeat)
zig build run -- gateway
# RAG is enabled by default to remember conversations. 
# To disable it for a specific run:
zig build run -- agent -m "Don't remember this" --no-rag
```

### Specialized Tests

```bash
# Run unit tests for the Xev Console bot
zig build test-mock-bot

# Run LLM tests with Xev integration
zig build test-llm-xev

# Run all unit tests
zig build test
```

## Architecture

SatiBot uses a **ReAct** (Reason+Action) loop for agentic behavior, listening for messages from various sources (CLI, Telegram, Cron), processing them through an LLM, executing tools, and persisting state.

For a deep dive into the code structure, Agent Loop, and Gateway system, see the [Architecture Guide](docs/ARCHITECTURE.md).

### Asynchronous Architecture

SatiBot now supports a high-performance asynchronous event loop based on **libxev**. This architecture allows for:

- **Non-blocking I/O**: Multi-threaded HTTP requests that don't block Telegram polling.
- **Task Parallelism**: Concurrent processing of LLM requests across multiple worker threads.
- **Scalability**: Better handling of high-traffic sessions and concurrent users.

For details on the event loop implementation, see [TELEGRAM_CHAT_APP.md](TELEGRAM_CHAT_APP.md).

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
