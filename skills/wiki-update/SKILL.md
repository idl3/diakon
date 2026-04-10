---
name: "dk:wiki-update"
description: "Sync workspace wiki with project wikis. Reads project wikis, updates root gateway articles, lints wikis, maintains indexes. Use when user says 'update wiki', 'sync wiki', 'refresh docs'."
argument-hint: "[--pull] [--dry-run]"
user-invocable: true
---

# Sync Wiki: Project Wikis to Root Gateway + Maintenance

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

### 1. Verify workspace

Run `dk_workspace_root` to get the workspace root. Confirm `.diakon/workspace.yaml` exists.

### 2. Parse flags

- `--pull`: before syncing, run `git pull --ff-only` in each project directory
- `--dry-run`: compute all changes but do not write any files; show what would change

### 3. Optional: pull latest

If `--pull` is set, for each enabled project (via `dk_enabled_projects`):

```bash
git -C "$abs_path" pull --ff-only 2>&1
```

Run all pulls in parallel. Report any failures but continue.

### 4. Build wiki registry

For each enabled project, detect its wiki path and count articles:

```bash
for project in $(dk_enabled_projects); do
  abs_path="$(dk_project_abs_path "$project")"
  if [[ -d "$abs_path/wiki" ]]; then
    wiki_path="$abs_path/wiki"
  elif [[ -d "$abs_path/docs/wiki" ]]; then
    wiki_path="$abs_path/docs/wiki"
  else
    wiki_path=""
  fi
  if [[ -n "$wiki_path" ]]; then
    article_count=$(find "$wiki_path" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
  fi
done
```

### 5. Gateway article mapping

The root wiki lives at `<workspace-root>/wiki/`. Each project has a gateway article:

| Project | Gateway Article |
|---------|----------------|
| olam | `wiki/03-olam.md` |
| aether | `wiki/05-aether.md` |
| pleri | `wiki/06-pleri.md` |
| diakon | `wiki/07-diakon.md` |

If a project is not in this table, skip it (no gateway article to update).

### 6. For each project with a wiki, compare and sync

For each project that has both a wiki AND a gateway article:

**Read project wiki data:**
- Read `<project>/wiki/index.md` (or `README.md`) for the article list
- Read `<project>/wiki/overview.md` for the current description

**Read root gateway article:**
- Read the gateway file (e.g., `wiki/07-diakon.md`)

**Compare:**
- Does the gateway overview text match the project overview? (First 2-3 paragraphs)
- Does the gateway link to all articles listed in the project wiki index?
- Does the gateway "At a Glance" table reflect the current article count?

**If update needed, rewrite the gateway article in this format:**

```markdown
# <Project Name> -- <Tagline>

<2-3 paragraph overview drawn from the project wiki overview>

## At a Glance

| Attribute | Value |
|-----------|-------|
| Wiki | `<project>/wiki/` |
| Articles | <count> |
| Key Topics | <comma-separated from wiki index> |

## Key Concepts

- **<Concept 1>** -- <one-line summary> (see `<project>/wiki/<file>`)
- **<Concept 2>** -- <one-line summary> (see `<project>/wiki/<file>`)
- ...

## Deep Dive

Full documentation lives in the project wiki:

| # | Article | Summary |
|---|---------|---------|
| 1 | [<title>](<project>/wiki/<file>) | <summary> |
| 2 | ... | ... |

## Next

<links to related root wiki articles>

For <project>'s own documentation: `<project>/wiki/`, `<project>/CLAUDE.md`.
```

### 7. Lint each project wiki

After syncing gateways, run a lightweight lint pass on each project wiki:

**Index completeness**: List all `.md` files in `wiki/` (excluding `index.md` and `log.md`). Check each is listed in the article table in `index.md`. Report any missing.

**Orphan detection**: Check for `.md` files in `wiki/` that are not referenced from `index.md`.

**Stale dates**: Read frontmatter `updated` field from each article. Flag any older than 30 days.

**Article count**: Verify the article count in `index.md` matches the actual file count.

**Source coverage**: If `sources/` directory exists, check for files in `sources/` that have no corresponding wiki article (no article lists the source filename in its `sources` frontmatter).

If issues found and NOT `--dry-run`:
- Add missing articles to `index.md` with placeholder summaries
- Update article count metadata in `index.md`

### 8. Append maintenance log entry

After all syncing and linting, append to each updated project's `wiki/log.md`:

```markdown
## [YYYY-MM-DD] update | Gateway sync + maintenance

- Synced gateway article wiki/<gateway-file>
- Lint: <N> issues found, <M> auto-fixed
- Articles: <count> total
```

### 9. Dry-run mode

If `--dry-run`: for each gateway article that would change, show a diff-style summary:

```
wiki/07-diakon.md:
  + Would add 3 new article links
  ~ Would update overview paragraph
  = "At a Glance" table already current

diakon/wiki/ lint:
  ⚠ 1 orphan page not in index
  ⚠ 2 articles with stale dates
  ✓ Source coverage OK
```

Do NOT write any files.

### 10. Write mode (default)

Use the Write tool to update each gateway article. Preserve any content below a `## Next` heading or similar cross-reference sections that link to other root wiki articles.

### 11. Report

Print a summary table:

```
dk:wiki-update Results
─────────────────────────────────────────────────────

Article                Status    Changes
─────────────────────  ────────  ──────────────────────
wiki/03-olam.md        UPDATED   +2 article links, overview refreshed
wiki/05-aether.md      OK        no changes needed
wiki/06-pleri.md       UPDATED   overview refreshed
wiki/07-diakon.md      UPDATED   +3 article links, At a Glance updated

Lint Results
─────────────────────────────────────────────────────

Project   Index   Orphans  Stale   Sources
────────  ──────  ───────  ──────  ───────
olam      10/10   0        2       1 uningest
aether    5/5     0        0       0
pleri     3/3     1        0       0
diakon    12/12   0        3       0
```

Status values:
- `UPDATED` -- gateway article rewritten
- `OK` -- gateway article already current
- `SKIPPED` -- project has no wiki or no gateway article
- `DRY-RUN` -- changes identified but not written
