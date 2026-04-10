# 03 — Secrets Management

Pseudocode for all Diakon secrets skills: set, get, list, add-recipient, remove,
and the first-time setup flow called from `/dk:init`.

Backend: **sops + age** with optional GCP KMS. Four tiers:
- Tier 1 (Solo): Single age key at ~/.config/sops/age/keys.txt
- Tier 2 (Team): Multiple age public keys in .diakon/.sops.yaml
- Tier 3 (Cloud): GCP KMS key in .sops.yaml, access via IAM
- Tier 4 (Hybrid): GCP KMS + age fallback for offline dev

Files:
- `.diakon/secrets.enc.yaml` — YAML, keys plaintext, values sops-encrypted
- `.diakon/.sops.yaml` — sops creation rules (age recipients and/or GCP KMS)
- `.diakon/workspace.yaml` — workspace registry (secrets section)

---

## Shared Constants

```
SOPS_CONFIG     := ".diakon/.sops.yaml"
SECRETS_FILE    := ".diakon/secrets.enc.yaml"
WORKSPACE_FILE  := ".diakon/workspace.yaml"
AGE_KEY_PATH    := "~/.config/sops/age/keys.txt"
SOPS_AGE_KEY_FILE_ENV := "SOPS_AGE_KEY_FILE"
```

---

## Shared Procedure: assert_prerequisites

Used by every secrets skill before any operation.

```
PROCEDURE assert_prerequisites(need_sops: bool, need_age: bool, need_gcloud: bool)

  # --- Tool availability ---
  IF need_sops:
    result := Bash("command -v sops")
    IF result.exit_code != 0:
      ERROR "sops not found."
      PRINT "Install: brew install sops  (macOS)"
      PRINT "         or: go install github.com/getsops/sops/v3/cmd/sops@latest"
      PRINT "         Docs: https://github.com/getsops/sops"
      ABORT

  IF need_age:
    result := Bash("command -v age")
    IF result.exit_code != 0:
      ERROR "age not found."
      PRINT "Install: brew install age  (macOS)"
      PRINT "         or: go install filippo.io/age/cmd/age@latest"
      ABORT

  IF need_gcloud:
    result := Bash("command -v gcloud")
    IF result.exit_code != 0:
      ERROR "gcloud CLI not found."
      PRINT "Install: https://cloud.google.com/sdk/docs/install"
      ABORT

  # --- Config files ---
  IF NOT file_exists(SOPS_CONFIG):
    ERROR ".diakon/.sops.yaml not found."
    PRINT "Run /dk:init to set up secrets infrastructure, or create .sops.yaml manually."
    ABORT

  IF NOT file_exists(WORKSPACE_FILE):
    ERROR ".diakon/workspace.yaml not found."
    PRINT "Run /dk:init first."
    ABORT

  RETURN OK
END PROCEDURE
```

---

## Shared Procedure: assert_secrets_file

Ensures the encrypted secrets file exists. Creates it if missing.

```
PROCEDURE assert_secrets_file()

  IF file_exists(SECRETS_FILE):
    RETURN OK

  # Create an empty encrypted YAML file.
  # sops needs at least an empty YAML document to work with.
  # Write a minimal YAML stub, then encrypt it in-place.

  PRINT "secrets.enc.yaml not found. Creating empty secrets file..."

  # Write empty YAML document
  Bash("echo '{}' > .diakon/secrets.plaintext.tmp.yaml")

  # Encrypt using the .sops.yaml config
  result := Bash(
    "cd .diakon && sops --encrypt --input-type yaml --output-type yaml "
    + "secrets.plaintext.tmp.yaml > secrets.enc.yaml"
  )

  IF result.exit_code != 0:
    # Clean up temp file
    Bash("rm -f .diakon/secrets.plaintext.tmp.yaml")
    ERROR "Failed to create encrypted secrets file."
    PRINT "sops output: " + result.stderr
    PRINT "Check that .diakon/.sops.yaml is valid and your age key exists at:"
    PRINT "  " + AGE_KEY_PATH
    ABORT

  # Clean up temp file
  Bash("rm -f .diakon/secrets.plaintext.tmp.yaml")

  PRINT "Created empty .diakon/secrets.enc.yaml"
  RETURN OK
END PROCEDURE
```

---

## Shared Procedure: detect_backend

Reads .sops.yaml and determines which backend(s) are active.

```
PROCEDURE detect_backend() -> BackendInfo

  sops_yaml := Read(SOPS_CONFIG)
  parsed    := yaml_parse(sops_yaml)

  info := BackendInfo {
    has_age: false,
    has_gcp_kms: false,
    age_recipients: [],
    gcp_kms_resources: [],
    tier: UNKNOWN
  }

  # sops.yaml structure:
  # creation_rules:
  #   - age: "age1abc...,age1def..."         # comma-separated public keys
  #     gcp_kms: "projects/.../cryptoKeys/k"  # optional

  FOR rule IN parsed.creation_rules:
    IF rule.age IS NOT EMPTY:
      info.has_age = true
      info.age_recipients = split(rule.age, ",")
      # Trim whitespace from each recipient
      info.age_recipients = [trim(r) FOR r IN info.age_recipients]

    IF rule.gcp_kms IS NOT EMPTY:
      info.has_gcp_kms = true
      info.gcp_kms_resources = split(rule.gcp_kms, ",")
      info.gcp_kms_resources = [trim(r) FOR r IN info.gcp_kms_resources]

  # Determine tier
  IF info.has_age AND info.has_gcp_kms:
    info.tier = "hybrid"       # Tier 4
  ELSE IF info.has_gcp_kms:
    info.tier = "cloud"        # Tier 3
  ELSE IF info.has_age AND len(info.age_recipients) > 1:
    info.tier = "team"         # Tier 2
  ELSE IF info.has_age:
    info.tier = "solo"         # Tier 1
  ELSE:
    info.tier = "unknown"

  RETURN info
END PROCEDURE
```

---

## Shared Procedure: sanitize_sops_value

Escapes a user-provided value for safe embedding in a sops --set command.

```
PROCEDURE sanitize_sops_value(raw_value: string) -> string

  # sops --set expects: '["key"] "value"'
  # The value portion is a JSON string. We must JSON-encode it.
  #
  # This handles:
  #   - Double quotes     -> \"
  #   - Backslashes       -> \\
  #   - Newlines          -> \n
  #   - Tabs              -> \t
  #   - Other control characters

  # Use a JSON encoder to produce a safe string.
  # In shell, jq is the simplest correct approach:
  #   echo -n "$RAW" | jq -Rs '.'
  # This produces a JSON-encoded string WITH surrounding quotes.

  result := Bash("printf '%s' " + shell_quote(raw_value) + " | jq -Rs '.'")

  IF result.exit_code != 0:
    # Fallback: manual escaping
    escaped := raw_value
    escaped = replace(escaped, "\\", "\\\\")
    escaped = replace(escaped, '"', '\\"')
    escaped = replace(escaped, "\n", "\\n")
    escaped = replace(escaped, "\t", "\\t")
    RETURN '"' + escaped + '"'

  # jq output already includes surrounding quotes
  RETURN trim(result.stdout)
END PROCEDURE
```

---

## Shared Procedure: sanitize_sops_key

Validates and escapes a key name for sops path expressions.

```
PROCEDURE sanitize_sops_key(key: string) -> string

  # Keys must be valid YAML keys. Enforce:
  #   - Non-empty
  #   - No leading/trailing whitespace
  #   - Alphanumeric, underscores, hyphens, dots only
  #   - Cannot be "sops" (reserved metadata key)

  key = trim(key)

  IF key IS EMPTY:
    ERROR "Key name cannot be empty."
    ABORT

  IF key == "sops":
    ERROR "Key name 'sops' is reserved by sops for metadata."
    ABORT

  IF NOT regex_match(key, "^[a-zA-Z_][a-zA-Z0-9_.\\-]*$"):
    ERROR "Invalid key name: '" + key + "'"
    PRINT "Keys must start with a letter or underscore."
    PRINT "Allowed characters: letters, digits, underscores, hyphens, dots."
    ABORT

  RETURN key
END PROCEDURE
```

---

## 1. /dk:secret-set <key> <value>

### SKILL.md Frontmatter

```yaml
---
name: secret-set
description: Encrypt and store a secret in .diakon/secrets.enc.yaml using sops+age.
trigger: /dk:secret-set
arguments:
  - name: key
    description: The secret key name (e.g., DATABASE_URL, API_KEY)
    required: true
  - name: value
    description: The secret value to encrypt and store
    required: true
tags: [secrets, sops, age, encryption]
---
```

