#!/usr/bin/env bash
# Diakon shell helpers — sourced by skills via:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
#
# Functions for workspace discovery, project enumeration, and YAML parsing.
# No external deps beyond bash 3.2+ (macOS compatible), grep, awk, sed.
#
# AUDIT FIXES APPLIED:
#   C-3: awk uses exact string match (not regex ~) for project names
#   H-1: No set -euo pipefail (would mutate caller's shell)
#   H-2: Field matching anchored to prevent substring collision
#   H-3: Path traversal validation via realpath
#   H-4/H-5: dk_safe_write with backup-before-mutation
#   M-1: Fixed dead gsub in dk_project_field
#   M-2: Comment lines skipped in all awk parsers
#   M-3: Numeric project names allowed ([a-zA-Z0-9_-])
#   M-4: CRLF stripped in all awk value extraction
#   M-7: Callback failures don't kill dk_for_each_project

# NOTE: Do NOT add set -euo pipefail here. This file is sourced by callers
# and would permanently change their shell options.

# ─── Constants ──────────────────────────────────────────────────────

DK_CONFIG_DIR=".diakon"
DK_WORKSPACE_FILE="workspace.yaml"

# Directories where /dk:init should refuse to run
DK_DENYLIST_DIRS="$HOME / /tmp /var /etc /usr /opt"

# ─── Workspace Discovery ────────────────────────────────────────────

# Walk up from CWD to find the Diakon workspace root.
# Prints the absolute path or returns 1.
dk_workspace_root() {
  local dir="${PWD}"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "ERROR: No $DK_CONFIG_DIR/$DK_WORKSPACE_FILE found in parent directories" >&2
  return 1
}

# Check if a directory is safe for workspace init.
# Returns 1 if the directory is in the denylist.
dk_is_safe_init_dir() {
  local target_dir="$1"
  local resolved
  resolved="$(cd "$target_dir" 2>/dev/null && pwd -P)" || return 1

  for denied in $DK_DENYLIST_DIRS; do
    local denied_resolved
    denied_resolved="$(cd "$denied" 2>/dev/null && pwd -P)" || continue
    if [[ "$resolved" == "$denied_resolved" ]]; then
      echo "ERROR: Refusing to initialize in $denied — too broad" >&2
      return 1
    fi
  done
  return 0
}

# ─── Tool Checking ──────────────────────────────────────────────────

# Verify required CLI tools are available.
# Usage: dk_check_deps sops age gcloud
# Returns 0 if all present, 1 with missing list on stderr.
dk_check_deps() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "Install with: brew install ${missing[*]}" >&2
    return 1
  fi
  return 0
}

# ─── Validation ─────────────────────────────────────────────────────

# Validate a project name: alphanumeric, hyphens, underscores only.
# Returns 0 if valid, 1 if not.
dk_validate_project_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "ERROR: Project name cannot be empty" >&2
    return 1
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "ERROR: Invalid project name '$name'. Use alphanumeric, hyphens, underscores. Must start with letter or digit." >&2
    return 1
  fi
  return 0
}

# ─── Project Enumeration ────────────────────────────────────────────

# List all project names from workspace.yaml, one per line.
# Uses exact string matching (not regex) for safety. Skips comments. Strips \r.
dk_list_projects() {
  local root
  root="$(dk_workspace_root)" || return 1
  local ws_file="$root/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE"

  awk '
    { gsub(/\r/, "") }
    /^#/ { next }
    /^projects:/ { found=1; next }
    found && /^[a-zA-Z0-9]/ { exit }
    found && /^  [a-zA-Z0-9]/ && /:/ {
      line = $0
      sub(/:.*/, "", line)
      sub(/^  /, "", line)
      if (line != "") print line
    }
  ' "$ws_file"
}

