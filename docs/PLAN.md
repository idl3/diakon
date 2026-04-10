# Diakon — Multi-Project Workspace Orchestration Plugin

## Context

Ein-sof unifies aether, olam, and pleri. But the orchestration patterns (project registry, recursive git ops, secrets) are generic and reusable. Diakon extracts these into a standalone Claude Code plugin. Named from Greek "diakonos" — servant/steward.

**Reference model**: atlas-one (git submodules + TypeScript CLI + JSON registry + YAML setups + docker-compose).

## Architecture Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| MCP server | **No** — pure skills | All ops are file/git-based. No persistent process needed. |
| Secrets | **sops + age** | Structured YAML encryption, keys plaintext, values encrypted. Diff-friendly. |
| Registry format | **YAML** | Supports comments, human-editable, matches pnpm-workspace.yaml convention. |
| Shell vs Node | **Shell helpers** | Zero runtime deps. workspace.yaml is simple enough for grep/awk. |

## Project Structure (`~/Projects/diakon/`)

```
diakon/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── skills/
│   ├── init/SKILL.md            # /dk:init — provision workspace
│   ├── add/SKILL.md             # /dk:add — register project
│   ├── remove/SKILL.md          # /dk:remove — unregister project
│   ├── list/SKILL.md            # /dk:list — show all projects
│   ├── info/SKILL.md            # /dk:info — project detail card
│   ├── status/SKILL.md          # /dk:status — git dashboard
│   ├── pull/SKILL.md            # /dk:pull — recursive git pull
│   ├── branch/SKILL.md          # /dk:branch — cross-project branching
│   ├── run/SKILL.md             # /dk:run — run command across projects
│   ├── secret-set/SKILL.md      # /dk:secret-set — encrypt & store
│   ├── secret-get/SKILL.md      # /dk:secret-get — decrypt & show
│   ├── secret-list/SKILL.md     # /dk:secret-list — list keys only
│   └── check/SKILL.md           # /dk:check — workspace health
├── agents/
│   └── workspace-steward.md     # Compound operations agent
├── scripts/
│   └── dk-helpers.sh            # Shared shell functions
├── CLAUDE.md
└── README.md
```

## Skill Inventory

| Skill | Trigger | What it does |
|-------|---------|-------------|
| `/dk:init` | "initialize workspace" | Auto-detect workspace type, discover projects, create `.diakon/`, setup secrets infra |
| `/dk:add` | "add project" | Register project with auto-detected metadata (type, packages, port) |
| `/dk:remove` | "remove project" | Unregister (does NOT delete files) |
| `/dk:list` | "list projects" | Table of all registered projects |
| `/dk:info` | "project details" | Deep info: git log, branch, dirty state, deps |
| `/dk:status` | "workspace status" | Dashboard: branch, clean/dirty, ahead/behind per project |
| `/dk:pull` | "pull all" | Recursive git pull with per-project results |
| `/dk:branch` | "create branch" | Create/switch branch across selected projects |
| `/dk:run` | "run in all" | Execute arbitrary command across projects |
| `/dk:secret-set` | "set secret" | Encrypt value with sops+age, store in `.diakon/secrets.enc.yaml` |
| `/dk:secret-get` | "get secret" | Decrypt and display specific key |
| `/dk:secret-list` | "list secrets" | Show keys without values (no decryption needed) |
| `/dk:check` | "health check" | Verify: paths exist, git valid, deps installed, cross-dep consistency |

## What `/dk:init` Provisions

```
target-workspace/
├── .diakon/
│   ├── workspace.yaml        # Auto-populated project registry
│   ├── secrets.enc.yaml      # Empty encrypted secrets (sops placeholder)
│   ├── .sops.yaml            # Age key config
│   └── .gitignore            # Protects *.key, *.age-key
└── .gitignore                # Appended: .diakon/secrets.key
```

Auto-detection during init:
1. Reads `pnpm-workspace.yaml` globs → discovers packages
2. Scans for `package.json` / `.git` in top-level dirs
3. For each project: detect type, sub-packages, scope
4. Checks for `age` + `sops` availability

## Workspace Registry Schema (`.diakon/workspace.yaml`)

```yaml
diakon: "0.1.0"

workspace:
  name: "ein-sof"
  type: "pnpm"
  package_manager: "pnpm@10.8.1"

projects:
  aether:
    path: "./aether"
    enabled: true
    type: "node"
    packages: ["types", "ui"]
    git:
      url: "git@github.com:idl3/aether.git"
      default_branch: "main"
    meta:
      description: "React component library for thought visualization"
      scope: "@idl3"

  olam:
    path: "./olam"
    enabled: true
    type: "node"
    packages: ["core", "adapters", "mcp-server", "cloudflare", "control-plane"]
    git:
      url: "git@github.com:idl3/olam.git"
      default_branch: "main"

  pleri:
    path: "./pleri"
    enabled: true
    type: "node"
    packages: ["api", "web", "types"]
    git:
      url: "git@github.com:idl3/pleri.git"
      default_branch: "main"

secrets:
  backend: "sops+age"
  file: ".diakon/secrets.enc.yaml"
```

## Secrets Workflow

1. **Init**: `age-keygen` creates key at `~/.config/sops/age/keys.txt` (never committed)
2. **Set**: `sops --set '["KEY"] "value"' .diakon/secrets.enc.yaml` — values encrypted, keys plaintext
3. **Get**: `sops -d --extract '["KEY"]' .diakon/secrets.enc.yaml`
4. **List**: Read YAML keys directly (no decryption needed)
5. **Team**: Add age public keys to `.sops.yaml`, run `sops updatekeys`

## Installation in ein-sof (dog-fooding)

In `~/Projects/ein-sof/.claude/settings.local.json`:
```json
{
  "plugins": {
    "local": [{ "path": "/Users/ernie/Projects/diakon" }]
  }
}
```

## Implementation Phases

| Phase | Time | What |
|-------|------|------|
| 1. Scaffold | 15m | git init, plugin.json, dk-helpers.sh, CLAUDE.md |
| 2. Core skills | 45m | init, list, add, remove, info |
| 3. Git ops | 30m | status, pull, branch, run |
| 4. Secrets | 30m | secret-set, secret-get, secret-list |
| 5. Health | 15m | check, workspace-steward agent |
| 6. Dog-food | 20m | Install in ein-sof, run /dk:init, validate checklist |
| 7. Polish | 15m | README, plugin validate, tests |

## Verification

1. `claude plugin validate` on the manifest
2. `/dk:init` in ein-sof auto-discovers all 3 projects + their sub-packages
3. `/dk:status` shows git dashboard for aether, olam, pleri
4. `/dk:secret-set TEST_KEY test-value` → `/dk:secret-get TEST_KEY` round-trips
5. `/dk:check` reports green across the workspace
