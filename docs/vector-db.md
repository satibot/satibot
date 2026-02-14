# Vector Database

## Vector DB CLI Usage

`vector-db` CLI command added to `satibot/src/main.zig`.

### Commands

```bash
# Show vector DB statistics
sati vector-db stats
# Output: Total entries, embedding dimension, DB path
```

Example output:

```text
--- sati 🐸 (build: 2026-02-06 17:13:57 UTC) ---
Vector DB Statistics:
  Total entries: 53
  Embedding dimension: 2
  DB path: /Users/x/.bots/vector_db.json
```

```bash
# List all entries
sati vector-db list
```

```bash
# Search vector DB (semantic similarity)
sati vector-db search "your query" [top_k]
# Example
sati vector-db search "sati" 5
sati vector-db search "programming language" 5

# Add text to vector DB
sati vector-db add "my name is John"
```

### How It Works

- Storage: `~/.bots/vector_db.json`
- Embeddings: Uses OpenRouter API (default: `arcee-ai/trinity-mini:free`)
- Configuration: Set `"disableRag": true` in `config.json`'s `agents.defaults` to disable all embedding and RAG operations globally.
- Search: Cosine similarity on vector embeddings
- Auto-save: Conversations auto-indexed via `agent.indexConversation()`

The CLI provides direct access to test and debug vector DB operations without running the full agent.
