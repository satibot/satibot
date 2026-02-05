<p align="center">
  <img src="docs/icons/icon.png" alt="satibot mascot" width="180" />
</p>

# satibot

Inspired by [OpenClawd](https://github.com/openclaw/openclaw) and [nanobot](https://github.com/HKUDS/nanobot), `satibot` is a Ziglang-based agent framework for:

- Chat tools intergation: Telegram, Discord, WhatsApp, etc.
- LLM providers (OpenRouter, Anthropic, etc.)
- Tool execution: shell commands, HTTP requests, etc.
- Conversation history
- Session persistence: Full session persistence in `~/.bots/sessions/`.
- Easy to add SKILL from any source, the agent can browse, search, and install its own skills.
  - Browse skills: <https://agent-skills.md/>
  - Install: `./scripts/install-skill.sh <github-url-or-path>`
- Context management: use memory, file, etc.
- **RAG & Knowledge base**: Local base with built-in support for:
  - **VectorDB**: Semantic search and long-term memory.
  - **GraphDB**: Relationship mapping and complex knowledge retrieval.
  - **RAG**: Retrieval-Augmented Generation for fact-based responses.

## Usage

```bash
# Run the agent with a message
zig build run -- agent -m "Your message"

# Run with a specific session ID to persist history
zig build run -- agent -m "Follow-up message" -s my-session

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

### Component Hierarchy (Text)

```text
src/main.zig (runAgent)
├── src/config.zig (Config.load)
├── src/agent.zig (Agent.init)
│   ├── src/agent/session.zig (load)
│   └── src/agent/tools.zig (ToolRegistry.init)
└── src/agent.zig (Agent.run)
    ├── src/providers/openrouter.zig (chatStream)
    │   └── src/http.zig (Client.postStream)
    ├── src/agent/context.zig (Context.add_message)
    ├── src/agent/tools.zig (Tool.execute)
    └── src/agent/session.zig (save)
```

#### ReAct Loop

```text
┌─────────────────────────────────────────────────────────────────┐
│                         Agent.run()                             │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
              ┌──────────────────────────────┐
              │  Add user message to context │
              └──────────────┬───────────────┘
                             │
         ┌───────────────────┴───────────────────┐
         │           AGENT LOOP                  │
         │       (max 10 iterations)             │
         │                                       │
         │    ┌─────────────────────────────┐    │
         │    │   LLM chatStream() call     │◄───┼──────────┐
         │    │   (Selects Provider)        │    │          │
         │    └─────────────┬───────────────┘    │          │
         │                  │                    │          │
         │                  ▼                    │          │
         │    ┌─────────────────────────────┐    │          │
         │    │  Add assistant response     │    │          │
         │    │  to context                 │    │          │
         │    └─────────────┬───────────────┘    │          │
         │                  │                    │          │
         │                  ▼                    │          │
         │         ┌────────────────┐            │          │
         │         │  Tool calls?   │            │          │
         │         └───────┬────────┘            │          │
         │                 │                     │          │
         │        ┌────────┴────────┐            │          │
         │        │                 │            │          │
         │       YES               NO            │          │
         │        │                 │            │          │
         │        ▼                 │            │          │
         │  ┌───────────────┐       │            │          │
         │  │ Execute tools │       │            │          │
         │  └───────┬───────┘       │            │          │
         │          │               │            │          │
         │          ▼               │            │          │
         │  ┌───────────────┐       │            │          │
         │  │ Add tool      │       │            │          │
         │  │ results/errors│───────┼────────────┼──────────┘
         │  │ to context    │       │            │ (continue loop)
         │  └───────────────┘       │            │
         │                          │            │
         └──────────────────────────┼────────────┘
                                    │
                                    ▼ (break loop)
              ┌──────────────────────────────┐
              │     Save session to disk     │
              └──────────────────────────────┘
```

### System Flow (Mermaid)

```mermaid
graph TD
    Main[src/main.zig: main] --> Config[src/config.zig: load]
    Main --> AgentInit[src/agent.zig: Agent.init]
    AgentInit --> SessionLoad[src/agent/session.zig: load]
    AgentInit --> Registry[src/agent/tools.zig: ToolRegistry.init]
    Main --> AgentRun[src/agent.zig: Agent.run]
    
    subgraph Agent Loop
        AgentRun --> Chat[src/providers/openrouter.zig: chatStream]
        Chat --> HTTP[src/http.zig: Client.postStream]
        AgentRun --> Context[src/agent/context.zig: Context.add_message]
        AgentRun --> ToolExec[src/agent/tools.zig: Tool.execute]
    end

    AgentRun --> SessionSave[src/agent/session.zig: save]
```

## Configuration

The agent's configuration is stored in `~/.bots/config.json`. You can configure your providers and chat tools there:

```json
{
  "agents": {
    "defaults": {
      "model": "anthropic/claude-3-7-sonnet"
    }
  },
  "providers": {
    "openrouter": {
      "apiKey": "YOUR_OPENROUTER_KEY"
    },
    "anthropic": {
      "apiKey": "YOUR_ANTHROPIC_KEY"
    }
  },
  "tools": {
    "web": {
      "search": {
        "apiKey": "YOUR_BRAVE_SEARCH_KEY"
      }
    },
    "telegram": {
      "botToken": "YOUR_BOT_TOKEN",
      "chatId": "YOUR_DEFAULT_CHAT_ID"
    },
    "discord": {
      "webhookUrl": "YOUR_WEBHOOK_URL"
    },
    "whatsapp": {
      "accessToken": "YOUR_META_ACCESS_TOKEN",
      "phoneNumberId": "YOUR_PHONE_NUMBER_ID",
      "recipientPhoneNumber": "YOUR_DEFAULT_RECIPIENT"
    }
  }
}
```

## Addition information

### Bot name meaning

TL;DR: In SatiBot, Sati means “remembering to stay aware of what is happening right now.” It comes from Pāli, where it originally meant memory, and in Buddhism evolved into the idea of mindful awareness — not forgetting the present moment.

1. The original meaning (language level)

In Pāli (the language of early Buddhist texts), sati literally means:

> memory + recollection + not forgetting

It comes from an ancient Indo-European root meaning “to remember”.

So at its most basic level, sati is the mental ability to keep something in mind instead of losing track of it.

1. How Buddhism deepened the meaning

In Buddhist psychology, the word was expanded.

> remembering the present experience

In other words:

- Remember you are breathing
- Remember you are walking
- Remember anger is happening
- Remember thoughts are arising

So "mindfulness" (the common English translation) really means:

> "not forgetting what is happening now"

Metaphorically, SatiBot suggests a system that:

- Doesn’t forget context
- Tracks state consistently
- Stays aware of ongoing processes
- Doesn’t lose events in the flow
