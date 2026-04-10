# Diakon Security Audit Report

**Date**: 2026-04-09
**Scope**: Pre-implementation review of pseudocode and design documents
**Auditor**: security-reviewer (Claude Code)
**Status**: Pre-implementation -- findings against design docs and pseudocode

---

## Executive Summary

Diakon is a Claude Code plugin that orchestrates multi-project workspaces with encrypted secrets management via sops+age. The design is fundamentally sound -- sops+age is a well-regarded encryption stack, key names vs. values separation is correct, and the tiered architecture is reasonable.

However, the audit identified **3 CRITICAL**, **5 HIGH**, **6 MEDIUM**, and **4 LOW** findings. The critical findings center on: (1) secret values leaking into process argument lists visible via /proc, (2) plaintext secrets written to disk in a non-tmpfs location without secure erasure, and (3) command injection via the yq/sed fallback path in secret-remove. These must be resolved before implementation ships.

---

## CRITICAL Findings

### C-1: Secret Values Exposed via /proc/cmdline in sops --set

**File**: docs/pseudocode/03-secrets-management.md, lines 322-328
**Confidence**: 0.92

**Attack path**: The sops --set command embeds the plaintext secret value directly in the process argument list. On Linux, any user on the system can read /proc/pid/cmdline for any process. On macOS, ps aux shows full argument lists. The sops process lifetime is non-trivial (it decrypts the file, modifies it, re-encrypts) -- giving an attacker a meaningful window to scrape the value.

The pseudocode itself acknowledges this risk in a security note (lines 397-400) but does not mitigate it.

**Impact**: Any local user or process monitor (malware, monitoring agent, shell history logger) can capture plaintext secret values.

**Remediation**: Replace sops --set with a decrypt-edit-encrypt pipeline that passes values via environment variables, never command-line arguments:

    # Decrypt -> pipe through yq with env var -> re-encrypt
    export __DK_VAL=""
    SOPS_AGE_KEY_FILE=... sops --decrypt secrets.enc.yaml       | yq eval '.KEY = env(__DK_VAL)' -       | SOPS_AGE_KEY_FILE=... sops --encrypt --input-type yaml           --output-type yaml /dev/stdin > secrets.enc.yaml.new       && mv secrets.enc.yaml.new secrets.enc.yaml
    unset __DK_VAL

Document that yq becomes a required dependency for secret-set.

---

### C-2: Plaintext Secrets Written to Workspace Directory on Disk

**File**: docs/pseudocode/03-secrets-management.md, lines 1159-1221 (secret-remove), lines 1736-1755 (init round-trip test)
**Confidence**: 0.90

**Attack path**: The dk:secret-remove skill decrypts the entire secrets file to .diakon/secrets.remove-tmp.yaml -- a plaintext file containing ALL secret values, written to the project workspace directory on a persistent filesystem. The same pattern occurs during init round-trip cleanup.

Problems:
1. If the process crashes, is killed (SIGKILL), or the machine loses power between decrypt and cleanup, the plaintext file persists on disk.
2. Even after rm -f, the data remains on the physical disk until overwritten. SSDs with wear-leveling make this worse.
3. The file is in the workspace directory, which is likely under git. A careless git add -f could commit it despite .gitignore.
4. Filesystem snapshots (Time Machine, ZFS snapshots) may capture the plaintext file.

**Impact**: Full plaintext exposure of all secrets in the file. The window of vulnerability is the entire decrypt-edit-encrypt cycle.

**Remediation**:
1. Use a tmpfs/ramfs mount for temporary decrypted files (macOS: RAM disk via hdiutil; Linux: /dev/shm).
2. Use a trap to guarantee cleanup on any exit: trap cleanup EXIT INT TERM.
3. If tmpfs is not available, overwrite file contents before deletion with random data.
4. Consider using sops exec-file which handles temp file lifecycle internally.

---

### C-3: Command Injection in secret-remove via sed/yq Key Interpolation

**File**: docs/pseudocode/03-secrets-management.md, lines 1182-1197
**Confidence**: 0.85

**Attack path**: The secret-remove skill constructs shell commands by interpolating the key variable directly into yq and sed commands. While sanitize_sops_key restricts keys to alphanumeric plus dots/hyphens/underscores, dots are meaningful in yq path expressions. A key like foo.bar would be interpreted by yq as a nested path del(.foo.bar) rather than del(.["foo.bar"]).

The sed fallback uses the key as a regex pattern where dots match any character. If the key validation were ever loosened, this becomes a direct injection vector.

**Impact**: Today -- semantic bugs with dot-containing keys. If validation loosened -- arbitrary command injection.

**Remediation**:
1. For yq: use bracket notation for all keys.
2. For sed: escape regex metacharacters, or make yq a hard dependency.
3. Consider removing dots from the allowed key character set.

---

## HIGH Findings

### H-1: /dk:run Executes Arbitrary Commands with No Guardrails

