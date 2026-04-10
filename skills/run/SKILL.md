---
name: "dk:run"
description: "Run a command across all or selected workspace projects. Use when the user says 'run across projects', 'execute in all projects'."
argument-hint: "<command> [--projects p1,p2]"
user-invocable: true
---

# Cross-Project Command Execution

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Parse arguments: extract `--projects` filter if present. Everything else is the command to run.

2. Get target projects (filtered or all enabled).

3. **For each project**, run the command:
```bash
cd "<abs_path>" && <command>
```

IMPORTANT on quoting: The `<abs_path>` must be double-quoted to handle spaces. The command is passed as-is — the user provides the full command string.

4. **Capture results**: exit code, stdout (first 50 lines), stderr (first 10 lines).

5. **Report per project**:
```
Running: npm outdated

  aether (exit 0):
    Package      Current  Wanted  Latest
    typescript   5.7.0    5.9.3   5.9.3

  olam (exit 0):
    All packages up to date.

  pleri (exit 1):
    Package      Current  Wanted  Latest
    wrangler     4.0.0    4.5.0   4.5.0
```

6. **Summary**: "Ran in N projects: M succeeded, K failed."

## Output Truncation

Truncate stdout at 50 lines per project. Show "[... N more lines truncated]" if exceeded. This protects Claude's context window from large outputs (e.g., `npm test` with verbose logging).

## Security Note

The user's command is passed directly to Bash. This is by design — the user explicitly provides what to run. The absolute project path is always quoted to prevent injection via malicious workspace.yaml paths (covered by H-3 path traversal validation in dk-helpers.sh). Never interpolate project metadata (names, descriptions) into the command string.
