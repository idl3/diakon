# Diakon Architecture Review

Date: 2026-04-09
Reviewer: System Architecture Expert (Claude Opus 4.6)
Scope: Full design review prior to implementation

---

## 1. Architecture Overview

Diakon is a Claude Code plugin that provides workspace-level orchestration for multi-project directories. Its architecture is deliberately minimal: SKILL.md files contain natural language instructions that Claude interprets and executes using built-in tools (Bash, Read, Write, Glob, Grep). A single YAML registry (`.diakon/workspace.yaml`) holds all state. Shell helpers (`dk-helpers.sh`) provide awk-based YAML parsing. Secrets management uses sops + age with optional GCP KMS.

The architectural thesis is: "no MCP server, no runtime dependencies, no build step." Everything is files, shell commands, and markdown instructions.

---

## 2. Completeness

### 2.1 Missing Skills

**Present and well-specified:**
- CRUD: init, add, remove, list, info
- Git ops: status, pull, branch, run
- Secrets: secret-set, secret-get, secret-list, secret-add-recipient, secret-remove
- Health: check
- Agent: workspace-steward

**Missing skills users would expect:**

| Skill | Why it matters | Priority |
|-------|---------------|----------|
| `/dk:sync` or `/dk:install` | After `/dk:pull`, dependencies are stale. The steward describes this as a compound step, but a dedicated skill for "install dependencies across projects" is a common standalone action. | Medium |
| `/dk:exec` (project-scoped) | `/dk:run` executes across all projects. A single-project variant (`/dk:exec aether "pnpm test"`) would reduce friction for the most common case. Currently `/dk:run --projects aether` serves this role, but the flag syntax is heavier than needed. | Low |
| `/dk:outdated` | Check for outdated dependencies across projects. The steward mentions this as part of "weekly health report" but it deserves its own skill since it is requested independently. | Low |
| `/dk:secret-rotate` | Rotate a secret (set new value + log rotation event). The current workflow is `/dk:secret-set KEY new-value`, but a rotate skill could prompt for the new value and optionally trigger downstream actions. | Low |
| `/dk:config` | View/set workspace-level configuration (default branch naming convention, parallel vs. sequential git ops, default package manager command). Currently there is no way to change workspace config after init without hand-editing YAML. | Medium |
| `/dk:env` | Generate a `.env` file from selected secrets for a specific project. This bridges the gap between encrypted secrets and what applications actually consume at runtime. | High |
| `/dk:diff` | Cross-project diff summary (what changed since last pull, across all repos). More useful than individual `git diff` per project. | Low |

The `/dk:env` gap is the most architecturally significant. Secrets are stored centrally but applications need them as environment variables or `.env` files. Without this skill, developers must manually extract secrets one at a time with `/dk:secret-get` and copy them into place, which defeats much of the purpose of centralized secrets management.

### 2.2 Workspace Schema Sufficiency

The schema covers the essential fields for real-world use. Specific concerns:

**Sufficient:**
- Project identity (name, path, type, packages, git)
- Enabled/disabled toggle
- Secrets backend configuration
- Schema version field (`diakon: "0.1.0"`)

**Gaps:**

1. **No `meta` extensibility contract.** The `meta` block appears in the example (`description`, `scope`) but is not documented as the official extension point for arbitrary user data. The schema should explicitly state that `meta` is a freeform map that Diakon never reads -- users can put anything there.

2. **No `port` or `url` field.** For projects that run local servers (olam's control plane, pleri's API), there is no standard place to record which port they bind. This matters for `/dk:run` workflows and potential future service dependency resolution.

3. **No `depends_on` field.** See Section 6.3.

4. **No `scripts` or `commands` block.** Projects have different build/test/dev commands. The schema relies on project type detection, but a `commands: { build: "pnpm build", dev: "pnpm dev", test: "pnpm test" }` block would let `/dk:run build` resolve to the correct command per project.

5. **No environment/profile support.** See Section 6.2.

### 2.3 `/dk:check` Health Dimensions

The check skill covers six dimensions:

