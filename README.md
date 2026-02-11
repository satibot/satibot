<p align="center">
  <img src="docs/icons/icon.png" alt="satibot mascot" width="180" />
</p>

# 🧘 satibot: The Mindful AI Agent Framework

Built in Zig for performance, designed for awareness.

`satibot` is a lightweight, memory-aware AI agent framework that never forgets. Inspired by [OpenClawd](https://github.com/openclaw/openclaw) and [nanobot](https://github.com/HKUDS/nanobot), it combines the power of ReAct loops with persistent memory to create agents that remember, learn, and assist.

IMPORTANT: Currently, it only supports Openrouter (LLM provider), Telegram and console, other features are under development.

- [x] Telegram + OpenRouter
- [x] Console
- [x] chat history saved to JSON base session file, start new session with `/new` message

## Comparison with others

| Feature | OpenClaw | NanoBot | PicoClaw | satibot |
|---|---|---|---|---|
| **Language** | TypeScript | Python | Go | Zig |
| **RAM Usage** | >1GB | >100MB | < 10MB | < 4MB |
| **Startup Time**<br>(0.8GHz core) | >500s | >30s | <1s | ?s |
| **Cost** | Mac Mini $599 | Most Linux SBC<br>~$50 | Any Linux Board<br>As low as $10 | Not checked |

⚡️ **Blazing Fast**: Written in Zig for zero-overhead performance
🧠 **Never Forgets**: Built-in RAG, VectorDB, and GraphDB for long-term memory
🔧 **Extensible**: Easy skill installation and tool system
💬 **Multi-Platform**: [TODO: current is using Telegram and console] Telegram, Discord, WhatsApp, and more

View more in [Features](docs/FEATURES.md).

---

## 📋 Requirements

- **OS**: Linux, macOS, or Windows (with WSL)

> **Note**: This project uses Zig 0.15.0's thread-based concurrency with XevEventLoop.

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

Install Zig: <https://ziglang.org/learn/getting-started/>

```bash
# verify zig version
zig version
# 0.15.2

git clone https://github.com/satibot/satibot.git
cd satibot

# build
zig build
# or
make build

# initialize `~/.bots/config.json`
zig build init
```

### 2. Configure

Read [docs/TELEGRAM_GUIDE.md](docs/TELEGRAM_GUIDE.md) for more details about Telegram + OpenRouter setup.

Edit `~/.bots/config.json`:

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
      "botToken": "",
      "chatId": ""
    }
  }
}
```

Add `satibot` to your PATH, for example add to `~/.zshrc`:

```bash
export PATH="/Users/your-username/chatbot/satibot/zig-out/bin:$PATH"
```

## Run

```bash
# for console, terminal base
satibot console

# for telegram
satibot telegram
```

---

## 💬 Chat Integrations

### Telegram

1. Create bot via [@BotFather](https://t.me/BotFather) --> `/newbot`
2. Get token and user ID via [@userinfobot](https://t.me/userinfobot)
3. Add to config and run `zig build telegram`

### Discord, WhatsApp & More

Full setup guides in our [Documentation](#-documentation).

**New**: WhatsApp support with Meta Cloud API is now available!

---

## 🛠️ Advanced Features

### 🧠 Memory System

- **VectorDB**: Semantic search across conversations
- **GraphDB**: Relationship mapping for complex knowledge
- **RAG**: Retrieval-Augmented Generation for accurate responses
- **Session Cache**: In-memory session history with automatic cleanup (30 minutes idle timeout)

### 🔄 Functional Architecture

satibot uses a pure functional approach for message processing:

- **No State Mutation**: All operations are pure functions that take input and return output
- **Immutable Data**: Session history is treated as immutable data structures
- **Predictable Behavior**: Same input always produces the same output
- **Easy Testing**: Pure functions are simple to test and debug
- **Memory Efficient**: Automatic cleanup prevents memory leaks

The session cache temporarily holds conversation history in memory for performance, automatically cleaning up inactive sessions after 30 minutes to prevent memory accumulation.

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

|Guide|Description|
|----|------------|
|[**Features**](docs/FEATURES.md)|Deep dive into Gateway, Voice, Cron systems|
|[**Configuration**](docs/CONFIGURATION.md)|Complete config guide for providers & tools|
|[**Architecture**](docs/ARCHITECTURE.md)|Technical guide to Agent Loop & Functional Architecture|
|[**Functional Design**](docs/FUNCTIONAL_DESIGN.md)|Pure functional approach and session cache|
|[**Telegram Guide**](docs/TELEGRAM_GUIDE.md)|Step-by-step Telegram bot setup|
|[**WhatsApp Guide**](docs/WHATSAPP_GUIDE.md)|WhatsApp Business API setup|
|[**RAG Guide**](docs/RAG.md)|Understanding the memory system|
|[**Release Guide**](docs/RELEASE_GUIDE.md)|Cross-platform builds and GitHub releases|

---

## 🤝 Contributing

We welcome contributions!

### Quick Development Setup

```bash
# Run the agent with a message
zig build run -- agent -m "Your message"

# Run with a specific session ID to persist history
zig build run -- agent -m "Follow-up message" -s my-session

# Run console-based interactive bot (Xev Mock Bot)
zig build console

# Run as a Telegram Bot (Xev/Asynchronous)
zig build telegram

# Run the GATEWAY (Telegram + Cron + Heartbeat)
zig build run -- gateway

# RAG is enabled by default to remember conversations. 
# To disable it for a specific run:
zig build run -- agent -m "Don't remember this" --no-rag

# Run as WhatsApp bot (requires Meta Cloud API setup)
zig build run -- whatsapp
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
