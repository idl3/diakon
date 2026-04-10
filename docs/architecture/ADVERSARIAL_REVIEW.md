# Adversarial Review — Diakon

**Date**: 2026-04-09
**Reviewer**: adversarial
**Depth**: Deep (200+ lines of specification, strong risk signals: encryption, secrets management, shell execution, YAML parsing with awk)
**Scope**: All pseudocode (01-05), dk-helpers.sh, architecture wiki, PLAN.md

---

## MUST FIX

Issues that WILL cause failures in normal usage.

---

### MF-1: awk project-name matching uses regex, not literal string — substring collision

**Severity**: CRITICAL
**Confidence**: 0.95

**The problem**: In `dk-helpers.sh`, `dk_project_path` (line 101) and `dk_project_field` (line 133) match project names with:

```awk
$0 ~ "^  "name":"
```

This is a **regex match**, not a literal string comparison. If workspace.yaml contains projects named `api` and `api-gateway`, then looking up `api` will match `api-gateway:` first (if it appears first in the file), because `api` is a substring that regex-matches `api-gateway`.

**Reproduction**:
```yaml
projects:
  api-gateway:
    path: "./api-gateway"
  api:
    path: "./api"
```

`dk_project_path api` returns `./api-gateway` instead of `./api`.

Worse: a project named `a.b` would match `a<any-char>b` because `.` is a regex metacharacter. A project named `test+` would cause an awk regex compilation error.

**Impact**: Every skill that resolves a project path gets the wrong project. Git operations run against the wrong repo. The user has no indication this happened.

**Fix**: Use exact string comparison in awk instead of regex:

```awk
# Instead of: $0 ~ "^  "name":"
# Use:
substr($0, 1, 2 + length(name) + 1) == "  " name ":"
```

Or anchor the regex with `:` and word boundary:

```awk
$0 == "  " name ":"  # Exact line match (if no trailing content)
```

---

### MF-2: dk_project_field awk has dead code — field extraction is broken

**Severity**: CRITICAL
**Confidence**: 0.92

**The problem**: In `dk-helpers.sh` line 133-146, `dk_project_field` contains this awk:

```awk
found && $0 ~ field":" {
  gsub(/.*"field": *"?/, "")    # ← literal string "field", not the variable
  sub(/^[^:]+: *"?/, "")
  gsub(/".*/, "")
  gsub(/ *$/, "")
  print
  exit
}
```

The first `gsub` uses the literal string `"field"` in the regex, not the awk variable `field`. This line never matches anything useful (unless the YAML literally contains the word `field`). The actual extraction falls through to the second `sub`, which works for simple cases — but the dead first line indicates the logic was not tested.

Furthermore, if the field name itself contains regex metacharacters (unlikely for known fields like `enabled`, `path`, `type` — but `dk_project_field` is a generic accessor), the `$0 ~ field":"` match will misfire.

**Impact**: Currently masked because the fallback `sub` handles simple cases. But if anyone modifies this function trusting the first `gsub` does something, they will introduce a regression. The function is fragile.

**Fix**: Remove the dead `gsub` line. Use `field` as an awk variable with `-v`, and use `index()` for literal matching instead of `~` regex.

---

### MF-3: /dk:secret-remove writes plaintext to disk with no crash protection

**Severity**: HIGH
**Confidence**: 0.90

**The problem**: The `secret-remove` workflow (03-secrets-management.md, lines 1159-1218) follows this sequence:

1. Decrypt entire secrets file to `.diakon/secrets.remove-tmp.yaml` (plaintext on disk)
2. Remove the key with yq or sed
3. Re-encrypt to `secrets.enc.yaml.new`
4. `mv` the new file over the original
5. `rm` the temp file

If the process is interrupted between step 1 and step 5 (Claude session timeout, Ctrl+C, terminal close, machine crash), the **plaintext secrets file remains on disk** at a predictable path. The `.diakon/.gitignore` does list `*.remove-tmp.yaml`, which prevents accidental git commits, but the file persists on the filesystem.

The same pattern exists in the init round-trip test (line 1736-1755) with `secrets.test-cleanup.tmp.yaml`.

**Scenario**: User runs `/dk:secret-remove API_KEY`. Claude's 2-minute bash timeout fires after decryption but before cleanup. Plaintext file with ALL secrets sits in the working directory until someone notices.

**Impact**: All secrets exposed in plaintext on the filesystem. On shared machines or unencrypted disks, this is a data breach.

