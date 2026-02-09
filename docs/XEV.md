# XEV

## The Core Purpose

The primary purpose of xev in this project is to provide a non-blocking foundation for the Telegram bot. Instead of the bot performing tasks sequentially (one after another) and waiting for slow network requests to finish, it uses xev to manage multiple operations concurrently.

## Problems It Solves

A. Network Latency & Blocking

Problem: In a traditional bot, when you call an API (like Telegram's getUpdates or an LLM provider), the entire program "stops" until the response arrives. This makes the bot unresponsive to other events or signals.

Solution: xev handles these network calls in the background. The main thread can continue to "tick" and schedule new work while the event loop handles the "waiting" for data to arrive from the internet.

B. Scaling Concurrency (Thread Overhead)

Problem: Spawning a new system thread for every single user message is expensive in terms of memory and CPU cycles.

Solution: The XevEventLoop uses a worker pool model (as seen in
src/utils/xev_event_loop.zig
). It manages a small, fixed number of worker threads (defaulting to 4) that pull tasks from a shared queue. This allows the bot to handle many concurrent messages efficiently without overwhelming the system.

C. Complex Task Scheduling

Problem: Implementing "do this in 5 seconds" or "retry this failed request later" usually requires complex timer logic or manual sleep calls that block execution.

Solution: xev provides high-resolution timers. Functions like scheduleEvent allow the bot to "set and forget" tasks, and the event loop will automatically trigger them at the exact right time using the OS's native wait mechanisms (like epoll, io_uring, or kqueue).
