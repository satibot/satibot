#!/bin/bash

# Test vector upsert and search functionality

echo "Testing vector upsert..."

# Upsert some test data
echo '{"text": "Zig is a general-purpose programming language designed for robustness, optimality, and clarity."}' | ./zig-out/bin/xev-mock-bot vector_upsert
echo '{"text": "Rust is a systems programming language focused on safety, speed, and concurrency."}' | ./zig-out/bin/xev-mock-bot vector_upsert
echo '{"text": "Go is a statically typed, compiled programming language designed at Google."}' | ./zig-out/bin/xev-mock-bot vector_upsert
echo '{"text": "Python is an interpreted, high-level programming language with dynamic semantics."}' | ./zig-out/bin/xev-mock-bot vector_upsert
echo '{"text": "JavaScript is a programming language that conforms to the ECMAScript specification."}' | ./zig-out/bin/xev-mock-bot vector_upsert

echo ""
echo "Testing vector search..."

# Search for programming languages
echo '{"query": "programming language", "top_k": 3}' | ./zig-out/bin/xev-mock-bot vector_search

echo ""
echo "Searching for 'systems programming'..."
echo '{"query": "systems programming", "top_k": 2}' | ./zig-out/bin/xev-mock-bot vector_search

echo ""
echo "Searching for 'Google'..."
echo '{"query": "Google", "top_k": 1}' | ./zig-out/bin/xev-mock-bot vector_search
