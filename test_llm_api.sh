#!/bin/bash

# Simple test script to verify LLM API connectivity using curl
# Usage: ./test_llm_api.sh

echo "🚀 Testing LLM API connectivity..."
echo ""

# Check if API key is set
if [ -z "$LLM_API_KEY" ]; then
    echo "❌ Error: LLM_API_KEY environment variable is required"
    echo ""
    echo "Please set your API key:"
    echo "  export LLM_API_KEY='your-api-key-here'"
    echo ""
    exit 1
fi

# Set default model if not specified
MODEL=${LLM_MODEL:-"claude-3-haiku-20240307"}

echo "Provider: Anthropic"
echo "Model: $MODEL"
echo "=========================================="
echo ""

# Test 1: Simple completion
echo "Test 1: Simple completion"
echo "------------------------"
echo "Prompt: Say 'Hello World' in exactly two words."
echo ""

response=$(curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $LLM_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"max_tokens\": 10,
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Say 'Hello World' in exactly two words.\"}
    ]
  }")

echo "Response:"
echo "$response" | jq -r '.content[0].text // "Error: '"$(echo "$response" | jq -r '.error.message // "Unknown error"")"'"'
echo ""

# Test 2: Conversation with context
echo "Test 2: Conversation with context"
echo "--------------------------------"
echo "User: You are a helpful assistant who loves cats. What is your favorite animal?"
echo ""

response=$(curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: $LLM_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"max_tokens\": 50,
    \"messages\": [
      {\"role\": \"user\", \"content\": \"You are a helpful assistant who loves cats. What is your favorite animal?\"}
    ]
  }")

echo "Assistant:"
echo "$response" | jq -r '.content[0].text // "Error: '"$(echo "$response" | jq -r '.error.message // "Unknown error"")"'"'
echo ""

# Test 3: Error handling
echo "Test 3: Error handling"
echo "---------------------"
echo "Testing with invalid API key..."
echo ""

response=$(curl -s -X POST https://api.anthropic.com/v1/messages \
  -H "x-api-key: invalid-key-12345" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"max_tokens\": 10,
    \"messages\": [
      {\"role\": \"user\", \"content\": \"This should fail\"}
    ]
  }")

error_msg=$(echo "$response" | jq -r '.error.message // "No error message"')
echo "✅ Expected error caught: $error_msg"
echo ""

echo "✅ All tests completed!"
