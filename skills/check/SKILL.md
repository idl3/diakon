---
name: "dk:check"
description: "Run workspace health checks — verify projects, dependencies, secrets, and builds. Use when the user says 'check workspace', 'verify everything', 'health check'."
argument-hint: "[--quick] [--fix]"
user-invocable: true
---

# Workspace Health Check

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

Run checks in order. Track pass/warn/fail counts. Present a summary report at the end.

### Check 1: Registry Validation

- `.diakon/workspace.yaml` exists and is readable
- Has `diakon:` version field
- Has `workspace:` section with `name` field
- Has `projects:` section

### Check 2: Project Validation (per project)

For each registered project:
- Directory exists at declared path
- If git configured: `.git` exists, `git rev-parse --is-inside-work-tree` succeeds
- If git remote in registry: actual remote matches (`git remote get-url origin`)

### Check 3: Dependency Validation (skip if --quick)

For node workspaces:
- All `workspace:*` references in package.json files resolve to actual workspace packages
- Lock file exists (pnpm-lock.yaml / yarn.lock / package-lock.json)
- Check for conflicting versions of shared deps across projects (read each package.json)

### Check 4: Build Validation (skip if --quick)

For each project with a build script:
- Run the build, check exit code
- Report failures with first 20 lines of output

### Check 5: Secrets Validation

If `.diakon/.sops.yaml` exists:
- Valid creation_rules with at least one recipient
- `.diakon/secrets.enc.yaml` exists
- If sops is installed: attempt to list keys (read the file, no decryption)

### Check 6: Cross-Project Checks

- No duplicate package names across workspace
- No circular `workspace:*` dependency chains

### --fix Mode

Auto-fix safe issues:
- Missing `.diakon/.gitignore` entries → append
- Stale lock file → offer to run `<pm> install`
- Missing workspace.yaml fields → add defaults

DO NOT auto-fix: build failures, git mismatches, secrets corruption.

### Output Format

```
dk:check — Workspace Health Report

  Registry:      OK
  Projects:      3/3 OK
  Dependencies:  1 warning
    WARN: pnpm-lock.yaml older than pleri/web/package.json
  Secrets:       OK (3 recipients)
  Builds:        OK (skipped: --quick)

  Overall: PASS (1 warning)
```

Severity levels:
- **PASS**: All checks green
- **WARN**: Non-blocking issues found
- **FAIL**: Critical issues that need fixing
