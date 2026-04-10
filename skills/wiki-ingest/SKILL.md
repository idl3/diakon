---
name: "dk:wiki-ingest"
description: "Ingest a source into a project wiki. Reads the source, writes a summary page, updates relevant wiki pages, updates index, appends log. Use when user says 'ingest', 'add to wiki', 'process this document'."
argument-hint: "<source-path> [--project <name>]"
user-invocable: true
---

# Ingest Source into Project Wiki

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

### 1. Verify workspace

Run `dk_workspace_root` to get the workspace root. Confirm `.diakon/workspace.yaml` exists.

### 2. Resolve source path

The first positional argument is the source path. It must be a file -- markdown, text, PDF, or a URL.

- If a relative path, resolve against CWD
- Verify the file exists (use `test -f` or Read tool)
- If the path is a URL, fetch the content first (save to a temp file, then treat as a local file for the rest of the workflow)
- Extract a human-readable title from the source: use the first `# heading` if markdown, or the filename (sans extension, de-kebab-cased) otherwise

### 3. Determine target project

Resolution order:
1. If `--project <name>` is given, use that project (validate with `dk_validate_project_name`)
2. If the source path is inside a project directory, use that project
3. If CWD is inside a project directory, use that project
4. Otherwise, ask the user to specify with `--project`

### 4. Verify project has a wiki

Check for `<project>/wiki/index.md`. If it does not exist:

```
Project '<name>' has no wiki. Run /dk:wiki-init <name> first.
```

Abort.

Also verify `<project>/sources/` exists. If not, create it:
```bash
mkdir -p "$abs_path/sources"
```

### 5. Read the source

Read the full content of the source file. For large files (>500 lines), read in chunks and summarize progressively.

Extract from the source:
- **Title**: first heading or filename
- **Key concepts**: major ideas, terms, entities mentioned
- **Relationships**: references to other known concepts in the wiki
- **Facts and claims**: concrete statements that should be captured

### 6. Copy source to `<project>/sources/`

If the source file is not already inside `<project>/sources/`:

```bash
cp "$source_path" "$abs_path/sources/"
```

The `sources/` directory is an immutable archive. Files placed here are never modified by the LLM.

If a file with the same name already exists in `sources/`, append a timestamp suffix:
```bash
cp "$source_path" "$abs_path/sources/${basename%.md}-$(date +%Y%m%d).md"
```

### 7. Write summary page

Create a new wiki page at `wiki/<kebab-title>.md` where `<kebab-title>` is the source title converted to lowercase-kebab-case.

Use Write tool to create the page:

```markdown
---
title: "<Source Title>"
summary: "<One-line summary of the source>"
updated: "<YYYY-MM-DD>"
confidence: "medium"
sources: ["<source-filename>"]
---

# <Source Title>

## Summary

<2-4 paragraph summary of the source document>

## Key Takeaways

- <Takeaway 1>
- <Takeaway 2>
- <Takeaway 3>
- ...

## Concepts

<For each major concept/entity extracted from the source, a brief paragraph explaining it>

## Cross-References

- [<Related wiki page>](<filename>.md) -- <how it relates>
- ...
```

### 8. Update existing wiki pages

This is the core Karpathy insight: "Single sources typically touch 10-15 wiki pages."

Read `wiki/index.md` to get the list of existing articles. For each existing article:

1. Read the article
2. Determine if the new source is relevant to it (shared concepts, contradictory claims, additional context)
3. If relevant, update the article:
   - Add a new section or expand existing sections with information from the source
   - Add the source filename to the article's `sources` frontmatter list
   - Update the `updated` frontmatter date
   - Add cross-references to the new summary page
   - If the source contradicts existing content, note the contradiction explicitly

Do NOT update articles where the source has no meaningful connection. Quality over quantity -- but a meaty source document should realistically touch many pages.

### 9. Update `wiki/index.md`

Add the new summary article to the article table in `index.md`:

```markdown
| <next-number> | [<Title>](<kebab-title>.md) | <One-line summary> | <YYYY-MM-DD> | 1 |
```

Also update the `Sources` count for any existing articles that were modified in step 8.

Update the `updated` date in the index frontmatter.

### 10. Append to `wiki/log.md`

Add a new entry at the top of the log (below the `# Wiki Log` heading):

```markdown
## [YYYY-MM-DD] ingest | <Source Title>

Source: `sources/<filename>`
New page: `wiki/<kebab-title>.md`
Updated pages: <comma-separated list of modified article filenames>
```

### 11. Report

Print a summary:

```
dk:wiki-ingest Results
─────────────────────────────────────────────────────

Source:     <source-filename>
Project:   <project-name>
Archived:  sources/<filename>

New Pages
─────────────────────────────────────────────────────
  wiki/<kebab-title>.md    <one-line summary>

Updated Pages
─────────────────────────────────────────────────────
  wiki/overview.md         Added section on <topic>
  wiki/architecture.md     Updated <section> with new context
  wiki/concepts.md         Added cross-reference
  ...

Index:  Updated (<total> articles)
Log:    Entry appended
```
