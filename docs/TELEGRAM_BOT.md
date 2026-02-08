# Telegram Bot Documentation

## Overview

The Telegram Bot is a fully async event loop-based implementation that manages interactions with the Telegram Bot API using long-polling. Telegram polling runs as a background task within the event loop, messages are processed asynchronously, and responses are sent via a callback mechanism.

Source code: `src/agent/telegram_bot.zig`.

## Architecture

```mermaid
graph TB
    %% External Systems
    TG[Telegram API] --> |HTTP Requests| TB[TelegramBot]
    USER[User] --> |Text Messages| TG
    
    %% Core Components
    TB --> EL[AsyncEventLoop]
    TB --> HTTP[HTTP Client]
    TB --> ALLOC[Allocator]
    
    %% Event Loop Components
    EL --> MSG_QUEUE[Message Queue]
    EL --> EVENT_QUEUE[Event Queue]
    EL --> CRON[Cron Jobs]
    EL --> ACTIVE_CHATS[Active Chats]
    
    %% Agent Components
    AG[Agent] --> CTX[Conversation Context]
    AG --> LLM[LLM Provider]
    AG --> MEM[Memory/Session Store]
    
    %% Internal State
    TB --> OFFSET[Update Offset]
    TB --> SHUTDOWN[Shutdown Flag]
    
    %% Signal Handling
    SIG[SIGINT/SIGTERM] --> SHUTDOWN
    SHUTDOWN --> |Graceful| TB
    
    %% Message Flow
    TB --> |addChatMessage| EL
    EL --> |processEvents| AG
    AG --> |AI Response| TB
    TB --> |Send Reply| TG
    TG --> |Deliver| USER
    
    %% Configuration
    CFG[Config] --> TB
    CFG --> EL
    CFG --> AG
    
    %% Styling
    classDef external fill:#e1f5fe
    classDef core fill:#f3e5f5
    classDef process fill:#e8f5e8
    classDef state fill:#fff3e0
    classDef event fill:#fff8e1
    
    class TG,USER external
    class TB,HTTP,ALLOC core
    class AG,CTX,LLM,MEM process
    class OFFSET,SHUTDOWN state
    class EL,MSG_QUEUE,EVENT_QUEUE,CRON,ACTIVE_CHATS event
```

## Key Components

### TelegramBot Struct

- **Purpose**: Main bot implementation that handles Telegram API interactions
- **Key Fields**:
  - `allocator`: Memory management for string operations and JSON parsing
  - `config`: Bot configuration including API tokens and provider settings
  - `event_loop`: `AsyncEventLoop` for concurrent message processing (contains offset, bot_token, message_sender callback)
  - `client`: `http.Client` with keep-alive for efficient API calls
- **Methods**:
  - `init()`: Creates HTTP client (60s timeout, keep-alive) and event loop with Telegram bot support
  - `deinit()`: Cleans up event loop and HTTP connections
  - `tick()`: (Legacy) Single polling iteration - fetches updates, processes messages, sends replies
  - `send_chat_action()`: Sends typing indicators to Telegram
  - `send_message()`: Sends text messages via Telegram API

### `run()` Entry Point

- **Purpose**: Main entry point for the Telegram Bot service
- **Flow**:
  1. Validates `telegram` config exists (returns `TelegramConfigNotFound` if missing)
  2. Initializes bot instance with async event loop
  3. Sets up SIGINT/SIGTERM signal handlers (signal handler calls `event_loop.requestShutdown()`)
  4. Validates `chatId` is configured (returns `TelegramChatIdNotConfigured` if missing)
  5. Sends startup message to configured chat
  6. Starts event loop: `event_loop.run()` (blocking, handles polling + processing)
  7. On shutdown: sends goodbye message to configured chat via defer block

**Note**: The main loop no longer calls `tick()` directly. Instead, `pollTelegramTask()` runs as a background thread within the event loop, fetching updates and queuing messages for async processing.

### AsyncEventLoop

- **Purpose**: Event-driven message processing, cron job management, and Telegram polling
- **Key Components**:
  - `message_queue`: Queue for immediate message processing
  - `event_queue`: Priority queue for timed events
  - `cron_jobs`: HashMap for scheduled tasks
  - `active_chats`: List tracking active conversations
  - `bot_token`: Telegram bot token for API calls
  - `message_sender`: Callback function for sending responses to Telegram
  - `http_client`: Shared HTTP client for polling
  - `offset`: Long-polling offset to prevent duplicate message processing
