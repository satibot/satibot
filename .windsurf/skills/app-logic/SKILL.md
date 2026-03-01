# Skill: SatiBot App Logic Flow Diagrams

This skill provides Mermaid diagrams illustrating the application logic and data flow in SatiBot.

## High-Level Architecture

```mermaid
flowchart TB
    subgraph Apps["Applications"]
        Console[Console App]
        Telegram[Telegram Bot]
        Web[Web API Server]
    end

    subgraph Agent["libs/agent - Core Agent"]
        AgentCore[Agent]
        Context[Context]
        ToolRegistry[Tool Registry]
    end

    subgraph Providers["LLM Providers"]
        OpenRouter[OpenRouter]
        Anthropic[Anthropic]
        Groq[Groq]
    end

    subgraph DB["Database Layer"]
        SessionDB[Session Storage]
        VectorDB[Vector Database]
        GraphDB[Graph Database]
    end

    subgraph Tools["Tools"]
        WebSearch[Web Search]
        WebFetch[Web Fetch]
        FileOps[File Operations]
        RAG[RAG Search]
    end

    Console --> AgentCore
    Telegram --> AgentCore
    Web --> AgentCore

    AgentCore --> Context
    AgentCore --> ToolRegistry
    AgentCore --> Providers

    ToolRegistry --> Tools
    Tools --> WebSearch
    Tools --> WebFetch
    Tools --> FileOps
    Tools --> RAG

    AgentCore --> SessionDB
    RAG --> VectorDB
    Tools --> GraphDB

    SessionDB --> DB
    VectorDB --> DB
    GraphDB --> DB
```

## Web API Request Flow

```mermaid
sequenceDiagram
    participant Client as HTTP Client
    participant Server as Web Server (:8080)
    participant Handler as handleRequest
    participant Chat as handleChat
    participant Agent as Agent
    participant LLM as LLM Provider
    participant DB as Session DB

    Client->>Server: POST /api/chat {messages}
    Server->>Handler: handleRequest(req)
    Handler->>Chat: handleChat(req)
    Chat->>Chat: Parse JSON body
    Chat->>Agent: Agent.init(allocator, config, session_id, rag_enabled)
    Chat->>Agent: ctx.addMessage(history)
    Chat->>Agent: bot.run(user_input)
    Agent->>LLM: Send messages + tools
    LLM-->>Agent: Response (with/without tool calls)
    alt Has tool calls
        Agent->>Tools: Execute tools
        Tools-->>Agent: Tool results
        Agent->>LLM: Continue conversation
    end
    Agent-->>Chat: Final response
    Chat-->>Server: JSON response
    Server-->>Client: {"content": "..."}
```

## Telegram Bot Flow

```mermaid
flowchart TB
    subgraph Main["Main Entry"]
        MainFn[main.zig] --> Config[Load Config]
        Config --> BotRun[telegram.runBot]
    end

    subgraph EventLoop["Xev Event Loop"]
        Poll[Poll Updates] --> HTTP[HTTP Task]
        HTTP --> Process[Process Update]
    end

    subgraph TelegramAPI["Telegram API"]
        GetUpdates[getUpdates]
        SendMessage[sendMessage]
    end

    subgraph Handlers["Telegram Handlers"]
        Parse[Parse Update]
        CreateAgent[Create Agent]
        ProcessMsg[Process Message]
        GetResponse[Get Response]
    end

    BotRun --> EventLoop
    EventLoop --> GetUpdates
    GetUpdates --> TelegramAPI
    TelegramAPI --> Parse
    Parse --> Process
    Process --> CreateAgent
    CreateAgent --> ProcessMsg
    ProcessMsg --> GetResponse
    GetResponse --> SendMessage
    SendMessage --> TelegramAPI
```

## Agent Execution Flow

```mermaid
flowchart TB
    Start[User Input] --> Init[Initialize Agent]
    Init --> LoadHistory[Load Session History]
    LoadHistory --> SystemPrompt[Ensure System Prompt]
    SystemPrompt --> AddUser[Add User Message]
    AddUser --> Loop{Loop (max 10)}
    
    Loop -->|Iteration| LLM[Call LLM Provider]
    LLM --> Response{Response Type}

    Response -->|Text| Save[Save to Context]
    Response -->|Tool Calls| Execute[Execute Tools]
    Execute --> Results[Get Results]
    Results --> LLM
    
    Save --> Done{More iterations?}
    Done -->|Yes| Loop
    Done -->|No| Return[Return Response]
    
    Return --> GetMsgs[ctx.getMessages]
    GetMsgs --> LastMsg[Last Assistant Message]
```

