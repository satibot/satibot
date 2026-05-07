# Implement s-cron CLI App

This plan details the steps to implement the `s-cron` CLI for scheduling recurring tasks.

## User Review Required

> [!WARNING]
> Zig does not have a built-in cron parser in its standard library. Implementing a fully compliant cron parser (handling all ranges, lists, step values like `*/5`, and day-of-week edge cases) can be complex.
> **Question**: Should I implement a basic cron parser that supports exact matches and `*` (e.g., `0 9 * * *` for daily at 9:00 AM) or is a more robust cron parsing library preferred/needed? 

## Proposed Changes

### Core Agent Lib (`libs/agent/`)

#### [MODIFY] `libs/agent/src/agent/cron.zig`
- Add a `.cron` variant to `CronScheduleKind`.
- Add `cron_expr: ?[]const u8` to `CronSchedule`.
- Implement a basic `next_cron_run(expr, now)` function to compute the next valid timestamp in milliseconds for a given cron expression.
- Update `CronStore.tick()` to recalculate `next_run_at_ms` using the cron parser after a cron job completes.

### Apps (`apps/`)

#### [NEW] `apps/cron/src/main.zig`
- Create the `s-cron` CLI application.
- Parse `--schedule` and `--message` arguments.
- Load `~/.bots/cron_jobs.json` using `CronStore`.
- Add the new job with the `.cron` schedule kind.
- Save the store back to disk.

### Build System

#### [MODIFY] `build.zig`
- Register `s-cron` as a new executable.
- Add `s-cron` to the installation step.
- Add a run step `run-cron` to allow executing `zig build run-cron -- --schedule "0 9 * * *" --message "Daily summary"`.

## Verification Plan

### Automated Tests
- Write unit tests in `libs/agent/src/agent/cron.zig` to verify the basic cron parser correctly calculates `next_run_at_ms` for given expressions (like `0 9 * * *`).

### Manual Verification
- Run `zig build s-cron`.
- Execute `./zig-out/bin/s-cron --schedule "0 9 * * *" --message "Daily summary"`.
- Inspect `~/.bots/cron_jobs.json` to verify the job was added correctly with the cron expression.