### Workflow

```
SKILL dk:secret-set(key: string, value: string)

  # ========================================
  # STEP 1: Validate prerequisites
  # ========================================
  assert_prerequisites(need_sops=true, need_age=false, need_gcloud=false)
  # Note: age is not strictly needed for set — sops handles encryption.
  # But sops needs access to the age key file for re-encryption.

  # ========================================
  # STEP 2: Validate inputs
  # ========================================
  key = sanitize_sops_key(key)

  IF value IS EMPTY:
    ERROR "Value cannot be empty. To remove a secret, use /dk:secret-remove."
    ABORT

  # ========================================
  # STEP 3: Ensure secrets file exists
  # ========================================
  assert_secrets_file()

  # ========================================
  # STEP 4: Detect backend for confirmation message
  # ========================================
  backend := detect_backend()

  # ========================================
  # STEP 5: Encode value for sops --set
  # ========================================
  json_value := sanitize_sops_value(value)

  # ========================================
  # STEP 6: Set the secret via sops
  # ========================================
  #
  # sops --set '["KEY"] VALUE' FILE
  #
  # - KEY is a JSON path expression
  # - VALUE is a JSON-encoded value (string in quotes, number bare, etc.)
  # - sops decrypts the file, sets the key, re-encrypts, writes back
  #
  # Environment: SOPS_AGE_KEY_FILE must point to the private key
  # sops will auto-detect from ~/.config/sops/age/keys.txt by default
  # but we set it explicitly for reliability.

  sops_cmd := (
    "SOPS_AGE_KEY_FILE=" + shell_quote(expand_path(AGE_KEY_PATH))
    + " sops --set '[\"" + key + "\"] " + json_value + "'"
    + " " + shell_quote(SECRETS_FILE)
  )

  result := Bash(sops_cmd)

  IF result.exit_code != 0:
    stderr := result.stderr

    # --- Error classification ---

    IF contains(stderr, "could not decrypt"):
      ERROR "Cannot decrypt secrets file."
      PRINT "Your age private key may not match the recipients in .sops.yaml."
      PRINT "Key file checked: " + AGE_KEY_PATH
      PRINT "Run: age-keygen -y " + AGE_KEY_PATH + "  to see your public key."
      PRINT "Then verify it appears in .diakon/.sops.yaml creation_rules."
      ABORT

    IF contains(stderr, "no matching creation rule"):
      ERROR "No matching creation rule in .sops.yaml for this file."
      PRINT "Check .diakon/.sops.yaml path_regex patterns."
      ABORT

    IF contains(stderr, "permission denied"):
      ERROR "Permission denied accessing secrets file or key."
      PRINT "Check file permissions on:"
      PRINT "  " + SECRETS_FILE
      PRINT "  " + AGE_KEY_PATH
      ABORT

    IF contains(stderr, "Mac mismatch"):
      ERROR "Secrets file integrity check failed (MAC mismatch)."
      PRINT "The file may have been corrupted or manually edited."
      PRINT "Recovery options:"
      PRINT "  1. Restore from git: git checkout -- " + SECRETS_FILE
      PRINT "  2. Re-create: delete the file and re-set all secrets"
      ABORT

    # Generic fallback
    ERROR "sops --set failed."
    PRINT "Exit code: " + str(result.exit_code)
    PRINT "stderr: " + stderr
    ABORT

  # ========================================
  # STEP 7: Verify the write (paranoia check)
  # ========================================
  # Read the file to confirm the key exists in plaintext keys
  file_content := Read(SECRETS_FILE)
  IF NOT contains(file_content, key + ":"):
    WARN "Write appeared to succeed but key not found in file."
    WARN "This may indicate a sops version incompatibility."

  # ========================================
  # STEP 8: Confirm to user
  # ========================================
  # SECURITY: Never echo the value. Only confirm the key name.

  backend_label := CASE backend.tier OF
    "solo"   -> "age (solo)"
    "team"   -> "age (team, " + str(len(backend.age_recipients)) + " recipients)"
    "cloud"  -> "GCP KMS"
    "hybrid" -> "GCP KMS + age fallback"
    DEFAULT  -> "sops"

  PRINT "Secret '" + key + "' stored (encrypted with " + backend_label + ")."

  # ========================================
  # SECURITY NOTES
  # ========================================
  # - The VALUE argument is visible in Claude's context but never echoed
  #   in output or written to logs.
  # - sops --set passes the value via command-line argument. On shared
  #   systems, /proc/<pid>/cmdline could expose it briefly. For maximum
  #   security in shared environments, consider piping through stdin
  #   (sops does not support this for --set; would need decrypt-edit-encrypt).
  # - The decrypted value exists in memory during the sops process.
  #   This is unavoidable with any encryption tool.

END SKILL
```

### Example Output

```
Secret 'DATABASE_URL' stored (encrypted with age (team, 3 recipients)).
```

### Error Examples

```
ERROR: sops not found.
Install: brew install sops  (macOS)
         or: go install github.com/getsops/sops/v3/cmd/sops@latest

ERROR: Cannot decrypt secrets file.
Your age private key may not match the recipients in .sops.yaml.
Key file checked: ~/.config/sops/age/keys.txt
Run: age-keygen -y ~/.config/sops/age/keys.txt  to see your public key.
Then verify it appears in .diakon/.sops.yaml creation_rules.

ERROR: Key name 'sops' is reserved by sops for metadata.
```

---

## 2. /dk:secret-get <key>

### SKILL.md Frontmatter

```yaml
---
name: secret-get
description: Decrypt and display a specific secret from .diakon/secrets.enc.yaml.
trigger: /dk:secret-get
arguments:
  - name: key
    description: The secret key name to retrieve
    required: true
tags: [secrets, sops, age, decryption]
---
```

### Workflow

```
SKILL dk:secret-get(key: string)

  # ========================================
  # STEP 1: Validate prerequisites
  # ========================================
  assert_prerequisites(need_sops=true, need_age=false, need_gcloud=false)

  # ========================================
  # STEP 2: Validate inputs
  # ========================================
  key = sanitize_sops_key(key)

  # ========================================
  # STEP 3: Verify secrets file exists
  # ========================================
  IF NOT file_exists(SECRETS_FILE):
    ERROR "No secrets file found at " + SECRETS_FILE
    PRINT "Run /dk:secret-set to create one, or /dk:init to set up secrets."
    ABORT

  # ========================================
  # STEP 4: Check the key exists before decrypting
  # ========================================
  # Read the encrypted file — keys are plaintext in sops YAML
  file_content := Read(SECRETS_FILE)
  available_keys := extract_yaml_top_level_keys(file_content, exclude=["sops"])

  IF key NOT IN available_keys:
    ERROR "Key '" + key + "' not found in secrets."

    IF len(available_keys) == 0:
      PRINT "No secrets are currently stored."
    ELSE:
      PRINT "Available keys:"
      FOR k IN sort(available_keys):
        PRINT "  - " + k

      # Suggest closest match (Levenshtein distance)
      closest := find_closest_match(key, available_keys, max_distance=3)
      IF closest IS NOT NULL:
        PRINT ""
        PRINT "Did you mean: " + closest + " ?"

    ABORT

  # ========================================
  # STEP 5: Decrypt the specific key
  # ========================================

  sops_cmd := (
    "SOPS_AGE_KEY_FILE=" + shell_quote(expand_path(AGE_KEY_PATH))
    + " sops --decrypt --extract '[\"" + key + "\"]'"
    + " " + shell_quote(SECRETS_FILE)
  )

  result := Bash(sops_cmd)

  IF result.exit_code != 0:
    stderr := result.stderr

    IF contains(stderr, "could not decrypt"):
      ERROR "Cannot decrypt. Your private key may not match."
      PRINT "Key file: " + AGE_KEY_PATH
      PRINT "Check that your public key is listed in .diakon/.sops.yaml."
      ABORT

    IF contains(stderr, "Mac mismatch"):
      ERROR "Secrets file integrity check failed."
      PRINT "The file may be corrupted. Restore from git:"
      PRINT "  git checkout -- " + SECRETS_FILE
      ABORT

    IF contains(stderr, "403") OR contains(stderr, "PERMISSION_DENIED"):
      ERROR "GCP KMS permission denied."
      PRINT "Ensure your gcloud credentials have kms.cryptoKeyVersions.useToDecrypt."
      PRINT "Run: gcloud auth application-default login"
      ABORT

    ERROR "sops --decrypt failed."
    PRINT "stderr: " + stderr
    ABORT

  # ========================================
  # STEP 6: Display the decrypted value
  # ========================================
  decrypted_value := trim(result.stdout)

  PRINT key + " = " + decrypted_value

  # ========================================
  # STEP 7: Security warning
  # ========================================
  PRINT ""
  WARN "This value is now visible in your session context."
  WARN "It will persist in Claude's conversation memory for this session."
  WARN "Do not copy it to unencrypted files or commit it to git."

  # ========================================
  # SECURITY NOTES
  # ========================================
  # - The decrypted value is intentionally displayed — that is the
  #   purpose of this skill. But we always warn the user.
  # - The value enters Claude's context window and will be visible
  #   in conversation history.
  # - We do NOT offer to "set as environment variable" because that
  #   would require shell manipulation outside Claude's sandbox.

END SKILL
```