## Console App Flow

```mermaid
flowchart LR
    Start[main] --> Args[Parse Args --no-rag]
    Args --> Config[Load Config]
    Config --> Run[console_sync.run]
    Run --> Loop{Chat Loop}
    
    Loop --> Input[Read Input]
    Input --> Empty{Empty?}
    Empty -->|Yes| Exit
    Empty -->|No| Agent[Create Agent]
    
    Agent --> RunBot[bot.run(input)]
    RunBot --> Output[Print Response]
    Output --> Loop
```

## RAG (Retrieval-Augmented Generation) Flow

```mermaid
flowchart TB
    User[User Query] --> Agent
    Agent --> Embed[Generate Embeddings]
    Embed --> Local{Embedding Model}
    Local -->|local| LocalEmbed[Local Embedder]
    Local -->|remote| API[OpenRouter API]
    
    LocalEmbed --> VectorDB[Vector DB Search]
    API --> VectorDB
    
    VectorDB --> Results[Top K Results]
    Results --> Context[Build Context]
    Context --> Prompt[Add to Prompt]
    Prompt --> LLM[Call LLM]
    LLM --> Response[Generate Response]
```

## Session Management Flow

```mermaid
flowchart TB
    subgraph Load["Load Session"]
        Init[Agent Init] --> CheckConfig{Check config.loadChatHistory}
        CheckConfig -->|Yes| LoadSession[session.load]
        CheckConfig -->|No| Skip
        LoadSession --> Limit[Limit by maxChatHistory]
        Limit --> Add[Add to Context]
    end
    
    subgraph Save["Save Session"]
        Response[Get Response] --> AddMsg[Add to Context]
        AddMsg --> SaveSession[session.save]
    end
    
    Add --> Response
    SaveSession --> Cleanup
```

## Tool Execution Flow

```mermaid
flowchart LR
    LLM[LLM Response<br/>with tool_calls] --> Parse[Parse Tool Call]
    Parse --> Registry[ToolRegistry]
    Registry --> Find{Find Tool}
    Find -->|Found| Execute[Execute Tool]
    Find -->|Not Found| Error[Error]
    
    Execute --> web_search[web_search]
    Execute --> web_fetch[web_fetch]
    Execute --> read_file[read_file]
    Execute --> write_file[write_file]
    Execute --> list_files[list_files]
    
    web_search --> Result1[Search Results]
    web_fetch --> Result2[Fetched Content]
    read_file --> Result3[File Content]
    write_file --> Result4[Write Success]
    list_files --> Result5[File List]
    
    Result1 --> Return[Return to LLM]
    Result2 --> Return
    Result3 --> Return
    Result4 --> Return
    Result5 --> Return
```

## Web Server Endpoints

```mermaid
flowchart TB
    Request[HTTP Request] --> Route{Route Path}
    
    Route -->|GET /| Status[Return OK Status]
    Route -->|GET /openapi.json| OpenAPI[Return OpenAPI Spec]
    Route -->|POST /api/chat| Chat[Handle Chat]
    Route -->|OPTIONS| CORS[CORS Preflight]
    Route -->|Other| NotFound[404 Not Found]
    
    Chat --> Parse[Parse JSON]
    Parse --> Validate{Validate Messages}
    Validate -->|Invalid| Error[Return Error]
    Validate -->|Valid| Agent[Create Agent]
    
    Agent --> Run[Run Agent]
    Run --> Response[Format Response]
    Response --> JSON[Return JSON]
```

## Key Files Reference

| Component | Key Files |
|-----------|-----------|
| Agent | `libs/agent/src/agent.zig` |
| Context | `libs/agent/src/agent/context.zig` |
| Tools | `libs/agent/src/agent/tools.zig` |
| Web Server | `apps/web/src/main.zig` |
| Telegram Bot | `apps/telegram/src/telegram/telegram.zig` |
| Console | `apps/console/src/main.zig` |
| Config | `libs/core/src/config.zig` |

## Configuration Flow

```mermaid
flowchart LR
    Env[Environment Variables] --> Load[config.load]
    Load --> Parse[Parse & Validate]
    Parse --> Config{Config Struct}
    
    Config --> APIKeys[API Keys<br/>- OPENROUTER_API_KEY<br/>- TELEGRAM_BOT_TOKEN]
    Config --> Agents[Agent Settings<br/>- model<br/>- embeddingModel<br/>- maxChatHistory<br/>- disableRag]
    Config --> Tools[Tool Config<br/>- web.search.apiKey<br/>- server.allowOrigin]
```
