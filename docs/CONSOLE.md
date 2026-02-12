# Console Bot (Terminal)

A console-based Console bot implementation for testing and development. Simulates Telegram bot behavior using console input/output with the xev event loop.

## Overview

The console bot (`src/agent/console.zig`) provides a command-line interface for testing the AI agent without requiring Telegram API credentials. It reads user input from stdin and processes it through the same agent logic used by the Telegram bot.

## Architecture

```txt
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Console Input  │────▶│   Xev Task Queue │────▶│  Event Loop   │
│  (tick/read)    │     │   (addTask)      │     │  (Worker)     │
└─────────────────┘     └──────────────────┘     └─────────────────┘
         │                                               │
         │                                               ▼
         │                                      ┌─────────────────┐
         │                                      │  Agent Logic    │
         │                                      │  (LLM + Tools)  │
         │                                      └─────────────────┘
         │                                               │
         │                                               ▼
         │                                      ┌─────────────────┐
         └─────────────────────────────────────▶│  Console Output │
                                                │  (Print Reply)  │
                                                └─────────────────┘
```

## Key Characteristics

| Feature | Description |
|---------|-------------|
| **Purpose** | Testing and development without Telegram |
| **Architecture** | xev event loop with async task processing |
| **Input Method** | Console/stdin reading |
| **Session Management** | Mock session IDs (`mock_tg_99999_{counter}`) |
| **Commands** | `/new`, `/help`, `exit`, `quit` |
| **Shutdown** | SIGINT (Ctrl+C) or `exit` command |

## How It Works

### 1. Initialization

```zig
var bot = try MockBot.init(allocator, config);
defer bot.deinit();
```

The Console bot initializes:

- Xev event loop for async processing
- Mock context with allocator and config
- Signal handlers for graceful shutdown
- Task handler for processing console input

### 2. Main Loop

```zig
pub fn run(self: *MockBot) !void
```

The `run()` method:

1. **Setup signal handlers** (SIGINT, SIGTERM)
2. **Start event loop thread** for async processing
3. **Main thread loops** calling `tick()` until shutdown

### 3. Input Reading (tick)

```zig
pub fn tick(self: *MockBot) !void
```

Each `tick()`:

1. Prints `User >` prompt
2. Reads line from stdin (up to 1024 bytes)
3. Handles special commands (`exit`, `quit`)
4. Adds input as task to event loop queue

### 4. Task Processing

```zig
fn mockTaskHandler(allocator: std.mem.Allocator, task: xev_event_loop.Task) anyerror!void
```

The task handler:

**Magic Commands:**

- `/new` - Increment session counter, start fresh session
- `/new <message>` - New session + process message
- `/help` - Show available commands

**Message Processing:**

1. Creates session ID: `mock_tg_99999_{counter}`
2. Initializes Agent with shutdown flag support
3. Runs agent logic: `agent.run(actual_text)`
4. Extracts and prints assistant response
5. Indexes conversation for RAG

### 5. Shutdown Handling

```zig
fn signalHandler(sig: i32) callconv(.c) void
```

Graceful shutdown on SIGINT/SIGTERM:

1. Sets `shutdown_requested` flag
2. Requests event loop shutdown
3. Prints shutdown message (once)

## Code Structure

### `MockBot` Struct

```zig
pub const MockBot = struct {
    allocator: std.mem.Allocator,
    config: Config,
    event_loop: XevEventLoop,
    ctx: MockContext,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*MockBot
    pub fn deinit(self: *MockBot) void
    pub fn tick(self: *MockBot) !void
    pub fn run(self: *MockBot) !void
};
```

### `MockContext` Struct

```zig
pub const MockContext = struct {
    allocator: std.mem.Allocator,
    config: Config,
};
```

### Global State

```zig
var shutdown_requested: std.atomic.Value(bool)      // Shutdown signal flag
var shutdown_message_printed: std.atomic.Value(bool) // Prevent duplicate messages
var global_event_loop: ?*XevEventLoop = null         // For signal handler access
var global_mock_context: ?*MockContext = null        // For task handler access
var mock_session_counter: u32 = 0                  // For unique session IDs
```

## Usage

### Build and Run

```bash
# Build console version
zig build console

# Run
./zig-out/bin/console
```

### Interactive Session

```bash
$ ./zig-out/bin/console
🎮 Mock Xev Bot started. Type 'exit' to quit.

User > hello
[Processing Message]: hello
🤖 [Bot]: Hello! How can I help you today?

User > /new
-----<Starting new session! Send me a new message.>-----

User > tell me about zig
[Processing Message]: tell me about zig
🤖 [Bot]: Zig is a general-purpose programming language...

User > exit
🛑 Console bot shutting down...
--- Console bot shut down successfully. ---
```

### Commands

| Command | Description |
|---------|-------------|
| `exit` or `quit` | Shutdown the bot gracefully |
| `/new` | Clear conversation history and start fresh session |
| `/new <message>` | Clear history and process the message immediately |
| `/help` | Show help text with available commands |

## Error Handling

- **Input errors**: Logged, continue to next iteration
- **Agent errors**: Printed to console, non-fatal
- **Interrupted errors**: Check shutdown flag, exit if set
- **Signal handling**: Graceful cleanup on Ctrl+C

## Session Management

Unlike the Telegram bot which uses real chat IDs, the console bot uses:

- **Base ID**: `mock_tg_99999`
- **Counter**: Increments on each `/new` command
- **Format**: `mock_tg_99999_{counter}`

This allows testing session isolation without real Telegram chats.

## Testing

```bash
# Run unit tests
zig test src/agent/console.zig

# Test with full agent (requires valid config)
zig build console && ./zig-out/bin/console
```

## Comparison with Telegram Bot

| Aspect | Console Bot | Telegram Sync | Telegram Async |
|--------|-------------|---------------|----------------|
| **File** | `console.zig` | `telegram_bot_sync.zig` | `telegram.zig` |
| **Input** | Stdin | Telegram API | Telegram API |
| **Event Loop** | ✅ xev | ❌ Direct | ✅ xev |
| **Session IDs** | `mock_tg_99999_{n}` | `tg_{chat_id}` | `tg_{chat_id}` |
| **Use Case** | Development | Simple deployment | Production |
| **Setup** | No credentials | Telegram token | Telegram token |

## Development Workflow

1. **Test agent logic** without Telegram setup
2. **Debug tool calls** in isolated environment
3. **Verify session management** with `/new` command
4. **Profile memory usage** with simple input/output

## Related Documentation

- [Telegram Sync Version](./TELEGRAM_SYNC.md)
- [Telegram Async Version](./TELEGRAM_CHAT_APP_EVENT_LOOP.md)
