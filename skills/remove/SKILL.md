---
name: "dk:remove"
description: "Unregister a project from the Diakon workspace. Does NOT delete files — only removes the registry entry. Use when the user says 'remove project' or 'unregister'."
argument-hint: "<project-name>"
user-invocable: true
---

# Remove Project from Workspace

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Verify workspace exists via `dk_workspace_root`. Abort if missing.

2. If no argument provided: list all projects using `dk_list_projects` and ask the user to select one.

3. Validate the project name exists in workspace.yaml by checking `dk_project_path` returns a non-empty value.

4. Read the project's path for the confirmation message.

5. Confirm with the user:
```
Remove project:
  Name: <name>
  Path: <path>

This only removes the registry entry.
Files at <path> will NOT be deleted.

Proceed? (y/N)
```

6. Read the full workspace.yaml. Remove the project block: everything from `  <name>:` (at 2-space indent) until the next project entry (another line at 2-space indent starting with alphanumeric) or the `secrets:` section. Write back using `dk_safe_write`.

7. Print: "Removed '<name>' from workspace. Files at <path> are untouched."

## CRITICAL

**NEVER delete actual project files.** This skill only modifies workspace.yaml.
