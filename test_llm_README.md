# LLM Standalone Test

This test allows you to verify LLM functionality without requiring Telegram or chat dependencies.

## Quick Start

### Option 1: Using curl (Recommended)

1. Set your API key:

```bash
export LLM_API_KEY='your-api-key-here'
```

1. Run the test:

```bash
./test_llm_api.sh
```

This script uses curl to test the LLM API directly and requires `jq` for JSON parsing.

### Option 2: Using the Zig implementation

The Zig implementation currently requires integration with the build system. See the Manual Build section below.

## Environment Variables

- **LLM_API_KEY** (required): Your API key for the LLM provider
- **LLM_MODEL** (optional): Model name (default: `claude-3-haiku-20240307`)
- **LLM_PROVIDER** (optional): Provider to use (`anthropic` or `groq`, default: `anthropic`)
- **LLM_BASE_URL** (optional): Custom base URL for the API

## Test Cases

The test includes three scenarios:

1. **Simple Completion**: Tests basic request/response
2. **Conversation with Context**: Tests conversation with system prompt
3. **Error Handling**: Tests behavior with invalid API key

## Manual Build

If you prefer to build manually:

```bash
zig build-exe test_llm_standalone.zig \
  --deps config,providers \
  --mod config:src/config.zig \
  --mod providers:src/providers/base.zig \
  --cache-dir .zig-cache \
  --name test_llm_standalone
```

## Example Output

```text
Testing LLM provider: anthropic
Model: claude-3-haiku-20240307
==========================================

Test 1: Simple completion
------------------------

Prompt: Say 'Hello World' in exactly two words.
Response: Hello World
Tokens used: 6

Test 2: Conversation with context
--------------------------------

System: You are a helpful assistant who loves cats.
User: What is your favorite animal?
Assistant: Cats! They're independent, playful, and have such unique personalities.
Tokens used: 24

Test 3: Error handling
---------------------

✅ Expected error caught: Unauthorized

✅ All tests completed!
```
