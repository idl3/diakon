---
name: "dk:list"
description: "List all projects registered in the Diakon workspace. Use when the user says 'list projects', 'show projects', or wants an overview."
user-invocable: true
---

# List Workspace Projects

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Verify workspace exists by calling `dk_workspace_root`. If it fails, print "No Diakon workspace found. Run /dk:init first." and stop.

2. Read `.diakon/workspace.yaml` in full.

3. Extract workspace header: use `dk_workspace_field` to get `name`, `type`, and `package_manager`.

4. Parse all projects using `dk_list_projects` to get names, then for each name use `dk_project_field` to get `type`, `path`, `enabled`, and read the `packages:` line.

5. Format as a table:

```
Workspace: ein-sof (pnpm, pnpm@10.8.1)
Projects:  3

Name      Type   Path       Packages                Enabled
────────  ─────  ─────────  ──────────────────────── ───────
aether    node   ./aether   types, ui                yes
olam      node   ./olam     core, adapters, mcp-...  yes
pleri     node   ./pleri    api, web, types          yes
```

6. If no projects are registered, show:
```
No projects registered.
  /dk:add <path>  — register a project
  /dk:init        — re-scan and auto-discover
```
