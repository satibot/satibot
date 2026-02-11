#!/bin/bash
# This test script is used to quickly verify the
# Telegram bot starts and runs without crashing.
# Easy for LLM read the output.
echo "Testing bot..."
./zig-out/bin/satibot telegram-sync &
BOT_PID=$!
sleep 3
echo "--- Bot output: ---"
ps aux | grep $BOT_PID
kill $BOT_PID 2>/dev/null
echo "--- Bot killed ---"
