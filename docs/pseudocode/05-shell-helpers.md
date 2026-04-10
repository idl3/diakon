# 05 — Shell Helpers Design

The actual implementation is at `scripts/dk-helpers.sh`. This document covers design rationale and edge cases.

---

## Functions

| Function | Purpose | Returns |
|----------|---------|---------|
| `dk_workspace_root` | Find .diakon/workspace.yaml in parent dirs | Absolute path or exit 1 |
| `dk_check_deps <cmds...>` | Verify CLI tools installed | 0 if all present, 1 with missing list |
| `dk_list_projects` | All project names from workspace.yaml | One name per line |
| `dk_enabled_projects` | Only enabled projects | One name per line |
| `dk_project_path <name>` | Relative path for a project | String like "./aether" |
| `dk_project_abs_path <name>` | Absolute path | /Users/.../ein-sof/aether |
| `dk_project_field <name> <field>` | Get any field from project block | Field value string |
| `dk_is_enabled <name>` | Check enabled status | exit 0 (true) or 1 (false) |
| `dk_workspace_field <field>` | Get workspace-level field | Field value string |
| `dk_for_each_project <fn>` | Iterate enabled projects | Calls fn(name, path) |

## YAML Parsing Strategy

The workspace.yaml schema is constrained to enable line-oriented parsing:

**Constraint 1**: Project names at exactly 2-space indent
```yaml
projects:
  aether:        ← matches /^  [a-zA-Z]/
    path: ...    ← does NOT match (4-space indent)
```

**Constraint 2**: Values on same line as key (no multi-line strings)
```yaml
  path: "./aether"    ← value extractable with gsub
```

**Constraint 3**: Lists use inline format
```yaml
  packages: ["types", "ui"]    ← NOT block format with - items
```

**Constraint 4**: Section delimiters
```
projects:     ← start of projects section
  ...
secrets:      ← end of projects section (next top-level key)
```

These constraints let awk state machines parse reliably:
- Enter state on section header
- Exit state on next top-level key
- Match fields within state

## Security Considerations

**Path traversal**: `dk_project_path` returns whatever is in workspace.yaml.
If someone puts `path: "../../etc"` in the YAML, commands like `git -C <path>`
would operate outside the workspace. Skills should validate that resolved paths
are within the workspace root:
```bash
realpath "$abs_path" | grep -q "^$(dk_workspace_root)" || error "Path outside workspace"
```

**Shell injection via YAML values**: Project names and paths from workspace.yaml
are passed to awk/grep. If a project name contains awk metacharacters (regex),
parsing could break or behave unexpectedly. Mitigation:
- Project names validated on /dk:add (alphanumeric + hyphens only)
- Paths are quoted in all Bash commands
- awk variables use -v (not string interpolation) where possible

## Compatibility

- bash 3.2+ (macOS ships 3.2, can't assume 4.x features)
- No associative arrays (bash 4+ only)
- No `readarray` / `mapfile` (bash 4+ only)
- Use `while read` instead of process substitution where possible
- awk is POSIX awk (not gawk-specific features)
