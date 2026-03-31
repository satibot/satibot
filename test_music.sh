#!/bin/bash

# Test script for MiniMax Music Generation CLI
# Usage: ./test_music.sh <your-api-key>

if [ $# -eq 0 ]; then
    echo "Usage: $0 <your-minimax-api-key>"
    echo ""
    echo "This script demonstrates the music generation capabilities:"
    echo "1. Generate lyrics from a prompt"
    echo "2. Generate music from a prompt (downloads MP3)"
    echo "3. Generate music with custom lyrics (downloads MP3)"
    echo ""
    exit 1
fi

API_KEY="$1"
CLI_PATH="./zig-out/bin/s-music"

echo "🎵 MiniMax Music Generation Test"
echo "================================"
echo ""

# Test 1: Generate lyrics
echo "Test 1: Generating lyrics..."
echo "Command: $CLI_PATH lyrics \"A upbeat pop song about summer adventures\" \"$API_KEY\""
echo ""
$CLI_PATH lyrics "A upbeat pop song about summer adventures" "$API_KEY"
echo ""
echo "----------------------------------------"
echo ""

# Test 2: Generate music (prompt only)
echo "Test 2: Generating music from prompt..."
echo "Command: $CLI_PATH music \"Upbeat Pop, Summer, Bright, Energetic\" \"$API_KEY\""
echo ""
$CLI_PATH music "Upbeat Pop, Summer, Bright, Energetic" "$API_KEY"
echo ""
echo "----------------------------------------"
echo ""

# Test 3: Generate music with custom lyrics
echo "Test 3: Generating music with custom lyrics..."
echo "Command: $CLI_PATH music \"Pop Rock, Upbeat, Catchy\" --lyrics \"[Verse 1]\\nSummer days and nights\\nDancing in the moonlight\\nEverything feels right\" \"$API_KEY\""
echo ""
$CLI_PATH music "Pop Rock, Upbeat, Catchy" --lyrics "[Verse 1]
Summer days and nights
Dancing in the moonlight
Everything feels right" "$API_KEY"
echo ""

echo "✅ Test completed!"
echo ""
echo "Generated MP3 files will be saved as:"
echo "- generated_music_<timestamp>.mp3"
echo ""
echo "The CLI automatically attempts to play the MP3 using your system's default player."
