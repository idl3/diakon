---
name: "dk:secret-add-recipient"
description: "Add a decryption recipient (age public key or GCP KMS resource ID) and re-encrypt all secrets. Use when the user says 'add recipient', 'add team member', 'share secrets with'."
argument-hint: "<age-public-key or GCP-KMS-resource-id>"
user-invocable: true
---

# Add Decryption Recipient

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

1. Check prerequisites: `dk_check_deps sops`.

2. Verify `.diakon/.sops.yaml` exists.

3. **Classify the argument**:
   - Starts with `age1` → age public key
   - Starts with `projects/` → GCP KMS resource ID
   - Otherwise → error with format guidance

4. **Validate**:
   - Age key: must match `^age1[a-z0-9]{50,}$` (Bech32 format, ~62 chars). Check for duplicates in existing .sops.yaml.
   - GCP KMS: must match `^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$`. If `gcloud` is available, verify with `gcloud kms keys describe`.

5. **Update .sops.yaml**: Read the file. In the first `creation_rules` entry, append the new recipient to the `age:` or `gcp_kms:` field. Write back using `dk_safe_write`.

6. **Re-encrypt secrets** (if secrets file exists):
```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  sops updatekeys --yes .diakon/secrets.enc.yaml
```
This re-encrypts the data key for all recipients. Requires the current user's private key.

**If updatekeys fails**: The .sops.yaml has been updated but secrets are NOT re-encrypted. Warn the user and suggest reverting .sops.yaml from backup.

7. **Update workspace.yaml**: Add the recipient to the `secrets.age_recipients` list using `dk_safe_write`.

8. Confirm: "Added <type> recipient. All secrets re-encrypted for N recipient(s)."

## Error Handling

- Duplicate recipient → idempotent (warn, don't error)
- updatekeys fails → warn about split state, suggest .sops.yaml.bak rollback
- GCP PERMISSION_DENIED → advise IAM role `roles/cloudkms.cryptoKeyEncrypterDecrypter`
