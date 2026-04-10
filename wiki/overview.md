---
title: Diakon Overview
summary: Skills-based Claude Code plugin for multi-project workspace orchestration — 19 commands, encrypted secrets, Karpathy wiki, Shuk distribution
updated: 2026-04-10
confidence: seed
sources:
  - ../README.md
  - ../CLAUDE.md
---

# Diakon

*The faithful steward.*

Diakon is a Claude Code plugin for multi-project workspace orchestration. The name comes from the Greek *diakonos* (a servant or steward) — it manages the workspace so you can focus on building.

## Skills-Based Architecture

Diakon is a pure-skills plugin. No MCP server, no Node.js, no build step. Each `/dk:*` command is a `SKILL.md` file that Claude reads and executes using built-in tools (Bash, Read, Write). Skills describe; Claude executes.

```
diakon/
├── .claude-plugin/plugin.json    # Plugin manifest
├── skills/                       # One SKILL.md per slash command
├── agents/workspace-steward.md   # Compound operations agent
├── scripts/dk-helpers.sh         # Shared bash functions
├── wiki/                         # Karpathy-style first-principles docs
└── docs/pseudocode/              # Implementation pseudocode
```

State lives in one flat file: `.diakon/workspace.yaml` (parseable with grep/awk, no yq required).

## 19 Commands

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
| `/dk:wiki-init` | Initialize a Karpathy-style wiki |
| `/dk:wiki-ingest` | Ingest a source document into a wiki |
| `/dk:wiki` | Query the wiki |
| `/dk:wiki-lint` | Health-check wiki for contradictions and staleness |
| `/dk:wiki-update` | Sync workspace wiki with project wikis |

## Secrets (sops + age)

Encrypted with [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age). Four tiers:

| Tier | Description |
|------|-------------|
| **Solo** | Single age key, local only |
| **Team** | Multiple age public keys, manually shared |
| **Cloud** | GCP KMS, IAM-based access |
| **Hybrid** | GCP KMS + age fallback for offline dev |

Keys are plaintext in git (diffable). Values are encrypted. Safe to commit.

## Wiki System (Karpathy Pattern)

Three-layer architecture for LLM-managed project documentation:

1. **`sources/`** — raw immutable documents dropped for ingestion
2. **`wiki/`** — LLM-generated pages owned entirely by the LLM
3. **`.wiki-schema.md`** — conventions, templates, confidence levels

Every page has YAML frontmatter (title, summary, updated, confidence, sources). The index is the master catalog. The log is append-only.

## Distribution via Shuk

Diakon is distributed through [Shuk](https://github.com/idl3/shuk), the Claude Code plugin marketplace:

```bash
/plugin marketplace add idl3/shuk
/plugin install dk@shuk
```

## Requirements

- Claude Code
- `git` (always available)
- `sops` + `age` (for secrets — `brew install sops age`)
- `jq` (for secret-set — `brew install jq`)
- `gcloud` (optional, for GCP KMS tier)

## Development Rules

- No MCP server — all operations use built-in Claude Code tools
- No Node.js dependency — skills are markdown, helpers are bash
- Zero external deps beyond git, sops, age
- workspace.yaml is flat — parseable with grep/awk
- Skills describe, Claude executes — write instructions, not code

## License

CC BY-NC 4.0 — free to use and adapt, not for commercial use.
