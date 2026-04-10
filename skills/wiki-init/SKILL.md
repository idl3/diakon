---
name: "dk:wiki-init"
description: "Initialize a Karpathy-style wiki for a project or the workspace. Use when the user says 'create wiki', 'init wiki', 'setup wiki'."
argument-hint: "[project-name | --all]"
user-invocable: true
---

# Initialize Project Wiki (Karpathy Three-Layer Architecture)

Source the helpers:
```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/dk-helpers.sh"
```

## Workflow

### 1. Verify workspace

Run `dk_workspace_root` to confirm we are inside a Diakon workspace. If not, abort with an error.

### 2. Parse arguments

- If argument is `--all`: target every enabled project (via `dk_enabled_projects`)
- If argument is a project name: validate with `dk_validate_project_name`, confirm it exists via `dk_list_projects`
- If no argument: target only the project whose directory we are currently inside (match CWD against project paths). If CWD is the workspace root, ask the user to specify a project or pass `--all`.

### 3. For each target project, detect existing wiki

Resolve the project's absolute path via `dk_project_abs_path`. Then check for an existing wiki:

```bash
# Check in order of precedence
if [[ -d "$abs_path/wiki" ]]; then
  wiki_path="$abs_path/wiki"
  wiki_style="wiki/"
elif [[ -d "$abs_path/docs/wiki" ]]; then
  wiki_path="$abs_path/docs/wiki"
  wiki_style="docs/wiki/"
else
  wiki_path=""
fi
```

If a wiki directory is found, count `.md` files inside it:
```bash
article_count=$(find "$wiki_path" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')
```

Detect style:
- If files use numbered prefixes (`01-`, `02-`): style is "numbered"
- If files are in subdirectories with `index.md`: style is "concept-dirs"
- Otherwise: style is "flat"

### 4. If wiki EXISTS

Report: `"Wiki exists at <relative-path> with N articles (style: <style>). Skipping."`

Do NOT modify or overwrite anything.

### 5. If wiki does NOT exist -- scaffold Karpathy three-layer architecture

Create the three-layer directory structure:

```bash
mkdir -p "$abs_path/sources"
touch "$abs_path/sources/.gitkeep"
mkdir -p "$abs_path/wiki"
```

#### 5a. Create `.wiki-schema.md`

Use Write tool to create `$abs_path/.wiki-schema.md`:

```markdown
# Wiki Schema

## Three Layers
- `sources/` -- raw immutable documents. Drop files here for ingestion.
- `wiki/` -- LLM-generated pages. The LLM owns these entirely.
- `.wiki-schema.md` -- this file. Defines conventions.

## Conventions
- Every wiki page gets YAML frontmatter: title, summary, updated, confidence, sources
- `index.md` is the master catalog -- update it on every ingest
- `log.md` is append-only -- add entry for every wiki operation
- File names: lowercase-kebab-case.md
- Cross-references: use relative markdown links [text](file.md)

## Page Template
\`\`\`markdown
---
title: "Page Title"
summary: "One-line summary"
updated: "YYYY-MM-DD"
confidence: "high|medium|low|seed"
sources: ["source-filename.md"]
---

# Page Title

Content here.
\`\`\`

## Categories
- concepts/ -- core ideas
- architecture/ -- design decisions
- guides/ -- how-to
- reference/ -- API, config, schemas

## Confidence Levels

| Value | Meaning |
|-------|---------|
| `seed` | Initial scaffold, needs real content |
| `low` | Written but unverified |
| `medium` | Reviewed, believed accurate |
| `high` | Verified against sources, well-cited |
| `log` | Append-only log, not a concept page |
```

#### 5b. Create `wiki/index.md` (Karpathy-style content catalog)

Use Write tool to create `$abs_path/wiki/index.md`:

```markdown
---
title: "<Project Name> Wiki"
updated: "<YYYY-MM-DD>"
---

# <Project Name> Wiki

LLM-maintained knowledge base. Each page explains one concept from scratch.

## Articles

| # | Article | Summary | Updated | Sources |
|---|---------|---------|---------|---------|
| 1 | [Overview](overview.md) | What this project is | <YYYY-MM-DD> | 0 |

## Categories

- **Concepts**: core ideas and mental models
- **Architecture**: system design decisions
- **Guides**: how-to articles
- **Reference**: API and config reference
```

Replace `<Project Name>` with the project name (capitalized) and `<YYYY-MM-DD>` with today's date.

#### 5c. Create `wiki/log.md` (Karpathy-style chronological log)

Use Write tool to create `$abs_path/wiki/log.md`:

```markdown
# Wiki Log

Chronological record of wiki activity. Newest entries at the top.

## [<YYYY-MM-DD>] init | Wiki initialized

Scaffolded wiki with index.md and log.md. Ready for first source ingest.
```

Replace `<YYYY-MM-DD>` with today's date.

#### 5d. Create `wiki/overview.md`

Check if a root wiki gateway article exists for this project. The root wiki lives at `<workspace-root>/wiki/`. Known gateway mappings:

| Project | Gateway Article |
|---------|----------------|
| olam | `wiki/03-olam.md` |
| aether | `wiki/05-aether.md` |
| pleri | `wiki/06-pleri.md` |
| diakon | `wiki/07-diakon.md` |

If a gateway article exists:
- Read it
- Extract the first 2-3 paragraphs (skip the title line) as the overview body
- Attribute: "Seeded from root wiki gateway: `wiki/<filename>`"

If no gateway article exists, write a placeholder overview:

```markdown
---
title: "<Project Name> Overview"
summary: "What <project-name> is, why it exists, and how it fits in the workspace."
updated: "<YYYY-MM-DD>"
confidence: "seed"
sources: []
---

# <Project Name>

TODO: Describe what this project is, the problem it solves, and its role in the workspace.
```

### 6. Report results

Print a summary table:

```
dk:wiki-init Results
─────────────────────────────────────────────────────

Project     Status    Articles  Path
──────────  ────────  ────────  ──────────────────────
aether      CREATED   3         aether/wiki/
olam        EXISTS    8         olam/wiki/
pleri       CREATED   3         pleri/wiki/
diakon      SKIPPED   --        (not targeted)
```

Status values:
- `CREATED` -- new wiki scaffolded (three-layer: sources/, wiki/, .wiki-schema.md)
- `EXISTS` -- wiki already present, not modified
- `SKIPPED` -- project not in target list

After the table, note the three-layer structure:
```
Three-layer structure scaffolded:
  sources/          Raw documents (immutable, never modified by LLM)
  wiki/             LLM-generated knowledge base
  .wiki-schema.md   Conventions, categories, page templates

Next steps:
  1. Drop source documents into sources/
  2. Run /dk:wiki-ingest <source-path> to process them
  3. Run /dk:wiki to query the knowledge base
```