- **Key Methods**:
  - `initWithBot()`: Initialize with Telegram bot support (token, sender callback, HTTP client)
  - `pollTelegramTask()`: Background task that polls Telegram API and queues messages
  - `processChatMessage()`: Process messages and send responses via callback
  - `run()`: Main event loop (starts polling thread, heartbeat, cron jobs, processes queue)

### Global State

- **`shutdown_requested`**: `std.atomic.Value(bool)` with `seq_cst` ordering for thread-safe shutdown signaling

## Message Processing Flow

```mermaid
sequenceDiagram
    participant User
    participant Telegram
    participant TelegramBot
    participant EventLoop
    participant Agent
    participant LLM
    
    %% Initial Setup
    Note over TelegramBot: run() validates config, sends startup message
    
    %% Main Loop
    Note over TelegramBot: event_loop.run() starts polling thread
    
    %% Async Polling
    loop Async polling in background
        AsyncEventLoop->>AsyncEventLoop: pollTelegramTask()
        AsyncEventLoop->>Telegram: getUpdates (long-polling, 5s timeout)
        Telegram-->>AsyncEventLoop: JSON updates array
        AsyncEventLoop->>AsyncEventLoop: Add messages to queue
    end
    
    %% Message Processing
    loop Process messages from queue
        AsyncEventLoop->>Agent: processChatMessage()
        Agent->>LLM: generate response
        LLM-->>Agent: AI response
        Agent-->>AsyncEventLoop: response via message_sender callback
        AsyncEventLoop->>Telegram: sendMessage(response)
    end
```

## Command Handling

The bot supports two magic commands (detected via `std.mem.startsWith`):

### `/help`

- **Purpose**: Display available commands
- **Response**: Shows command list (`/new`, `/help`) and usage instructions
- **Behavior**: Sends help text and skips further processing (`continue`)

### `/new`

- **Purpose**: Clear conversation session memory
- **Action**: Deletes session file at `~/.bots/sessions/tg_{chat_id}.json`
- **Variant**: `/new` alone sends confirmation and skips processing
- **Variant**: `/new <prompt>` clears session then processes `<prompt>` with a fresh agent

### Session ID Format

- **Pattern**: `tg_{chat_id}` (e.g., `tg_123456789`)
- **Storage**: `~/.bots/sessions/tg_{chat_id}.json`

## Event Loop Architecture

```mermaid
graph TB
    %% Main Components
    MAIN[Main Thread] --> |runs| EL[AsyncEventLoop]
    MAIN --> |polls| TG[Telegram API]
    
    %% Event Loop Processing
    EL --> MSG_Q[Message Queue]
    EL --> EVENT_Q[Event Queue]
    EL --> CRON_Q[Cron Jobs]
    
    %% Message Flow
    TG --> |addChatMessage| MSG_Q
    MSG_Q --> |processChatMessage| AGENT[Agent]
    
    %% Event Processing
    EVENT_Q --> |timed events| HANDLER[Event Handler]
    CRON_Q --> |schedule| EVENT_Q
    
    %% Agent Processing
    AGENT --> |LLM request| LLM[LLM Provider]
    LLM --> |response| AGENT
    
    %% Response Flow
    AGENT --> |response| TG
    TG --> |deliver| USER[User]
    
    %% Styling
    classDef main fill:#e3f2fd
    classDef event fill:#fff8e1
    classDef process fill:#e8f5e8
    classDef external fill:#e1f5fe
    
    class MAIN main
    class EL,MSG_Q,EVENT_Q,CRON_Q,HANDLER event
    class AGENT,LLM process
    class TG,USER external
```

### Event Loop Coordination

- **Main Thread**: Calls `event_loop.run()` which blocks until shutdown
- **Polling Thread**: Background thread running `pollTelegramTask()` for Telegram API long-polling
- **Heartbeat Thread**: Background thread for periodic health checks
- **Message Queue**: Immediate processing of incoming chat messages (populated by polling thread)
- **Event Queue**: Priority-based processing of timed events (cron jobs)
- **Agent Processing**: Synchronous AI response generation within event loop
- **Response Delivery**: Via `message_sender` callback to send responses back to Telegram
- **Resource Management**: Automatic cleanup and memory management

