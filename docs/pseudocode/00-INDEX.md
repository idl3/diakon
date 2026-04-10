# Diakon Pseudocode Index

Implementation-ready pseudocode for all 14 Diakon skills.

| File | Skills | Status |
|------|--------|--------|
| [01-core-skills.md](01-core-skills.md) | /dk:init, /dk:add, /dk:remove, /dk:list, /dk:info | Complete |
| [02-git-operations.md](02-git-operations.md) | /dk:status, /dk:pull, /dk:branch, /dk:run | Complete |
| [03-secrets-management.md](03-secrets-management.md) | /dk:secret-set, /dk:secret-get, /dk:secret-list, /dk:secret-add-recipient, /dk:secret-remove, init_secrets_infrastructure | Complete |
| [04-health-and-agent.md](04-health-and-agent.md) | /dk:check, workspace-steward agent | Complete |
| [05-shell-helpers.md](05-shell-helpers.md) | dk-helpers.sh implementation | Complete |

## Shared Patterns

All skills follow this structure:
1. Validate workspace exists (`.diakon/workspace.yaml`)
2. Parse registry with line-oriented tools (Grep/awk)
3. Execute operations via Bash
4. Present formatted output

YAML parsing uses grep/awk — no yq dependency. The schema is deliberately flat enough for line-oriented parsing.
