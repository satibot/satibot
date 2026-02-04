### Installing Skills

Add capabilities to your agent by installing skills from [agent-skills.md](https://agent-skills.md/):

```bash
# Install a skill from a GitHub repository
./scripts/install-skill.sh https://github.com/owner/repo/tree/main/skills/skill-name

# Install all skills from a repository
./scripts/install-skill.sh owner/repo

# Using shorthand format
./scripts/install-skill.sh owner/repo/skills/skill-name
```

For unlimited API access, set a GitHub token:

```bash
export GITHUB_TOKEN=your-github-token

# Install all skills from a repository
./scripts/install-skill.sh owner/repo
```

Skills are installed to `.agent/skills/` and automatically available to the agent.
