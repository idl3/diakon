# 02 — Git Operations Pseudocode

Pseudocode for the 4 git operation skills.

---

## /dk:status

### Frontmatter
```yaml
---
name: dk-status
description: Show git status dashboard across all workspace projects
user-invocable: true
---
```

### Workflow

#### Step 1: Load Projects
```
Read workspace.yaml → get all enabled projects
```

#### Step 2: Parallel Git Queries
```
FOR EACH project (batch Bash calls in single message):
  Bash("git -C <path> branch --show-current 2>/dev/null || echo 'detached'")
  Bash("git -C <path> status --porcelain 2>/dev/null | wc -l")
  Bash("git -C <path> log --oneline -1 2>/dev/null || echo '(no commits)'")
  Bash("git -C <path> rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo '0\t0'")
```

#### Step 3: Format Dashboard
```
  Project   | Branch  | Status | Ahead/Behind | Last Commit
  ----------|---------|--------|--------------|------------
  aether    | main    | clean  | 0/0          | abc1234 feat: add tokens
  olam      | feat/x  | dirty  | 2/0          | def5678 fix: adapter types
  pleri     | main    | clean  | 0/3          | ghi9012 chore: deps
```

### Edge Cases
- No upstream → show "no remote" instead of ahead/behind
- Detached HEAD → show "detached@<short-sha>"
- Empty repo (no commits) → show "(no commits)"
- Directory missing → show "MISSING" with warning

---

## /dk:pull [--rebase] [project-name]

### Frontmatter
```yaml
---
name: dk-pull
description: Git pull across all workspace projects
argument-hint: "[--rebase] [project-name]"
user-invocable: true
---
```

### Workflow

#### Step 1: Pre-flight Check
```
FOR EACH project:
  dirty = Bash("git -C <path> status --porcelain")
  IF dirty:
    WARN "Project <name> has uncommitted changes — skipping"
    mark as SKIPPED
```

#### Step 2: Pull
```
FOR EACH non-skipped project:
  result = Bash("git -C <path> pull [--rebase] --ff-only 2>&1")
  IF exit_code != 0:
    Check for merge conflicts in output
    Report failure with stderr
```

#### Step 3: Post-Pull
```
IF any pulls brought changes AND workspace has package manager:
  PRINT "Dependencies may have changed."
  Offer to run: pnpm install / npm install / yarn install
```

### Error Handling
- Merge conflicts → report which project, suggest `git -C <path> merge --abort`
- Network failure → report, continue with remaining projects
- Dirty working tree → SKIP (never force pull over uncommitted work)

---

## /dk:branch <branch-name> [--projects p1,p2] [--create]

### Frontmatter
```yaml
---
name: dk-branch
description: Create or switch branches across workspace projects
argument-hint: "<branch-name> [--projects p1,p2] [--create]"
user-invocable: true
---
```

### Workflow
1. Parse args: branch name (required), --projects filter (optional), --create flag
2. Pre-flight: check dirty status on all target projects
3. If --create: `git -C <path> checkout -b <branch>` for each
4. If no --create: `git -C <path> checkout <branch>` for each
5. Report transitions: "aether: main → feat/xyz"

### Edge Cases
- Branch already exists (with --create) → skip that project, report
- Branch doesn't exist (without --create) → skip, report
- Uncommitted changes → warn but proceed (git checkout will fail safely)

---

## /dk:run <command> [--projects p1,p2] [--parallel]

### Frontmatter
```yaml
---
name: dk-run
description: Run a command across all or selected workspace projects
argument-hint: "<command> [--projects p1,p2]"
user-invocable: true
---
```

### Workflow
1. Parse: everything after flags is the command
2. Filter projects if --projects specified
3. For each project: `cd <path> && <command>`
4. Capture exit code, stdout (truncate at 50 lines), stderr
5. Report per-project results

### SECURITY: Command Injection
```
The command argument is passed directly to Bash. This is intentional —
the user is explicitly providing a command to run. However:
- NEVER interpolate project metadata (name, path) INTO the command string
- Use: cd "<absolute-path>" && <user-command>
- The path comes from workspace.yaml, which the user controls
- If path contains shell metacharacters, quoting prevents injection
```

### Output Truncation
```
Truncate stdout at 50 lines per project to protect Claude's context window.
Show: "[... truncated, N more lines]"
```
