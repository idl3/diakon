---
name: "dk:wiki"
description: "Query the workspace wiki. Ask anything about any project. Use when user says 'wiki', 'look up in wiki', 'how does X work', 'what is Y'."
argument-hint: "<question> [--project <name>] [--list] [--index]"
user-invocable: true
---

# Query Workspace Wiki

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

### 1. Verify workspace

Run `dk_workspace_root` to get the workspace root. Confirm `.diakon/workspace.yaml` exists.

### 2. Parse arguments

- `--list`: list all wiki articles across all projects
- `--index`: show unified table of contents from all wiki indexes
- `--project <name>`: scope search to one project's wiki only
- Everything else: treated as a free-form question

### 3. Mode: `--list`

Scan all projects for wiki directories. For each project with a wiki, list all `.md` files.

Format as a table:

```
Workspace Wiki Articles
─────────────────────────────────────────────────────

Project   #   Article                         Path
────────  ──  ──────────────────────────────  ────────────────────────────
diakon    1   What is Diakon                  diakon/wiki/01-what-is-diakon.md
diakon    2   Architecture                    diakon/wiki/02-architecture.md
diakon    3   Workspace Model                 diakon/wiki/03-workspace-model.md
...
olam      1   Overview                        olam/wiki/overview.md
...
```

Also include the root wiki if it exists at `<workspace-root>/wiki/`:

```
(root)    1   The Thesis                      wiki/00-the-thesis.md
(root)    2   What is Ein-Sof                 wiki/01-what-is-ein-sof.md
...
```

Sort by project name, then by filename.

### 4. Mode: `--index`

For each project with a wiki, read its `index.md` (or `README.md`). Extract the article list. Also read the root wiki `README.md`.

Format as a unified table of contents:

```
Workspace Wiki Index
─────────────────────────────────────────────────────

Root Wiki (ein-sof)
  1. The Thesis
  2. What is Ein-Sof
  3. The Stack
  ...

diakon/wiki/
  1. What is Diakon
  2. Architecture
  3. Workspace Model
  ...

olam/wiki/
  1. Overview
  2. ...
```

### 5. Mode: Free-form question

#### 5a. Route by keyword

Extract keywords from the question. If the question mentions a known project name (olam, aether, pleri, diakon), prioritize that project's wiki. If `--project` was specified, restrict to that project only.

#### 5b. Search wiki content

Use Grep to search across all wiki directories for keywords from the question:

- Search `<workspace-root>/wiki/` (root wiki)
- Search `<workspace-root>/*/wiki/` (project wikis)
- Search `<workspace-root>/*/docs/wiki/` (alternate wiki locations)

If `--project` is set, restrict to that project's wiki only.

#### 5c. Read matching files

Read the top 5-8 files with the most keyword matches. Prioritize:
1. Files where the keyword appears in the title (first `#` heading)
2. Files where the keyword appears multiple times
3. Files in the most relevant project (if question mentions a project)

#### 5d. Synthesize answer

Compose an answer from the wiki content. Follow these rules:
- Answer the question directly, do not just list sources
- Cite sources inline: "According to `olam/wiki/overview.md`..."
- Quote relevant passages when they directly answer the question
- If multiple wiki articles contribute, synthesize across them
- If wiki content is incomplete for the question, say so explicitly

#### 5e. File substantial answers as wiki pages

After synthesizing an answer, if the answer is substantial (>200 words and draws from 3+ source files), offer to file it as a new wiki page:

```
This answer could be filed as a new wiki page.
File as wiki/<suggested-kebab-name>.md? (y/N)
```

If the user accepts:
1. Determine which project the answer most relates to (or root wiki if cross-project)
2. Create the page with proper frontmatter:
   ```markdown
   ---
   title: "<Title derived from question>"
   summary: "<One-line summary of the answer>"
   updated: "<YYYY-MM-DD>"
   confidence: "medium"
   sources: ["<list of source files used>"]
   ---
   ```
3. Write the synthesized answer as the page body, preserving inline citations
4. Update `wiki/index.md` -- add the new article to the article table
5. Append to `wiki/log.md`: `## [YYYY-MM-DD] query-filed | <Title>`
6. Report: `Filed as <project>/wiki/<filename>.md and updated index.`

#### 5f. Sources table

End every answer with a sources table:

```
Sources
─────────────────────────────────────────────────────

File                              Relevance
────────────────────────────────  ─────────
diakon/wiki/02-architecture.md    High -- describes the data model
diakon/wiki/05-skills-anatomy.md  Medium -- explains skill execution
wiki/07-diakon.md                 Low -- overview only
```

### 6. No matches

If Grep finds no matching content:

```
No wiki coverage found for "<question>".

This topic could be documented in:
  - <project>/wiki/<suggested-filename>.md (if project-specific)
  - wiki/<suggested-number>-<slug>.md (if cross-project)

To create a wiki article, use /dk:wiki-init to scaffold a wiki first.
```

Suggest a concrete filename based on the question keywords.