### Helper: extract_yaml_top_level_keys

```
PROCEDURE extract_yaml_top_level_keys(yaml_content: string, exclude: list[string]) -> list[string]

  # In sops-encrypted YAML, top-level keys are plaintext.
  # The file looks like:
  #
  #   DATABASE_URL: ENC[AES256_GCM,data:...,iv:...,tag:...]
  #   API_KEY: ENC[AES256_GCM,data:...,iv:...,tag:...]
  #   sops:
  #     kms: []
  #     age:
  #       - recipient: age1...
  #     ...
  #
  # We need to extract top-level keys (lines that start at column 0
  # and end with a colon, ignoring sops metadata).

  keys := []
  FOR line IN split(yaml_content, "\n"):
    # Skip empty lines and comments
    IF trim(line) IS EMPTY OR starts_with(trim(line), "#"):
      CONTINUE

    # Top-level key: starts at column 0, contains a colon
    IF NOT starts_with(line, " ") AND NOT starts_with(line, "\t"):
      IF contains(line, ":"):
        key_name := trim(split(line, ":")[0])
        IF key_name NOT IN exclude AND key_name IS NOT EMPTY:
          keys.append(key_name)

  RETURN keys
END PROCEDURE
```

### Helper: find_closest_match

```
PROCEDURE find_closest_match(target: string, candidates: list[string], max_distance: int) -> string | NULL

  best_match := NULL
  best_distance := max_distance + 1

  FOR candidate IN candidates:
    dist := levenshtein_distance(lower(target), lower(candidate))
    IF dist < best_distance:
      best_distance = dist
      best_match = candidate

  IF best_distance <= max_distance:
    RETURN best_match
  RETURN NULL
END PROCEDURE
```

### Example Output

```
DATABASE_URL = postgres://user:pass@host:5432/mydb

WARNING: This value is now visible in your session context.
WARNING: It will persist in Claude's conversation memory for this session.
WARNING: Do not copy it to unencrypted files or commit it to git.
```

### Error Example (key not found)

```
ERROR: Key 'DATABSE_URL' not found in secrets.
Available keys:
  - API_KEY
  - DATABASE_URL
  - STRIPE_SECRET

Did you mean: DATABASE_URL ?
```

---

## 3. /dk:secret-list

### SKILL.md Frontmatter

```yaml
---
name: secret-list
description: List all secret keys without decrypting values. Shows backend info and recipient count.
trigger: /dk:secret-list
arguments: []
tags: [secrets, sops, age, listing]
---
```

### Workflow

```
SKILL dk:secret-list()

  # ========================================
  # STEP 1: Minimal prerequisites (no sops needed — we just read the file)
  # ========================================
  IF NOT file_exists(SECRETS_FILE):
    PRINT "No secrets file found."
    PRINT "Run /dk:secret-set <key> <value> to create one."
    RETURN

  IF NOT file_exists(SOPS_CONFIG):
    WARN ".sops.yaml not found. Cannot determine backend info."

  # ========================================
  # STEP 2: Read encrypted file (no decryption)
  # ========================================
  file_content := Read(SECRETS_FILE)

  # ========================================
  # STEP 3: Extract keys
  # ========================================
  keys := extract_yaml_top_level_keys(file_content, exclude=["sops"])

  IF len(keys) == 0:
    PRINT "No secrets stored in " + SECRETS_FILE
    PRINT "Use /dk:secret-set <key> <value> to add one."
    RETURN

  # ========================================
  # STEP 4: Extract type metadata from sops-encrypted values
  # ========================================
  # sops-encrypted YAML values look like:
  #   KEY: ENC[AES256_GCM,data:base64...,iv:base64...,tag:base64...,type:str]
  # The 'type' field at the end tells us the original value type.

  key_types := {}
  FOR line IN split(file_content, "\n"):
    FOR key IN keys:
      IF starts_with(trim(line), key + ":"):
        value_part := trim(substring_after(line, ":"))
        type_match := regex_extract(value_part, "type:([a-z]+)")
        IF type_match IS NOT NULL:
          key_types[key] = type_match
        ELSE:
          key_types[key] = "unknown"

  # ========================================
  # STEP 5: Get backend info
  # ========================================
  IF file_exists(SOPS_CONFIG):
    backend := detect_backend()
  ELSE:
    backend := BackendInfo { tier: "unknown", age_recipients: [], gcp_kms_resources: [] }

  # ========================================
  # STEP 6: Display
  # ========================================

  # Header
  backend_label := CASE backend.tier OF
    "solo"   -> "age (solo)"
    "team"   -> "age (team)"
    "cloud"  -> "GCP KMS"
    "hybrid" -> "GCP KMS + age"
    DEFAULT  -> "unknown"

  recipient_count := len(backend.age_recipients) + len(backend.gcp_kms_resources)

  PRINT "Secrets in " + SECRETS_FILE
  PRINT "Backend: " + backend_label
  PRINT "Recipients: " + str(recipient_count)
  PRINT "---"

  # Table of keys
  PRINT ""
  PRINT "  Key" + pad(30) + "Type"
  PRINT "  " + repeat("-", 40)

  FOR key IN sort(keys):
    type_label := key_types.get(key, "str")
    PRINT "  " + pad_right(key, 30) + type_label

  PRINT ""
  PRINT str(len(keys)) + " secret(s) stored."
  PRINT ""
  PRINT "Use /dk:secret-get <key> to decrypt a specific value."

  # ========================================
  # SECURITY NOTES
  # ========================================
  # - No decryption occurs. Only key names and types are shown.
  # - Key names are considered non-sensitive (they are plaintext in
  #   the encrypted file and visible in git diffs).
  # - The sops metadata block is excluded from the listing.

END SKILL
```

### Example Output

```
Secrets in .diakon/secrets.enc.yaml
Backend: age (team)
Recipients: 3
---

  Key                           Type
  ----------------------------------------
  API_KEY                       str
  DATABASE_URL                  str
  MAX_RETRIES                   int
  STRIPE_SECRET                 str

4 secret(s) stored.

Use /dk:secret-get <key> to decrypt a specific value.
```

---

## 4. /dk:secret-add-recipient <public-key-or-gcp-resource>

### SKILL.md Frontmatter

```yaml
---
name: secret-add-recipient
description: >
  Add a decryption recipient (age public key or GCP KMS resource ID) to
  .diakon/.sops.yaml and re-encrypt all secrets for the updated recipient list.
trigger: /dk:secret-add-recipient
arguments:
  - name: recipient
    description: >
      An age public key (starts with age1...) or a GCP KMS resource ID
      (projects/{project}/locations/{loc}/keyRings/{ring}/cryptoKeys/{key}).
    required: true
tags: [secrets, sops, age, gcp-kms, team, recipients]
---
```

### Workflow

