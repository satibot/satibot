# Telegram Bot Documentation

## Overview

The Telegram Bot is a synchronous implementation that manages interactions with the Telegram Bot API using long-polling. It processes text messages and maintains conversation sessions with AI agents.

## Architecture

```mermaid
graph TB
    %% External Systems
    TG[Telegram API] --> |HTTP Requests| TB[TelegramBot]
    USER[User] --> |Text Messages| TG
    
    %% Core Components
    TB --> AG[Agent]
    TB --> HTTP[HTTP Client]
    TB --> ALLOC[Allocator]
    
    %% Agent Components
    AG --> CTX[Conversation Context]
    AG --> LLM[LLM Provider]
    AG --> MEM[Memory/Session Store]
    
    %% Internal State
    TB --> OFFSET[Update Offset]
    TB --> CHATS[Active Chats]
    TB --> SHUTDOWN[Shutdown Flag]
    
    %% Signal Handling
    SIG[SIGINT/SIGTERM] --> SHUTDOWN
    SHUTDOWN --> |Graceful| TB
    
    %% Message Flow
    TB --> |Process Updates| MSG_LOOP[Message Loop]
    MSG_LOOP --> |Text Only| AG
    AG --> |AI Response| TB
    TB --> |Send Reply| TG
    TG --> |Deliver| USER
    
    %% Configuration
    CFG[Config] --> TB
    CFG --> AG
    
    %% Styling
    classDef external fill:#e1f5fe
    classDef core fill:#f3e5f5
    classDef process fill:#e8f5e8
    classDef state fill:#fff3e0
    
    class TG,USER external
    class TB,HTTP,ALLOC core
    class AG,CTX,LLM,MEM process
    class OFFSET,CHATS,SHUTDOWN,MSG_LOOP state
```

## Key Components

### TelegramBot Struct

- **Purpose**: Main bot implementation that handles Telegram API interactions
- **Key Fields**:
  - `allocator`: Memory management for string operations and JSON parsing
  - `config`: Bot configuration including API tokens and provider settings
  - `offset`: Long-polling offset to prevent duplicate message processing
  - `client`: HTTP client with keep-alive for efficient API calls

### Global State

- **`shutdown_requested`**: Atomic flag for graceful shutdown
- **`active_chats`**: List tracking all chats that need shutdown notifications
- **`active_chats_mutex`**: Thread-safe access to active chats list

## Message Processing Flow

```mermaid
sequenceDiagram
    participant User
    participant Telegram
    participant TelegramBot
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
    
    %% Message Processing
    TelegramBot->>Agent: process message
    Agent->>LLM: generate response
    LLM-->>Agent: AI response
    Agent-->>TelegramBot: final response
    
    %% Response Delivery
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

## Threading Model

```mermaid
graph LR
    MAIN[Main Thread] --> |spawn| AGENT[Agent Thread]
    MAIN --> |spawn| TYPING[Typing Indicator Thread]
    
    AGENT --> |process| LLM[LLM Request]
    TYPING --> |every 5s| TELEGRAM[sendChatAction]
    
    AGENT --> |done| STATE[Shared State]
    TYPING --> |check| STATE
    
    STATE --> |done| MAIN[Join Threads]
    
    classDef thread fill:#e3f2fd
    classDef shared fill:#fce4ec
    
    class MAIN,AGENT,TYPING thread
    class STATE shared
```

### Thread Coordination

- **Agent Thread**: Processes LLM requests and generates responses
- **Typing Thread**: Sends "typing" indicators every 5 seconds
- **Shared State**: Thread-safe coordination using mutex
- **Cleanup**: Both threads joined before processing next message

## Error Handling

### Robustness Features

- **Network Errors**: Retry with 5-second delay on `tick()` failures
- **JSON Parsing**: Optional fields handle missing data gracefully
- **Thread Errors**: Isolated to prevent bot crashes
- **Resource Cleanup**: Proper defer blocks for memory management

### Graceful Shutdown

```mermaid
stateDiagram-v2
    [*] --> Running
    Running --> Shutdown: SIGINT/SIGTERM
    Shutdown --> SendGoodbyeActive: active_chats > 0
    Shutdown --> SendGoodbyeConfig: no active chats
    SendGoodbyeActive --> SendGoodbyeConfig: always
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

- **Purpose**: Send shutdown messages to active users and configured chat
- **Thread Safety**: Mutex-protected ArrayList
- **Lifecycle**: Created on first message, cleaned on shutdown

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

### Concurrent Processing

- **Non-blocking**: Main thread remains responsive
- **Typing Indicators**: Visual feedback during processing
- **Error Isolation**: Thread failures don't crash bot

## Security Notes

- **Token Protection**: Never log or expose bot tokens
- **Input Validation**: JSON parsing with unknown field ignored
- **Memory Safety**: Proper cleanup of allocated strings
