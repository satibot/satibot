#!/bin/bash

# Script to run the standalone LLM test
# Usage: ./run_llm_test.sh

echo "🚀 Running LLM standalone test..."
echo ""

# Set default environment variables if not already set
# export LLM_PROVIDER=${LLM_PROVIDER:-"anthropic"}
# export LLM_MODEL=${LLM_MODEL:-"claude-3-haiku-20240307"}

# Check if API key is set
if [ -z "$LLM_API_KEY" ]; then
    echo "❌ Error: LLM_API_KEY environment variable is required"
    echo ""
    echo "Please set your API key:"
    echo "  export LLM_API_KEY='your-api-key-here'"
    echo ""
    echo "Optional variables:"
    echo "  export LLM_PROVIDER='anthropic'  # or 'groq'"
    echo "  export LLM_MODEL='claude-3-haiku-20240307'"
    echo "  export LLM_BASE_URL='https://api.anthropic.com'  # for custom endpoints"
    echo ""
    exit 1
fi

# Build and run the test using the build system
echo "Building test..."
zig build

if [ $? -eq 0 ]; then
    echo ""
    echo "Running test..."
    echo "================"
    ./zig-out/bin/test_llm_simple
    echo ""
    echo "✅ Test completed!"
else
    echo "❌ Build failed!"
    exit 1
fi
