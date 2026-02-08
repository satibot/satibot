# Telegram Bot Documentation

## Overview

The Telegram Bot is an event loop-based implementation that manages interactions with the Telegram Bot API using long-polling. It processes text messages asynchronously through an event-driven architecture and maintains conversation sessions with AI agents.

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
  - `event_loop`: AsyncEventLoop for concurrent message processing
  - `offset`: Long-polling offset to prevent duplicate message processing
  - `client`: HTTP client with keep-alive for efficient API calls

### AsyncEventLoop

- **Purpose**: Event-driven message processing and cron job management
- **Key Components**:
  - `message_queue`: Queue for immediate message processing
  - `event_queue`: Priority queue for timed events
  - `cron_jobs`: HashMap for scheduled tasks
  - `active_chats`: List tracking active conversations

### Global State

- **`shutdown_requested`**: Atomic flag for graceful shutdown

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
    Note over TelegramBot: Bot starts and sends startup message
    
    %% Message Reception
    User->>Telegram: Sends text message
    Telegram->>TelegramBot: getUpdates webhook
    
    %% Voice Message Handling (if applicable)
    alt Voice Message
        TelegramBot->>TelegramBot: Send "not supported" message
        Note over User: User informed voice messages not supported
    end
    
    %% Message Processing via Event Loop
    TelegramBot->>EventLoop: addChatMessage()
    EventLoop->>EventLoop: processEvents()
    EventLoop->>Agent: process message
    Agent->>LLM: generate response
    LLM-->>Agent: AI response
    Agent-->>EventLoop: final response
    
    %% Response Delivery
    EventLoop-->>TelegramBot: response ready
    TelegramBot->>Telegram: sendMessage
    Telegram->>User: bot response
    
    %% Session Management
    Agent->>Agent: index_conversation()
```

## Command Handling

The bot supports several magic commands:

### `/help`

- **Purpose**: Display available commands
- **Response**: Shows command list and usage instructions

### `/new`

- **Purpose**: Clear conversation session memory
- **Action**: Deletes session file and starts fresh conversation
- **Variant**: `/new <prompt>` clears session then processes prompt

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

- **Main Thread**: Handles Telegram API polling and event loop execution
- **Message Queue**: Immediate processing of incoming chat messages
- **Event Queue**: Priority-based processing of timed events
- **Cron Jobs**: Scheduled tasks with configurable intervals
- **Agent Processing**: Synchronous AI response generation
- **Resource Management**: Automatic cleanup and memory management

## Error Handling

### Robustness Features

- **Network Errors**: Retry with 5-second delay on `tick()` failures
- **JSON Parsing**: Optional fields handle missing data gracefully
- **Event Loop Errors**: Isolated to prevent bot crashes
- **Resource Cleanup**: Proper defer blocks for memory management

### Graceful Shutdown

```mermaid
stateDiagram-v2
    [*] --> Running
    Running --> Shutdown: SIGINT/SIGTERM
    Shutdown --> SendGoodbyeConfig: always
    SendGoodbyeConfig --> Cleanup
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

### Long-Polling Optimization

- **Timeout**: 5 seconds to reduce empty responses
- **Offset Management**: Prevents duplicate processing
- **Connection Reuse**: Keep-alive reduces overhead

### Event Loop Processing

- **Non-blocking**: Event loop processes messages efficiently
- **Queue-based**: Message and event queues prevent blocking
- **Resource Efficient**: No thread spawning overhead
- **Scalable**: Handles multiple concurrent conversations

## Security Notes

- **Token Protection**: Never log or expose bot tokens
- **Input Validation**: JSON parsing with unknown field ignored
- **Memory Safety**: Proper cleanup of allocated strings
