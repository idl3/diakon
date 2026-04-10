---
name: "dk:secret-get"
description: "Decrypt and display a specific secret from the workspace secrets store. Use when the user says 'get secret', 'show secret', 'what is the value of'."
argument-hint: "<key>"
user-invocable: true
---

# Get a Secret

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Check prerequisites: `dk_check_deps sops`.

2. Verify `.diakon/secrets.enc.yaml` exists. If not, suggest `/dk:secret-set` or `/dk:init`.

3. **Check the key exists** — read the encrypted file (keys are plaintext in sops YAML). Parse top-level keys excluding "sops":
```bash
grep -E '^[a-zA-Z_][a-zA-Z0-9_-]*:' .diakon/secrets.enc.yaml | grep -v '^sops:' | sed 's/:.*//'
```
If the requested key is not in this list, show available keys and suggest the closest match.

4. **Decrypt the specific key**:
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops --decrypt --extract '["<key>"]' .diakon/secrets.enc.yaml
```

5. Display the decrypted value:
```
<KEY> = <decrypted-value>
```

6. **Security warning**:
```
WARNING: This value is now visible in your session context.
```

## Error Handling

- "could not decrypt" → private key mismatch, check age key file
- "PERMISSION_DENIED" (GCP) → suggest `gcloud auth application-default login`
- Key not found → list available keys, suggest closest match
