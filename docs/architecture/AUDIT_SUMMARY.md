# Diakon Pre-Implementation Audit Summary

Synthesized from 4 parallel reviews: Security, Adversarial, Correctness, Architecture.

---

## CRITICAL (3) — Must fix before ANY implementation

### C-1: Secret values exposed via /proc/cmdline
**Source**: Security + Adversarial
**Location**: `sops --set '["KEY"] "VALUE"' file` in /dk:secret-set

`sops --set` passes the plaintext value as a command-line argument. On shared systems, any user can read it via `ps aux` or `/proc/<pid>/cmdline`.

**Fix**: Replace `sops --set` with a decrypt-edit-encrypt pipeline:
```bash
# Instead of: sops --set '["KEY"] "VALUE"' file
# Do:
sops -d file > /tmp/dk-$$-secrets.yaml   # decrypt to temp
yq -i '.KEY = env(DK_VALUE)' /tmp/...     # edit with env var (never cmdline)
sops -e /tmp/... > file                    # re-encrypt
rm /tmp/dk-$$-secrets.yaml                 # cleanup
```
Pass value via environment variable (`DK_VALUE`), never command-line.

### C-2: Plaintext temp files on persistent disk
**Source**: Security + Adversarial
**Location**: /dk:secret-remove, assert_secrets_file, init round-trip test

Secrets are decrypted to `.diakon/secrets.remove-tmp.yaml` on persistent disk. A crash/timeout leaves plaintext secrets unprotected. Time Machine or ZFS snapshots may capture them.

**Fix**:
1. Use `mktemp` in system temp dir (not workspace dir)
2. Add `trap 'rm -f "$tmpfile"' EXIT` for crash cleanup
3. On macOS: `/private/var/folders` (auto-purged)
4. Never write decrypted secrets inside the workspace directory

### C-3: awk regex matching causes project name collisions
**Source**: Adversarial + Correctness
**Location**: `dk-helpers.sh` lines 101, 111 — `$0 ~ "^  "name":"`

The awk `~` operator does regex matching. Project `api` matches `api-gateway`. Dots in project names (`my.project`) match any character.

**Fix**: Use exact string comparison:
```awk
# Instead of: $0 ~ "^  "name":"
# Do:
substr($0, 1, length("  "name":")) == "  "name":"
```

---

## HIGH (7) — Should fix before implementation

### H-1: `set -euo pipefail` in sourced library
**Source**: Correctness
**Location**: `dk-helpers.sh` line 8

When sourced, this permanently mutates the caller's shell options. Any skill that handles non-zero exits will break.

**Fix**: Remove `set -euo pipefail` from the library. Each function should handle errors internally. Callers set their own shell options.

### H-2: dk_project_field substring field matching
**Source**: Correctness
**Location**: `dk-helpers.sh` line 136 — `$0 ~ field":"`

Field `type` matches `subtype:`. Field `url` matches `base_url:`.

**Fix**: Anchor the match: `$0 ~ "^    "field":"`  (exact 4-space indent + field name + colon).

### H-3: Path traversal — no validation implemented
**Source**: Security
**Location**: `dk_project_abs_path` in dk-helpers.sh

Design doc notes the risk and provides a fix, but the implementation doesn't include it.

**Fix**: Add after path resolution:
```bash
realpath "$abs_path" | grep -q "^$(dk_workspace_root)" || { echo "Path outside workspace" >&2; return 1; }
```

### H-4: No file locking on workspace.yaml
**Source**: Adversarial + Architecture
**Location**: All write operations (/dk:add, /dk:remove, /dk:secret-add-recipient)

Two concurrent operations can both read, both pass validation, both write — one is silently lost.

**Fix**: Write-then-rename pattern with `flock`:
```bash
dk_safe_write() {
  local file="$1" content="$2"
  local tmp="${file}.new.$$"
  echo "$content" > "$tmp"
  mv "$tmp" "$file"  # atomic on same filesystem
}
```

### H-5: No workspace.yaml backup before mutation
**Source**: Architecture
**Location**: All write operations

One bad write corrupts the registry with no recovery path.

**Fix**: Copy `workspace.yaml` to `workspace.yaml.bak` before any write.

### H-6: `sed -i ''` is macOS-only
**Source**: Adversarial
**Location**: /dk:secret-remove pseudocode

`sed -i ''` (empty extension) is macOS syntax. Linux `sed -i` doesn't take an empty argument.

**Fix**: Use `sed -i.bak` then `rm *.bak`, or better — use `yq` for YAML manipulation and make it a required dependency for secret operations.

### H-7: No guard on /dk:init in dangerous directories
**Source**: Adversarial
**Location**: /dk:init step 1

User running `/dk:init` in `$HOME` or `/` scans everything, creates a massive workspace.yaml, and subsequent `/dk:status` exhausts Claude's context window.

**Fix**: Check `WORKSPACE_ROOT` against a denylist (`$HOME`, `/`, `/tmp`, etc.) and warn.

---

## MEDIUM (8) — Fix during implementation

| ID | Issue | Fix |
|----|-------|-----|
| M-1 | `dk_project_field` has dead `gsub` using literal "field" | Fix the awk to use the variable |
| M-2 | Comments in workspace.yaml affect `dk_enabled_projects` | Skip lines starting with `#` |
| M-3 | Numeric project names silently dropped (`[a-zA-Z]` pattern) | Change to `[a-zA-Z0-9]` |
| M-4 | CRLF line endings break awk value extraction | Strip `\r` in all awk programs |
| M-5 | Error messages may leak sops stderr fragments | Sanitize/truncate before display |
| M-6 | No audit logging for secret operations | Add append-only log file |
| M-7 | `dk_for_each_project` callback failure kills iteration | Wrap callback in `|| true` |
| M-8 | .gitignore missing `secrets.enc.yaml.new`, `keys.txt` patterns | Add all temp file patterns |

---

## Missing Capabilities (from Architecture Review)

| Feature | Priority | Description |
|---------|----------|-------------|
| `/dk:env` | HIGH | Generate .env file from selected secrets for a project |
| `commands` block in schema | MEDIUM | Project-specific commands (build, deploy, migrate) |
| `runtime` block in schema | MEDIUM | Docker/wrangler configs per project |
| Atomic writes | HIGH | Write-then-rename for all YAML mutations |
| Schema migration path | LOW | Handle diakon version upgrades gracefully |
| Setup profiles | LOW | Named configs like atlas-one's setups/*.yml |

---

## Remediation Priority

**Before writing ANY skill:**
1. Fix dk-helpers.sh: remove `set -euo pipefail`, fix awk regex matching (C-3), fix field substring matching (H-2), add path traversal check (H-3)
2. Add `dk_safe_write` function (H-4, H-5)

**Before implementing secrets skills:**
3. Replace `sops --set` with decrypt-edit-encrypt pipeline (C-1)
4. Use system temp dir + trap for cleanup (C-2)
5. Make `jq` a hard prerequisite for secret operations (H-6 related)
6. Add init directory denylist (H-7)

**During implementation:**
7. Handle all MEDIUM issues as they arise
8. Add `/dk:env` skill to the skill inventory