```
SKILL dk:secret-add-recipient(recipient: string)

  # ========================================
  # STEP 1: Validate prerequisites
  # ========================================
  assert_prerequisites(need_sops=true, need_age=false, need_gcloud=false)

  # ========================================
  # STEP 2: Classify recipient type
  # ========================================

  recipient = trim(recipient)

  IF starts_with(recipient, "age1"):
    recipient_type := "age"
  ELSE IF starts_with(recipient, "projects/"):
    recipient_type := "gcp_kms"
  ELSE:
    ERROR "Unrecognized recipient format."
    PRINT "Expected one of:"
    PRINT "  - age public key:    age1xxxxxxxxx..."
    PRINT "  - GCP KMS resource:  projects/{project}/locations/{loc}/keyRings/{ring}/cryptoKeys/{key}"
    ABORT

  # ========================================
  # STEP 3A: Validate age public key
  # ========================================
  IF recipient_type == "age":

    # age public keys are Bech32-encoded, starting with "age1"
    # Typical length: 62 characters (age1 + 58 chars)
    IF len(recipient) < 50 OR len(recipient) > 100:
      ERROR "age public key has unexpected length: " + str(len(recipient))
      PRINT "Expected ~62 characters starting with 'age1'."
      PRINT "Verify the key was copied correctly."
      ABORT

    IF NOT regex_match(recipient, "^age1[a-z0-9]{50,}$"):
      ERROR "Invalid age public key format."
      PRINT "age public keys are lowercase Bech32: age1 followed by lowercase letters and digits."
      PRINT "Received: " + recipient[:20] + "..."
      ABORT

    # Check for duplicate
    backend := detect_backend()
    IF recipient IN backend.age_recipients:
      WARN "This age recipient is already in .sops.yaml."
      PRINT "Current recipients:"
      FOR i, r IN enumerate(backend.age_recipients):
        PRINT "  " + str(i+1) + ". " + r
      RETURN  # Idempotent — not an error

    # --- Read and update .sops.yaml ---
    sops_yaml := Read(SOPS_CONFIG)
    parsed := yaml_parse(sops_yaml)

    # Append to the first creation rule's age field
    # .sops.yaml structure:
    #   creation_rules:
    #     - path_regex: .*secrets\.enc\.yaml$
    #       age: "age1abc...,age1def..."

    IF parsed.creation_rules IS EMPTY:
      ERROR ".sops.yaml has no creation_rules."
      PRINT "The file may be malformed. Expected structure:"
      PRINT "  creation_rules:"
      PRINT "    - path_regex: .*secrets\\.enc\\.yaml$"
      PRINT "      age: \"<public-key>\""
      ABORT

    rule := parsed.creation_rules[0]

    IF rule.age IS NOT EMPTY:
      # Append to existing comma-separated list
      rule.age = rule.age + "," + recipient
    ELSE:
      # First age recipient
      rule.age = recipient

    parsed.creation_rules[0] = rule

    # Write updated .sops.yaml
    Write(SOPS_CONFIG, yaml_serialize(parsed))
    PRINT "Added age recipient to .diakon/.sops.yaml"

  # ========================================
  # STEP 3B: Validate GCP KMS resource ID
  # ========================================
  ELSE IF recipient_type == "gcp_kms":

    # Expected format:
    # projects/{PROJECT}/locations/{LOCATION}/keyRings/{RING}/cryptoKeys/{KEY}
    gcp_pattern := "^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$"

    IF NOT regex_match(recipient, gcp_pattern):
      ERROR "Invalid GCP KMS resource ID format."
      PRINT "Expected: projects/{project}/locations/{location}/keyRings/{ring}/cryptoKeys/{key}"
      PRINT "Received: " + recipient
      ABORT

    # Check gcloud availability for verification
    gcloud_available := (Bash("command -v gcloud").exit_code == 0)

    IF gcloud_available:
      PRINT "Verifying GCP KMS key access..."
      verify_result := Bash("gcloud kms keys describe " + shell_quote(recipient) + " --format='value(purpose)' 2>&1")

      IF verify_result.exit_code != 0:
        stderr := verify_result.stderr + verify_result.stdout

        IF contains(stderr, "NOT_FOUND"):
          ERROR "GCP KMS key not found: " + recipient
          PRINT "Verify the project, location, keyring, and key name."
          ABORT

        IF contains(stderr, "PERMISSION_DENIED") OR contains(stderr, "403"):
          WARN "Cannot verify GCP KMS key (permission denied)."
          PRINT "The key may still be valid. Proceeding..."
          PRINT "Ensure IAM grants roles/cloudkms.cryptoKeyEncrypterDecrypter."
          # Do NOT abort — the user may have encrypt-only access

        ELSE:
          WARN "Could not verify GCP KMS key."
          PRINT "gcloud output: " + stderr
          PRINT "Proceeding anyway..."

      ELSE:
        purpose := trim(verify_result.stdout)
        IF purpose != "ENCRYPT_DECRYPT":
          WARN "KMS key purpose is '" + purpose + "', expected 'ENCRYPT_DECRYPT'."
          PRINT "sops requires a symmetric encrypt/decrypt key."
    ELSE:
      WARN "gcloud CLI not available. Skipping KMS key verification."
      PRINT "Ensure the resource ID is correct before re-encrypting."

    # Check for duplicate
    backend := detect_backend()
    IF recipient IN backend.gcp_kms_resources:
      WARN "This GCP KMS resource is already in .sops.yaml."
      RETURN

    # --- Read and update .sops.yaml ---
    sops_yaml := Read(SOPS_CONFIG)
    parsed := yaml_parse(sops_yaml)

    rule := parsed.creation_rules[0]

    IF rule.gcp_kms IS NOT EMPTY:
      rule.gcp_kms = rule.gcp_kms + "," + recipient
    ELSE:
      rule.gcp_kms = recipient

    parsed.creation_rules[0] = rule

    Write(SOPS_CONFIG, yaml_serialize(parsed))
    PRINT "Added GCP KMS key to .diakon/.sops.yaml"

  END IF

  # ========================================
  # STEP 4: Re-encrypt secrets for updated recipients
  # ========================================

  IF NOT file_exists(SECRETS_FILE):
    PRINT "No secrets file yet. New recipient will apply when secrets are first created."
    GOTO step_6_update_workspace

  PRINT "Re-encrypting secrets for updated recipient list..."

  # sops updatekeys re-encrypts the data key for all recipients
  # in the matching creation rule. It does NOT need the private keys
  # of all recipients — only the current user's private key to decrypt
  # the data key, then re-encrypts it for all listed recipients.

  updatekeys_cmd := (
    "SOPS_AGE_KEY_FILE=" + shell_quote(expand_path(AGE_KEY_PATH))
    + " sops updatekeys --yes"
    + " " + shell_quote(SECRETS_FILE)
  )

  result := Bash(updatekeys_cmd)

  IF result.exit_code != 0:
    stderr := result.stderr

    IF contains(stderr, "could not decrypt"):
      ERROR "Cannot decrypt to re-encrypt."
      PRINT "You need a valid private key to re-encrypt for new recipients."
      PRINT "Check: " + AGE_KEY_PATH
      # Rollback .sops.yaml?
      WARN "The .sops.yaml has been updated but secrets have NOT been re-encrypted."
      WARN "Either fix your key or revert .sops.yaml."
      ABORT

    ERROR "sops updatekeys failed."
    PRINT "stderr: " + stderr
    WARN "The .sops.yaml has been updated but secrets may NOT be re-encrypted."
    ABORT

  PRINT "All secrets re-encrypted."

  # ========================================
  # STEP 5: Verify (sanity check)
  # ========================================
  # Read the sops metadata from the encrypted file to confirm
  # the new recipient appears.

  file_content := Read(SECRETS_FILE)
  IF recipient_type == "age":
    IF NOT contains(file_content, recipient):
      WARN "Recipient not found in file's sops metadata."
      WARN "The updatekeys command may not have fully applied."
  ELSE IF recipient_type == "gcp_kms":
    # GCP KMS resource IDs appear in the sops metadata section
    # Extract the key name portion for a fuzzy check
    key_name := last(split(recipient, "/"))
    IF NOT contains(file_content, key_name):
      WARN "GCP KMS key not found in file's sops metadata."

  # ========================================
  # STEP 6: Update workspace.yaml
  # ========================================
  LABEL step_6_update_workspace:

  workspace := yaml_parse(Read(WORKSPACE_FILE))

  # Ensure secrets section exists
  IF workspace.secrets IS NULL:
    workspace.secrets = {}

  # Update age_recipients list
  IF recipient_type == "age":
    IF workspace.secrets.age_recipients IS NULL:
      workspace.secrets.age_recipients = []
    IF recipient NOT IN workspace.secrets.age_recipients:
      workspace.secrets.age_recipients.append(recipient)

  # Update gcp_kms_resources list
  ELSE IF recipient_type == "gcp_kms":
    IF workspace.secrets.gcp_kms_resources IS NULL:
      workspace.secrets.gcp_kms_resources = []
    IF recipient NOT IN workspace.secrets.gcp_kms_resources:
      workspace.secrets.gcp_kms_resources.append(recipient)

  Write(WORKSPACE_FILE, yaml_serialize(workspace))

  # ========================================
  # STEP 7: Confirm
  # ========================================

  updated_backend := detect_backend()
  total_recipients := len(updated_backend.age_recipients) + len(updated_backend.gcp_kms_resources)

  IF recipient_type == "age":
    PRINT "Added age recipient. All secrets re-encrypted for " + str(total_recipients) + " recipient(s)."
  ELSE:
    PRINT "Added GCP KMS key. All secrets re-encrypted for " + str(total_recipients) + " recipient(s)."

  # ========================================
  # SECURITY NOTES
  # ========================================
  # - The public key / resource ID is NOT sensitive. Safe to display and commit.
  # - Private age keys are NEVER read or displayed by this skill.
  # - Re-encryption requires the current user's private key to decrypt
  #   the data key. The new recipient's private key is NOT needed.
  # - After re-encryption, the new recipient can decrypt with their
  #   private key. Existing recipients retain access.

END SKILL
```

### Example Output (age)

```
Added age recipient to .diakon/.sops.yaml
Re-encrypting secrets for updated recipient list...
All secrets re-encrypted.
Added age recipient. All secrets re-encrypted for 3 recipient(s).
```

### Example Output (GCP KMS)

```
Verifying GCP KMS key access...
Added GCP KMS key to .diakon/.sops.yaml
Re-encrypting secrets for updated recipient list...
All secrets re-encrypted.
Added GCP KMS key. All secrets re-encrypted for 2 recipient(s).
```

---

## 5. /dk:secret-remove <key>

### SKILL.md Frontmatter

```yaml
---
name: secret-remove
description: Remove a specific key from .diakon/secrets.enc.yaml.
trigger: /dk:secret-remove
arguments:
  - name: key
    description: The secret key name to remove
    required: true
tags: [secrets, sops, age, removal]
---
```

### Workflow

```
SKILL dk:secret-remove(key: string)

  # ========================================
  # STEP 1: Validate prerequisites
  # ========================================
  assert_prerequisites(need_sops=true, need_age=false, need_gcloud=false)

  # ========================================
  # STEP 2: Validate inputs
  # ========================================
  key = sanitize_sops_key(key)

  # ========================================
  # STEP 3: Verify the key exists
  # ========================================
  IF NOT file_exists(SECRETS_FILE):
    ERROR "No secrets file found at " + SECRETS_FILE
    ABORT

  file_content := Read(SECRETS_FILE)
  available_keys := extract_yaml_top_level_keys(file_content, exclude=["sops"])

  IF key NOT IN available_keys:
    ERROR "Key '" + key + "' not found."
    IF len(available_keys) > 0:
      PRINT "Available keys: " + join(sort(available_keys), ", ")
    ABORT

  # ========================================
  # STEP 4: Confirm removal
  # ========================================
  # In a Claude Code skill context, we can ask for confirmation
  # by presenting the action and proceeding — Claude will ask if unsure.

  PRINT "Removing secret '" + key + "' from " + SECRETS_FILE + "..."

  # ========================================
  # STEP 5: Remove via sops
  # ========================================
  # sops does not have a native --remove-key flag.
  # Strategy: decrypt to temp, remove key, re-encrypt in place.
  #
  # Alternative: use sops exec-env or decrypt/edit/encrypt.
  # Safest approach: decrypt → manipulate → encrypt.

  # Step 5a: Decrypt to a temporary file
  tmp_file := ".diakon/secrets.remove-tmp.yaml"

  decrypt_cmd := (
    "SOPS_AGE_KEY_FILE=" + shell_quote(expand_path(AGE_KEY_PATH))
    + " sops --decrypt " + shell_quote(SECRETS_FILE)
    + " > " + shell_quote(tmp_file)
  )

  result := Bash(decrypt_cmd)
  IF result.exit_code != 0:
    Bash("rm -f " + shell_quote(tmp_file))
    ERROR "Failed to decrypt secrets file."
    PRINT "stderr: " + result.stderr
    ABORT

  # Step 5b: Remove the key from the decrypted YAML
  # Use a YAML-aware approach. In shell, yq is ideal:
  #   yq eval 'del(.KEY)' file.yaml

  yq_available := (Bash("command -v yq").exit_code == 0)

  IF yq_available:
    remove_cmd := "yq eval 'del(." + key + ")' -i " + shell_quote(tmp_file)
    result := Bash(remove_cmd)
    IF result.exit_code != 0:
      Bash("rm -f " + shell_quote(tmp_file))
      ERROR "Failed to remove key with yq."
      ABORT
  ELSE:
    # Fallback: use grep/sed to remove the key line.
    # This is fragile for multi-line values but works for simple sops secrets
    # which are always single-line after decryption.
    remove_cmd := "sed -i '' '/^" + key + ":/d' " + shell_quote(tmp_file)
    result := Bash(remove_cmd)
    IF result.exit_code != 0:
      Bash("rm -f " + shell_quote(tmp_file))
      ERROR "Failed to remove key with sed."
      ABORT

  # Step 5c: Re-encrypt the modified file
  encrypt_cmd := (
    "SOPS_AGE_KEY_FILE=" + shell_quote(expand_path(AGE_KEY_PATH))
    + " sops --encrypt --input-type yaml --output-type yaml"
    + " " + shell_quote(tmp_file)
    + " > " + shell_quote(SECRETS_FILE + ".new")
  )

  result := Bash(encrypt_cmd)

  IF result.exit_code != 0:
    Bash("rm -f " + shell_quote(tmp_file))
    Bash("rm -f " + shell_quote(SECRETS_FILE + ".new"))
    ERROR "Failed to re-encrypt after removing key."
    PRINT "stderr: " + result.stderr
    PRINT "Original secrets file is unchanged."
    ABORT

  # Step 5d: Atomic replace
  Bash("mv " + shell_quote(SECRETS_FILE + ".new") + " " + shell_quote(SECRETS_FILE))

  # Step 5e: Clean up temp file (contains plaintext!)
  Bash("rm -f " + shell_quote(tmp_file))

  # ========================================
  # STEP 6: Verify
  # ========================================
  updated_content := Read(SECRETS_FILE)
  updated_keys := extract_yaml_top_level_keys(updated_content, exclude=["sops"])

  IF key IN updated_keys:
    WARN "Key appears to still be present after removal."
    WARN "Manual verification recommended."
  ELSE:
    PRINT "Secret '" + key + "' removed. " + str(len(updated_keys)) + " secret(s) remaining."

  # ========================================
  # SECURITY NOTES
  # ========================================
  # - A temporary decrypted file exists briefly on disk. We remove it
  #   immediately after re-encryption.
  # - The decrypted value passes through the filesystem. On systems
  #   with encrypted disks (FileVault, LUKS), this is acceptable.
  # - For maximum security, consider using tmpfs / ramfs, but this
  #   is not portable across macOS and Linux.
  # - The removed secret's historical values remain in git history.
  #   If the secret was compromised, rotate it — don't just delete it.

END SKILL
```

### Example Output

```
Removing secret 'OLD_API_KEY' from .diakon/secrets.enc.yaml...
Secret 'OLD_API_KEY' removed. 3 secret(s) remaining.
```

---

## 6. First-Time Secrets Setup (called from /dk:init)

### Overview

This procedure is invoked during `/dk:init` workspace provisioning. It sets up
the entire secrets infrastructure: `.sops.yaml` config, age keys, optional GCP KMS,
and the initial encrypted secrets file.

### Workflow