**Fix**:
- Use a trap to clean up temp files on any exit: `trap 'rm -f "$tmp_file"' EXIT`
- Or use `mktemp` in `/tmp` (backed by tmpfs on Linux, in-memory) instead of the workspace directory
- Or use `sops exec-file` which handles the temp file lifecycle internally
- At minimum, the skill should check for and delete stale temp files at the START of execution

---

### MF-4: /dk:add has no file locking — concurrent adds create duplicate or corrupted YAML

**Severity**: HIGH
**Confidence**: 0.85

**The problem**: `/dk:add` (01-core-skills.md, line 154) does:
1. Read workspace.yaml
2. Check if project already registered
3. Append project block

If two Claude sessions (or the same user in two terminals) run `/dk:add` concurrently for different projects, both read the file at step 1, both see no conflict at step 2, and both write at step 3. The second write either overwrites the first addition entirely (if using Write to replace the file) or creates malformed YAML (if using append).

If the **same** project is added twice concurrently, both pass the duplicate check and both append — creating a duplicate key in YAML, which is **undefined behavior** per the YAML spec (last wins in most parsers, but awk will match the first).

**Scenario**: User opens two Claude sessions. Session A runs `/dk:add ./frontend`. Session B runs `/dk:add ./backend`. Both read workspace.yaml simultaneously. Both append. One project's entry is lost.

**Impact**: Silent data loss in the workspace registry.

**Fix**: Use a lockfile pattern (`flock` on Linux, though macOS needs `shlock` or `mkdir`-based locks). Or accept that concurrent skill execution is unsupported and document it prominently.

---

### MF-5: /dk:init in home directory creates .diakon/ in $HOME with every subdirectory as a "project"

**Severity**: HIGH
**Confidence**: 0.93

**The problem**: `/dk:init` (01-core-skills.md, step 4) scans top-level directories for `package.json` or `.git` when no workspace type is detected:

```
ELSE:
  Scan top-level dirs for package.json or .git
```

If the user runs `/dk:init` in `~` (their home directory), every git repo and Node project in their home becomes a registered project. Subsequent `/dk:pull` would attempt to pull dozens or hundreds of repos. `/dk:run` would execute commands across all of them.

There is no guard checking whether the workspace root is a "reasonable" directory. The home directory, `/`, `/tmp`, or `/Users` would all be accepted.

**Scenario**: User is in `~` and types `/dk:init my-workspace`. Diakon creates `~/.diakon/workspace.yaml` listing 47 projects. User runs `/dk:status` — Claude attempts 47 parallel git commands, consuming the entire context window with output.

**Impact**: Unusable workspace state, potential context window exhaustion, unintended git operations on unrelated repos.

**Fix**: Add a guard: refuse to init if the workspace root is `$HOME`, `/`, or any directory containing more than N (e.g., 20) top-level subdirectories. Or require explicit confirmation for large discoveries: "Found 47 potential projects. This seems like a lot. Continue?"

---

## SHOULD FIX

Issues that will cause problems for a meaningful subset of users.

---

### SF-1: sops --set passes secret values on the command line — visible in process list

**Severity**: HIGH
**Confidence**: 0.88

**The problem**: The pseudocode for `/dk:secret-set` (03-secrets-management.md, line 322-328) constructs:

```
sops --set '["KEY"] "the-actual-secret-value"' .diakon/secrets.enc.yaml
```

The secret value is a command-line argument. On Linux, any user on the system can read `/proc/<pid>/cmdline` for any process. On macOS, `ps aux` shows command arguments. The pseudocode acknowledges this (line 397-399) but only as a comment, not as a mitigation.

For multi-user development machines, CI environments, or containers with shared PID namespaces, the secret is briefly visible to other processes.

**Impact**: Secrets exposed in process list for the duration of the sops command (~100ms to ~2s).

**Fix**: Use environment variable or stdin-based approaches. For sops, the `--set` flag does not support stdin, but you can: decrypt to temp, modify, re-encrypt — same pattern as `secret-remove` but with the value injected via a file, not a command arg. Or use `SOPS_AGE_KEY_FILE=... sops exec-env file.enc.yaml 'env'` patterns.

---

### SF-2: dk_enabled_projects awk misses the last project if file has no trailing newline or section

**Severity**: MEDIUM
**Confidence**: 0.82

**The problem**: In `dk-helpers.sh`, `dk_enabled_projects` (line 64-89) prints the current project name at the `END` block. But the awk logic for detecting "next project starts" relies on seeing `^  [a-zA-Z]` to trigger printing the previous project. If the `projects:` section is the **last** section in workspace.yaml (no `secrets:` or other top-level key after it), the last project is only printed by the `END` block.