# List only enabled project names (enabled: true or field missing = default true).
dk_enabled_projects() {
  local root
  root="$(dk_workspace_root)" || return 1
  local ws_file="$root/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE"

  awk '
    { gsub(/\r/, "") }
    /^#/ { next }
    /^projects:/ { in_projects=1; next }
    in_projects && /^[a-zA-Z0-9]/ && !/^  / {
      if (name != "" && enabled != "false") print name
      name = ""
      exit
    }
    in_projects && /^  [a-zA-Z0-9]/ && /:/ && !/^    / {
      if (name != "" && enabled != "false") print name
      line = $0
      sub(/:.*/, "", line)
      sub(/^  /, "", line)
      name = line
      enabled = "true"
      next
    }
    in_projects && /^    enabled:/ {
      line = $0
      sub(/.*enabled: */, "", line)
      gsub(/[ \t"]*$/, "", line)
      gsub(/^[ \t"]*/, "", line)
      enabled = line
    }
    END {
      if (name != "" && enabled != "false") print name
    }
  ' "$ws_file"
}

# ─── Project Field Access ───────────────────────────────────────────

# Get the relative path for a project.
# Usage: dk_project_path <project-name>
dk_project_path() {
  local name="$1"
  local root
  root="$(dk_workspace_root)" || return 1
  local ws_file="$root/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE"

  # Use exact string match: "  <name>:" at start of line
  local target="  ${name}:"
  awk -v target="$target" '
    { gsub(/\r/, "") }
    /^#/ { next }
    {
      if (substr($0, 1, length(target)) == target) { found=1; next }
    }
    found && /^  [a-zA-Z0-9]/ && !/^    / { exit }
    found && /^    path:/ {
      line = $0
      sub(/.*path: *"?/, "", line)
      sub(/".*/, "", line)
      gsub(/[ \t]*$/, "", line)
      print line
      exit
    }
  ' "$ws_file"
}

# Get an absolute path for a project, with path traversal validation (H-3).
dk_project_abs_path() {
  local name="$1"
  local root
  root="$(dk_workspace_root)" || return 1
  local rel
  rel="$(dk_project_path "$name")" || return 1

  if [[ -z "$rel" ]]; then
    echo "ERROR: No path found for project '$name'" >&2
    return 1
  fi

  local abs_path="$root/${rel#./}"

  # Path traversal check: resolved path must be under workspace root
  if command -v realpath &>/dev/null; then
    local resolved
    resolved="$(realpath -m "$abs_path" 2>/dev/null)" || resolved="$abs_path"
    local resolved_root
    resolved_root="$(realpath -m "$root" 2>/dev/null)" || resolved_root="$root"
    case "$resolved" in
      "$resolved_root"/*) ;; # OK — under workspace root
      "$resolved_root") ;; # OK — is the workspace root
      *)
        echo "ERROR: Path '$rel' resolves outside workspace root" >&2
        return 1
        ;;
    esac
  fi

  echo "$abs_path"
}

# Get a field value from a project block.
# Usage: dk_project_field <project-name> <field-name>
# Uses exact string matching for both project name and field name.
dk_project_field() {
  local name="$1"
  local field="$2"
  local root
  root="$(dk_workspace_root)" || return 1
  local ws_file="$root/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE"

  local target="  ${name}:"
  local field_target="    ${field}:"

  awk -v target="$target" -v field_target="$field_target" '
    { gsub(/\r/, "") }
    /^#/ { next }
    {
      if (substr($0, 1, length(target)) == target) { found=1; next }
    }
    found && /^  [a-zA-Z0-9]/ && !/^    / { exit }
    found {
      if (substr($0, 1, length(field_target)) == field_target) {
        line = $0
        sub(/^[^:]+: *"?/, "", line)
        sub(/".*/, "", line)
        gsub(/[ \t]*$/, "", line)
        print line
        exit
      }
    }
  ' "$ws_file"
}

# Check if a project is enabled (defaults to true if field missing).
dk_is_enabled() {
  local val
  val="$(dk_project_field "$1" "enabled")" || true
  [[ "$val" != "false" ]]
}

# ─── Workspace Fields ───────────────────────────────────────────────

# Get a workspace-level field (name, type, package_manager).
# Usage: dk_workspace_field <field-name>
dk_workspace_field() {
  local field="$1"
  local root
  root="$(dk_workspace_root)" || return 1
  local ws_file="$root/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE"

  local field_target="  ${field}:"

  awk -v field_target="$field_target" '
    { gsub(/\r/, "") }
    /^#/ { next }
    /^workspace:/ { in_ws=1; next }
    in_ws && /^[a-zA-Z0-9]/ { exit }
    in_ws {
      if (substr($0, 1, length(field_target)) == field_target) {
        line = $0
        sub(/^[^:]+: *"?/, "", line)
        sub(/".*/, "", line)
        gsub(/[ \t]*$/, "", line)
        print line
        exit
      }
    }
  ' "$ws_file"
}

# ─── Safe File Writes ───────────────────────────────────────────────

# Write content to a file atomically with backup (H-4, H-5).
# Usage: dk_safe_write <file-path> <content>
# Creates a .bak backup before overwriting.
dk_safe_write() {
  local file="$1"
  local content="$2"
  local tmp="${file}.new.$$"

  # Backup existing file
  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak" || {
      echo "ERROR: Failed to create backup of $file" >&2
      return 1
    }
  fi

  # Write to temp, then atomic rename
  printf '%s' "$content" > "$tmp" || {
    echo "ERROR: Failed to write to $tmp" >&2
    rm -f "$tmp"
    return 1
  }

  mv "$tmp" "$file" || {
    echo "ERROR: Failed to rename $tmp to $file" >&2
    rm -f "$tmp"
    return 1
  }
}

# ─── Iteration ──────────────────────────────────────────────────────

# Iterate over all enabled projects and call a function with (name, abs_path).
# Usage: dk_for_each_project my_callback_fn
# Callback failures are logged but do NOT stop iteration (M-7).
dk_for_each_project() {
  local callback="$1"
  local root
  root="$(dk_workspace_root)" || return 1
  local had_errors=0

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local abs_path
    abs_path="$(dk_project_abs_path "$name")" || { had_errors=1; continue; }
    "$callback" "$name" "$abs_path" || {
      echo "WARNING: callback failed for project '$name'" >&2
      had_errors=1
    }
  done < <(dk_enabled_projects)

  return $had_errors
}

# ─── Self-Test ──────────────────────────────────────────────────────

if [[ "${1:-}" == "--test" ]]; then
  PASS=0
  FAIL=0
  echo "=== dk-helpers.sh self-test ==="

  _assert() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
      echo "  PASS: $label"
      ((PASS++)) || true
    else
      echo "  FAIL: $label (expected '$expected', got '$actual')"
      ((FAIL++)) || true
    fi
  }

  # Test dk_check_deps: present tool
  if dk_check_deps bash 2>/dev/null; then
    echo "  PASS: dk_check_deps finds bash"; ((PASS++)) || true
  else
    echo "  FAIL: dk_check_deps should find bash"; ((FAIL++)) || true
  fi

  # Test dk_check_deps: missing tool
  if dk_check_deps nonexistent_tool_xyz 2>/dev/null; then
    echo "  FAIL: dk_check_deps should fail for nonexistent tool"; ((FAIL++)) || true
  else
    echo "  PASS: dk_check_deps correctly fails for nonexistent tool"; ((PASS++)) || true
  fi

  # Test dk_validate_project_name: valid names
  for valid_name in aether olam my-project project_1 3dviewer; do
    if dk_validate_project_name "$valid_name" 2>/dev/null; then
      echo "  PASS: validate accepts '$valid_name'"; ((PASS++)) || true
    else
      echo "  FAIL: validate should accept '$valid_name'"; ((FAIL++)) || true
    fi
  done

  # Test dk_validate_project_name: invalid names
  for invalid_name in "" "-starts-with-dash" "has spaces" "has.dots" "a/b"; do
    if dk_validate_project_name "$invalid_name" 2>/dev/null; then
      echo "  FAIL: validate should reject '$invalid_name'"; ((FAIL++)) || true
    else
      echo "  PASS: validate rejects '$invalid_name'"; ((PASS++)) || true
    fi
  done

  # Test dk_is_safe_init_dir: should reject HOME
  if dk_is_safe_init_dir "$HOME" 2>/dev/null; then
    echo "  FAIL: should reject HOME"; ((FAIL++)) || true
  else
    echo "  PASS: rejects HOME dir"; ((PASS++)) || true
  fi

  # Test dk_is_safe_init_dir: should reject /
  if dk_is_safe_init_dir "/" 2>/dev/null; then
    echo "  FAIL: should reject /"; ((FAIL++)) || true
  else
    echo "  PASS: rejects / dir"; ((PASS++)) || true
  fi

  # Test dk_safe_write: write and verify
  _test_tmp="/tmp/dk-test-$$"
  dk_safe_write "$_test_tmp" "hello world"
  _actual="$(cat "$_test_tmp" 2>/dev/null)"
  _assert "dk_safe_write creates file" "hello world" "$_actual"

  # Test dk_safe_write: creates backup
  dk_safe_write "$_test_tmp" "updated"
  _actual_bak="$(cat "${_test_tmp}.bak" 2>/dev/null)"
  _assert "dk_safe_write creates .bak" "hello world" "$_actual_bak"
  rm -f "$_test_tmp" "${_test_tmp}.bak"

  # Test workspace parsing with a fixture
  _fixture_dir="/tmp/dk-fixture-$$"
  mkdir -p "$_fixture_dir/$DK_CONFIG_DIR"
  cat > "$_fixture_dir/$DK_CONFIG_DIR/$DK_WORKSPACE_FILE" << 'FIXTURE'
diakon: "0.1.0"

workspace:
  name: "test-workspace"
  type: "pnpm"
  package_manager: "pnpm@10.8.1"

projects:
  aether:
    path: "./aether"
    enabled: true
    type: "node"
    packages: ["types", "ui"]
  api:
    path: "./api"
    enabled: true
    type: "node"
  api-gateway:
    path: "./api-gateway"
    enabled: false
    type: "node"
  3dviewer:
    path: "./3dviewer"
    enabled: true
    type: "node"

secrets:
  backend: "sops+age"
FIXTURE

  # Run tests in the fixture dir
  pushd "$_fixture_dir" > /dev/null 2>&1

  # Test dk_workspace_root
  _actual="$(dk_workspace_root)"
  _assert "dk_workspace_root finds fixture" "$_fixture_dir" "$_actual"

  # Test dk_workspace_field
  _actual="$(dk_workspace_field "name")"
  _assert "dk_workspace_field name" "test-workspace" "$_actual"
  _actual="$(dk_workspace_field "type")"
  _assert "dk_workspace_field type" "pnpm" "$_actual"

  # Test dk_list_projects: should list all 4
  _actual="$(dk_list_projects | wc -l | tr -d ' ')"
  _assert "dk_list_projects count" "4" "$_actual"

  # Test dk_list_projects: includes numeric name (M-3 fix)
  _actual="$(dk_list_projects | grep -c '3dviewer')"
  _assert "dk_list_projects includes numeric name" "1" "$_actual"

  # Test dk_enabled_projects: should list 3 (api-gateway is disabled)
  _actual="$(dk_enabled_projects | wc -l | tr -d ' ')"
  _assert "dk_enabled_projects count" "3" "$_actual"

  # Test dk_enabled_projects: should NOT include api-gateway
  if dk_enabled_projects | grep -q "api-gateway"; then
    echo "  FAIL: dk_enabled_projects should exclude disabled api-gateway"; ((FAIL++)) || true
  else
    echo "  PASS: dk_enabled_projects excludes disabled project"; ((PASS++)) || true
  fi

  # C-3 FIX TEST: "api" should NOT match "api-gateway"
  _actual="$(dk_project_path "api")"
  _assert "C-3: api path is ./api (not api-gateway)" "./api" "$_actual"

  _actual="$(dk_project_path "api-gateway")"
  _assert "C-3: api-gateway path is ./api-gateway" "./api-gateway" "$_actual"

  # H-2 FIX TEST: field "type" should not match "subtype"
  _actual="$(dk_project_field "aether" "type")"
  _assert "H-2: field exact match for type" "node" "$_actual"

  _actual="$(dk_project_field "aether" "path")"
  _assert "field exact match for path" "./aether" "$_actual"

  popd > /dev/null 2>&1
  rm -rf "$_fixture_dir"

  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi
