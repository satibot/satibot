---
title: OpenRouter API Reference
description: Comprehensive guide to OpenRouter's API as used in Satibot
---

# OpenRouter API Reference

OpenRouter provides a unified interface to multiple LLM models and providers. **Satibot** uses OpenRouter as one of its primary providers to access models like GPT-4, Claude 3, and various open-source models.

## Integration in Satibot

In this project, OpenRouter is implemented in:

- `src/providers/openrouter.zig`: Core provider implementation.
- `src/providers/base.zig`: Base interfaces for LLM providers.

### Configuration

OpenRouter requires an API key, which should be stored in your environment variables:

```bash
export OPENROUTER_API_KEY=your_key_here
```

## OpenAPI Specification

- **YAML**: [https://openrouter.ai/openapi.yaml](https://openrouter.ai/openapi.yaml)

- **JSON**: [https://openrouter.ai/openapi.json](https://openrouter.ai/openapi.json)

---

## Requests

### Completions Request Format

The body of a `POST` request to `https://openrouter.ai/api/v1/chat/completions`.

```typescript
type Request = {
  // Either "messages" or "prompt" is required
  messages?: Message[];
  prompt?: string;

  // Model ID (e.g., "anthropic/claude-3-opus", "openai/gpt-4-turbo")
  model?: string;

  response_format?: { type: 'json_object' } | { type: 'json_schema', json_schema: object };
  stop?: string | string[];
  stream?: boolean;
  max_tokens?: number;
  temperature?: number; // Range: [0, 2]
  
  // Tool calling
  tools?: Tool[];
  tool_choice?: 'none' | 'auto' | { type: 'function', function: { name: string } };

  // Advanced parameters
  seed?: number;
  top_p?: number;
  top_k?: number; // Not available for OpenAI models
  transforms?: string[]; // e.g., ["middle-out"]
  models?: string[]; // For model routing/fallbacks
  route?: 'fallback';
};
```

### Zig Example (Internal Usage)

```zig
const OpenRouterProvider = @import("providers/openrouter.zig").OpenRouterProvider;
const base = @import("providers/base.zig");

// Initialize
var provider = try OpenRouterProvider.init(allocator, api_key);
defer provider.deinit();

// Simple Chat
const response = try provider.chat(&[_]base.LLMMessage{
    .{ .role = "user", .content = "Hello!" }
}, "openai/gpt-3.5-turbo");

std.debug.print("Response: {s}\n", .{response.content.?});
```

---

## Responses

### Completion Response Format

```typescript
type Response = {
  id: string;
  choices: Choice[];
  created: number; // Unix timestamp
  model: string;
  object: 'chat.completion' | 'chat.completion.chunk';
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
};

type Choice = {
  finish_reason: 'stop' | 'length' | 'tool_calls' | 'content_filter' | 'error';
  message: {
    content: string | null;
    role: string;
    tool_calls?: ToolCall[];
  };
};
```

---

## Error Handling

OpenRouter returns standard HTTP status codes. When an error occurs, the body contains details:

| Status | Code | Meaning |
| :--- | :--- | :--- |
| **400** | 400 | **Bad Request**: Invalid parameters or malformed JSON. |
| **401** | 401 | **Unauthorized**: Invalid or missing API Key. |
| **402** | 402 | **Payment Required**: Credits exhausted or limit reached. |
| **403** | 403 | **Forbidden**: App/IP blocked or safety filter triggered. |
| **408** | 408 | **Request Timeout**: The upstream provider took too long. |
| **429** | 429 | **Rate Limit**: Too many requests. Check `X-RateLimit` headers. |
| **502** | 502 | **Bad Gateway**: The selected upstream provider is down. |
| **503** | 503 | **Service Unavailable**: OpenRouter is temporarily unavailable. |

**Error Body Example:**

```json
{
  "error": {
    "message": "Invalid API Key",
    "code": 401,
    "metadata": { ... }
  }
}
```

---

## Rate Limits

OpenRouter provides rate limit information in the response headers:

- `X-RateLimit-Limit`: Maximum requests allowed in the window.
- `X-RateLimit-Remaining`: Remaining requests allowed.
- `X-RateLimit-Reset`: Time (Unix timestamp) when the limit resets.

---

## Additional Endpoints

### List Available Models

`GET https://openrouter.ai/api/v1/models`

Returns a list of all models currently supported by OpenRouter, including their pricing and context lengths.

### Check Credits / Account

`GET https://openrouter.ai/api/v1/auth/key`

Returns metadata about your API key, including usage limits and remaining balance.

---

## Advanced Features

### Assistant Prefill

You can "prefill" the assistant message to guide the response:

```json
{
  "messages": [
    { "role": "user", "content": "Write a JSON object for a person." },
    { "role": "assistant", "content": "{" }
  ]
}
```

### Structured Outputs

Use `response_format` to enforce JSON output.

- `json_object`: General JSON validity.
- `json_schema`: Strict adherence to a provided JSON Schema.

### Tools & Function Calling

OpenRouter normalizes tool calling across models. If a model doesn't support it natively, OpenRouter will attempt to provide the functionality via prompt wrapping.
