# 04 — Health Check & Workspace Steward Agent

---

## /dk:check [--quick] [--fix]

### Frontmatter
```yaml
---
name: dk-check
description: Run workspace health checks — verify projects, dependencies, secrets, builds
argument-hint: "[--quick] [--fix]"
user-invocable: true
---
```

### Checks (in order)

#### 1. Registry Validation
```
- workspace.yaml exists and is valid YAML (Read succeeds)
- Has required top-level keys: diakon, workspace, projects
- diakon version field is present
- workspace.name is non-empty
```

#### 2. Project Validation (per project)
```
FOR EACH registered project:
  - Directory exists at declared path
  - If git.url set: .git directory exists
  - Git repo is valid: Bash("git -C <path> rev-parse --is-inside-work-tree")
  - Git remote matches registry: Bash("git -C <path> remote get-url origin") == git.url
  - No untracked large files: find -size +10M (warning only)
```

#### 3. Dependency Validation (skip if --quick)
```
FOR EACH node project:
  - package.json exists
  - All workspace:* references resolve to actual workspace packages
  - No conflicting versions of shared external deps across projects
  - Lock file exists (pnpm-lock.yaml, yarn.lock, package-lock.json)
  - Lock file fresher than package.json (warn if stale)
```

#### 4. Build Validation (skip if --quick)
```
FOR EACH project with a build script:
  - Run build command, check exit code
  - Report failures with truncated output
```

#### 5. Secrets Validation
```
IF .diakon/.sops.yaml exists:
  - Valid YAML with creation_rules
  - At least one recipient (age or gcp_kms)
  - secrets.enc.yaml exists and is valid sops file
  - Round-trip test: set temp key, get it, verify match, delete
IF secrets backend configured but tools missing:
  - Warn: "sops/age not installed but secrets are configured"
```

#### 6. Cross-Project Checks
```
- TypeScript: check for conflicting strict/noEmit across tsconfigs
- Node: check for mismatched engines.node across package.json files
- Detect circular workspace:* dependencies
- Check for duplicate package names across projects
```

### --fix Mode
```
Auto-fix what's safe:
- Missing .gitignore entries → append
- Stale lock file → run <package-manager> install
- Missing workspace.yaml fields → add defaults
- Missing .diakon/.gitignore → create

DO NOT auto-fix:
- Build failures
- Git remote mismatches
- Circular dependencies
- Secrets corruption
```

### Output Format
```
dk:check — Workspace Health Report

  Registry:     OK
  Projects:     3/3 OK
  Dependencies: 2 warnings
    WARN: @tanstack/react-query version mismatch (5.60.0 in pleri-web vs 5.97.0 in aether-ui)
    WARN: pnpm-lock.yaml is older than pleri-web/package.json
  Secrets:      OK (3 recipients, round-trip verified)
  Builds:       OK (skip if --quick)

  Overall: PASS (2 warnings)
```

---

## Workspace Steward Agent

### File: agents/workspace-steward.md

```yaml
---
name: workspace-steward
description: >
  Orchestrates compound multi-step workspace operations.
  Delegates to dk:* skills and coordinates cross-project tasks.
tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
---
```

### Role
The steward handles compound operations that span multiple dk:* skills:

1. **"Update everything"**: pull → install → build → test → report
2. **"Prepare release"**: check status → ensure clean → tag → push tags
3. **"Onboard teammate"**: list recipients → add key → updatekeys → verify
4. **"Weekly health report"**: status + check + outdated deps + security

### How It Works
The agent reads workspace.yaml to understand the workspace, then calls
the appropriate dk:* skills in sequence. It handles failures between
steps (e.g., if pull fails for one project, skip its build).

### Example Compound Operation
```
User: "Update everything and make sure it all works"

Steward:
  1. /dk:status → check starting state
  2. /dk:pull → update all projects
  3. Bash("pnpm install") → sync dependencies
  4. Bash("pnpm turbo build") → build all
  5. Bash("pnpm turbo test") → run tests
  6. /dk:check --quick → validate health
  7. Report: what changed, what passed, what failed
```
