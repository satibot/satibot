# Debugging Guide

This guide covers debugging capabilities in satibot, including the debug flag system and troubleshooting techniques.

## Debug Mode

### Overview

satibot includes a built-in debug mode that provides detailed logging for troubleshooting and development. The debug mode can be enabled using command-line flags.

### Enabling Debug Mode

```bash
# Long form flag
satibot --debug <command>

# Short form flag  
satibot -D <command>

# Examples
satibot --debug status
satibot -D agent -m "hello world"
satibot --debug telegram-sync
```

### Log Levels

satibot uses structured logging with different levels:

| Level | Prefix | Description | When Shown |
|-------|--------|-------------|------------|
| **info** | `[info]` | General operational information | Always |
| **warn** | `[warn]` | Warning messages | Always |
| **err** | `[err]` | Error messages | Always |
| **debug** | `[debug]` | Detailed debug information | Only with `--debug`/`-D` |

### Log Format

```text
[level] (scope): message
```

- **level**: Log level (info, warn, err, debug)
- **scope**: Module name (main, telegram_bot, agent, etc.)
- **message**: Log message content

### Examples

#### Normal Mode (Clean Output)

```bash
$ satibot status
--- satibot 🐸 (build: 2026-02-13 10:24:25 UTC) ---
[info] (main): Running status command

--- satibot Status 🐸 ---
Default Model: z-ai/glm-4.5-air:free
...
```

#### Debug Mode (Detailed Output)

```bash
$ satibot --debug status
--- satibot 🐸 (build: 2026-02-13 10:24:25 UTC) ---
[debug] (main): Parsed 2 command line arguments
[debug] (main): Debug mode enabled
[debug] (main): After filtering, have 2 arguments
[debug] (main): Dispatching command: status
[debug] (main): Starting status check
[info] (main): Running status command
[debug] (main): Configuration loaded successfully

--- satibot Status 🐸 ---
Default Model: z-ai/glm-4.5-air:free
...
```

## Debugging Common Issues

### Configuration Problems

Use debug mode to diagnose configuration issues:

```bash
satibot --debug status
```

Look for:

- Configuration file loading errors
- Missing API keys
- Invalid model names
- Permission issues

### Network Issues

Debug network connectivity:

```bash
satibot --debug test-llm
```

Look for:

- Connection timeouts
- API authentication errors
- Rate limiting messages
- Network resolution issues

### Telegram Bot Issues

Debug Telegram bot problems:

```bash
satibot --debug telegram-sync
```

Look for:

- Bot token validation
- Chat ID resolution
- Message parsing errors
- Webhook/polling issues

### Memory and Performance

Monitor memory usage and performance:

```bash
satibot --debug agent -m "test message"
```

Look for:

- Memory allocation patterns
- Session cache behavior
- Vector DB operations
- RAG indexing performance

## Advanced Debugging

### Environment Variables

Set environment variables for additional debugging:

```bash
# Enable verbose logging
export SATIBOT_DEBUG=1

# Specify log file
export SATIBOT_LOG_FILE=/tmp/satibot.log

# Set log level explicitly
export SATIBOT_LOG_LEVEL=debug
```

### Debug Scopes

Different modules have different debug scopes:

- **main**: Command parsing, configuration loading
- **telegram_bot**: Telegram bot operations
- **agent**: Agent processing and tool execution
- **heartbeat**: Background task scheduling

### Common Debug Patterns

#### 1. Command Not Found

```bash
$ satibot unknown-command
[err] (main): Unknown command: unknown-command
```

**Solution**: Check available commands with `satibot help`

#### 2. Configuration Missing

```bash
$ satibot --debug status
[debug] (main): Starting status check
[err] (main): Failed to load config: FileNotFound
```

**Solution**: Run `satibot in` to create initial configuration

#### 3. API Key Issues

```bash
$ satibot --debug test-llm
[debug] (main): Testing LLM provider connectivity
[err] (main): OpenRouter API key not configured
```

**Solution**: Set `OPENROUTER_API_KEY` environment variable or update config.json

#### 4. Telegram Bot Token

```bash
$ satibot --debug telegram-sync
[debug] (telegram_bot): Initializing Telegram bot
[err] (telegram_bot): Invalid bot token format
```

**Solution**: Get valid bot token from @BotFather on Telegram

## Performance Debugging

### Memory Usage

Monitor memory usage with debug mode:

```bash
# Check baseline memory
satibot --debug status

# Monitor during operations
satibot --debug agent -m "long test message"
```

### Timing Information

Debug mode includes timing information for operations:

- Configuration loading time
- API request duration
- Vector DB search time
- Message processing latency

### Resource Cleanup

Debug mode shows resource cleanup:

- Session cache expiration
- Memory deallocation
- Connection cleanup
- File handle management

## Troubleshooting Checklist

When encountering issues:

1. **Enable Debug Mode**: Use `--debug` or `-D` flag
2. **Check Configuration**: Verify config.json syntax and values
3. **Verify API Keys**: Ensure environment variables are set
4. **Test Connectivity**: Use `satibot test-llm` to verify provider access
5. **Check Permissions**: Ensure file access to ~/.bots directory
6. **Monitor Resources**: Check memory and disk space
7. **Review Logs**: Look for error patterns and warnings

## Getting Help

If debug mode doesn't resolve your issue:

1. **Collect Debug Output**: Save full debug log
2. **Check Documentation**: Review relevant guide documents
3. **Search Issues**: Check GitHub issues for similar problems
4. **Create Issue**: Include debug output and configuration details

## Development Debugging

For developers working on satibot:

### Adding Debug Logs

```zig
const log = std.log.scoped(.your_module);

// Debug level (only shown with --debug)
log.debug("Detailed operation info: {s}", .{details});

// Info level (always shown)
log.info("Operation completed: {s}", .{operation});

// Error level (always shown)
log.err("Operation failed: {any}", .{error});
```

### Testing Debug Functionality

Run tests with debug output:

```bash
zig test src/main_test.zig
```

See `src/main_test.zig` for debug flag parsing tests.
