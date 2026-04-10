---
name: "dk:add"
description: "Add a project to the workspace — default: git submodule, or --symlink for symlinked local repos. Accepts a GitHub URL or local path."
argument-hint: "<path-or-github-url> [--symlink] [--name <name>] [--type <type>]"
user-invocable: true
---

# Add Project to Workspace

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Modes

| Input | Default behavior | With `--symlink` |
|-------|-----------------|------------------|
| GitHub URL | `git submodule add <url>` | Not supported (need a local path to symlink) |
| Local path (inside workspace) | Register existing directory | Register existing directory |
| Local path (outside workspace) | Error — must be inside workspace | `ln -s <external-path> <workspace-path>` then register |

## Workflow

1. Verify workspace exists via `dk_workspace_root`. Abort if missing.

2. **Parse flags**: Extract `--symlink`, `--name`, `--type` from arguments. Everything else is the path or URL.

3. **Detect input type** — check if the argument is a GitHub URL or a local path:

   A GitHub URL matches any of:
   - `git@github.com:<owner>/<repo>.git`
   - `https://github.com/<owner>/<repo>.git`
   - `https://github.com/<owner>/<repo>`
   - `github.com/<owner>/<repo>`
   - `<owner>/<repo>` (shorthand — exactly one `/`, no `.` or path separators beyond that)

   **IMPORTANT: Always use SSH URLs (`git@github.com:...`) for git operations, not HTTPS.** If the user provides an HTTPS URL, convert it to SSH format before running git commands:
   - `https://github.com/owner/repo.git` → `git@github.com:owner/repo.git`
   - `https://github.com/owner/repo` → `git@github.com:owner/repo.git`
   - Shorthand `owner/repo` → `git@github.com:owner/repo.git`

4. **If GitHub URL (default = submodule)**:

   Extract the repo name from the URL (last path segment, strip `.git` suffix).

   If `--symlink` is set: error — "Cannot symlink a remote repo. Use a local path with --symlink, or omit --symlink to add as submodule."

   Check if target directory already exists:
   - If it exists AND is already a submodule (`git submodule status <path>` succeeds): warn "Already a submodule", skip to registration.
   - If it exists but NOT a submodule: ask "Directory exists. Remove and re-add as submodule? (y/N)". If no, just register the existing directory.
   - If it doesn't exist: proceed with submodule add.

   ```bash
   git submodule add <url> <repo-name>
   git submodule update --init --recursive <repo-name>
   ```

   Set the project path to `./<repo-name>`.

5. **If local path**:

   Resolve the path. Two sub-cases:

   **a) Path is inside the workspace** (e.g., `./aether`, `./my-service`):
   - Verify directory exists
   - Just register it (no git operation needed)

   **b) Path is outside the workspace** (e.g., `~/Projects/atlas`, `../other-project`):
   - If `--symlink` is set:
     ```bash
     # Create symlink inside workspace
     ln -s <absolute-external-path> <workspace-root>/<basename>
     ```
     Set the project path to `./<basename>`.
   - If `--symlink` is NOT set:
     Error: "Path is outside workspace. Use --symlink to create a symlink, or provide a GitHub URL to add as submodule."

6. **Validate path is inside workspace**: The resolved project path (after submodule add or symlink) must be under the workspace root.

7. **Check for duplicates**: Read workspace.yaml. Check if any existing project has the same path OR the same name. If duplicate, abort with message.

8. **Auto-detect metadata**:
   - **Name**: Use `--name` override if provided. Otherwise read `package.json` name field (strip `@scope/` prefix), or fall back to directory basename. Validate with `dk_validate_project_name`.
   - **Type**: Use `--type` override if provided. Otherwise detect: `package.json` → node, `Gemfile` → rails, `go.mod` → go, `Cargo.toml` → rust, `requirements.txt`/`pyproject.toml` → python.
   - **Sub-packages**: Run `find <path> -maxdepth 2 -name package.json -not -path '*/node_modules/*' -not -path '<path>/package.json'`. Each match is a sub-package.
   - **Git**: `git -C <path> remote get-url origin`, default branch detection.
   - **Description**: From `package.json` description field.
   - **Mode**: Record how the project was added: `submodule`, `symlink`, or `directory`.

9. **Confirm with user**: Show all detected metadata including the mode (submodule/symlink/directory) and ask "Add to workspace? (Y/n)".

10. **Append to workspace.yaml**: Build the YAML block for the new project. Include the `mode` field:
    ```yaml
    my-project:
      path: "./my-project"
      mode: "submodule"  # or "symlink" or "directory"
      enabled: true
      type: "node"
      ...
    ```
    Write back using `dk_safe_write`.

11. **Optionally update pnpm-workspace.yaml**: If workspace type is pnpm, check if the project path is covered by existing globs. If not, offer to add a glob pattern (e.g., `"my-project/*"` for projects with sub-packages).

12. Print confirmation: "Added <name> as <mode> to workspace."

## Examples

```bash
# Add remote repo as submodule (default)
/dk:add git@github.com:idl3/atlas.git

# Add remote repo as submodule (shorthand)
/dk:add idl3/atlas

# Register existing directory already in workspace
/dk:add ./my-service

# Symlink an external local project into workspace
/dk:add ~/Projects/atlas --symlink

# With overrides
/dk:add idl3/atlas --name atlas-core --type rails
```

## Submodule Management Notes

After adding submodules, the workspace `.gitmodules` file is updated automatically by git. When other developers clone the workspace, they need:
```bash
git clone --recurse-submodules <workspace-url>
# or after clone:
git submodule update --init --recursive
```

The `/dk:pull` skill should also handle `git submodule update --init --recursive` after pulling.