| Dimension | Covered | Notes |
|-----------|---------|-------|
| Registry validity | Yes | YAML parse, required keys, version |
| Project paths exist | Yes | Directory + .git validation |
| Git remote matches | Yes | Compares registry vs. actual |
| Dependency consistency | Yes | Cross-project version conflicts, lock file freshness |
| Build validation | Yes | Run build, check exit code |
| Secrets round-trip | Yes | Set/get/delete test key |
| Cross-project tsconfig | Yes | Conflicting strict/noEmit |
| Circular workspace deps | Yes | Detected |

**Missing health dimensions:**

- **Node version mismatch**: `engines.node` is checked, but the _actual running Node version_ is not compared against it. `node -v` should be compared to declared `engines`.
- **Package manager version**: The schema stores `package_manager: "pnpm@10.8.1"` but `/dk:check` never verifies the installed pnpm version matches.
- **Docker / container health**: No check for whether Docker is running, required containers are up, or Docker Compose files are valid. Relevant for olam.
- **Port conflicts**: If two projects declare the same port (once the schema supports it), `/dk:check` should detect collisions.
- **Stale branches**: Projects sitting on branches that are many commits behind their default branch. Not a failure, but a useful warning.
- **Config file drift**: Project-specific config files (`.olam/config.yaml`, `wrangler.toml`) are not validated. This is probably out of scope for v0.1, but worth noting.

### 2.4 Workspace Steward Agent

The steward is well-conceived but underspecified for implementation. Specifically:

- **No failure policy.** The description says "handles failures between steps" but does not define the policy. Should the steward continue on failure (report at end), stop immediately, or ask the user? This should be explicit: default to continue-on-failure with a summary, with `--fail-fast` to stop.
- **No idempotency guarantee.** "Update everything" can be interrupted midway. The steward should be safe to re-run (pull is idempotent, install is idempotent, build is idempotent -- but the agent doc should state this explicitly).
- **Limited compound operations.** Four operations are listed (update, release, onboard, health report). Consider also: "bootstrap new developer machine" (clone all projects, install deps, run init), "align branches" (check out the same branch name across all projects).

---

## 3. Design Integrity

### 3.1 "No MCP Server" Decision

**Verdict: Still correct.** The full skill set operates exclusively through file reads/writes and shell commands. No skill requires persistent state, connection pooling, or event subscriptions. The decision is well-documented in `wiki/07-why-no-mcp.md` and includes a clear migration path if persistent state becomes necessary.

The only operation that tests this boundary is the workspace steward agent's compound workflows, which maintain state across multiple sequential steps. But Claude's conversation context handles that -- no separate process is needed.

### 3.2 YAML vs. JSON for the Registry

**Verdict: YAML is the right choice.** Reasons:

1. **Convention alignment.** The target workspace (`pnpm-workspace.yaml`) already uses YAML. Diakon's registry sits alongside it conceptually.
2. **Comments.** YAML supports inline comments. For a human-edited registry, this matters. Developers will annotate project entries.
3. **Readability.** The registry is the central artifact developers inspect. YAML is more scannable than JSON for this use case.
4. **awk parseability.** The flat schema constraints make YAML parseable with line-oriented tools. JSON would require `jq`, adding a dependency.

The tradeoff is that YAML's flexibility creates parsing ambiguity. The design mitigates this through schema constraints (inline lists, no multi-line values, fixed indentation). This is a reasonable constraint for v0.1.

### 3.3 Awk-Based Parsing Durability

**Verdict: Adequate for v0.1 but fragile at the boundary. Plan for yq as an optional dependency.**

The awk parsing works because the schema is deliberately constrained. The documented constraints are:
- Project names at exactly 2-space indent
- Values on same line as key
- Lists use inline `[a, b]` format
- Section delimiters separate blocks

**Where it breaks:**