**File**: docs/pseudocode/02-git-operations.md, lines 135-156
**Confidence**: 0.85

**Description**: /dk:run passes user-provided commands directly to Bash across all workspace projects. While intentional, there are no guardrails:
1. Any agent that can invoke skills can execute arbitrary shell commands.
2. No programmatic enforcement against interpolating project metadata into commands.
3. Path quoting is an implementation assumption, not a guarantee.

**Impact**: Arbitrary code execution. A compromised agent could silently execute destructive commands.

**Remediation**:
1. Add confirmation prompt for destructive-looking commands (rm, chmod, curl|sh, eval).
2. Log all executed commands to .diakon/run.log (command and timestamp, not output).
3. Enforce shell_quote() on path interpolation with security-critical code comments.

---

### H-2: Decrypted Secret Values Enter Claude Context Window Permanently

**File**: docs/pseudocode/03-secrets-management.md, lines 536-557
**Confidence**: 0.80

**Description**: /dk:secret-get decrypts a secret and prints it as KEY = VALUE. Once in Claude context:
1. Persists for the entire conversation with no redaction mechanism.
2. May be logged or sent to Anthropic servers depending on data retention.
3. Claude might inadvertently include the value in generated code or commits.
4. Bash tool output is captured in the conversation transcript.

**Impact**: Secret values persist in an uncontrolled data store with no TTL or encryption.

**Remediation**:
1. Write decrypted value to a temporary file instead of printing into context.
2. If displayed, show only first/last N characters with middle redacted.
3. Document as a known architectural limitation.

---

### H-3: Missing Path Traversal Validation in Project Operations

**File**: docs/pseudocode/05-shell-helpers.md, lines 57-61; scripts/dk-helpers.sh, lines 95-121
**Confidence**: 0.82

**Description**: The design doc explicitly calls out path traversal risk and provides a remediation, but dk-helpers.sh does NOT implement it. dk_project_abs_path returns whatever is in workspace.yaml with no validation.

**Impact**: If an attacker can modify workspace.yaml, they can cause skills to operate on arbitrary directories.

**Remediation**: Implement the check the design doc already describes -- validate resolved path starts with workspace root using realpath.

---

### H-4: sanitize_sops_value Fallback Escaping is Incomplete

**File**: docs/pseudocode/03-secrets-management.md, lines 196-212
**Confidence**: 0.78

**Description**: When jq is unavailable, the fallback manual escaping misses carriage return, null bytes, and Unicode control characters. The interaction between shell_quote() and the produced JSON string is fragile.

**Impact**: Data corruption or shell injection through secret values containing control characters.

**Remediation**: Make jq a hard prerequisite for dk:secret-set. If the fallback must exist, expand it per RFC 8259.

---

### H-5: age Key File Permissions Not Verified on Existing Keys

**File**: docs/pseudocode/03-secrets-management.md, lines 1340-1360
**Confidence**: 0.75

**Description**: During init, existing age keys are reused without checking permissions. Only newly generated keys get chmod 600. An existing key with world-readable permissions would be silently accepted.

**Impact**: Private age key may be readable by other system users.

**Remediation**: Always verify and fix permissions on the key file during init.

---

## MEDIUM Findings

### M-1: .gitignore Does Not Cover All Temporary File Patterns

**File**: docs/pseudocode/03-secrets-management.md, lines 1662-1676; root .gitignore
**Confidence**: 0.75

**Description**: The encrypt step creates secrets.enc.yaml.new which is NOT covered by gitignore. The root .gitignore lacks keys.txt.

**Remediation**: Add secrets.enc.yaml.new to .diakon/.gitignore. Add keys.txt to root .gitignore.

---

### M-2: awk Pattern Matching Uses String Concatenation for Project Names

**File**: scripts/dk-helpers.sh, lines 101-111
**Confidence**: 0.72

**Description**: dk_project_path uses awk regex matching with the project name variable. Regex metacharacters in names could match wrong projects.

**Remediation**: Add name validation in dk_project_path. Use awk string comparison instead of regex.

---

### M-3: Error Messages May Leak Partial Secrets from sops stderr

**File**: docs/pseudocode/03-secrets-management.md, lines 365-366
**Confidence**: 0.68

**Description**: Multiple error paths print raw sops stderr which could contain fragments of decrypted data. This output enters Claude context.

**Remediation**: Sanitize sops stderr before displaying. Truncate to 500 characters.

---

### M-4: No Audit Logging for Secret Operations

**File**: docs/pseudocode/03-secrets-management.md (entire file)
**Confidence**: 0.70

**Description**: No secret operations produce an audit log, making investigation of leaks impossible for team tiers.

**Remediation**: Write append-only audit log to .diakon/secrets.audit.log with operation type, key name, timestamp, and username. Never log values.

---

### M-5: GCP KMS Parameters Not Validated for Naming Constraints

**File**: docs/pseudocode/03-secrets-management.md, lines 1445-1470
**Confidence**: 0.68

