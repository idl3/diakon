---
name: "dk:pull"
description: "Git pull across all workspace projects. Use when the user says 'pull all', 'update all projects', 'sync everything'."
argument-hint: "[--rebase] [project-name]"
user-invocable: true
---

# Recursive Git Pull

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Verify workspace exists. Get enabled projects.

2. If a specific project name is given as argument, filter to just that one. Validate it exists.

3. **Pre-flight dirty check** — for each target project:
```bash
git -C <abs_path> status --porcelain 2>/dev/null
```
If output is non-empty, mark as DIRTY. Warn: "Skipping <name> — has uncommitted changes."

4. **Pull each non-dirty project** sequentially (not parallel — merge conflicts need sequential attention):
```bash
git -C <abs_path> pull --ff-only 2>&1
```
If `--rebase` flag was given, use `git pull --rebase` instead.

5. **Report results per project**:
```
Pull results:
  aether     OK     Already up to date.
  olam       OK     3 files changed, 42 insertions(+)
  pleri      SKIP   Has uncommitted changes
```

6. **Post-pull dependency check**: If any project was updated AND the workspace has a package manager (pnpm/npm/yarn), offer: "Dependencies may have changed. Run `<pm> install`?"

6. **Update submodules**: After pulling, if the workspace has `.gitmodules`:
```bash
git submodule update --init --recursive
```
This ensures submodule pointers are synced to the commit the workspace expects. For submodule projects, also pull within each submodule:
```bash
# For each project where mode == "submodule":
git -C <abs_path> pull --ff-only
```

7. **Post-pull dependency check**: If any project was updated AND the workspace has a package manager (pnpm/npm/yarn), offer: "Dependencies may have changed. Run `<pm> install`?"

## Error Handling

- **Merge conflicts**: Report which project has conflicts. Suggest `git -C <path> merge --abort` or `git -C <path> rebase --abort`.
- **Network failure**: Report the error, continue with remaining projects.
- **No upstream**: Skip with message "no remote tracking branch".

## IMPORTANT

Never use `--force` or `--hard` flags. Never discard uncommitted changes. If dirty, SKIP — don't stash automatically unless the user explicitly asks.
