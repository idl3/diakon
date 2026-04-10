---
name: "dk:branch"
description: "Create or switch branches across workspace projects. Use when the user says 'create branch', 'switch branch', 'checkout branch' for multiple projects."
argument-hint: "<branch-name> [--projects p1,p2] [--create]"
user-invocable: true
---

# Cross-Project Branch Management

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Parse arguments:
   - `branch-name`: required
   - `--projects p1,p2`: optional comma-separated filter
   - `--create`: flag to create new branch (otherwise checkout existing)

2. Get target projects: if `--projects` given, filter enabled projects to those names. Otherwise use all enabled projects.

3. **Pre-flight for each project**: Check current branch and dirty status.

4. **Execute**:

   If `--create`:
   ```bash
   git -C <abs_path> checkout -b <branch-name> 2>&1
   ```
   If branch already exists in that project, skip and report.

   If no `--create` (checkout existing):
   ```bash
   git -C <abs_path> checkout <branch-name> 2>&1
   ```
   If branch doesn't exist in that project, skip and report.

5. **Report transitions**:
```
Branch operations:
  aether     main → feat/xyz        created
  olam       main → feat/xyz        created
  pleri      main → feat/xyz        created
```

6. If any project has uncommitted changes, warn but don't abort — git checkout will fail safely with a message. Report the failure.
