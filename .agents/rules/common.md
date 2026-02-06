---
trigger: always_on
---

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
