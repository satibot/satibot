#!/bin/bash
echo "Testing bot..."
./zig-out/bin/satibot telegram openrouter &
BOT_PID=$!
sleep 3
echo "Bot output:"
ps aux | grep $BOT_PID
kill $BOT_PID 2>/dev/null
echo "Bot killed"
