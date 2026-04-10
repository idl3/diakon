# Diakon

*The faithful steward.*

Multi-project workspace orchestration for [Claude Code](https://claude.ai/code). Manage projects, git operations, and encrypted secrets across a unified workspace — no daemon, no dependencies, just skills.

The name comes from the Greek *diakonos* (διάκονος) — a servant or steward. In early Christian communities, a diakon managed practical affairs so others could focus on their work. Here, Diakon manages the workspace so you can focus on building.

## Install

```bash
/plugin marketplace add idl3/shuk
/plugin install dk@shuk
```

## Commands

| Command | What it does |
|---------|-------------|
| `/dk:init` | Initialize workspace — auto-detect projects, setup secrets |
| `/dk:list` | List registered projects |
| `/dk:add <path>` | Register a project |
| `/dk:remove <name>` | Unregister a project (files untouched) |
| `/dk:info <name>` | Project detail card with git status |
| `/dk:status` | Git dashboard across all projects |
| `/dk:pull` | Recursive git pull |
| `/dk:branch <name>` | Create/switch branches across projects |
| `/dk:run <cmd>` | Run a command in every project |
| `/dk:secret-set <key> <val>` | Encrypt and store a secret |
| `/dk:secret-get <key>` | Decrypt and display a secret |
| `/dk:secret-list` | List secret keys (no decryption) |
| `/dk:secret-add-recipient` | Add a team member or GCP KMS key |
| `/dk:check` | Workspace health check |

## How it works

Diakon is a pure-skills Claude Code plugin. No MCP server, no Node.js, no build step. Each `/dk:*` command is a SKILL.md file that Claude reads and executes using built-in tools (Bash, Read, Write).

State lives in one file: `.diakon/workspace.yaml`.

## Secrets

Encrypted with [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age). Four tiers:

1. **Solo** — single age key, local only
2. **Team** — multiple age public keys, manually shared
3. **Cloud** — GCP KMS, IAM-based access
4. **Hybrid** — GCP KMS + age fallback for offline dev

Keys are plaintext in git (diffable). Values are encrypted. Safe to commit.

## Requirements

- Claude Code
- `git` (always available)
- `sops` + `age` (for secrets — `brew install sops age`)
- `jq` (for secret-set — `brew install jq`)
- `gcloud` (optional, for GCP KMS tier)

## Documentation

- [Wiki](wiki/) — first-principles docs (Karpathy-style)
- [Architecture](docs/architecture/) — security audit, adversarial review
- [Pseudocode](docs/pseudocode/) — implementation specs

## License

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) — free to use and adapt, not for commercial use. Commercial licenses available — contact ernest.codes@gmail.com. Or, if you want to use it commercially, just get Claude to understand the philosophies and recreate the project from scratch.
