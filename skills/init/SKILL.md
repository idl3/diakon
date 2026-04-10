---
name: "dk:init"
description: "Initialize a Diakon workspace — auto-detect projects, create registry, setup secrets infrastructure. Use when the user says 'initialize workspace', 'setup diakon', or 'dk init'."
argument-hint: "[workspace-name]"
user-invocable: true
---

# Initialize Diakon Workspace

Source the helpers first:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

### 1. Determine workspace root and name

Use the current working directory as the workspace root. If an argument is provided, use it as the workspace name; otherwise use the directory basename.

### 2. Safety check

Run `dk_is_safe_init_dir` on the current directory. If it returns failure (the directory is `$HOME`, `/`, `/tmp`, etc.), warn the user and **abort**. Do NOT initialize in these directories.

### 3. Check if already initialized

Check if `.diakon/workspace.yaml` already exists. If it does, read it, show the current workspace name and project count, and ask: "Workspace already initialized. Re-initialize? This will overwrite the registry. (y/N)". If the user says no, abort.

### 4. Detect workspace type

Check in this order:
1. If `pnpm-workspace.yaml` exists → type is "pnpm". Read the pnpm version with `pnpm --version`.
2. Else if `package.json` exists and has a `workspaces` field → check for `yarn.lock` (yarn) or default to "npm".
3. Else → type is "none", no package manager.

### 5. Discover projects

**For pnpm workspaces**: Read `pnpm-workspace.yaml` and parse the `packages:` array. For each glob pattern (e.g., `"aether/*"`), use Glob to find matching directories containing `package.json`. Group discovered directories by their top-level parent (e.g., `aether/types` and `aether/ui` both group under `aether`). The parent directory name becomes the project name, and the subdirectories become sub-packages.

**For npm/yarn workspaces**: Same approach using the `workspaces` field from `package.json`.

**For no workspace**: Scan top-level directories for `package.json`, `.git`, `Gemfile`, `go.mod`, `Cargo.toml`, or `pyproject.toml`.

### 6. Detect project metadata

For each discovered project:
- **Type**: Check for `package.json` → node, `Gemfile` → rails, `go.mod` → go, `Cargo.toml` → rust, `requirements.txt`/`pyproject.toml` → python
- **Name**: From `package.json` name field (strip scope) or directory name
- **Scope**: If package name starts with `@`, extract the scope (e.g., `@idl3`)
- **Git remote**: `git -C <path> remote get-url origin 2>/dev/null`
- **Default branch**: `git -C <path> symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'` — fallback to "main"
- **Description**: From `package.json` description field

### 7. Secrets backend selection

Check if `sops` and `age` are installed using `dk_check_deps sops age`. If either is missing, print install instructions and set secrets backend to "none".

If both are available, ask the user to select a tier:
```
Secrets backend:
  1. age (solo — single local key)
  2. age (team — multiple public keys)
  3. GCP KMS (cloud-managed)
  4. GCP KMS + age fallback (hybrid)
```

**For age tiers (1, 2, 4)**:
- Check if `~/.config/sops/age/keys.txt` exists
- If not: run `mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt` and `chmod 600 ~/.config/sops/age/keys.txt`
- Extract public key: `grep 'public key:' ~/.config/sops/age/keys.txt | awk '{print $NF}'`
- If tier 2: ask user to paste additional team member public keys (one per line, empty to finish)

**For GCP KMS tiers (3, 4)**:
- Check `dk_check_deps gcloud`
- Ask for: GCP project ID (try `gcloud config get-value project` as default), location (default: global), keyring name, key name
- Build resource ID: `projects/{project}/locations/{location}/keyRings/{ring}/cryptoKeys/{key}`
- Offer to create keyring and key if they don't exist via `gcloud kms keyrings create` and `gcloud kms keys create --purpose=encryption`

### 8. Write .diakon/ files

Create the `.diakon/` directory with `mkdir -p .diakon`.

**workspace.yaml** — Generate YAML content with all discovered projects and write using `dk_safe_write`. Structure:
```yaml
diakon: "0.1.0"

workspace:
  name: "<workspace-name>"
  type: "<detected-type>"
  package_manager: "<detected-pm>"

projects:
  <project-name>:
    path: "./<path>"
    enabled: true
    type: "<detected-type>"
    packages: [<sub-packages>]
    mode: "<submodule|symlink|directory>"
    git:
      url: "<remote-url>"
      default_branch: "<branch>"
    meta:
      description: "<description>"
      scope: "<scope>"

secrets:
  backend: "<backend>"
  file: ".diakon/secrets.enc.yaml"
```

**.sops.yaml** — Write creation rules based on selected tier. For age: list all public keys. For GCP KMS: include resource ID.

**secrets.enc.yaml** — Create initial empty encrypted file:
```bash
echo '{}' | SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --encrypt --input-type yaml --output-type yaml --config .diakon/.sops.yaml /dev/stdin > .diakon/secrets.enc.yaml
```
If this fails, write a placeholder comment file.

**.diakon/.gitignore**:
```
*.key
*.age-key
keys.txt
*.tmp.yaml
```

### 9. Update root .gitignore

Read `.gitignore` (or create if missing). Append these entries if not already present:
```
# Diakon secrets (never commit)
.diakon/*.key
.diakon/*.age-key
```

### 10. Print summary

Show the workspace name, type, package manager, secrets backend, number of projects discovered, and list each project with its type and sub-package count. Then show next steps:
```
Next steps:
  /dk:list          — review registered projects
  /dk:info <name>   — inspect a project
  /dk:secret-set    — store your first secret
```