However, the `exit` condition is:

```awk
in_projects && /^[a-z]/ { exit }
```

If `secrets:` exists, this triggers an exit — and the `END` block runs, printing the last project. But if `secrets:` does NOT exist (e.g., secrets not configured), and the file ends after the last project block, then the `END` block handles it correctly.

The real issue: if there's a **blank line** or **comment** between the last project and the `secrets:` key, the awk exit condition `^[a-z]` won't fire on the blank/comment line, and the state machine continues scanning into the `secrets:` block. Lines like `backend: "sops+age"` have 2-space indent and would not match `^  [a-zA-Z]` (they match `^  [a-z]` — wait, they would). So `backend` would be detected as a project name.

**Reproduction**:
```yaml
projects:
  aether:
    path: "./aether"
    enabled: true

secrets:
  backend: "sops+age"
```

The blank line between `aether` block and `secrets:` does not trigger `^[a-z]` (it's empty). Then `secrets:` triggers `^[a-z]` and the awk exits. But `backend:` has 2-space indent — it would NOT be reached because `secrets:` already triggered exit.

Actually, the more dangerous case: if the projects section is followed by a top-level key that starts with uppercase or underscore, `^[a-z]` would not match it, and parsing would continue into that section.

**Impact**: Ghost project entries or missed projects when workspace.yaml has non-standard structure.

**Fix**: Change the exit condition to `^[^ ]` (any line starting with a non-space character) or `^[a-zA-Z_]` to catch all top-level keys.

---

### SF-3: /dk:secret-add-recipient updates .sops.yaml but does NOT rollback on updatekeys failure

**Severity**: HIGH
**Confidence**: 0.90

**The problem**: In `dk:secret-add-recipient` (03-secrets-management.md, lines 854-999), the workflow is:

1. Write updated .sops.yaml with new recipient
2. Run `sops updatekeys` to re-encrypt

If step 2 fails (network error for GCP KMS, wrong private key, corrupted secrets file), the .sops.yaml is already modified but secrets are NOT re-encrypted. The pseudocode warns about this (line 992-993) but does not roll back.

This leaves the system in an inconsistent state: .sops.yaml lists a recipient who cannot actually decrypt the secrets. The next `sops --set` operation will encrypt for this recipient, but existing secrets remain encrypted for the old recipient set.

**Cascade**: New team member is added. updatekeys fails silently (user ignores warning). Team member tries to decrypt. Fails. User re-runs add-recipient. Duplicate check says "already in .sops.yaml." Returns idempotently. Team member still cannot decrypt.

**Impact**: Team members unable to decrypt secrets with no clear remediation path.

**Fix**: Save a backup of .sops.yaml before modifying. On updatekeys failure, restore the backup and abort cleanly.

---

### SF-4: /dk:remove awk-based YAML block deletion will corrupt file on nested structures

**Severity**: MEDIUM
**Confidence**: 0.80

**The problem**: `/dk:remove` (01-core-skills.md, line 183) says "Read full workspace.yaml, remove the project block (awk/line-based)." The pseudocode does not specify the awk logic, but `dk-helpers.sh` shows the pattern: match `^  <name>:`, then consume lines until the next `^  [a-zA-Z]` line.

If a project block contains a nested map with keys at 4-space indent that happen to have blank lines between them, or if the YAML has comments associated with the project block, the awk deletion may leave orphaned lines or delete too few lines.

Example:
```yaml
projects:
  aether:
    path: "./aether"
    type: "node"
    # Aether is our component library
    git:
      url: "git@github.com:idl3/aether.git"
      default_branch: "main"
    meta:
      description: "Component library"
      scope: "@idl3"

  olam:
    path: "./olam"
```

If removing `aether`, the awk must consume everything from `  aether:` through the blank line, stopping before `  olam:`. A naive implementation might stop at the first blank line (leaving `git:`, `meta:` orphaned) or might not handle the comment line.

**Impact**: Corrupted workspace.yaml requiring manual repair.

**Fix**: Define the awk deletion logic precisely: a project block starts at `^  <name>:` and ends at the next line matching `^  [a-zA-Z]` or `^[a-zA-Z]` (next project or next top-level section). Everything in between, including blank lines and comments, is deleted.

---

### SF-5: /dk:run allows arbitrary command execution with no confirmation for destructive commands

**Severity**: MEDIUM
**Confidence**: 0.85

**The problem**: `/dk:run <command>` (02-git-operations.md, line 124-157) runs any user-provided command across all projects:

```
cd "<absolute-path>" && <user-command>
```

The security note says "This is intentional — the user is explicitly providing a command to run." However, Claude Code skills don't have a separate confirmation step for destructive commands. If a user types `/dk:run rm -rf node_modules` intending to clear caches, a typo like `/dk:run rm -rf .` would delete all project directories.

More subtly: `/dk:run git reset --hard` across all projects silently discards uncommitted work in every project with no recovery path.

**Impact**: Mass data loss from a single typo across all workspace projects.

**Fix**: Add a confirmation step that shows the exact command and all target projects before execution. For known destructive patterns (`rm -rf`, `git reset --hard`, `git clean -f`), require explicit "I understand this is destructive" confirmation.

---

### SF-6: Context window exhaustion from /dk:info and /dk:status at scale

**Severity**: MEDIUM
**Confidence**: 0.83

**The problem**: `/dk:info` (01-core-skills.md, lines 222-236) runs per project:
- `git log --oneline -5` (~5 lines)
- `git status --porcelain` (up to hundreds of lines for dirty repos)
- file counts (source + test)

`/dk:status` (02-git-operations.md, lines 26-31) runs 4 bash commands per project in "parallel" (batched tool calls). For 10 projects, that's 40 bash calls. For 20, it's 80. Each bash result consumes context window tokens.

Claude Code has finite context. With 20 projects, `/dk:status` generates ~80 tool call results plus the formatted dashboard. The formatting step itself requires Claude to hold all results in context. At 50 projects, this is almost certainly beyond practical context limits.

`/dk:run` truncates at 50 lines per project, but `/dk:status` has no truncation — `git status --porcelain` on a very dirty repo can produce thousands of lines (piped through `wc -l` so only the count, but the point stands for `/dk:info`).

**Impact**: Skills fail silently or produce truncated/nonsensical output at moderate scale (15+ projects).

**Fix**:
- `/dk:status` and `/dk:info`: batch git commands into a single compound bash call per project (semicolon-separated), reducing tool calls from 4N to N
- Add a project count check: if >15 projects, warn and offer `--projects` filter
- For `/dk:info`: truncate `git status --porcelain` output to first 20 entries

---

### SF-7: Paths with spaces break unquoted variable expansion in awk patterns

**Severity**: MEDIUM
**Confidence**: 0.80

**The problem**: `dk_project_path` in `dk-helpers.sh` (line 104-106) extracts the path value:

```awk
gsub(/.*path: *"?/, "")
gsub(/".*/, "")
print
```

This works for quoted paths like `path: "./my project"` — the first gsub strips up to and including the opening quote, the second strips from the closing quote. But for **unquoted** paths with spaces like `path: ./my project`, the awk extracts `./my project` correctly (everything after `path: `), but then callers use this value in bash:

```bash
abs_path="$root/${rel#./}"
```

The quoting here is correct. But if any downstream skill constructs a bash command by string concatenation without quoting the path, it breaks. The pseudocode explicitly warns about this (01-core-skills.md, line 159: "Path has spaces → quote all variables") but the warning is in the edge cases section of `/dk:add`, not enforced systematically.

Similarly, `dk_for_each_project` (line 182-192) passes `$abs_path` to the callback, but the `local abs_path` declaration inside the while loop means the variable is re-declared each iteration — this is fine in bash but worth noting.

**Impact**: Paths with spaces work in dk-helpers.sh (properly quoted) but may break in skill pseudocode that Claude translates to bash commands, since Claude interprets pseudocode heuristically.

**Fix**: Add a validation in `/dk:add` that rejects paths containing spaces, or explicitly test space-in-path scenarios end-to-end during dogfooding.

---

### SF-8: sed -i '' is macOS-specific — breaks on Linux

**Severity**: MEDIUM
**Confidence**: 0.95

**The problem**: In `secret-remove` (03-secrets-management.md, line 1192):

```
sed -i '' '/^KEY:/d' file
```

The `sed -i ''` syntax (empty string argument to -i) is macOS/BSD sed. On GNU/Linux, `sed -i` takes no argument (or `sed -i ''` interprets `''` as the first file operand). This command will fail on Linux with a confusing error.

The PLAN.md does not mention Linux compatibility, but the CLAUDE.md says nothing about macOS-only. The `age` and `sops` install instructions include both brew (macOS) and `go install` (cross-platform), implying cross-platform intent.

**Impact**: Secret removal broken on Linux.

**Fix**: Use `sed -i.bak` (works on both) and then `rm file.bak`, or prefer `yq` for YAML manipulation (already preferred in the pseudocode, with sed as fallback).

---

## WATCH

Issues to monitor during implementation and dogfooding.

---

### W-1: Skills are instructions, not programs — Claude interpretation drift

**Confidence**: 0.70

Diakon skills are SKILL.md files that Claude reads and interprets. Claude decides how to translate pseudocode like `yaml_parse()` or `shell_quote()` into actual tool calls. There is no guarantee that:
- Claude will use `jq` for JSON encoding vs. manual escaping
- Claude will quote paths correctly in every generated bash command
- Claude will implement the awk logic identically to what dk-helpers.sh provides
- Claude will handle the error branches in the exact order specified

Each Claude session may interpret the same skill differently. Over model updates, the interpretation may change.

**Monitor**: Keep the dogfooding test suite. Run it after each Claude model update. Track whether skill execution drifts.

---

### W-2: Race between /dk:pull and /dk:branch across projects

**Confidence**: 0.65

If `/dk:pull` is running (pulling project A, then B, then C) and the user simultaneously triggers `/dk:branch` in another session, the branch operation may run on a project that's mid-pull. Git handles this gracefully (lock file prevents concurrent operations on the same repo), but the error messages will be confusing: "Unable to create '.git/index.lock': File exists."

**Monitor**: Document that concurrent dk:* operations on the same workspace are not supported.

---

### W-3: dk_workspace_root walks to filesystem root — slow on deep paths, confusing on NFS

**Confidence**: 0.60

`dk_workspace_root()` walks from `$PWD` to `/`, checking each directory for `.diakon/workspace.yaml`. On deep paths (20+ levels, common with node_modules or monorepo nested packages), this is many stat calls. On NFS or slow network filesystems, each stat may take 100ms+, making the function take seconds.

Also, if there's a stale `.diakon/workspace.yaml` in a parent directory (e.g., user abandoned a workspace), `dk_workspace_root` will find it instead of realizing no workspace exists at the current level.

**Monitor**: Not critical but worth a max-depth limit (e.g., stop after 10 levels up) and a `--workspace-root` override flag.

---

### W-4: /dk:check round-trip test creates a real secret in production secrets file

**Confidence**: 0.75

The health check (04-health-and-agent.md, line 60) runs a round-trip test: set a temp key `_DIAKON_INIT_TEST`, get it, verify, delete. If the delete step fails (yq not available and sed fails on the key format), the test key persists in the secrets file.

More concerning: during the init round-trip test (03-secrets-management.md, line 1690-1756), if the cleanup fails, the test key `_DIAKON_INIT_TEST` remains in the encrypted file forever, appearing in `/dk:secret-list`.

**Monitor**: Add a check in `/dk:secret-list` to warn if `_DIAKON_INIT_TEST` exists. Or use a different cleanup strategy that doesn't leave debris.

---

### W-5: workspace.yaml "flat YAML" constraint is not enforced

**Confidence**: 0.75

The architecture says "workspace.yaml is flat — parseable with grep/awk, no yq required" (CLAUDE.md). The pseudocode for 05-shell-helpers.md defines 4 constraints (2-space indent projects, same-line values, inline lists, section delimiters). But nothing enforces these constraints.

If a user hand-edits workspace.yaml to use block-style lists:
```yaml
packages:
  - types
  - ui
```

...the awk parser will not see `packages: ["types", "ui"]` and will fail silently (returning empty or wrong data).

If a user adds a YAML multi-line string:
```yaml
description: >
  This is a long
  description
```

...the awk parser will only see the first line.

**Monitor**: `/dk:check` should validate that workspace.yaml conforms to the flat YAML constraints. Any violation should be a health check warning.

---

### W-6: /dk:init does not handle symlinks in project paths

**Confidence**: 0.70

During project discovery, `/dk:init` resolves globs from pnpm-workspace.yaml. If a top-level directory is a symlink to a directory outside the workspace (common in development setups), `dk_project_abs_path` will resolve to a location outside the workspace root.

Subsequent operations like `/dk:pull` or `/dk:run` would operate on the symlink target, which may be on a different filesystem, in a different user's home directory, or a read-only mount.

**Monitor**: Resolve symlinks during `/dk:add` and `/dk:init` using `realpath`, then validate the resolved path is within the workspace root.

---

### W-7: age key file permission check is missing from prerequisites

**Confidence**: 0.80

The init procedure sets `chmod 600` on a newly generated age key (03-secrets-management.md, line 1376). But `assert_prerequisites` does NOT check permissions on an existing key file. If the key file is world-readable (`644` — the default for many file creation scenarios), secrets operations will succeed but the private key is exposed.

SSH checks key permissions and refuses to use overly-permissive keys. age and sops do not perform this check.

**Monitor**: Add a permission check in `assert_prerequisites`: `stat -f '%Lp' "$AGE_KEY_PATH"` should be `600` or `400`. Warn if not.

---

### W-8: /dk:secret-set value argument visible in Claude's conversation context

**Confidence**: 0.85

When a user types `/dk:secret-set DATABASE_URL postgres://user:pass@host/db`, the value `postgres://user:pass@host/db` is:
1. In the user's message (visible to Claude, stored in conversation history)
2. Passed to `Bash()` as a command argument (visible in tool call logs)
3. In the sops command line (briefly visible in process list)

The pseudocode notes this (line 395-396) and never echoes the value in output. But the value is already in Claude's context window for the rest of the session. If the session is long and the context is sent to Anthropic's API, the secret value transits through the API.

There is no way to avoid #1 given the architecture (the user typed it). But it should be documented prominently that secrets passed via `/dk:secret-set` are visible to Claude and included in API calls.

**Monitor**: Consider an alternative flow where the skill prompts the user to paste the value after invocation, so it's in a separate message that could theoretically be excluded from context summaries. Or recommend using `sops` directly for high-sensitivity secrets.

---

## Specific Attack Scenarios

### Scenario A: Partial git pull leaves workspace in inconsistent state

**Trigger**: `/dk:pull` on 5 projects, network drops after project 3.

**Chain**:
1. Projects 1-3 pulled successfully to latest
2. Network drops. Projects 4-5 fail with "Could not resolve host"
3. `/dk:pull` reports: "3 succeeded, 2 failed"
4. User runs `pnpm install` — dependency resolution uses the NEW versions of packages from projects 1-3 but OLD versions from 4-5
5. If project 4 published a breaking change that project 1 depends on, the workspace is now in a state where `pnpm install` fails or builds break in confusing ways
6. The user sees build errors in project 1 that reference types from project 4 — but project 4 is at the old version

**Outcome**: Cross-project dependency mismatch that is not attributable to any single project. The `/dk:status` dashboard would show the version skew if the user thinks to check it.

**Mitigation**: After partial pull failure, explicitly warn: "WARNING: Partial pull may cause cross-project dependency mismatches. Run `/dk:pull` again when network is restored, or revert pulled projects with `git reset --hard HEAD~1`."

---

### Scenario B: sops updatekeys interruption corrupts secrets file

**Trigger**: `/dk:secret-add-recipient` on a secrets file with 50 keys, `sops updatekeys` killed mid-write.

**Chain**:
1. User adds new team member's age public key
2. .sops.yaml updated successfully
3. `sops updatekeys` begins re-encrypting the data key in secrets.enc.yaml
4. Process killed (Ctrl+C, OOM, machine sleep) while sops is writing
5. secrets.enc.yaml is partially written — sops metadata is incomplete
6. Next `sops --decrypt` fails with MAC mismatch
7. User tries `git checkout -- .diakon/secrets.enc.yaml` to restore
8. Restored file has OLD recipient list but .sops.yaml has NEW list
9. Next `sops --set` re-encrypts with NEW recipients — but previous data key was for OLD recipients
10. Team member can decrypt new secrets but not old ones

**Outcome**: Split-brain secrets: some values encrypted for old recipients, some for new. No single operation can fix this without decrypting everything and re-encrypting.

**Mitigation**: Before `sops updatekeys`, copy the current secrets file to `.diakon/secrets.enc.yaml.bak`. On success, delete the backup. On failure, restore from backup and revert .sops.yaml.

---

### Scenario C: /dk:init with hand-edited malformed workspace.yaml

**Trigger**: User previously ran `/dk:init`, then hand-edits workspace.yaml incorrectly (e.g., wrong indentation), then runs `/dk:init` again.

**Chain**:
1. `/dk:init` step 2: checks if `.diakon/workspace.yaml` exists — it does
2. Reads it with `Read()` — succeeds (it's a file)
3. "Shows current state" — but the YAML is malformed, so the display is garbled or incomplete
4. User says "y" to re-initialize
5. Re-init overwrites with a fresh workspace.yaml — this is actually the GOOD outcome
6. But if the user says "n", they continue with a malformed workspace.yaml
7. All subsequent operations parse the malformed YAML with awk — producing wrong results silently

**Outcome**: Silent corruption of all operations based on malformed YAML.

**Mitigation**: Before showing "Re-initialize?", validate the YAML structure. If malformed, say: "workspace.yaml appears to be malformed. Re-initialization recommended."

---

### Scenario D: Unicode project names break awk parsing

**Trigger**: User has a directory named with unicode characters (e.g., `日本語-app` or `cafe\u0301`) and runs `/dk:add ./日本語-app`.

**Chain**:
1. `/dk:add` validates the name — the regex `^[a-zA-Z_][a-zA-Z0-9_.\-]*$` in `sanitize_sops_key` would reject this. But this is the sops key sanitizer, not a project name validator
2. The project name validator (if any) is not specified in the pseudocode
3. If the name passes validation, it's written to workspace.yaml
4. awk's `[a-zA-Z]` character class in `dk_list_projects` does not match unicode characters in POSIX locale
5. The project is invisible to all enumeration functions

**Outcome**: Project registered but invisible — a ghost entry that consumes space in workspace.yaml but is never operated on.

**Mitigation**: Define an explicit project name regex (same as sops key: `^[a-zA-Z_][a-zA-Z0-9_.\-]*$`) and enforce it in `/dk:add`.

---

```json
{
  "reviewer": "adversarial",
  "findings": [
    {
      "id": "MF-1",
      "title": "awk regex match on project names causes substring collision and metacharacter failures",
      "severity": "critical",
      "confidence": 0.95,
      "category": "assumption_violation",
      "evidence": [
        "dk-helpers.sh line 101: $0 ~ \"^  \"name\":\" uses regex, not literal match",
        "Project 'api' regex-matches 'api-gateway:' if it appears first in file",
        "Project names with dots (a.b) match any character, names with + cause awk regex error",
        "All skills using dk_project_path or dk_project_field get wrong project data silently"
      ],
      "location": "/Users/ernie/Projects/diakon/scripts/dk-helpers.sh:101",
      "autofix_class": "manual",
      "owner": "human"
    },
    {
      "id": "MF-2",
      "title": "dk_project_field contains dead gsub with literal 'field' string instead of awk variable",
      "severity": "high",
      "confidence": 0.92,
      "category": "composition_failure",
      "evidence": [
        "dk-helpers.sh line 138: gsub(/.*\"field\": *\"?/, \"\") uses literal 'field' not the variable",
        "Second sub() line handles extraction as fallback, masking the bug",
        "Function appears to work but for wrong reasons — fragile to future modification"
      ],
      "location": "/Users/ernie/Projects/diakon/scripts/dk-helpers.sh:138",
      "autofix_class": "manual",
      "owner": "human"
    },
    {
      "id": "MF-3",
      "title": "secret-remove leaves plaintext secrets on disk if process interrupted between decrypt and cleanup",
      "severity": "high",
      "confidence": 0.90,
      "category": "cascade_construction",
      "evidence": [
        "03-secrets-management.md line 1160: decrypts to .diakon/secrets.remove-tmp.yaml",
        "If Claude session timeout (2min), Ctrl+C, or crash occurs after decrypt but before rm",
        "Plaintext file containing ALL secrets persists at predictable path on disk",
        ".gitignore prevents accidental commit but file remains on filesystem",
        "Same pattern in init round-trip test at line 1736 with secrets.test-cleanup.tmp.yaml"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/03-secrets-management.md:1160",
      "autofix_class": "manual",
      "owner": "human"
    },
    {
      "id": "MF-4",
      "title": "Concurrent /dk:add operations create duplicate entries or overwrite each other",
      "severity": "high",
      "confidence": 0.85,
      "category": "abuse_case",
      "evidence": [
        "01-core-skills.md line 154: read workspace.yaml, check duplicates, append",
        "No file locking between read and write steps",
        "Two concurrent adds both pass duplicate check, both append — second overwrites first or creates duplicate YAML key",
        "YAML spec says duplicate keys are undefined behavior"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/01-core-skills.md:154",
      "autofix_class": "advisory",
      "owner": "human"
    },
    {
      "id": "MF-5",
      "title": "/dk:init in home directory registers every git repo as a project",
      "severity": "high",
      "confidence": 0.93,
      "category": "assumption_violation",
      "evidence": [
        "01-core-skills.md step 4: scans top-level dirs for package.json or .git when no workspace type detected",
        "No guard on workspace root being $HOME, /, /tmp, or other system directories",
        "Subsequent /dk:pull or /dk:run would operate on dozens of unrelated repositories",
        "Context window exhaustion from /dk:status on 50+ projects"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/01-core-skills.md:58",
      "autofix_class": "manual",
      "owner": "human"
    },
    {
      "id": "SF-1",
      "title": "Secret values passed as command-line arguments visible in process list",
      "severity": "high",
      "confidence": 0.88,
      "category": "abuse_case",
      "evidence": [
        "03-secrets-management.md line 322: sops --set '[\"KEY\"] \"secret-value\"'",
        "/proc/<pid>/cmdline readable by all users on Linux",
        "ps aux shows arguments on macOS",
        "Pseudocode acknowledges this at line 397 but provides no mitigation"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/03-secrets-management.md:322",
      "autofix_class": "advisory",
      "owner": "human"
    },
    {
      "id": "SF-3",
      "title": "secret-add-recipient modifies .sops.yaml before updatekeys — no rollback on failure creates split-brain state",
      "severity": "high",
      "confidence": 0.90,
      "category": "cascade_construction",
      "evidence": [
        "03-secrets-management.md line 884: writes updated .sops.yaml",
        "Line 976: runs sops updatekeys which may fail",
        "Lines 992-993: warns but does NOT rollback .sops.yaml",
        "New recipient appears in config but cannot decrypt existing secrets",
        "Subsequent add-recipient returns 'already exists' idempotently — no path to fix"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/03-secrets-management.md:884",
      "autofix_class": "manual",
      "owner": "human"
    },
    {
      "id": "SF-6",
      "title": "Context window exhaustion from /dk:status and /dk:info at 15+ projects",
      "severity": "medium",
      "confidence": 0.83,
      "category": "abuse_case",
      "evidence": [
        "02-git-operations.md lines 26-31: 4 bash calls per project for /dk:status",
        "At 20 projects: 80 tool call results in context window",
        "01-core-skills.md line 222: /dk:info runs git log, status, rev-list, file counts per project",
        "No truncation or batching strategy for status; run-only truncates at 50 lines",
        "Claude context window is finite; no project count guard"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/02-git-operations.md:26",
      "autofix_class": "advisory",
      "owner": "human"
    },
    {
      "id": "SF-8",
      "title": "sed -i '' is macOS-specific — secret-remove fallback broken on Linux",
      "severity": "medium",
      "confidence": 0.95,
      "category": "assumption_violation",
      "evidence": [
        "03-secrets-management.md line 1192: sed -i '' (BSD syntax)",
        "GNU sed interprets '' as first file argument, not in-place flag",
        "Install instructions include go install (cross-platform) suggesting Linux support intended",
        "Fallback used when yq not available — common on minimal CI images"
      ],
      "location": "/Users/ernie/Projects/diakon/docs/pseudocode/03-secrets-management.md:1192",
      "autofix_class": "manual",
      "owner": "downstream-resolver"
    }
  ],
  "residual_risks": [
    "Claude interpretation drift: skills are markdown instructions, not deterministic programs. Behavior may vary across Claude model versions or sessions. No test harness can cover this.",
    "Git lock contention: concurrent dk:* operations on the same workspace will hit .git/index.lock conflicts with confusing error messages.",
    "Flat YAML constraint unenforced: hand-edits introducing block lists, multi-line strings, or flow mappings will silently break all awk-based parsing.",
    "Age key file permissions: no runtime check that ~/.config/sops/age/keys.txt is 600. World-readable key files silently accepted.",
    "Secret values in Claude context: any secret passed to /dk:secret-set or retrieved via /dk:secret-get persists in the conversation context for the session duration."
  ],
  "testing_gaps": [
    "dk-helpers.sh self-test only covers dk_check_deps — no tests for project enumeration, field extraction, or path resolution",
    "No test for workspace.yaml with 0 projects, 1 project, or 20+ projects",
    "No test for project names that are substrings of each other (api vs api-gateway)",
    "No test for paths containing spaces, unicode, or symlinks",
    "No test for interrupted secret operations (crash recovery)",
    "No cross-platform test (macOS vs Linux sed/awk behavior differences)",
    "No test for malformed workspace.yaml (missing sections, wrong indentation, duplicate keys)"
  ]
}
```
