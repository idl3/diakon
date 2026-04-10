---
name: "dk:secret-set"
description: "Encrypt and store a secret in the workspace secrets store. Use when the user says 'set secret', 'add secret', 'store secret'."
argument-hint: "<key> <value>"
user-invocable: true
---

# Set a Secret

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Check prerequisites: `dk_check_deps sops jq`. Both sops and jq are required (jq for safe value encoding — audit finding H-4).

2. Verify `.diakon/.sops.yaml` exists. If not, suggest `/dk:init`.

3. Validate the key name: must match `^[a-zA-Z_][a-zA-Z0-9_-]*$`. Must NOT be "sops" (reserved by sops for metadata).

4. Verify value is non-empty.

5. **Create secrets file if missing**: If `.diakon/secrets.enc.yaml` doesn't exist:
```bash
echo '{}' | SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops --encrypt --input-type yaml --output-type yaml --config .diakon/.sops.yaml /dev/stdin > .diakon/secrets.enc.yaml
```

6. **Set the secret using decrypt-edit-encrypt pipeline** (audit fix C-1 — never pass value on command line):

```bash
# Step 1: Decrypt to system temp dir (C-2: never in workspace)
DK_TMP=$(mktemp /tmp/dk-secret-XXXXXX.yaml)
trap 'rm -f "$DK_TMP"' EXIT

SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --decrypt .diakon/secrets.enc.yaml > "$DK_TMP"

# Step 2: Set the value via environment variable (C-1: never on cmdline)
export DK_VALUE="<the-secret-value>"
jq --arg key "<key>" --arg val "$DK_VALUE" '.[$key] = $val' "$DK_TMP" > "${DK_TMP}.new"
mv "${DK_TMP}.new" "$DK_TMP"
unset DK_VALUE

# Step 3: Re-encrypt
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --encrypt --input-type json --output-type yaml \
  --config .diakon/.sops.yaml "$DK_TMP" > .diakon/secrets.enc.yaml.new

# Step 4: Atomic replace
mv .diakon/secrets.enc.yaml.new .diakon/secrets.enc.yaml

# Step 5: Cleanup (trap handles this, but be explicit)
rm -f "$DK_TMP"
```

**IMPORTANT**: The value is passed via the `DK_VALUE` environment variable, NOT as a command-line argument. Environment variables are not visible in `/proc/<pid>/cmdline`. The `jq` command reads from env, not from args.

7. Confirm: "Secret '<key>' stored (encrypted with <backend>)."

**NEVER echo or display the value.** Only confirm the key name.

## Error Handling

| Error | Cause | Recovery |
|-------|-------|----------|
| "could not decrypt" | Private key mismatch | Check ~/.config/sops/age/keys.txt |
| "no matching creation rule" | .sops.yaml path_regex wrong | Fix .sops.yaml |
| "Mac mismatch" | File corrupted | `git checkout -- .diakon/secrets.enc.yaml` |
| jq not found | Missing dependency | `brew install jq` |
