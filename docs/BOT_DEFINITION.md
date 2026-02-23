# Bot Definition Files

SatiBot supports loading personality and context files from `~/.bots/` to customize the bot's behavior.

## Files

| File | Purpose | Content |
|---|---|---|
| SOUL.md | Bot's identity | Personality, values, how it responds |
| USER.md | User context | Who the user is, preferences, background |
| MEMORY.md | Long-term memory | Past interactions, important facts |

## Location

All files are loaded from: `~/.bots/`

```text
~/.bots/
├── config.json   # Required: bot configuration
├── SOUL.md       # Optional: bot personality
├── USER.md       # Optional: user context
└── MEMORY.md     # Optional: long-term memory
```

## How It Works

```text
┌─────────────────────────────────────────────────────────────────┐
│                        Agent Initialization                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  bot_definition.load(allocator)                                 │
│  ├── Read ~/.bots/SOUL.md                                       │
│  ├── Read ~/.bots/USER.md                                       │
│  └── Read ~/.bots/MEMORY.md                                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
            ┌───────────────┐       ┌───────────────┐
            │ Files exist?  │       │ Files missing?│
            └───────────────┘       └───────────────┘
                    │                       │
                    ▼                       ▼
            ┌───────────────┐       ┌───────────────┐
            │ Load content  │       │ Return empty  │
            │ into memory   │       │ definition    │
            └───────────────┘       └───────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Agent.ensureSystemPrompt()                                     │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ System Prompt Structure:                                  │  │
│  │                                                           │  │
│  │ [SOUL.md content]                                         │  │
│  │                                                           │  │
│  │ User context:                                             │  │
│  │ [USER.md content]                                         │  │
│  │                                                           │  │
│  │ Long-term memory:                                         │  │
│  │ [MEMORY.md content]                                       │  │
│  │                                                           │  │
│  │ [RAG capabilities... ]                                    │  │
│  │ [Tool capabilities... ]                                   │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Example Usage

### SOUL.md

```markdown
You are SatiBot, a thoughtful and concise AI assistant.
You prefer short, direct answers unless elaboration is requested.
You avoid jargon and explain technical terms when used.
```

### USER.md

```markdown
- Name: Alex
- Timezone: PST
- Interests: programming, hiking, coffee
- Preferred language: English
```

### MEMORY.md

```markdown
- Alex prefers responses under 3 sentences
- Remembered: Alex works as a software engineer
- Last project discussion: Zig language learning
```

## Logic Flow

```text
                    START
                      │
                      ▼
            ┌─────────────────┐
            │ Load config.json│
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Agent.init()    │
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Load bot_def    │◄──── Load SOUL.md, USER.md, MEMORY.md
            │ from ~/.bots/  │      from filesystem
            └────────┬────────┘      (non-blocking if missing)
                     │
                     ▼
            ┌─────────────────┐
            │ Add system msg  │
            │ to context      │
            └────────┬────────┘
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
    ┌─────────┐┌─────────┐┌─────────┐
    │ SOUL    ││ USER    ││ MEMORY  │
    │ present ││ present ││ present │
    └────┬────┘└────┬────┘└────┬────┘
         │          │          │
         └──────────┴──────────┘
                    │
                    ▼
            ┌─────────────────┐
            │ Build system    │
            │ prompt          │
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ Ready for       │
            │ conversation    │
            └─────────────────┘
```

## Disabling

This feature is always enabled. If a file doesn't exist, it's simply skipped without error.

To "disable" a specific context:

- Leave the file empty
- Delete the file
- Move the file outside `~/.bots/`