1. **Nested git block.** The schema has `git: { url: ..., default_branch: ... }`. The awk parser in `dk_project_field` uses a generic field extraction pattern. Extracting `git.url` (a nested field) requires the awk to understand the 6-space-indented sub-block. The current `dk_project_field` implementation does not handle dotpath access like `dk_project_field aether "git.url"` -- it would match the first line containing "url:" in the project block, which is correct only by accident (there's only one "url" per project). If a `meta.url` field is ever added, this breaks.

2. **The `meta` block.** If users add arbitrary keys under `meta`, awk parsers may misidentify them as project-level fields. The current code does not distinguish between `meta.description` and a hypothetical top-level `description` field.

3. **YAML quoting variations.** The awk strips `"` characters from values. But YAML allows unquoted values, single-quoted values, and double-quoted values. A path like `path: ./aether` (no quotes) and `path: "./aether"` produce different awk results. The current code handles both cases with `"?` in the gsub, which is fine, but `path: './aether'` (single quotes) would break.

4. **Comments in the YAML.** If a user adds `# path: old/location` as a comment within a project block, the awk parser could match it.

**Recommendation:** Ship v0.1 with awk. Add a `dk_parse_yaml` function that delegates to `yq` when available, falling back to awk. The schema constraints document should explicitly warn that certain YAML features (block scalars, anchors, flow mappings, single-quoted strings) are not supported.

### 3.4 Atomicity of workspace.yaml Writes

**This is the most significant design integrity concern.**

Multiple skills write to `workspace.yaml`:
- `/dk:add` appends a project block
- `/dk:remove` deletes a project block
- `/dk:init` creates the entire file
- `/dk:secret-add-recipient` updates the secrets section
- `/dk:check --fix` adds missing fields

None of these operations are atomic. The pseudocode for `/dk:add` says "insert before `secrets:` section" -- this is a line-oriented insert into a live YAML file. If Claude is interrupted mid-write (user cancels, session timeout), the file could be left in a partial state.

**Specific risks:**

1. **Partial writes.** The Write tool overwrites the entire file. If the new content is malformed YAML (e.g., Claude generates it with a syntax error), the registry is corrupted.
2. **No backup before mutation.** No skill copies `workspace.yaml` to `workspace.yaml.bak` before modifying it.
3. **Concurrent modification.** Two Claude sessions (or a Claude session + a manual edit) could write to `workspace.yaml` simultaneously. This is unlikely but not impossible in a team setting.
4. **secrets.enc.yaml rename dance.** The `/dk:secret-remove` pseudocode does implement an atomic rename (`mv new old`), which is good. But `workspace.yaml` writes do not use the same pattern.

**Recommendation:**

- Add a `dk_safe_write` pattern to the helpers: write to `workspace.yaml.new`, validate it is parseable, then `mv workspace.yaml.new workspace.yaml`. This gives atomicity at the filesystem level.
- Before any mutation, copy `workspace.yaml` to `workspace.yaml.bak`. If the skill fails, the user can restore.
- Document that `workspace.yaml` is not designed for concurrent writers. Single-writer assumption is fine for v0.1.

---

## 4. Dog-Fooding Gap Analysis (ein-sof)

### 4.1 Ein-sof Structure

Ein-sof is a pnpm workspace containing:
- **aether**: React component library (`@idl3` scope, sub-packages: types, ui)
- **olam**: Development world manager (sub-packages: core, adapters, mcp-server, cloudflare, control-plane). Has `.olam/config.yaml`, Docker containers, plugin directory.
- **pleri**: Full-stack app (sub-packages: api, web, types). Has `wrangler.toml`, D1 migrations.

### 4.2 Olam-Specific Gaps

1. **Project-specific config files.** Olam has `.olam/config.yaml` that configures the Olam runtime (Docker image, port mappings, environment variables). Diakon has no concept of "project config files" -- it tracks the project but not its internal configuration artifacts. A `config_files` field in the schema (e.g., `config_files: [".olam/config.yaml"]`) would let `/dk:check` validate these exist and are syntactically valid.

2. **Docker container lifecycle.** Olam runs Docker containers. `/dk:status` shows git state but not container state. A project-level `runtime` field could indicate the project has a Docker component:
   ```yaml
   olam:
     runtime:
       type: "docker-compose"
       file: "docker-compose.yml"
   ```
   This would let `/dk:check` verify Docker is running and containers are healthy.

3. **Plugin directory.** Olam has a plugin directory that users can extend. Diakon does not track plugin directories or their health.

### 4.3 Pleri-Specific Gaps

1. **Wrangler.toml.** Pleri deploys to Cloudflare Workers and uses `wrangler.toml` for configuration. `/dk:run` can execute `wrangler` commands, but there is no validation that `wrangler.toml` is present and valid for projects that need it.

2. **D1 Migrations.** Pleri has Cloudflare D1 database migrations. `/dk:run "wrangler d1 migrations apply"` would work, but `/dk:check` has no concept of pending migrations. A migration check dimension ("are there unapplied migrations?") would be valuable for database-backed projects.

3. **Multiple deployment targets.** Pleri's `api` sub-package deploys to Cloudflare Workers; `web` may deploy elsewhere. The schema has no concept of deployment targets per sub-package.

### 4.4 Cross-Project Dependency Awareness

The schema tracks `packages` as a flat list of sub-package names. It does not track which sub-packages depend on which. In ein-sof:
- `pleri/web` depends on `aether/ui`
- `pleri/api` depends on `aether/types`
- `olam/cloudflare` depends on `olam/core`

These are pnpm `workspace:*` dependencies that `/dk:check` detects for consistency, but Diakon does not model the dependency graph explicitly. For v0.1 this is acceptable -- pnpm handles resolution. But for compound operations like "build in dependency order," the steward agent would need to discover this graph at runtime (by parsing `package.json` files), which is fragile.

---

## 5. Extensibility

### 5.1 Custom Project Metadata

**Current state:** The `meta` block appears in examples but is not documented as a formal extension point.

**Recommendation:** Explicitly define `meta` as a freeform map in the schema documentation:
```yaml
meta:
  # User-defined metadata. Diakon never reads this block.
  # Use it for project-specific notes, labels, or custom tooling.
  description: "Component library"
  scope: "@idl3"
  team: "frontend"
  deploy_target: "cloudflare"
```

This is a zero-cost extension point that requires no schema changes.

### 5.2 Third-Party Skill Extension

**Current state:** The plugin.json declares `"skills": ["./skills/"]`. Third parties cannot add skills without modifying the Diakon plugin directory.

**Recommendation:** Document the pattern for complementary plugins. A third-party plugin (e.g., `diakon-cloudflare`) can define its own skills that read `.diakon/workspace.yaml` and add `/dkcf:*` commands. This is already supported by Claude Code's plugin system -- it just needs documentation.

Alternatively, consider a `skills_dirs` field in `workspace.yaml` that Diakon scans for additional skill directories. This is more complex and probably not needed for v0.1.

### 5.3 Schema Versioning

**Current state:** The schema has `diakon: "0.1.0"` as a version field. No migration path is documented.

**Recommendation:** Define the versioning contract:
- `diakon: "0.1.0"` -- skills check this field before operating
- If the version is newer than the skill expects, warn: "workspace.yaml version 0.2.0 is newer than this Diakon installation (0.1.0). Some features may not work."
- If the version is older, offer to migrate: "workspace.yaml version 0.1.0 can be upgraded to 0.2.0. Run `/dk:migrate` to update."
- Migrations are additive -- new fields get defaults, no fields are removed without a major version bump.

Add a `dk_check_version` function to the shell helpers that skills call at startup.

---

## 6. Missing Concerns

### 6.1 CI/CD Integration

**Current state:** Not addressed. Diakon is described as a "developer workspace" tool, not a CI tool.

**Gap:** The workspace registry is a structured representation of all projects and their metadata. This is exactly the data CI needs to generate build matrices. A `dk:ci-matrix` skill or a simple script could produce:

```json
{
  "include": [
    { "project": "aether", "path": "./aether", "type": "node" },
    { "project": "olam", "path": "./olam", "type": "node" },
    { "project": "pleri", "path": "./pleri", "type": "node" }
  ]
}
```

This would be consumed by GitHub Actions `strategy.matrix`:

```yaml
jobs:
  build:
    strategy:
      matrix: ${{ fromJSON(needs.setup.outputs.matrix) }}
```

**Recommendation:** Add a `/dk:ci-matrix` skill (or a shell script `dk-ci-matrix.sh` for non-Claude contexts) that reads `workspace.yaml` and outputs JSON suitable for GitHub Actions matrix strategies. This is a natural extension of the registry and high-value for the CI use case. It also validates the registry's data model -- if the schema is sufficient for CI matrix generation, it is sufficient for developer workflows.

### 6.2 Environment / Setup Profiles

**Current state:** Not addressed. The reference model (atlas-one) has `setups/*.yml` for environment profiles.

**Gap:** Different developers or environments need different configurations:
- Developer A uses Docker for olam, Developer B uses a local runtime
- Staging needs different secrets than development
- CI needs a minimal setup (no Docker, mock secrets)

The current design has a single flat secrets file and no concept of environment profiles.

**Recommendation for v0.1:** Defer full profile support. Instead, support environment-scoped secrets using key naming conventions:

```yaml
# In secrets.enc.yaml
DATABASE_URL: ENC[...]           # default
DATABASE_URL__staging: ENC[...]  # staging override
DATABASE_URL__ci: ENC[...]       # CI override
```

The `/dk:env` skill (recommended in Section 2.1) could accept an `--env` flag: `/dk:env pleri --env staging`. This is a minimal implementation that avoids multi-file complexity.

For v0.2, consider a `profiles/` directory under `.diakon/`:
```
.diakon/
  workspace.yaml
  secrets.enc.yaml
  profiles/
    development.yaml    # overrides for local dev
    staging.yaml        # overrides for staging
    ci.yaml             # overrides for CI
```

### 6.3 Service Dependencies

**Current state:** Not addressed. No mechanism to express "project A depends on project B running."

**Gap:** In ein-sof:
- pleri/api might depend on olam being running (for world management)
- pleri/web depends on pleri/api (for data)
- aether has no runtime dependencies

Without dependency modeling, `/dk:run "pnpm dev"` starts all projects simultaneously. If pleri/api needs olam's control plane running first, the user must know this and start them in order.

**Recommendation for v0.1:** Add an optional `depends_on` field to the project schema:

```yaml
projects:
  olam:
    path: "./olam"
    depends_on: []

  pleri:
    path: "./pleri"
    depends_on: ["olam"]
```

The `/dk:run` and workspace steward can use this to determine execution order. For v0.1, this is informational -- the steward reports the dependency order. For v0.2, `/dk:run` could start projects in topological order with health checks between stages.

**Important caveat:** Service dependencies create a runtime dependency graph that is different from the build dependency graph (pnpm `workspace:*` references). The schema should keep them separate:
- `depends_on` = "this project needs that project *running*"
- pnpm `workspace:*` = "this package needs that package *built*" (handled by pnpm, not Diakon)

---

## 7. Risk Analysis

### 7.1 High Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| workspace.yaml corruption from partial write | High | Implement `dk_safe_write` (write-then-rename) pattern |
| awk parser breaks on unexpected YAML syntax | High | Document schema constraints explicitly; add yq fallback path |
| Secret value leaked in Claude context window | High | Already mitigated with warnings in `/dk:secret-get`; consider adding a `--clipboard` mode that copies to clipboard without displaying |

### 7.2 Medium Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Schema outgrows awk parser (nested fields, multi-line values) | Medium | Plan for yq from v0.2; keep schema flat in v0.1 |
| `dk_project_field` matches wrong field in nested blocks | Medium | Add dotpath support or restrict field extraction to direct children only |
| sops command-line argument exposes secret in process list | Medium | Documented in pseudocode; acceptable for dev workstation use |
| No rollback for failed `/dk:add` or `/dk:remove` | Medium | Add `workspace.yaml.bak` before mutations |

### 7.3 Low Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Two Claude sessions modify workspace.yaml concurrently | Low | Document single-writer assumption; advisory file lock in v0.2 |
| `sed -i ''` syntax is macOS-specific (GNU sed uses `-i` without `''`) | Low | The helpers doc mentions bash 3.2+ compatibility but `sed -i` portability is a known landmine. Use `awk` for all mutations or detect the platform. |
| Plugin registration changes in future Claude Code versions | Low | Plugin spec is versioned; monitor for breaking changes |

---

## 8. Compliance Check

### 8.1 SOLID Principles

| Principle | Assessment |
|-----------|-----------|
| **Single Responsibility** | Each skill does one thing. The steward agent handles composition. Clean separation. |
| **Open/Closed** | The `meta` block allows extension without modifying the schema. Skills are independent files -- adding a new skill does not modify existing ones. |
| **Liskov Substitution** | N/A for a skill-based system (no type hierarchy). |
| **Interface Segregation** | Each skill reads only the workspace.yaml fields it needs. No skill is forced to deal with irrelevant data. |
| **Dependency Inversion** | Skills depend on the abstract workspace.yaml schema, not on specific project implementations. Shell helpers provide an abstraction layer over raw awk parsing. |

### 8.2 Architectural Pattern Consistency

The "skills as instructions, Claude as executor" pattern is applied consistently across all 13+ skills. No skill breaks this pattern by embedding executable code. The shell helpers are the only executable component, and they are purely data-access functions (read-only parsing of workspace.yaml).

### 8.3 Boundary Violations

No boundary violations detected. Skills do not directly import or depend on each other. The steward agent composes skills by invoking them through Claude, not by importing their logic.

---

## 9. Recommendations Summary

### Must-Have for v0.1

1. **Implement `dk_safe_write` pattern.** Write-then-rename for all workspace.yaml mutations. This is a data integrity issue.
2. **Document schema constraints explicitly.** Create a `wiki/09-schema-constraints.md` that lists what YAML features are and are not supported.
3. **Add backup before mutation.** Copy workspace.yaml to workspace.yaml.bak before any /dk:add, /dk:remove, or /dk:check --fix operation.
4. **Formalize the `meta` block.** Document it as the official user extension point in the schema.
5. **Add version checking.** `dk_check_version` function that skills call at startup.

### Should-Have for v0.1

6. **Add `/dk:env` skill.** Generate `.env` files from secrets for a specific project. This completes the secrets workflow.
7. **Add `depends_on` field.** Even if v0.1 only uses it for display, the field should be in the schema from the start.
8. **Add `commands` block.** Per-project build/dev/test commands, so `/dk:run build` does the right thing without guessing.
9. **Validate installed tool versions in `/dk:check`.** Compare actual `node -v` and `pnpm -v` against declared versions.

### Nice-to-Have for v0.2

10. **yq as optional dependency.** `dk_parse_yaml` function that uses yq when available, awk fallback.
11. **`/dk:ci-matrix` skill.** Generate GitHub Actions matrix from workspace.yaml.
12. **Environment profiles.** Secret scoping by environment name.
13. **Docker/container health in `/dk:check`.** For projects with `runtime` configuration.
14. **Advisory file locking.** Prevent concurrent workspace.yaml modifications.

### Deferred (v0.3+)

15. **Full dependency graph modeling.** Build order from pnpm workspace deps + runtime deps.
16. **Service startup orchestration.** Start projects in dependency order with health checks.
17. **Migration system.** `dk:migrate` skill for schema version upgrades.

---

## 10. Final Assessment

Diakon's architecture is sound. The "no MCP server" decision is correct for the current feature set. YAML is the right registry format. The skill-based design is clean, extensible, and consistent. The shell helpers are pragmatic and the schema constraints that enable awk parsing are well-thought-out.

The primary risks are data integrity (non-atomic workspace.yaml writes) and parser fragility (awk on YAML). Both have clear mitigations. The dog-fooding gaps for ein-sof are real but manageable -- most gaps are additive schema fields rather than architectural changes.

The design is ready for implementation with the must-have recommendations above incorporated.
