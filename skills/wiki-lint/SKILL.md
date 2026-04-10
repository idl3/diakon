---
name: "dk:wiki-lint"
description: "Health-check project wikis for contradictions, stale claims, orphan pages, missing cross-references. Use when user says 'lint wiki', 'check wiki health', 'wiki quality'."
argument-hint: "[--project <name>] [--fix]"
user-invocable: true
---

# Lint Project Wikis

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

### 1. Verify workspace

Run `dk_workspace_root` to get the workspace root. Confirm `.diakon/workspace.yaml` exists.

### 2. Determine scope

- If `--project <name>` is given: lint only that project's wiki
- Otherwise: lint every enabled project that has a `wiki/` directory

### 3. For each project wiki, run all checks

Resolve the project's absolute path via `dk_project_abs_path`. Locate the wiki at `$abs_path/wiki/`.

#### 3a. Index completeness

List all `.md` files in `wiki/` (excluding `index.md` and `log.md`). Read `wiki/index.md` and extract the article table. Check that every `.md` file appears in the index.

Result: `N/M articles listed` (where N = listed, M = total files)

#### 3b. Orphan pages

Inverse of index completeness: find `.md` files in `wiki/` that are NOT referenced from `index.md` (not in the article table, not linked from any other line).

Result: list of orphan filenames, or "0 orphan pages"

#### 3c. Dead links

Scan all `.md` files in `wiki/` for markdown links in the format `[text](file.md)`. For each link:
- Check if the target file exists (relative to `wiki/`)
- Check if the target file exists (relative to project root)

Result: list of broken links with source file and line number, or "0 broken links"

#### 3d. Stale dates

Read frontmatter `updated` field from each article. Flag any where the date is more than 30 days before today.

Result: count of stale articles with their filenames and last-updated dates

#### 3e. Missing frontmatter

Check each `.md` file in `wiki/` (excluding `log.md`) for required YAML frontmatter fields:
- `title` -- required
- `summary` -- required
- `updated` -- required
- `confidence` -- optional but recommended

Result: list of files missing required fields

#### 3f. Source coverage

If `<project>/sources/` exists and contains files:
- List all files in `sources/`
- For each source file, check if any wiki article lists it in its `sources` frontmatter field
- A source file with no corresponding wiki article is "uningested"

Result: count of uningested source files with their filenames

#### 3g. Cross-reference density

For each article in `wiki/`, count how many OTHER articles link to it (inbound links). Flag articles with zero inbound links (excluding `index.md`, `log.md`, and `overview.md` which are entry points).

Result: count of articles with zero inbound links

### 4. Auto-fix mode (`--fix`)

If `--fix` is passed, automatically fix what is safe to fix:

**Add missing index entries**: For orphan pages, read their frontmatter and add them to the article table in `index.md` with:
- Next sequential number
- Title from frontmatter (or first `#` heading)
- Summary from frontmatter (or "TODO: add summary")
- Today's date
- Source count from frontmatter

**Update stale dates**: For articles that have been modified in git more recently than their `updated` frontmatter, update the frontmatter date to the git modification date:
```bash
git log -1 --format=%cs -- "$file"
```

**Add missing frontmatter**: For files without required frontmatter, add a minimal frontmatter block using the first heading as title and "TODO" for summary.

**Update index metadata**: Update the `updated` date in `index.md` frontmatter to today.

Do NOT auto-fix:
- Dead links (requires human judgment on correct target)
- Cross-reference density (requires human judgment on which links to add)
- Source coverage (requires full ingest workflow via `/dk:wiki-ingest`)

### 5. Report

Print a per-project report:

```
dk:wiki-lint Results
─────────────────────────────────────────────────────
Project: olam (wiki/)

  ✓ Index completeness     10/10 articles listed
  ⚠ Stale dates            3 articles >30d old
  ✓ Dead links             0 broken links
  ⚠ Orphan pages           1 file not in index: old-draft.md
  ✓ Frontmatter            All articles have required fields
  ⚠ Uningested sources     2 files in sources/ not yet ingested
  ✓ Cross-references       All articles have ≥1 inbound link

─────────────────────────────────────────────────────
Project: diakon (wiki/)

  ✓ Index completeness     12/12 articles listed
  ✓ Stale dates            0 articles >30d old
  ✓ Dead links             0 broken links
  ✓ Orphan pages           0 orphan pages
  ⚠ Frontmatter            2 articles missing 'summary'
  ✓ Source coverage         No sources/ directory
  ⚠ Cross-references       1 article with 0 inbound links

─────────────────────────────────────────────────────
Summary: 4 projects checked, 6 issues found (2 auto-fixed)
```

Symbols:
- `✓` -- check passed
- `⚠` -- issue found (with detail)
- `✗` -- critical issue (e.g., index.md missing entirely)

If `--fix` was used, append:
```
Auto-fixed:
  - Added 1 missing index entry in olam/wiki/index.md
  - Updated 2 stale dates in diakon/wiki/
```