## Error Handling

### Robustness Features

- **Network Errors**: Retry with 5-second delay on polling failures
- **Event Loop Errors**: Logged but don't crash the bot
- **Agent Errors**: Caught per-message, sends error notice to user, does not crash bot
- **JSON Parsing**: `ignore_unknown_fields = true`, optional fields handle missing data
- **Resource Cleanup**: Proper `defer` blocks for all allocations (`allocPrint`, `path.join`, etc.)
- **Typing Indicator**: `send_chat_action` errors are silently ignored (`catch {}`)
- **RAG Indexing**: `index_conversation()` errors are silently ignored (`catch {}`)
- **Signal Handling**: SIGINT/SIGTERM triggers graceful shutdown via `requestShutdown()`

### Graceful Shutdown

```mermaid
stateDiagram-v2
    [*] --> ValidateConfig
    ValidateConfig --> InitBot: config OK
    ValidateConfig --> [*]: missing config (error)
    InitBot --> SetupSignals
    SetupSignals --> SendStartup
    SendStartup --> StartEventLoop: event_loop.run()
    StartEventLoop --> PollTelegram: spawn pollTelegramTask thread
    StartEventLoop --> Heartbeat: spawn heartbeat thread
    StartEventLoop --> ProcessQueue: process messages
    PollTelegram --> ProcessQueue: queue messages
    ProcessQueue --> SendResponse: via message_sender callback
    SendResponse --> TelegramAPI: sendMessage()
    StartEventLoop --> Shutdown: SIGINT/SIGTERM
    Shutdown --> SendGoodbye: defer block sends to configured chatId
    SendGoodbye --> Cleanup: bot.deinit()
    Cleanup --> [*]
```

## Configuration Requirements

### Required Fields

- `tools.telegram.botToken`: Bot authentication token
- `tools.telegram.chatId`: Default chat for startup messages

### Optional Fields

- `providers.*`: Various LLM provider configurations

## Memory Management

### JSON-Based Session Storage

The bot uses **JSON-based memory** stored in `~/.bots/sessions/` directory:

- **Storage Format**: JSON files named `{session_id}.json`
- **Location**: `~/.bots/sessions/` (shared across bot instances)
- **Structure**: Each session contains an array of `LLMMessage` objects

### Memory Components

#### Session Module (`src/agent/session.zig`)

- **Purpose**: Persistent conversation storage
- **Functions**:
  - `save()`: Serializes messages to JSON with 2-space indentation
  - `load()`: Deserializes JSON back to memory structures
  - `saveToPath()`/`load_internal()`: Low-level file operations

#### Context Module (`src/agent/context.zig`)

- **Purpose**: In-memory conversation management
- **Structure**: `ArrayListUnmanaged(LLMMessage)` for efficient message storage
- **Operations**: Add messages, retrieve conversation history

#### Message Structure

```zig
pub const LLMMessage = struct {
    role: []const u8,           // "user", "assistant", "system", "tool"
    content: ?[]const u8,       // Message text (optional for tool results)
    tool_call_id: ?[]const u8,  // Tool call identifier
    tool_calls: ?[]const ToolCall, // Array of tool calls
};
```

### Memory Flow to LLM

#### Session Loading (Agent initialization)

```zig
// In Agent.init()
if (session.load(allocator, session_id)) |history| {
    for (history) |msg| {
        self.ctx.add_message(msg) catch {};
    }
}
```

#### Memory Transmission to LLM

1. **Context Retrieval**: `self.ctx.get_messages()` returns all conversation messages
2. **Provider Integration**: Messages sent directly to LLM providers (Anthropic, Groq, etc.)
3. **Complete History**: Entire conversation context included in each LLM request

#### Session Persistence

```zig
// After each message processing
try session.save(self.allocator, self.session_id, self.ctx.get_messages());
```

### Long-Term Memory (RAG)

The bot also implements **Retrieval-Augmented Generation**:

#### index_conversation()

- Concatenates all message content into full text
- Creates embeddings using `get_embeddings()`
- Stores in vector database via `vector_upsert()`
- Enables semantic search across conversation history

### Session Management Features

#### Session Commands

- `/new`: Clears session file, starts fresh conversation
- `/new <prompt>`: Clears session then processes immediate prompt