**Description**: User-provided GCP parameters are not validated against GCP naming patterns before constructing the resource ID.

**Remediation**: Validate against actual GCP naming constraints before use.

---

### M-6: assert_secrets_file Creates Plaintext Temp File in Workspace

**File**: docs/pseudocode/03-secrets-management.md, lines 97-118
**Confidence**: 0.72

**Description**: Writes empty YAML to a plaintext temp file before encrypting. While no secrets are exposed, the pattern encourages plaintext-on-disk.

**Remediation**: Use stdin: echo {} | sops --encrypt --input-type yaml --output-type yaml /dev/stdin > secrets.enc.yaml

---

## LOW Findings

### L-1: Root .gitignore Missing keys.txt Pattern

**File**: .gitignore
**Confidence**: 0.65

**Description**: Root .gitignore has *.key and *.age-key but not keys.txt.

**Remediation**: Add keys.txt and **/keys.txt to root .gitignore.

---

### L-2: shell_quote Implementation Not Specified

**File**: docs/pseudocode/03-secrets-management.md (referenced throughout)
**Confidence**: 0.60

**Description**: shell_quote() is used extensively but never defined. Incorrect implementation makes every interpolation an injection vector.

**Remediation**: Document canonical implementation (printf %q) and add unit tests for edge cases.

---

### L-3: No Key Rotation Guidance for GCP KMS

**File**: docs/pseudocode/03-secrets-management.md, wiki/04-secrets-model.md
**Confidence**: 0.60

**Description**: GCP KMS setup creates keys with default rotation (none). No guidance on enabling automatic rotation.

**Remediation**: Add rotation guidance to init output and wiki documentation.

---

### L-4: Test Secret Value in Init Round-Trip is Predictable

**File**: docs/pseudocode/03-secrets-management.md, lines 1696-1700
**Confidence**: 0.55

**Description**: Round-trip test key _DIAKON_INIT_TEST is predictable. Value is random and immediately deleted. Negligible risk.

**Remediation**: Ensure test key is removed before any git operations.

---

## Residual Risks

1. **Claude context as a secret store**: Any secret retrieved via /dk:secret-get enters an AI model context window. Data retention is outside Diakon control.

2. **age key as single point of failure (Tier 1)**: Solo users have one key. Loss means unrecoverable secrets. Inherent to the age model.

3. **workspace.yaml as trust boundary**: All project paths and metadata come from this file. A malicious PR modifying it influences command execution targets.

4. **sops process memory**: During encryption/decryption, plaintext values exist in process memory. Unavoidable with any encryption tool.

---

## Testing Gaps

1. **Shell quoting integration tests**: Create workspace.yaml entries with paths containing spaces, quotes, shell metacharacters.

2. **Crash recovery for secret-remove**: Kill the process at each step of decrypt-edit-encrypt. Verify no plaintext remains.

3. **Key validation edge cases**: Test sanitize_sops_key with empty string, sops, dot-containing strings, max length, unicode, strings starting with dash.

4. **Concurrent access**: Two sessions running /dk:secret-set simultaneously could corrupt secrets.enc.yaml.

5. **Large secret values**: Test with values over 1MB, all 256 byte values, multi-line values, YAML special characters.

6. **gitignore effectiveness**: Run git add -A in a test workspace and verify no sensitive files are staged.

---

## Summary Table

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| C-1 | CRITICAL | Secret values in process cmdline via sops --set | Must fix |
| C-2 | CRITICAL | Plaintext secrets on persistent disk in workspace dir | Must fix |
| C-3 | CRITICAL | Command injection via sed/yq key interpolation | Must fix |
| H-1 | HIGH | /dk:run arbitrary command execution without guardrails | Should fix |
| H-2 | HIGH | Decrypted secrets persist in Claude context window | Should fix |
| H-3 | HIGH | Missing path traversal validation (designed but not implemented) | Should fix |
| H-4 | HIGH | Incomplete fallback escaping in sanitize_sops_value | Should fix |
| H-5 | HIGH | age key file permissions not verified on existing keys | Should fix |
| M-1 | MEDIUM | gitignore gaps for .new temp files and root keys.txt | Fix during impl |
| M-2 | MEDIUM | awk regex matching on unvalidated project names | Fix during impl |
| M-3 | MEDIUM | Error messages may leak partial secrets via sops stderr | Fix during impl |
| M-4 | MEDIUM | No audit logging for secret operations | Fix during impl |
| M-5 | MEDIUM | GCP KMS parameters not validated for naming constraints | Fix during impl |
| M-6 | MEDIUM | Plaintext temp file pattern in assert_secrets_file | Fix during impl |
| L-1 | LOW | Root .gitignore missing keys.txt | Document |
| L-2 | LOW | shell_quote implementation not specified | Document |
| L-3 | LOW | No GCP KMS key rotation guidance | Document |
| L-4 | LOW | Predictable test secret key name in init | Accept |
