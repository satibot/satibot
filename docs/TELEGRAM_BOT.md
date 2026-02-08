# Telegram Bot Documentation

## Overview

The Telegram Bot is an event loop-based implementation that manages interactions with the Telegram Bot API using long-polling. It processes text messages asynchronously through an event-driven architecture and maintains conversation sessions with AI agents.

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

### `/setibot`

- **Purpose**: Generate default configuration file
- **Action**: Creates `~/.bots/config.json` with template
- **Features**: Handles existing config gracefully

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

### Session Storage

- **Location**: `~/.bots/sessions/{session_id}.json`
- **Format**: JSON conversation history
- **Cleanup**: Manual via `/new` command

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
