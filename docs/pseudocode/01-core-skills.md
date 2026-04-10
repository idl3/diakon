# 01 — Core Skills Pseudocode

Pseudocode for the 5 core workspace management skills.

---

## /dk:init [workspace-name]

### Frontmatter
```yaml
---
name: dk-init
description: Initialize a Diakon workspace — auto-detect projects, create registry, setup secrets infrastructure
argument-hint: "[workspace-name]"
user-invocable: true
---
```

### Workflow

#### Step 1: Determine Workspace Root
```
WORKSPACE_ROOT = Bash("pwd")
WORKSPACE_NAME = argument OR basename(WORKSPACE_ROOT)
```

#### Step 2: Guard — Already Initialized?
```
IF .diakon/workspace.yaml exists:
  Read it, show current state
  ASK "Re-initialize? This will overwrite the registry. (y/N)"
  IF answer != "y": ABORT
```

#### Step 3: Detect Workspace Type
```
IF pnpm-workspace.yaml exists:
  WORKSPACE_TYPE = "pnpm"
  PNPM_VERSION = Bash("pnpm --version")
ELSE IF package.json has workspaces field:
  IF yarn.lock exists: WORKSPACE_TYPE = "yarn"
  ELSE: WORKSPACE_TYPE = "npm"
ELSE:
  WORKSPACE_TYPE = "none"
```

#### Step 4: Discover Projects
```
IF WORKSPACE_TYPE == "pnpm":
  Parse pnpm-workspace.yaml globs (e.g., "aether/*", "olam/*")
  Resolve each glob: Glob("{pattern}/package.json")
  Group by top-level directory → project with sub-packages

ELSE IF WORKSPACE_TYPE in ["npm", "yarn"]:
  Parse package.json workspaces field
  Same glob resolution

ELSE:
  Scan top-level dirs for package.json or .git
```

#### Step 5: Detect Project Metadata (per project)
```
FOR EACH project:
  TYPE = detect by marker file:
    package.json → "node"
    Gemfile → "rails"
    go.mod → "go"
    Cargo.toml → "rust"
    requirements.txt/pyproject.toml → "python"

  NAME = package.json name field OR directory name
  SCOPE = extract @scope from name (e.g., "@idl3")
  DESCRIPTION = package.json description

  GIT_URL = Bash("git -C <path> remote get-url origin")
  DEFAULT_BRANCH = Bash("git -C <path> symbolic-ref refs/remotes/origin/HEAD")
    fallback: check for origin/main, then origin/master
```

#### Step 6: Check Secrets Tooling
```
AGE_AVAILABLE = Bash("command -v age")
SOPS_AVAILABLE = Bash("command -v sops")
IF missing: advise "brew install <missing>"
```

#### Step 7: Secrets Backend Selection
```
PRINT "Select secrets backend:"
  1. age (solo)
  2. age (team — multiple keys)
  3. GCP KMS
  4. GCP KMS + age fallback

FOR age tiers:
  Check ~/.config/sops/age/keys.txt
  IF not found: Bash("age-keygen -o ~/.config/sops/age/keys.txt")
  Extract public key: Bash("grep 'public key:' <keyfile>")

FOR GCP KMS tiers:
  ASK: project ID, location, keyring, key name
  Build resource ID: projects/{p}/locations/{l}/keyRings/{r}/cryptoKeys/{k}
  Optionally create: gcloud kms keyrings create, gcloud kms keys create
```

#### Step 8: Write .diakon/ Files
```
Write .diakon/workspace.yaml (populated with discovered projects)
Write .diakon/.sops.yaml (creation_rules with age/GCP KMS recipients)
Create .diakon/secrets.enc.yaml (sops-encrypted empty YAML)
Write .diakon/.gitignore (*.key, *.age-key, keys.txt)
```

#### Step 9: Update Root .gitignore
```
Append: .diakon/*.key, .diakon/*.age-key (if not already present)
```

#### Step 10: Print Summary
```
Show: workspace name, type, package manager, secrets backend
Show: discovered projects with package counts
Show: files created
Show: next steps (/dk:list, /dk:info, /dk:secret-set)
```

### Edge Cases
- .diakon/ already exists → confirm re-init
- pnpm globs match zero dirs → warn, continue with empty projects
- Project dir has no .git → git fields null
- age key already exists → reuse, don't overwrite
- sops encryption fails on empty file → plaintext placeholder

---

## /dk:add <project-path> [--name X] [--type X]

### Frontmatter
```yaml
---
name: dk-add
description: Register a project in the Diakon workspace with auto-detected metadata
argument-hint: "<project-path> [--name <name>] [--type <type>]"
user-invocable: true
---
```

### Workflow
1. Resolve path (relative to workspace root)
2. Validate: directory exists, not already registered (check paths AND names)
3. Auto-detect: name, type, sub-packages, git remote, default branch, description
4. Confirm detected metadata with user
5. Append project block to workspace.yaml (insert before `secrets:` section)
6. If pnpm workspace: offer to add glob to pnpm-workspace.yaml

### Edge Cases
- Path outside workspace root → abort with warning
- Path has spaces → quote all variables in Bash commands
- Duplicate name → abort with message
- No .git → set git fields to null
- workspace.yaml has no `secrets:` line → insert at end

---

## /dk:remove <project-name>

### Frontmatter
```yaml
---
name: dk-remove
description: Unregister a project from the Diakon workspace (does not delete files)
argument-hint: "<project-name>"
user-invocable: true
---
```

### Workflow
1. If no argument: list projects, ask user to select
2. Validate project exists in registry
3. Show project info, confirm removal
4. Read full workspace.yaml, remove the project block (awk/line-based)
5. Write updated file
6. Confirm: "Removed X. Files at Y are untouched."

### CRITICAL: Never delete files. Only unregister from workspace.yaml.

---

## /dk:list

### Frontmatter
```yaml
---
name: dk-list
description: List all projects registered in the Diakon workspace
user-invocable: true
---
```

### Workflow
1. Read workspace.yaml
2. Parse workspace header (name, type, package_manager)
3. Parse all projects (name, type, path, packages, enabled)
4. Format table: Name | Type | Path | Packages | Enabled
5. If empty: suggest /dk:add

---

## /dk:info <project-name>

### Frontmatter
```yaml
---
name: dk-info
description: Show detailed information about a registered project
argument-hint: "<project-name>"
user-invocable: true
---
```

### Workflow
1. Parse project from workspace.yaml
2. Git data (parallel Bash calls):
   - current branch
   - dirty status (git status --porcelain)
   - last 5 commits (git log --oneline -5)
   - ahead/behind remote (git rev-list --left-right --count)
3. Package data: version from package.json, workspace deps
4. File counts: source files + test files (heuristic by project type)
5. Display as info card with all sections

### Edge Cases
- Project directory deleted → show warning, display registry data only
- Git remote unreachable → show "unknown" for sync status
- No package.json → skip version/deps section
