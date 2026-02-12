# Telegram Chat Bot: Synchronous Version

A simplified, synchronous Telegram bot implementation that processes messages one at a time. Designed for reliability, simplicity, and lower resource usage.

## Overview

The synchronous version (`src/agent/telegram_bot_sync.zig`) uses direct HTTP calls and sequential message processing. It is ideal for development, debugging, and deployments where simplicity is preferred over high-throughput concurrency.

## Architecture

```txt
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Long-Polling   │────▶│ Process Message  │────▶│  Send Response  │
│  Loop (tick)    │     │  (Sequential)    │     │  to Telegram    │
└─────────────────┘     └──────────────────┘     └─────────────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌──────────────────┐
│ Telegram API    │     │ Agent + LLM      │
│ getUpdates      │     │ (OpenRouter)     │
└─────────────────┘     └──────────────────┘
```

## Key Characteristics

| Feature | Description |
|---------|-------------|
| **Processing** | Single-threaded, one message at a time |
| **Architecture** | Direct HTTP calls, no event loop |
| **Memory Usage** | ~2MB base, minimal overhead |

## How It Works

### 1. Initialization

```zig
var bot = try TelegramBot.init(allocator, config);
defer bot.deinit();
```

The bot initializes with:

- HTTP client (60s timeout, keep-alive enabled)
- Configuration (bot token, model settings)
- Offset tracker (prevents duplicate message processing)

### 2. Message Polling

```zig
pub fn tick(self: *TelegramBot) !void
```

The `tick()` method performs one polling iteration:

1. **Long-polling request** to Telegram API:

   ```text
   GET https://api.telegram.org/bot{token}/getUpdates?offset={offset}&timeout=5
   ```

2. **Parse updates** from JSON response

3. **Process each message sequentially**:
   - Update offset to acknowledge message
   - Handle voice messages (reject with notice)
   - Process text messages through Agent

4. **Send responses** back to Telegram

### 3. Message Processing Flow

For each text message:

```text
User Message --> Session ID (tg_{chat_id}) --> Agent.run() --> LLM (OpenRouter) --> Response
```

**Session Management**: Each chat gets a unique session ID (`tg_123456`) for persistent conversation history.

**Magic Commands**:

- `/new` - Clear conversation memory and start fresh
- `/new <message>` - Clear memory and process the message

```json
{
  "model": "<configured-model>",
  "messages": [
    {
      "role": "system",
      "content": "You can access to a local Vector Database where you can store and retrieve information from past conversations.\nUse 'vector_search' or 'rag_search' when the user asks about something you might have discussed before...\nUse 'upsertVector' to remember important facts..."
    },
    {
      "role": "user", 
      "content": "<the user's actual message text>"
    }
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "upsertVector",
        "description": "Add text to vector database for future retrieval...",
        "parameters": {"type": "object", "properties": {"text": {"type": "string"}}}
      }
    },
    {
      "type": "function", 
      "function": {
        "name": "vector_search",
        "description": "Search vector database for similar content...",
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "top_k": {"type": "integer"}}}
      }
    }
  ]
}
```

### 4. Agent Integration

```zig
var agent = Agent.init(allocator, config, session_id);
defer agent.deinit();

try agent.run(user_text);
```

The Agent:

1. Loads conversation history from disk
2. Sends "typing" indicator to Telegram
3. Processes message through LLM (OpenRouter)
4. Executes any tool calls (vector search/upsert)
5. Returns final response

## Code Structure

### `TelegramBot` Struct

```zig
pub const TelegramBot = struct {
    allocator: std.mem.Allocator,
    config: Config,
    offset: i64 = 0,           // Prevents duplicate processing
    client: http.Client,       // Reused for connection keep-alive

    pub fn init(allocator: std.mem.Allocator, config: Config) !TelegramBot
    pub fn deinit(self: *TelegramBot) void
    pub fn tick(self: *TelegramBot) !void
    fn send_message(self: *TelegramBot, token: []const u8, chat_id: []const u8, text: []const u8) !void
    fn send_chat_action(self: *TelegramBot, token: []const u8, chat_id: []const u8) !void
};
```

### Main Entry Point

```zig
pub fn run(allocator: std.mem.Allocator, config: Config) !void
```

The `run()` function:

1. Initializes the bot
2. Sends startup message to admin chat (if configured)
3. Enters infinite polling loop with error recovery
4. Retries on network errors (5-second delay)

## Usage

### Build and Run

```bash
# Build sync version
zig build telegram-sync

# Run
./zig-out/bin/telegram-sync
```

### Configuration

Required in `~/.bots/config.json`:

```json
{
  "agents": {
    "defaults": {
      "model": "arcee-ai/trinity-large-preview:free"
    }
  },
  "providers": {
    "openrouter": {
      "apiKey": "sk-or-v1-xxx"
    }
  },
  "tools": {
    "telegram": {
      "botToken": "your-bot-token",
      "chatId": "admin-chat-id"
    }
  }
}
```

## Error Handling

The sync version uses simple error handling:

- **Network errors**: Logged, retry after 5 seconds
- **API errors**: Logged, continue processing
- **Agent errors**: Send user-friendly error message
- **Typing indicator failures**: Non-fatal, continue processing

## Limitations

1. **Sequential processing**: One message at a time
2. **No voice support**: Voice messages rejected with notice
3. **No concurrency**: Cannot handle multiple users simultaneously
4. **Blocking**: Long LLM responses block other messages

## When to Use

✅ **Use sync version when:**

- Developing or debugging
- Resource usage is a concern
- Simple, reliable bot needed
- No voice transcription required
- Low concurrent user load

❌ **Don't use when:**

- High-throughput needed
- Voice transcription required
- Many concurrent users
- Production with heavy load

## Testing

```bash
# Run unit tests
zig build test-sync

# Test specific functions
zig test src/agent/telegram_bot_sync.zig
```

## Comparison with Async Version

| Aspect | Sync Version | Async Version |
|--------|--------------|---------------|
| File | `telegram_bot_sync.zig` | `chat_apps/telegram/telegram.zig` |
| Complexity | Low | High |
| Resource Usage | Low | Medium |
| Throughput | 1 msg at a time | Concurrent |

## Related Documentation

- [Sync vs Async Comparison](./TELEGRAM_SYNC_VS_ASYNC.md)
- [Async Event Loop Version](./TELEGRAM_CHAT_APP_EVENT_LOOP.md)
- [Main README](../README.md)
