---
name: "dk:secret-list"
description: "List all secret keys without decrypting values. Shows backend info and recipient count. Use when the user says 'list secrets', 'what secrets exist', 'show secret keys'."
user-invocable: true
---

# List Secret Keys

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Verify `.diakon/secrets.enc.yaml` exists. If not, print "No secrets file found. Use /dk:secret-set to create one." and stop.

2. **Read the encrypted file** using the Read tool (no decryption needed — keys are plaintext in sops YAML).

3. **Extract keys**: Parse top-level YAML keys, excluding the `sops` metadata key. In sops-encrypted YAML, values look like `ENC[AES256_GCM,data:...,type:str]` — extract the `type:` portion for display.

4. **Read backend info** from `.diakon/.sops.yaml`: count age recipients and GCP KMS resources.

5. **Display**:
```
Secrets in .diakon/secrets.enc.yaml
Backend: age (team)
Recipients: 3

  Key                        Type
  ──────────────────────────  ────
  API_KEY                    str
  DATABASE_URL               str
  STRIPE_SECRET              str

3 secret(s) stored.

Use /dk:secret-get <key> to decrypt a specific value.
```

## Security Note

No decryption occurs in this skill. Only key names and types are shown. Key names are considered non-sensitive (they are plaintext in the encrypted file and visible in git diffs).