```
PROCEDURE init_secrets_infrastructure(workspace_dir: string)

  # ========================================
  # STEP 1: Check tool availability
  # ========================================

  sops_installed  := (Bash("command -v sops").exit_code == 0)
  age_installed   := (Bash("command -v age").exit_code == 0)
  gcloud_installed := (Bash("command -v gcloud").exit_code == 0)

  IF NOT sops_installed:
    WARN "sops is not installed."
    PRINT "Install: brew install sops"
    PRINT "Secrets management will be skipped. Run /dk:init again after installing."
    RETURN SKIPPED

  IF NOT age_installed:
    WARN "age is not installed."
    PRINT "Install: brew install age"
    PRINT "Secrets management will be skipped. Run /dk:init again after installing."
    RETURN SKIPPED

  # ========================================
  # STEP 2: Check if already initialized
  # ========================================

  IF file_exists(workspace_dir + "/.diakon/.sops.yaml"):
    PRINT "Secrets infrastructure already exists."

    # Offer to reconfigure
    existing_backend := detect_backend()
    PRINT "Current backend: " + existing_backend.tier
    PRINT "Recipients: " + str(len(existing_backend.age_recipients))

    # In Claude Code context, ask the user
    ASK "Secrets are already configured. Skip? (Reconfigure will overwrite .sops.yaml)"
    IF user_says_skip:
      RETURN ALREADY_EXISTS

  # ========================================
  # STEP 3: Ask which backend tier
  # ========================================

  PRINT "Select secrets backend tier:"
  PRINT ""
  PRINT "  1. Solo (age)        — Single developer. One age key."
  PRINT "  2. Team (age)        — Multiple developers. Multiple age public keys."
  PRINT "  3. Cloud (GCP KMS)   — Team with GCP. Centralized key management."
  PRINT "  4. Hybrid (KMS+age)  — GCP KMS primary + age fallback for offline dev."
  PRINT ""

  tier := ASK "Enter tier (1-4, default: 1):"
  IF tier IS EMPTY:
    tier = "1"

  IF tier NOT IN ["1", "2", "3", "4"]:
    ERROR "Invalid tier. Expected 1-4."
    ABORT

  # ========================================
  # STEP 4: Set up age key (Tiers 1, 2, 4)
  # ========================================

  age_public_key := NULL
  age_recipients := []

  IF tier IN ["1", "2", "4"]:

    age_key_path := expand_path(AGE_KEY_PATH)

    IF file_exists(age_key_path):
      PRINT "Found existing age key at " + age_key_path

      # Extract public key from key file.
      # The key file has a comment line: # public key: age1...
      public_key_line := Bash("grep '^# public key:' " + shell_quote(age_key_path))

      IF public_key_line.exit_code == 0:
        age_public_key = trim(split(public_key_line.stdout, ": ")[1])
        PRINT "Your public key: " + age_public_key
      ELSE:
        # Fallback: derive public key from private key
        derive_result := Bash("age-keygen -y " + shell_quote(age_key_path))
        IF derive_result.exit_code == 0:
          age_public_key = trim(derive_result.stdout)
          PRINT "Your public key: " + age_public_key
        ELSE:
          ERROR "Cannot extract public key from " + age_key_path
          PRINT "The key file may be corrupted."
          PRINT "Regenerate: age-keygen -o " + age_key_path
          ABORT

    ELSE:
      PRINT "No age key found. Generating a new one..."

      # Ensure directory exists
      Bash("mkdir -p " + shell_quote(dirname(age_key_path)))

      result := Bash("age-keygen -o " + shell_quote(age_key_path) + " 2>&1")

      IF result.exit_code != 0:
        ERROR "Failed to generate age key."
        PRINT "stderr: " + result.stderr
        ABORT

      # Set restrictive permissions (owner read/write only)
      Bash("chmod 600 " + shell_quote(age_key_path))

      # Extract public key from output
      # age-keygen prints: Public key: age1...
      age_public_key = regex_extract(result.stdout + result.stderr, "age1[a-z0-9]+")

      IF age_public_key IS NULL:
        # Fallback: read from file comment
        public_key_line := Bash("grep '^# public key:' " + shell_quote(age_key_path))
        age_public_key = trim(split(public_key_line.stdout, ": ")[1])

      PRINT "Generated new age key."
      PRINT "Public key: " + age_public_key
      PRINT ""
      WARN "IMPORTANT: Back up your private key!"
      WARN "Location: " + age_key_path
      WARN "If lost, you will NOT be able to decrypt your secrets."

    age_recipients.append(age_public_key)

    # --- Tier 2: collect additional team member keys ---
    IF tier == "2":
      PRINT ""
      PRINT "Enter additional team member age public keys."
      PRINT "Paste one per line. Enter empty line when done."

      LOOP:
        additional_key := ASK "Public key (or empty to finish):"
        IF additional_key IS EMPTY:
          BREAK

        additional_key = trim(additional_key)

        IF NOT starts_with(additional_key, "age1"):
          WARN "Invalid key (must start with age1). Skipping."
          CONTINUE

        IF NOT regex_match(additional_key, "^age1[a-z0-9]{50,}$"):
          WARN "Key format looks invalid. Skipping."
          CONTINUE

        IF additional_key IN age_recipients:
          WARN "Duplicate key. Skipping."
          CONTINUE

        age_recipients.append(additional_key)
        PRINT "Added. (" + str(len(age_recipients)) + " recipients total)"

      PRINT str(len(age_recipients)) + " age recipient(s) configured."

  # ========================================
  # STEP 5: Set up GCP KMS (Tiers 3, 4)
  # ========================================

  gcp_kms_resource := NULL

  IF tier IN ["3", "4"]:

    IF NOT gcloud_installed:
      ERROR "gcloud CLI is required for GCP KMS tiers."
      PRINT "Install: https://cloud.google.com/sdk/docs/install"
      IF tier == "4":
        PRINT "Falling back to age-only (Tier 1/2) without GCP KMS."
        # Allow continuing with just age for hybrid
      ELSE:
        ABORT

    IF gcloud_installed:
      # --- Collect GCP KMS parameters ---
      project_id := ASK "GCP project ID:"
      IF project_id IS EMPTY:
        # Try to auto-detect from gcloud config
        detect_result := Bash("gcloud config get-value project 2>/dev/null")
        IF detect_result.exit_code == 0 AND trim(detect_result.stdout) IS NOT EMPTY:
          project_id = trim(detect_result.stdout)
          PRINT "Using detected project: " + project_id
        ELSE:
          ERROR "GCP project ID is required."
          ABORT

      location := ASK "KMS location (default: global):"
      IF location IS EMPTY:
        location = "global"

      keyring_name := ASK "KMS keyring name (default: diakon-keyring):"
      IF keyring_name IS EMPTY:
        keyring_name = "diakon-keyring"

      key_name := ASK "KMS key name (default: diakon-secrets-key):"
      IF key_name IS EMPTY:
        key_name = "diakon-secrets-key"

      gcp_kms_resource = (
        "projects/" + project_id
        + "/locations/" + location
        + "/keyRings/" + keyring_name
        + "/cryptoKeys/" + key_name
      )

      # --- Check if keyring exists ---
      PRINT "Checking GCP KMS keyring..."
      check_ring := Bash(
        "gcloud kms keyrings describe " + shell_quote(keyring_name)
        + " --location=" + shell_quote(location)
        + " --project=" + shell_quote(project_id)
        + " 2>&1"
      )

      IF check_ring.exit_code != 0:
        IF contains(check_ring.stdout + check_ring.stderr, "NOT_FOUND"):
          PRINT "Keyring '" + keyring_name + "' does not exist."
          create_ring := ASK "Create it? (Y/n):"
          IF create_ring IS EMPTY OR lower(create_ring) == "y":
            result := Bash(
              "gcloud kms keyrings create " + shell_quote(keyring_name)
              + " --location=" + shell_quote(location)
              + " --project=" + shell_quote(project_id)
            )
            IF result.exit_code != 0:
              ERROR "Failed to create keyring."
              PRINT "stderr: " + result.stderr
              ABORT
            PRINT "Created keyring: " + keyring_name
          ELSE:
            ERROR "Keyring is required. Cannot proceed."
            ABORT
        ELSE:
          ERROR "Failed to check keyring."
          PRINT "Output: " + check_ring.stdout + check_ring.stderr
          ABORT
      ELSE:
        PRINT "Keyring '" + keyring_name + "' exists."

      # --- Check if key exists ---
      PRINT "Checking KMS key..."
      check_key := Bash(
        "gcloud kms keys describe " + shell_quote(key_name)
        + " --keyring=" + shell_quote(keyring_name)
        + " --location=" + shell_quote(location)
        + " --project=" + shell_quote(project_id)
        + " 2>&1"
      )

      IF check_key.exit_code != 0:
        IF contains(check_key.stdout + check_key.stderr, "NOT_FOUND"):
          PRINT "Key '" + key_name + "' does not exist."
          create_key := ASK "Create it? (Y/n):"
          IF create_key IS EMPTY OR lower(create_key) == "y":
            result := Bash(
              "gcloud kms keys create " + shell_quote(key_name)
              + " --keyring=" + shell_quote(keyring_name)
              + " --location=" + shell_quote(location)
              + " --project=" + shell_quote(project_id)
              + " --purpose=encryption"
            )
            IF result.exit_code != 0:
              ERROR "Failed to create KMS key."
              PRINT "stderr: " + result.stderr
              ABORT
            PRINT "Created KMS key: " + key_name
          ELSE:
            ERROR "KMS key is required. Cannot proceed."
            ABORT
        ELSE:
          ERROR "Failed to check KMS key."
          PRINT "Output: " + check_key.stdout + check_key.stderr
          ABORT
      ELSE:
        PRINT "KMS key '" + key_name + "' exists."

      PRINT "GCP KMS resource: " + gcp_kms_resource

  # ========================================
  # STEP 6: Generate .diakon/.sops.yaml
  # ========================================

  PRINT "Creating .diakon/.sops.yaml..."

  # Build the creation rule
  creation_rule := {}
  creation_rule.path_regex = "secrets\\.enc\\.yaml$"

  IF len(age_recipients) > 0:
    creation_rule.age = join(age_recipients, ",")

  IF gcp_kms_resource IS NOT NULL:
    creation_rule.gcp_kms = gcp_kms_resource

  sops_config := {
    "creation_rules": [creation_rule]
  }

  # Write as YAML
  sops_yaml_content := yaml_serialize(sops_config)

  # Add a header comment for human readers
  header := (
    "# Diakon secrets configuration (sops)\n"
    + "# Managed by /dk:init and /dk:secret-add-recipient\n"
    + "# Docs: https://github.com/getsops/sops\n"
    + "#\n"
    + "# Tier: " + CASE tier OF
        "1" -> "Solo (single age key)"
        "2" -> "Team (multiple age keys)"
        "3" -> "Cloud (GCP KMS)"
        "4" -> "Hybrid (GCP KMS + age fallback)"
      END
    + "\n"
  )

  Write(SOPS_CONFIG, header + sops_yaml_content)

  PRINT "Created .diakon/.sops.yaml"

  # ========================================
  # STEP 7: Create initial empty secrets file
  # ========================================

  PRINT "Creating initial encrypted secrets file..."

  # Write empty YAML, then encrypt
  tmp_path := workspace_dir + "/.diakon/secrets.init.tmp.yaml"
  Bash("echo '{}' > " + shell_quote(tmp_path))

  # Set SOPS_AGE_KEY_FILE for the encryption
  encrypt_env := ""
  IF len(age_recipients) > 0:
    encrypt_env = "SOPS_AGE_KEY_FILE=" + shell_quote(expand_path(AGE_KEY_PATH)) + " "

  encrypt_cmd := (
    encrypt_env
    + "sops --encrypt"
    + " --input-type yaml --output-type yaml"
    + " --config " + shell_quote(SOPS_CONFIG)
    + " " + shell_quote(tmp_path)
    + " > " + shell_quote(SECRETS_FILE)
  )

  result := Bash(encrypt_cmd)

  # Clean up temp file immediately
  Bash("rm -f " + shell_quote(tmp_path))

  IF result.exit_code != 0:
    ERROR "Failed to create initial secrets file."
    PRINT "stderr: " + result.stderr
    PRINT ""
    PRINT "Troubleshooting:"
    PRINT "  1. Verify .sops.yaml was created correctly"
    PRINT "  2. Ensure age key exists at: " + AGE_KEY_PATH
    IF gcp_kms_resource IS NOT NULL:
      PRINT "  3. Ensure gcloud auth is configured: gcloud auth application-default login"
    ABORT

  PRINT "Created .diakon/secrets.enc.yaml"

  # ========================================
  # STEP 8: Update workspace.yaml secrets section
  # ========================================

  workspace := yaml_parse(Read(WORKSPACE_FILE))

  workspace.secrets = {
    "backend": CASE tier OF
      "1" -> "sops+age"
      "2" -> "sops+age"
      "3" -> "sops+gcp-kms"
      "4" -> "sops+gcp-kms+age"
    END,
    "tier": int(tier),
    "file": ".diakon/secrets.enc.yaml"
  }

  IF len(age_recipients) > 0:
    workspace.secrets.age_recipients = age_recipients

  IF gcp_kms_resource IS NOT NULL:
    workspace.secrets.gcp_kms_resources = [gcp_kms_resource]

  Write(WORKSPACE_FILE, yaml_serialize(workspace))

  # ========================================
  # STEP 9: Update .diakon/.gitignore
  # ========================================

  gitignore_path := workspace_dir + "/.diakon/.gitignore"

  gitignore_entries := [
    "# Private keys — NEVER commit these",
    "*.key",
    "*.age-key",
    "keys.txt",
    "",
    "# Temp files from secret operations",
    "*.tmp.yaml",
    "*.remove-tmp.yaml",
    "",
    "# Decrypted secrets (safety net)",
    "secrets.yaml",
    "secrets.decrypted.yaml",
    "secrets.plaintext.yaml"
  ]

  IF file_exists(gitignore_path):
    existing := Read(gitignore_path)
    # Append only entries that aren't already present
    FOR entry IN gitignore_entries:
      IF NOT contains(existing, entry) AND entry IS NOT EMPTY:
        append_to_file(gitignore_path, entry)
  ELSE:
    Write(gitignore_path, join(gitignore_entries, "\n") + "\n")

  # ========================================
  # STEP 10: Round-trip verification test
  # ========================================

  PRINT ""
  PRINT "Running round-trip verification..."

  test_key := "_DIAKON_INIT_TEST"
  test_value := "diakon-init-" + random_hex(8)

  # Set test secret
  set_cmd := (
    encrypt_env
    + "sops --set '[\"" + test_key + "\"] \"" + test_value + "\"'"
    + " " + shell_quote(SECRETS_FILE)
  )

  result := Bash(set_cmd)
  IF result.exit_code != 0:
    WARN "Round-trip test: SET failed."
    PRINT "stderr: " + result.stderr
    PRINT "Secrets infrastructure was created but may not work correctly."
    PRINT "Try: /dk:secret-set TEST_KEY test-value"
    RETURN PARTIAL

  # Get test secret
  get_cmd := (
    encrypt_env
    + "sops --decrypt --extract '[\"" + test_key + "\"]'"
    + " " + shell_quote(SECRETS_FILE)
  )

  result := Bash(get_cmd)
  IF result.exit_code != 0:
    WARN "Round-trip test: GET failed."
    PRINT "stderr: " + result.stderr
    RETURN PARTIAL

  retrieved_value := trim(result.stdout)
  IF retrieved_value != test_value:
    WARN "Round-trip test: Value mismatch!"
    PRINT "Expected: (hidden)"
    PRINT "Got:      (hidden)"
    PRINT "Lengths:  " + str(len(test_value)) + " vs " + str(len(retrieved_value))
    RETURN PARTIAL

  # Delete test secret (decrypt, remove key, re-encrypt)
  # Use the full remove flow to clean up
  tmp_file := workspace_dir + "/.diakon/secrets.test-cleanup.tmp.yaml"

  Bash(encrypt_env + "sops --decrypt " + shell_quote(SECRETS_FILE) + " > " + shell_quote(tmp_file))

  yq_available := (Bash("command -v yq").exit_code == 0)
  IF yq_available:
    Bash("yq eval 'del(." + test_key + ")' -i " + shell_quote(tmp_file))
  ELSE:
    Bash("sed -i '' '/^" + test_key + ":/d' " + shell_quote(tmp_file))

  Bash(
    encrypt_env
    + "sops --encrypt --input-type yaml --output-type yaml"
    + " --config " + shell_quote(SOPS_CONFIG)
    + " " + shell_quote(tmp_file)
    + " > " + shell_quote(SECRETS_FILE + ".new")
  )

  Bash("mv " + shell_quote(SECRETS_FILE + ".new") + " " + shell_quote(SECRETS_FILE))
  Bash("rm -f " + shell_quote(tmp_file))

  PRINT "Round-trip test passed."

  # ========================================
  # STEP 11: Summary
  # ========================================

  PRINT ""
  PRINT "=== Secrets Infrastructure Ready ==="
  PRINT ""
  PRINT "  Tier:       " + tier + " (" + CASE tier OF
    "1" -> "Solo"
    "2" -> "Team"
    "3" -> "Cloud"
    "4" -> "Hybrid"
  END + ")"

  PRINT "  Config:     " + SOPS_CONFIG
  PRINT "  Secrets:    " + SECRETS_FILE
  PRINT "  Recipients: " + str(len(age_recipients) + (1 IF gcp_kms_resource ELSE 0))

  IF len(age_recipients) > 0:
    PRINT ""
    PRINT "  Age recipients:"
    FOR i, key IN enumerate(age_recipients):
      label := "(you)" IF i == 0 ELSE "(team member " + str(i) + ")"
      PRINT "    " + str(i+1) + ". " + key[:20] + "..." + key[-8:] + "  " + label

  IF gcp_kms_resource IS NOT NULL:
    PRINT ""
    PRINT "  GCP KMS:"
    PRINT "    " + gcp_kms_resource

  PRINT ""
  PRINT "  Commands:"
  PRINT "    /dk:secret-set <KEY> <VALUE>   — store a secret"
  PRINT "    /dk:secret-get <KEY>           — retrieve a secret"
  PRINT "    /dk:secret-list                — list all keys"
  PRINT "    /dk:secret-add-recipient <KEY> — add a team member"
  PRINT ""

  # ========================================
  # SECURITY NOTES
  # ========================================
  # - The age private key at AGE_KEY_PATH is never displayed, only the public key.
  # - The test value is random and immediately deleted.
  # - The .gitignore protections guard against accidental commits of:
  #     - Private key files
  #     - Temporary decrypted files
  #     - Files that look like plaintext secrets
  # - For Tier 2 (Team): team members must share their public keys out-of-band
  #   (Slack, email, etc.). Private keys are NEVER shared.
  # - For Tier 3/4 (GCP): access is governed by IAM. No key files to manage
  #   on the GCP side, but the age fallback key still needs safeguarding.

  RETURN OK
END PROCEDURE
```

