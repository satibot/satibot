# Telegram Bot: Sync vs Async Versions

satibot offers two Telegram bot implementations, each designed for different use cases.

## 🔄 Synchronous Version (Simple & Reliable)

**File**: `src/agent/telegram_bot_sync.zig`

The synchronous version processes messages one at a time, making it simple and reliable.

### Characteristics

- **Single-threaded**: Processes messages sequentially
- **Simple architecture**: Direct HTTP calls, no event loop complexity
- **Easy to debug**: Straightforward execution flow
- **Lower resource usage**: No thread pools or event loop overhead
- **Predictable behavior**: Each message is fully processed before the next

### When to Use

✅ **Use the sync version when:**

- You need a simple, reliable bot
- Resource usage is a concern (e.g., small VPS)
- You're developing or debugging
- You don't need high-throughput concurrent processing
- You want the easiest setup and maintenance
- You only need text message support

❌ **Don't use the sync version when:**

- You need voice message transcription
- You need high-performance concurrent processing
- You have many concurrent users

### Architecture

```text
┌─────────────┐    ┌──────────────┐    ┌─────────────┐
│   Polling   │───▶│ Process One  │───▶│   Response  │
│   Loop      │    │   Message    │    │   Send      │
└─────────────┘    └──────────────┘    └─────────────┘
```

### Performance

- **Memory**: ~2MB base usage, smaller than async version
- **CPU**: Low, single-threaded
- **Throughput**: 1 message at a time
- **Latency**: ~1-2 seconds per message

## ⚡ Asynchronous Version (High Performance)

**File**: `src/chat_apps/telegram/telegram.zig`

The asynchronous version uses xev event loop for concurrent message processing.

### Characteristics

- **Event-driven**: Handles multiple messages concurrently
- **High performance**: Optimized for throughput
- **Complex architecture**: Event loop with task queues
- **Higher resource usage**: Thread pools and event loop overhead
- **Scalable**: Can handle many simultaneous messages

### When to Use

✅ **Use the async version when:**

- You need high-throughput processing
- You have many concurrent users
- Performance is critical
- You have sufficient system resources
- You're comfortable with complex debugging

### Architecture

```mermaid
graph LR
    A[ Polling Loop ] -->|-->| B[ Event Loop ]
    B -->|-->| C[ Concurrent Processing ]
```

### Performance

- **Memory**: more than sync version
- **CPU**: Medium, multi-threaded
- **Throughput**: Multiple messages concurrently
- **Latency**: ~500ms per message (under load)

## 🚀 Quick Start

### Sync Version

```bash
# Build and run sync version
zig build s-telegram-sync
./zig-out/bin/s-telegram-sync

# Or via main CLI
sati s-telegram-sync
```

### Async Version

```bash
# Build and run async version
zig build s-telegram
./zig-out/bin/s-telegram

# Or via main CLI
sati s-telegram
```

## 📊 Feature Comparison

| Feature | Sync Version | Async Version |
|---|---|---|
| **Simplicity** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Performance** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Resource Usage** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Debugability** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Scalability** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Reliability** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Concurrent Processing** | ❌ Sequential | ✅ Concurrent |

## 🔧 Configuration

Both versions use the same configuration file (`~/.bots/config.json`):

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
      "botToken": "your-bot-token"
    }
  }
}
```

**Note**: The sync version only requires OpenRouter for text processing.
Groq is only needed for voice transcription in the async version.

## 🛠️ Development

### Adding New Features

1. **Sync Version**: Modify `telegram_bot_sync.zig`
   - Simple, direct implementation
   - Easy to test and debug
   - Good for prototyping

2. **Async Version**: Modify `telegram.zig` and `telegram_handlers.zig`
   - More complex, event-driven
   - Requires understanding of xev event loop
   - Better for production features

### Testing

```bash
# Test sync version
zig build test-sync

# Test async version  
zig build test-telegram
```

## 🚨 Troubleshooting

### Sync Version Issues

- **Problem**: Bot seems slow
- **Cause**: Sequential processing
- **Solution**: Consider async version for high load

### Async Version Issues

- **Problem**: Complex debugging
- **Cause**: Event loop concurrency
- **Solution**: Use sync version for development

## 📚 Migration

### From Sync to Async

1. Test async version in development
2. Monitor resource usage
3. Gradual rollout to production

### From Async to Sync

1. Evaluate performance requirements
2. Check resource constraints
3. Simple deployment switch

## 💡 Best Practices

1. **Start with sync version** for development and testing
2. **Upgrade to async version** for production with high load
3. **Monitor resource usage** and performance metrics
4. **Choose based on requirements**, not just performance

## 🤝 Contributing

When contributing to the Telegram bot:

1. **Clearly indicate** which version you're modifying
2. **Test both versions** if making core changes
3. **Update documentation** for new features
4. **Consider performance impact** on both versions

---

**Need help?** Check the [main documentation](../README.md) or open an issue on GitHub.