#### Memory Safety

- Deep copying of all strings to prevent memory corruption
- Proper cleanup with `deinit()` methods
- Tool call data duplication for independence

#### Session Error Handling

- Graceful handling of missing session files (returns empty array)
- JSON parsing with `ignore_unknown_fields = true`
- 10MB file size limit for session loading

### JSON Session Example

```json
{
  "messages": [
    {
      "role": "user",
      "content": "Hello, how are you?"
    },
    {
      "role": "assistant", 
      "content": "I'm doing well, thank you!"
    },
    {
      "role": "user",
      "content": "Can you help me with Zig programming?"
    }
  ]
}
```

### Active Chat Tracking

- **Purpose**: Track active conversations within the event loop
- **Management**: Handled internally by AsyncEventLoop
- **Lifecycle**: Created on first message, cleaned on shutdown
- **Thread Safety**: Mutex-protected within event loop

## Telegram API Methods

The bot uses three Telegram Bot API endpoints:

- **`getUpdates`**: `GET /bot{token}/getUpdates?offset={n}&timeout=5` - Long-polling for new messages
- **`sendMessage`**: `POST /bot{token}/sendMessage` - Send text replies to users
- **`sendChatAction`**: `POST /bot{token}/sendChatAction` - Show "typing" indicator

### Request Format

- **Content-Type**: `application/json`
- **Body**: JSON with `chat_id` + `text` (sendMessage) or `action` (sendChatAction)
- **Response Parsing**: `UpdateResponse` struct defined inline in `tick()` with `ignore_unknown_fields`

## HTTP Client Configuration

- **Timeout**: 60 seconds for all requests
- **Keep-Alive**: Enabled for connection reuse
- **TLS**: Handshake optimization for long-running operations

## Debug Logging

The bot provides extensive debug output:

- Message processing status
- Error details with context
- Shutdown process tracking
- Active chat management

## Performance Considerations

### Async Architecture Benefits

- **True Async**: Polling runs in background thread, main thread processes queue
- **No Blocking**: Main thread never blocked by network I/O during polling
- **Queue-based**: Messages queued for processing, preventing message loss during high load
- **Thread Safety**: Mutex-protected queues enable concurrent access
- **Scalable**: Handles multiple concurrent conversations efficiently

### Long-Polling Optimization

- **Timeout**: 5-second server-side wait reduces empty responses
- **Offset Management**: `self.offset = update_id + 1` prevents duplicate processing
- **Connection Reuse**: Keep-alive HTTP client reduces TLS handshake overhead
- **Polling Interval**: 100ms sleep between cycles in pollTelegramTask() prevents tight looping

### Event Loop Processing

- **Non-blocking**: Event loop processes messages from queue without waiting for polling
- **Queue-based**: Message and event queues prevent blocking between components
- **Resource Efficient**: Minimal thread spawning (only polling + heartbeat threads)
- **Scalable**: Handles multiple concurrent conversations via queue processing
- **Callback-based**: Responses sent via message_sender callback, decoupling components

### Agent Lifecycle

- **Per-message**: A fresh `Agent` is created for each incoming message
- **Session Loading**: Agent loads history from disk on init
- **Session Saving**: Agent saves updated history after `run()` completes
- **Cleanup**: Agent is deinitialized via `defer` after each message

## Security Notes

- **Token Protection**: Never log or expose bot tokens
- **Input Validation**: JSON parsing with `ignore_unknown_fields = true`
- **Memory Safety**: Proper cleanup of all allocated strings via `defer`
- **Voice Messages**: Rejected with user-facing notice (not processed)

## Unit Tests

The file includes the following tests:

- **`TelegramBot lifecycle`**: Init/deinit with event loop configured for Telegram
- **`TelegramBot init fails without config`**: init() returns error when telegram config is null
- **`TelegramBot config validation`**: Verifies fields are accessible after init
- **`TelegramBot session ID generation`**: `tg_{chat_id}` format validation
- **`TelegramBot command detection - /new`**: `startsWith` logic for `/new` and `/new <prompt>`
- **`TelegramBot message JSON serialization`**: JSON output contains expected fields
- **`TelegramBot config file template generation`**: Template contains all required config keys
- **`TelegramBot parallel messages`** (various tests): Tests concurrent message queuing via event loop
