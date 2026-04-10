---
name: "dk:info"
description: "Show detailed information about a registered project — git status, dependencies, file counts. Use when the user says 'project info', 'project details', or 'tell me about <project>'."
argument-hint: "<project-name>"
user-invocable: true
---

# Project Info Card

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Verify workspace exists. If no argument, list projects and ask user to select.

2. Validate the project exists in workspace.yaml using `dk_project_field`.

3. **Read registry data**: Use `dk_project_field` to get: path, type, enabled, and read the packages, git.url, git.default_branch, meta.description, meta.scope fields from the project block.

4. **Gather live git data** — run these Bash commands (batch them in parallel where possible):
```bash
git -C <abs_path> branch --show-current 2>/dev/null || echo "detached"
git -C <abs_path> status --porcelain 2>/dev/null | wc -l | tr -d ' '
git -C <abs_path> log --oneline -5 2>/dev/null
git -C <abs_path> rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0	0"
git -C <abs_path> log -1 --format='%cr' 2>/dev/null || echo "unknown"
```

5. **Package info** (node projects): Read `package.json` for version. Search dependencies and devDependencies for any `workspace:*` references — these are workspace dependencies.

6. **File counts**: Count source and test files based on project type:
   - node: `*.ts`, `*.tsx`, `*.js`, `*.jsx` (excluding node_modules, dist)
   - go: `*.go` (excluding `*_test.go` for source, `*_test.go` for tests)
   - python: `*.py` (excluding `test_*` for source)
   - rust: `*.rs` (excluding target/)

7. **Display info card**:
```
┌─────────────────────────────────────────┐
│  olam                                   │
└─────────────────────────────────────────┘

  Path:           ./olam
  Type:           node
  Version:        0.1.0
  Enabled:        true
  Description:    World lifecycle manager

  Packages (5):
    - core
    - adapters
    - mcp-server
    - cloudflare
    - control-plane

  Git:
    Remote:       git@github.com:idl3/olam.git
    Branch:       main
    Status:       clean
    Sync:         up to date
    Last commit:  2 hours ago

  Recent commits:
    abc1234 feat: add streaming support
    def5678 fix: connection pool timeout
    ...

  Workspace deps:
    - @idl3/aether-types

  Files:
    Source:  142
    Tests:   38
```

If the project directory doesn't exist on disk, show a warning and display only registry data.
