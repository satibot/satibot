# Common

## Write comments

Write comments in the code to explain why the code need to do that.
Check if need to update docs, README.md, etc.

## Log your work

Whenever you finish a task or change codes, always log your work using the l-log bash command (llm-lean-log-cli package) with the following format:

`l-log add ./logs/chat.csv "<Task Name>" --tags="<tags>" --problem="<problem>" --solution="<solution>" --action="<action>" --files="<files>" --tech-stack="<tech>" --created-by-agent="<agent-name>"`

Note: `--last-commit-short-sha` is optional and will be auto-populated by the CLI if not provided.

Before run:

- Install the l-log CLI if not already installed: `bun add -g llm-lean-log-cli`.
- If need, run CLI help command: `l-log -h` for more information.
- log path: `./logs/chat.csv`.

## Multiple number

Replace arithmetic expressions with pre-calculated constants in memory allocations.
For example, instead of `1024 * 1024`, use the result value `1048576` and add a comment to explain the calculation like `// 1024 * 1024`.

## Free owned fields before deiniting containers

When a struct has a `deinit` method that destroys a container (ArrayList, HashMap, etc.), always iterate over remaining items and free any heap-allocated fields **before** calling `container.deinit()`.

**Why:** If items are added to a queue with `allocator.dupe()` / `allocPrint()` and consumed elsewhere (e.g. an event loop pops and frees them), items that are still in the container at shutdown will leak because `deinit()` only releases the container's backing memory, not the contents.

**Rule:** For every container that holds structs with owned allocations:

1. In `deinit`, loop over all remaining items and free each owned field.
2. Then call `container.deinit()`.

```zig
// Example: free owned fields before deiniting the queue
for (self.message_queue.items) |msg| {
    self.allocator.free(msg.text);
    self.allocator.free(msg.session_id);
}
self.message_queue.deinit(self.allocator);
```

## When catch error

When catch error, always log the error message.

## Add comments to code

Add comments to code to explain why the code does or what the code does when it is complex.
Do not add comments to simple codes.
For example, do not add comments to simple codes:

```zig
// Print response
std.debug.print("Response: {s}\n", .{response.content});
```

## Memory Management

Follow strict memory management rules to prevent use-after-free and memory leaks:

- See [memory-management.zig.md](memory-management.zig.md) for general memory management rules
- See [async-event-loop-patterns.md](async-event-loop-patterns.md) for async/event loop specific rules
- See [error-handling.zig.md](error-handling.zig.md) for error handling best practices

Key principles:

- Never store pointers to stack-local variables in structs that outlive the function
- Ensure handler contexts have valid pointer references for async operations
- Always verify pointer lifetime when passing to threads or callbacks
- Never use `catch unreachable` for operations that can fail

## Prefer Functional Programming over OOP

Avoid Object-Oriented Programming (OOP) patterns where state is hidden within objects (structs with many methods that mutate self). Instead:

- Favor Pure Functions: Use functions that take data as input and return new or modified data as output.
- Avoid "Instances": Minimize the use of long-lived stateful objects. Only use "init" patterns for resource management (e.g., allocators, network connections).
- Separate Data and Logic: Keep data structures simple and process them with external, stateless functions.
- Separate IO from Logic: Isolate Input/Output operations (network, disk) from core logic. Core logic should be pure and testable without mocks.
- Stateless Handlers: Design task and event handlers to be stateless transformations of input data.
