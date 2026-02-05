# RAG, VectorDB, and GraphDB in satibot

This document provides an overview of the Retrieval-Augmented Generation (RAG) capabilities, including the built-in VectorDB and GraphDB support.

## Overview

`satibot` features a local-first knowledge management system that allows the agent to persist, retrieve, and relate information across sessions.

```bash
# Example: Teaching the agent something to remember via VectorDB
./satibot -m "Remember that the secret code for the vault is 42."

# Later, you can ask it:
./satibot -m "What was the secret code for the vault?"
# The agent will call vector_search/rag_search to find the answer.
```

## 1. VectorDB

The VectorDB provides semantic search capabilities using vector embeddings.

- **Storage**: `~/.bots/vector_db.json`
- **Algorithm**: Cosine Similarity for linear search.
- **Tools**:
  - `vector_upsert`: Embeds and stores a text snippet in the database.
  - `vector_search`: Finds the top-K most similar snippets for a given query.

## 2. GraphDB

The GraphDB allows for structured knowledge representation through nodes and edges.

- **Storage**: `~/.bots/graph_db.json`
- **Structure**: Nodes (ID, Label) and Edges (From, To, Relation).
- **Tools**:
  - `graph_upsert_node`: Adds a node (e.g., a Person, Project, or Concept).
  - `graph_upsert_edge`: Connects two nodes with a named relation (e.g., "OWNER", "MEMBER_OF", "DEPENDS_ON").
  - `graph_query`: Returns a text description of all relations connected to a specific node.

## 3. RAG Search

RAG combines retrieval with generation. The `rag_search` tool is currently a wrapper for `vector_search`, providing a specialized interface for the agent to find relevant context before answering a question.

## Configuration

You can configure the embedding model in `~/.bots/config.json`:

```json
{
  "agents": {
    "defaults": {
      "model": "anthropic/claude-3-7-sonnet",
      "embeddingModel": "openai/text-embedding-3-small"
    }
  }
}
```

## Implementation Details

- **Embeddings**: Calculated via the `OpenRouterProvider` (OpenRouter/OpenAI-compatible).
- **Architecture**: Tools access the embedding service via the `ToolContext.get_embeddings` function pointer provided by the `Agent` during execution.
- **Persistence**: Both databases are serialized/deserialized as JSON for easy inspection and debugging.

## Example Use Cases

### Long-term Memory

The agent can use `vector_upsert` to remember user preferences, project details, or specific facts mentioned in conversations that should persist beyond a single session.

### Knowledge Mapping

The agent can use `graph_upsert_edge` to map out complex structures, such as:

- "Project A" --[WRITTEN_IN]--> "Zig"
- "User" --[WORKS_ON]--> "Project A"
- "Module B" --[DEPENDS_ON]--> "Module C"
