<p align="center">
  <img src="docs/icons/icon.png" alt="satibot mascot" width="180" />
</p>

# 🧘 satibot: The Mindful AI Agent Framework

**Built in Zig for performance, designed for awareness.**

`satibot` is a lightweight, memory-aware AI agent framework that never forgets. Inspired by [OpenClawd](https://github.com/openclaw/openclaw) and [nanobot](https://github.com/HKUDS/nanobot), it combines the power of ReAct loops with persistent memory to create agents that remember, learn, and assist.

⚡️ **Blazing Fast**: Written in Zig for zero-overhead performance
🧠 **Never Forgets**: Built-in RAG, VectorDB, and GraphDB for long-term memory
🔧 **Extensible**: Easy skill installation and tool system
💬 **Multi-Platform**: Telegram, Discord, WhatsApp, and more

View more in [Features](docs/FEATURES.md).

---

## ✨ Key Features

🪶 **Lightweight & Fast**: Minimal footprint with Zig's performance guarantees
🔬 **Research-Ready**: Clean, readable codebase perfect for experimentation
⚡️ **Gateway System**: Single command runs all services together
🧠 **Smart Memory**: RAG + VectorDB + GraphDB for intelligent context management
🔧 **Skill Ecosystem**: Browse and install skills from <https://agent-skills.md/>
🎙️ **Voice Ready**: Automatic voice transcription with Groq
⏰ **Proactive**: Heartbeat system wakes agent for pending tasks
📅 **Scheduled**: Built-in cron for recurring tasks

---

## 🚀 Quick Start

### 1. Install

```bash
git clone https://github.com/satibot/satibot.git
cd satibot
```

### 2. Configure

Create `~/.bots/config.json`:

```json
{
  "providers": {
    "openrouter": {
      "apiKey": "sk-or-v1-xxx"
    }
  },
  "agents": {
    "defaults": {
      "model": "anthropic/claude-3-5-sonnet"
    }
  }
}
```

### 3. Run

```bash
# Chat directly
zig build run -- agent -m "Hello, satibot!"

# Start the gateway (Telegram + Cron + Heartbeat)
zig build run -- gateway

# Run as Telegram bot
zig build run -- telegram
```

That's it! You have a mindful AI assistant running in seconds.

---

## 💬 Chat Integrations

### Telegram

1. Create bot via [@BotFather](https://t.me/BotFather) → `/newbot`
2. Get token and user ID via [@userinfobot](https://t.me/userinfobot)
3. Add to config and run `zig build run -- gateway`

### Discord, WhatsApp & More

Full setup guides in our [Documentation](#-documentation).

---

## 🛠️ Advanced Features

### 🧠 Memory System

- **VectorDB**: Semantic search across conversations
- **GraphDB**: Relationship mapping for complex knowledge
- **RAG**: Retrieval-Augmented Generation for accurate responses

### 🔧 Skills & Tools

```bash
# Browse available skills
curl https://agent-skills.md/

# Install a new skill
./scripts/install-skill.sh <github-url-or-path>

# Use built-in tools
zig build run -- agent -m "Run: ls -la"
```

### ⏰ Automation

```bash
# Heartbeat: Proactive task checking
echo "Check emails" > HEARTBEAT.md

# Cron: Schedule recurring tasks
zig build run -- cron --schedule "0 9 * * *" --message "Daily summary"
```

---

## 📚 Documentation

| Guide | Description |
|-------|-------------|
| [**Features**](docs/FEATURES.md) | Deep dive into Gateway, Voice, Cron systems |
| [**Configuration**](docs/CONFIGURATION.md) | Complete config guide for providers & tools |
| [**Architecture**](docs/ARCHITECTURE.md) | Technical guide to Agent Loop & internals |
| [**Telegram Guide**](docs/TELEGRAM_GUIDE.md) | Step-by-step Telegram bot setup |
| [**RAG Guide**](docs/RAG.md) | Understanding the memory system |

---

## 🏗️ Project Structure

```text
src/
├── main.zig              # CLI entry point
├── agent.zig             # Core agent logic
├── config.zig            # Configuration management
├── http.zig              # HTTP client
├── providers/            # LLM provider implementations
│   ├── base.zig
│   └── openrouter.zig
└── agent/                # Agent subsystems
    ├── context.zig       # Conversation history
    ├── session.zig       # Session persistence
    ├── tools.zig         # Tool system
    ├── vector_db.zig     # Vector database
    └── graph_db.zig      # Graph database
```

---

## 🤝 Contributing

We welcome contributions!

### Quick Development Setup

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

---

## 📖 The Meaning of Sati

**Sati** (Pāli) means "mindful awareness" — the art of not forgetting the present moment - "remembering to stay aware of what is happening right now.".

In Buddhist psychology, sati evolved from simple memory to profound awareness:

- Remember you are breathing
- Remember thoughts are arising
- Remember what is happening now

**SatiBot embodies this principle:**

- 🧠 Never forgets context or conversations
- 📍 Tracks state consistently across sessions
- 👁️ Stays aware of ongoing processes
- 🌊 Never loses events in the flow

---

## 📊 Stats

![GitHub stars](https://img.shields.io/github/stars/satibot/satibot?style=social)
![GitHub forks](https://img.shields.io/github/forks/satibot/satibot?style=social)
![GitHub issues](https://img.shields.io/github/issues/satibot/satibot)
![GitHub license](https://img.shields.io/github/license/satibot/satibot)

---

## 📄 License

Licensed under the MIT License.

---

<div align="center">
  <sub>Built with ❤️ by the SatiBot community</sub>
</div>
