---
description: Install skills from agent-skills.md or GitHub repositories
---

# Install Agent Skills

This workflow helps you install skills from [agent-skills.md](https://agent-skills.md/) or any GitHub repository containing SKILL.md files.

## Prerequisites

- `curl` installed
- `jq` installed (for JSON parsing)
- Optional: `GITHUB_TOKEN` env var for higher API rate limits

## Steps

### 1. Browse available skills

Visit [agent-skills.md](https://agent-skills.md/) to browse the skill directory. You can search by:
- Category: Development, Productivity, Data, etc.
- Tags: git, docker, api, etc.
- Author: Find skills from specific creators

### 2. Find the skill you want

Each skill page shows:
- **Name**: The skill identifier
- **Description**: What the skill does
- **Repository**: The source GitHub repo
- **Files**: SKILL.md and supporting files

### 3. Install the skill

Use the install script with the skill's GitHub URL or path:

```bash
# From a specific skill folder
./scripts/install-skill.sh https://github.com/owner/repo/tree/main/skills/skill-name

# Install all skills from a repository
./scripts/install-skill.sh https://github.com/owner/repo

# Using shorthand format
./scripts/install-skill.sh owner/repo/skills/skill-name
```

### 4. Verify installation

Check that the skill was installed:

```bash
ls -la .agent/skills/
```

The skill should appear as a folder with at least a `SKILL.md` file.

## Examples

```bash
# Install the GitHub skill for git operations
./scripts/install-skill.sh https://github.com/anthropics/anthropic-cookbook/tree/main/skills/github

# Install Notion integration skill
./scripts/install-skill.sh futantan/agent-skills.md/skills/notion

# List available skills in a repository before installing
./scripts/install-skill.sh owner/repo
```

## Troubleshooting

### Rate limiting

If you hit GitHub API rate limits, set a token:

```bash
export GITHUB_TOKEN="your-github-token"
./scripts/install-skill.sh owner/repo/skill-name
```

### Skill not found

Make sure:
1. The repository is public (or you have access with GITHUB_TOKEN)
2. The path contains a `SKILL.md` file
3. The SKILL.md has valid frontmatter with `name` and `description`

## Skill format

Skills follow the [agent-skills.md specification](https://agent-skills.md/):

```
skill-name/
├── SKILL.md          # Required - skill description and instructions
├── scripts/          # Optional - executable scripts
├── references/       # Optional - additional documentation
└── assets/           # Optional - templates, images, data files
```

SKILL.md frontmatter:

```yaml
---
name: skill-name
description: What this skill does and when to use it
metadata:
  author: author-name
  category: Development
  tags: git docker api
---

# Skill Instructions

Detailed instructions for the agent...
```
