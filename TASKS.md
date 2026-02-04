# Minbot Implementation Tasks

## Phase 1: Foundation

- [x] **Configuration Loader**
  - [x] Implement `get_config_path` to resolve `~/.bots/config.json`
  - [x] Use `std.json` to parse the config file
  - [x] Update `src/config.zig` to replace mock data with actual loaded values
  - [x] Handle missing config gracefully (fallback or error)
- [x] Basic project structure and build system
- [x] Configuration loading (`~/.bots/config.json`)
- [x] Zig 0.15.2 Standard Library Migration
- [x] Core Agent loop
- [x] **HTTP Client & LLM Provider**
  - [x] Create `src/http.zig` for basic HTTP requests (likely using `std.http.Client`)
  - [x] Implement `src/providers/base.zig` interface
  - [x] Test connection to LLM with a simple "Hello" (code written, ready for testing)

## Phase 2: Core Agent

- [x] **Context Builder**
  - [x] Create `src/agent/context.zig`
  - [x] Define Message and Role structs
  - [x] Implement `build_messages` to format history for the LLM API

- [x] **Tool System**
  - [x] Define `Tool` interface/struct in `src/agent/tools.zig`
  - [x] Implement `FileTools` (Read, Write, List)
  - [x] Implement `WebSearchTool` (Brave API)
  - [x] Create a `ToolRegistry` to look up tools by name

### Phase 3: LLM Integration

- [x] OpenRouter provider implementation (migrated to 0.15.2, needs testing)
- [x] Anthropic provider implementation

## Phase 4: The Loop

- [x] **Agent Loop Implementation**
  - [x] Update `src/agent.zig` to use the real Provider
  - [x] Implement the ReAct loop:
    1. Send history to LLM
    2. Parse tool calls from response (JSON)
    3. Execute tools
    4. Append results to history
    5. Repeat
  - [x] Handle max iterations

## Phase 5: Polish

- [x] **CLI UX**
  - [x] Streaming response output
  - [x] Better error handling
- [x] **Session Management**
  - [x] Save/Load conversation history to `~/.bots/sessions/`
- [x] **Marketplace Integration**
  - [x] Implement `list_marketplace` tool
  - [x] Implement `search_marketplace` tool
  - [x] Implement `install_skill` tool
