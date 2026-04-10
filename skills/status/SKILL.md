---
name: "dk:status"
description: "Show git status dashboard across all workspace projects. Use when the user says 'workspace status', 'project status', 'what state are things in'."
user-invocable: true
---

# Workspace Status Dashboard

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Verify workspace exists via `dk_workspace_root`. Get workspace name via `dk_workspace_field "name"`.

2. Get all enabled projects via `dk_enabled_projects`.

3. **Gather git data in parallel** — for each project, issue these as **parallel Bash calls** (batch all projects in a single message with multiple Bash tool uses):

```bash
git -C <abs_path> branch --show-current 2>/dev/null || echo "detached"
git -C <abs_path> status --porcelain 2>/dev/null | wc -l | tr -d ' '
git -C <abs_path> log --oneline --no-decorate -1 2>/dev/null || echo "(no commits)"
git -C <abs_path> rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0	0"
```

You can combine all 4 commands for one project into a single Bash call to reduce tool calls:
```bash
cd <abs_path> && echo "BRANCH:$(git branch --show-current 2>/dev/null || echo detached)" && echo "DIRTY:$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')" && echo "LAST:$(git log --oneline --no-decorate -1 2>/dev/null || echo '(none)')" && echo "SYNC:$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo '0	0')"
```

Run one such combined command per project. Issue ALL project commands in parallel (one Bash call per project, all in the same message).

4. **Parse results** for each project:
   - Branch: the BRANCH line
   - Dirty count: the DIRTY line (0 = clean)
   - Last commit: the LAST line
   - Ahead/behind: parse SYNC as "ahead\tbehind"

5. **Format dashboard**:

```
Workspace: ein-sof
─────────────────────────────────────────────────────────────────────

Project    Branch   Status   Sync     Last Commit
─────────  ───────  ───────  ───────  ──────────────────────────────
aether     main     clean    =        a1b2c3d feat: add tokens
olam       feat/x   2 dirty  +2       d4e5f6g fix: adapter types
pleri      main     clean    -3       h7i8j9k chore: update deps
```

Status indicators:
- `clean` — no uncommitted changes
- `N dirty` — N files with changes
- `=` — up to date with remote
- `+N` — ahead of remote by N commits
- `-N` — behind remote by N commits
- `+N/-M` — diverged
- `no remote` — no upstream configured

6. If a project directory is missing, show `MISSING` in the status column.

## Context Window Management

If more than 10 projects, consider truncating the last commit message to keep output compact. Always use `--no-decorate` on git log to avoid long ref names.
