# Skill & Rule System

This document describes the Skill and Rule management system in SatiBot CLI, inspired by OpenCode and Claude Code.

## Overview

SatiBot CLI provides a skill and rule management system that allows the AI agent to load specialized knowledge and coding conventions on-demand.

## Architecture

```mermaid
graph TB
    subgraph CLI["Sati CLI"]
        Main[main.zig]
        Commands[Command Handler]
    end

    subgraph Storage["Skill/Rule Storage"]
        AgentsSkills[.agents/skills/]
        OpencodeSkills[.opencode/skills/]
        AgentsRules[.agents/rules/]
        OpencodeRules[.opencode/rules/]
    end

    subgraph Memory["In-Memory Storage"]
        SkillMap[loaded_skills HashMap]
        RuleMap[loaded_rules HashMap]
    end

    Main --> Commands
    Commands --> SkillMap
    Commands --> RuleMap
    
    SkillMap -.-> AgentsSkills
    SkillMap -.-> OpencodeSkills
    RuleMap -.-> AgentsRules
    RuleMap -.-> OpencodeRules
```

## Directory Structure

```mermaid
graph LR
    subgraph Skills["Skills Directory"]
        S1[.agents/skills/]
        S2[.opencode/skills/]
    end
    
    subgraph SkillExample["Skill Structure"]
        SE[skill-name/]
        SEMD[SKILL.md]
    end
    
    S1 --> SE
    S2 --> SE
    SE --> SEMD
```

Skills are stored in directories with a `SKILL.md` file:

```
.agents/skills/<name>/SKILL.md
.opencode/skills/<name>/SKILL.md
```

Rules are stored as individual markdown files:

```
.agents/rules/<name>.md
.opencode/rules/<name>.md
```

## SKILL.md Format

```yaml
---
name: skill-name
description: Brief description of what this skill provides
---

# Skill Name

Detailed documentation content...
```

## Command Flow

```mermaid
sequenceDiagram
    participant User
    participant CLI
    participant FileSystem
    participant Memory

    User->>CLI: sati skills
    CLI->>FileSystem: Scan .agents/skills/
    CLI->>FileSystem: Scan .opencode/skills/
    FileSystem-->>CLI: List of skill names
    CLI->>User: Display skills

    User->>CLI: sati skill load codebase
    CLI->>FileSystem: Read SKILL.md
    FileSystem-->>CLI: Skill content
    CLI->>Memory: Store in loaded_skills
    Memory-->>CLI: Confirm
    CLI->>User: ✅ Loaded skill

    User->>CLI: sati read codebase
    CLI->>Memory: Check loaded_skills
    alt In memory
        Memory-->>CLI: Return content
    else Not in memory
        CLI->>FileSystem: Read SKILL.md
        FileSystem-->>CLI: Return content
    end
    CLI->>User: Display content
```

## Available Commands

```mermaid
graph TB
    subgraph Commands["CLI Commands"]
        SkillsCmd[sati skills]
        SkillCmd[sati skill]
        RulesCmd[sati rules]
        RuleCmd[sati rule]
        ReadCmd[sati read]
    end

    SkillsCmd -->|"list"| List[List all skills]
    SkillCmd -->|"load"| Load[Load skill to memory]
    SkillCmd -->|"show"| Show[Show skill details]
    RulesCmd -->|"list"| ListR[List all rules]
    RuleCmd -->|"show"| ShowR[Show rule details]
    ReadCmd -->|"read"| Read[Read skill/rule content]
```

## Skill Loading Flow

```mermaid
flowchart TD
    Start[User runs sati agent] --> CheckArgs{Check args for --skill}
    
    CheckArgs -->|yes| LoadSkill[Load skill content]
    CheckArgs -->|no| Skip[Skip skill loading]
    
    LoadSkill --> FindSkill{Find SKILL.md}
    FindSkill -->|found| Parse[Parse YAML frontmatter]
    Parse --> AddToContext[Add to agent context]
    AddToContext --> Continue[Continue agent run]
    
    FindSkill -->|not found| Error[Show error]
    Error --> Help[Show available skills]
    
    Skip --> Continue
```

## Use Cases

### 1. Codebase Context Loading

```bash
# Load codebase skill before running agent
sati agent --skill codebase

# Or load multiple skills
sati agent --skill codebase --skill zig-best-practices
```

### 2. On-Demand Rule Lookup

```bash
# Check naming conventions
sati rule zig-naming-conventions

# Check debug print rules
sati rule zig-debug-print
```

### 3. Skill Exploration

```bash
# List all available skills
sati skills

# Read full skill content
sati read codebase

# Read specific rule
sati read llm-best-practices
```

## Integration with Agent

```mermaid
graph LR
    subgraph Agent["Agent Execution"]
        Input[User Input]
        Context[Context Builder]
        LLM[LLM Call]
        Response[Response]
    end
    
    subgraph Skills["Loaded Skills"]
        Skill1[Skill 1]
        Skill2[Skill 2]
    end
    
    subgraph Rules["Loaded Rules"]
        Rule1[Rule 1]
    end
    
    Input --> Context
    Context --> Skills
    Context --> Rules
    Context --> LLM
    LLM --> Response
```

When running the agent with loaded skills/rules, they are injected into the system prompt to provide additional context:

```
System: You are a helpful AI assistant.
[Skill: codebase] Project structure: ...
[Skill: zig-best-practices] Use patterns: ...
[Rule: zig-naming-conventions] camelCase, snake_case, ...
```

## Adding New Skills

1. Create directory: `.agents/skills/my-skill/`
2. Add `SKILL.md` with YAML frontmatter
3. Document purpose, usage, and examples
4. Test with `sati skill my-skill`

## Adding New Rules

1. Add file: `.agents/rules/my-rule.md`
2. Start with `# Rule Title` on first line
3. Document the rule with examples
4. Test with `sati rule my-rule`

## Example Skills

| Skill | Description |
|-------|-------------|
| `codebase` | Project structure and key files |
| `zig-best-practices` | Zig coding patterns |
| `http-fetch` | HTTP fetching capabilities |
| `app-logic` | Application flow diagrams |

## Example Rules

| Rule | Description |
|------|-------------|
| `zig-naming-conventions` | Naming rules for Zig |
| `zig-debug-print` | Debug print usage |
| `llm-best-practices` | LLM interaction best practices |
| `zig-0.15-quick-reference` | Zig 0.15 breaking changes |

## Testing

Run tests for the skill/rule system:

```bash
zig build test
```

Unit tests verify:
- Description extraction from YAML frontmatter
- First line extraction for rules
- File reading and parsing
- HashMap storage operations