### Example Output (Tier 1 — Solo)

```
Found existing age key at /Users/ernie/.config/sops/age/keys.txt
Your public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

Creating .diakon/.sops.yaml...
Created .diakon/.sops.yaml
Creating initial encrypted secrets file...
Created .diakon/secrets.enc.yaml

Running round-trip verification...
Round-trip test passed.

=== Secrets Infrastructure Ready ===

  Tier:       1 (Solo)
  Config:     .diakon/.sops.yaml
  Secrets:    .diakon/secrets.enc.yaml
  Recipients: 1

  Age recipients:
    1. age1ql3z7hjy54pw3h...mcac8p  (you)

  Commands:
    /dk:secret-set <KEY> <VALUE>   — store a secret
    /dk:secret-get <KEY>           — retrieve a secret
    /dk:secret-list                — list all keys
    /dk:secret-add-recipient <KEY> — add a team member
```

### Example Output (Tier 4 — Hybrid)

```
Found existing age key at /Users/ernie/.config/sops/age/keys.txt
Your public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p

GCP project ID: my-project-123
KMS location (default: global): us-east1
KMS keyring name (default: diakon-keyring): diakon-keyring
KMS key name (default: diakon-secrets-key): diakon-secrets-key

Checking GCP KMS keyring...
Keyring 'diakon-keyring' exists.
Checking KMS key...
Key 'diakon-secrets-key' does not exist.
Create it? (Y/n): Y
Created KMS key: diakon-secrets-key
GCP KMS resource: projects/my-project-123/locations/us-east1/keyRings/diakon-keyring/cryptoKeys/diakon-secrets-key

Creating .diakon/.sops.yaml...
Created .diakon/.sops.yaml
Creating initial encrypted secrets file...
Created .diakon/secrets.enc.yaml

Running round-trip verification...
Round-trip test passed.

=== Secrets Infrastructure Ready ===

  Tier:       4 (Hybrid)
  Config:     .diakon/.sops.yaml
  Secrets:    .diakon/secrets.enc.yaml
  Recipients: 2

  Age recipients:
    1. age1ql3z7hjy54pw3h...mcac8p  (you)

  GCP KMS:
    projects/my-project-123/locations/us-east1/keyRings/diakon-keyring/cryptoKeys/diakon-secrets-key

  Commands:
    /dk:secret-set <KEY> <VALUE>   — store a secret
    /dk:secret-get <KEY>           — retrieve a secret
    /dk:secret-list                — list all keys
    /dk:secret-add-recipient <KEY> — add a team member
```

