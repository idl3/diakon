# Diakon — Multi-Project Workspace Orchestration

## What This Is

A Claude Code plugin providing `/dk:*` slash commands for managing multi-project workspaces: project CRUD, recursive git operations, and encrypted secrets (sops + age).

## Project Structure

```
diakon/
├── .claude-plugin/plugin.json    # Plugin manifest
├── skills/                       # One SKILL.md per slash command
│   ├── init/                     # /dk:init
│   ├── add/, remove/, list/, info/
│   ├── status/, pull/, branch/, run/
│   ├── secret-set/, secret-get/, secret-list/, secret-add-recipient/
│   └── check/
├── agents/workspace-steward.md   # Compound operations agent
├── scripts/dk-helpers.sh         # Shared bash functions
├── wiki/                         # Karpathy-style first-principles docs
└── docs/pseudocode/              # Implementation pseudocode
```

## Development Rules

- **No MCP server** — all operations use built-in Claude Code tools (Bash, Read, Write)
- **No Node.js dependency** — skills are markdown, helpers are bash
- **Zero external deps** — only git (always present), sops + age (for secrets)
- **workspace.yaml is flat** — parseable with grep/awk, no yq required
- **Skills describe, Claude executes** — write instructions, not code

## Key Files

| File | Purpose |
|------|---------|
| `scripts/dk-helpers.sh` | Shell functions all skills source |
| `.diakon/workspace.yaml` | The registry schema (in target workspace) |
| `.diakon/.sops.yaml` | sops encryption config (in target workspace) |
| `docs/pseudocode/` | Implementation-ready pseudocode for each skill |

## Testing

- `bash scripts/dk-helpers.sh --test` — self-test the shell helpers
- Dog-food target: `~/Projects/ein-sof/` (install as local plugin)