---

## Generated .sops.yaml Examples

### Tier 1 (Solo)

```yaml
# Diakon secrets configuration (sops)
# Managed by /dk:init and /dk:secret-add-recipient
# Docs: https://github.com/getsops/sops
#
# Tier: Solo (single age key)
creation_rules:
  - path_regex: secrets\.enc\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

### Tier 2 (Team)

```yaml
# Diakon secrets configuration (sops)
# Managed by /dk:init and /dk:secret-add-recipient
# Docs: https://github.com/getsops/sops
#
# Tier: Team (multiple age keys)
creation_rules:
  - path_regex: secrets\.enc\.yaml$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p,
      age1an7ecvtaxx07gywnrjkphn30uf9hxy8fnr7ep40cyk4gxj0zt8eqf7jfmg,
      age1m9pwgq0fkkr4uyksf5xjzg3dvrf9jlhcf7rw4qxhses8tapxvjqqsak7wy
```

### Tier 3 (Cloud)

```yaml
# Diakon secrets configuration (sops)
# Managed by /dk:init and /dk:secret-add-recipient
# Docs: https://github.com/getsops/sops
#
# Tier: Cloud (GCP KMS)
creation_rules:
  - path_regex: secrets\.enc\.yaml$
    gcp_kms: projects/my-project/locations/global/keyRings/diakon-keyring/cryptoKeys/diakon-secrets-key
```

### Tier 4 (Hybrid)

```yaml
# Diakon secrets configuration (sops)
# Managed by /dk:init and /dk:secret-add-recipient
# Docs: https://github.com/getsops/sops
#
# Tier: Hybrid (GCP KMS + age fallback)
creation_rules:
  - path_regex: secrets\.enc\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
    gcp_kms: projects/my-project/locations/us-east1/keyRings/diakon-keyring/cryptoKeys/diakon-secrets-key
```

---

## Error Catalog

Comprehensive reference of all error conditions across secrets skills.

| Error | Skill(s) | Cause | Recovery |
|-------|----------|-------|----------|
| `sops not found` | All | sops not installed | `brew install sops` |
| `age not found` | init | age not installed | `brew install age` |
| `gcloud not found` | add-recipient, init (tier 3/4) | gcloud not installed | Install Google Cloud SDK |
| `.sops.yaml not found` | set, get, add-recipient | Not initialized | Run `/dk:init` |
| `secrets.enc.yaml not found` | get, list, remove | No secrets yet | Run `/dk:secret-set` |
| `could not decrypt` | set, get, remove | Private key mismatch | Verify key at `~/.config/sops/age/keys.txt` |
| `no matching creation rule` | set | .sops.yaml path_regex mismatch | Fix path_regex in .sops.yaml |
| `permission denied` | set, get | File permissions | `chmod 600` on key file |
| `Mac mismatch` | set, get | File corrupted | `git checkout -- secrets.enc.yaml` |
| `PERMISSION_DENIED` (GCP) | get, add-recipient | IAM missing | Grant `cloudkms.cryptoKeyEncrypterDecrypter` |
| `NOT_FOUND` (GCP) | add-recipient, init | KMS key/ring missing | Create with `gcloud kms keys create` |
| `Key 'sops' is reserved` | set, remove | User tried to use reserved name | Choose different key name |
| `Invalid key format` | set, remove | Special characters in key | Use alphanumeric, underscore, hyphen, dot |
| `Key not found` | get, remove | Typo or key was removed | Run `/dk:secret-list` |
| `Value mismatch (round-trip)` | init | Encryption/decryption inconsistency | Reinstall sops, check age version |

---

## Security Model Summary

### What is safe to display

- Secret key names (always plaintext in sops YAML)
- Age public keys (designed to be shared)
- GCP KMS resource IDs (not sensitive)
- Recipient counts
- Backend tier information
- Encrypted ciphertext (opaque, useless without keys)

### What is NEVER displayed

- Age private keys (at ~/.config/sops/age/keys.txt)
- Decrypted secret values (except in /dk:secret-get, with warning)
- The VALUE argument to /dk:secret-set (only key name is confirmed)
- GCP service account credentials

### What is NEVER committed to git

- `*.key`, `*.age-key`, `keys.txt` (via .gitignore)
- Temporary decrypted files (`*.tmp.yaml`)
- Files named `secrets.yaml` or `secrets.decrypted.yaml` (safety net)

### Threat model notes

- **Stolen laptop**: Full-disk encryption (FileVault/LUKS) is the first defense. Age keys at rest are protected by filesystem permissions (600). If disk encryption is absent, the age private key is accessible to anyone with physical access.
- **Compromised git repo**: Only encrypted values and public keys are in git. Attacker gets key names but not values. Useless without a matching private key or KMS access.
- **Leaked age private key**: Rotate immediately. Generate new key, update .sops.yaml recipients, run `sops updatekeys`. Remove the old public key from recipients. Rotate all secret values.
- **Lost age private key**: If solo (Tier 1), secrets are unrecoverable. For team (Tier 2), another team member can decrypt and re-encrypt for a new key. For hybrid (Tier 4), GCP KMS can still decrypt.
- **GCP IAM misconfiguration**: Principle of least privilege. Grant `roles/cloudkms.cryptoKeyEncrypterDecrypter` only to specific service accounts and users, not broad groups.
