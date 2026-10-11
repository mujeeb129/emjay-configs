---
name: emjay-map
description: Map an existing codebase and write a single self-contained HTML onboarding guide for new developers — architecture, main entry points, flowcharts and sequence diagrams of key flows, DB schemas, config, dev workflow and a reading list. Use when the user runs /emjay-map, or asks for an onboarding doc, codebase map, architecture overview or "explain this repo to a new dev" document.
argument-hint: "[path to repo or sub-directory] [focus areas, e.g. 'billing flow, auth']"
---

# emjay-map — codebase → HTML onboarding guide

You map the codebase that exists **today** and produce **one self-contained
HTML document** a developer in their first week can read top to bottom. You are
documenting, not changing: don't edit product code.

The look follows the `emjay-plan` skill's template; this skill ships its own
`template.html` with the same head, palette and components but onboarding
sections.

## 1. Scope

- Root: a path in `$ARGUMENTS` if given, else `git rev-parse --show-toplevel`.
- Focus: any feature/area names in `$ARGUMENTS` get their own flow in
  section 06. Without them, pick the 2–4 flows a newcomer will touch first.
- Record for the header: repo name, `git rev-parse --short HEAD`, branch,
  today's date, author (`git config user.name`).

## 2. Recon (breadth first, cheap commands)

Work inline. For a very large repo you may hand **one** narrow, mechanical
chunk (e.g. "list every ORM model class with its file:line") to a single
`Explore` agent with `model: "haiku"`; never fan out to several agents.

Read in this order, stopping each step once you have the picture:

1. **Self-description** — `README*`, `CLAUDE.md`/`AGENTS.md`, `docs/`,
   `CONTRIBUTING*`, ADRs. Treat them as claims to verify, not facts.
2. **Shape** — `git ls-files | head -400`, a per-directory file count
   (`git ls-files | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -40`),
   language mix by extension, and `git log --oneline -15` for recent activity.
3. **Manifests & tooling** — `package.json`, `pyproject.toml`/`requirements*`,
   `go.mod`, `Cargo.toml`, `pom.xml`/`build.gradle`, `Gemfile`, `composer.json`,
   `Makefile`/`justfile`/`Taskfile`, `Dockerfile*`, `docker-compose*`,
   `Procfile`, CI (`.github/workflows`, `.gitlab-ci.yml`), k8s/helm/terraform.
4. **Entry points** — look for each kind and record `file:line`:
   - binaries/CLIs: `bin`/`main`/`scripts` in package.json, `[project.scripts]`,
     `func main()`/`cmd/*/main.go`, `if __name__ == "__main__"`, `fn main`,
     executable files with a shebang, install/setup scripts
   - servers: app/router construction (`express()`, `FastAPI()`, `Flask(`,
     Django `urls.py`/`wsgi.py`/`asgi.py`, `http.ListenAndServe`, Spring
     `@SpringBootApplication`, Rails `routes.rb`)
   - workers, consumers, cron/scheduled jobs, serverless handlers, migrations
   - what actually starts in prod: Dockerfile `CMD`/`ENTRYPOINT`, Procfile,
     compose `command`, k8s container `args`
   - for libraries/plugins/themes: the file the host loads and the hooks it
     registers
5. **Data** — migrations (`migrations/`, `alembic/`, `db/migrate/`,
   `prisma/schema.prisma`, `*.sql`), ORM models (SQLAlchemy/Django models,
   TypeORM/Sequelize entities, GORM structs, Mongoose schemas, ActiveRecord),
   caches/queues/object stores. Prefer the latest schema state (models or a
   schema dump) over replaying every migration.
6. **Config** — env var reads (`process.env`, `os.environ`/`getenv`,
   `os.Getenv`, `ENV[`), `.env.example`, settings modules, feature flags,
   user-facing options.
7. **Tests** — layout, runner, how to run one test, fixtures.

Use `grep -rn` / `git grep -n` to locate things; read excerpts, not whole
large files.

## 3. Trace

- For each entry point, follow the happy path through the code until it hits
  I/O (HTTP response, DB, file, terminal output). Note each hop as `file:line`.
- For each chosen flow, capture: trigger, the ordered hops, side effects
  (writes, events, external calls), and where errors are handled.
- Name components after what the code calls them (module/package/class
  names), not invented labels.
- **Don't invent.** Every architectural claim, table, column and env var must
  be traceable to a file. Anything you infer but can't confirm, or that the
  code contradicts in the docs, goes into Open questions.

## 4. Content

Fill the template's sections in order. Skip a sub-part that genuinely
doesn't apply (say so in one line) rather than padding.

1. **Overview** — 2–4 sentences: what the system does, for whom, how it runs.
   At-a-glance chips: primary language(s), file count, LOC (rough, via
   `git ls-files | xargs wc -l` on source files), runtime/deploy target.
2. **Tech stack** — table `Layer | Technology | Version | Where`.
3. **Repository map** — annotated directory tree (2–3 levels, only folders and
   files that matter), each with a short `# comment`.
4. **Architecture** — Mermaid `flowchart` of components, external systems and
   data stores (hand-built `border-l-4` layer bands if the system is clearly
   layered). Then component cards: name, responsibility, key files, what it
   talks to.
5. **Entry points** — table `Entry point | Kind | Location | What it does |
   How to run`, then a numbered boot/startup sequence for the main one.
6. **Key flows** — per flow: a Mermaid `flowchart TD` of control flow
   (decisions as `{…}` diamonds, error branches in red) **and** a
   `sequenceDiagram` across components/external systems, followed by an
   ordered list of hops with `file:line` refs.
7. **Data model** — Mermaid `erDiagram`; one card per table/collection with
   `Column | Type | Null | Default | Constraints / notes` and indexes; where
   the schema lives and how migrations run. If there's no database, say so in
   one line and list the state the system does keep (files, caches, env,
   in-memory) in the state-stores table instead.
8. **Configuration** — table `Setting | Default | Read at | Effect`.
9. **Dev workflow** — setup, run, test, lint/format, build, deploy commands
   (copy-pasteable, verified against manifests/CI), and the test layout.
10. **Conventions & gotchas** — naming, error handling, logging, code style,
    non-obvious traps (amber callouts for traps).
11. **Start here** — ordered reading list of 5–10 files with one line on why
    each, in the order a newcomer should open them.
12. **Glossary** — domain terms and project-specific jargon.
13. **Open questions** — table `# | Question | Why it matters | Where to look`.

## 5. Write the HTML

- Start from `template.html` in this skill's directory
  (`${CLAUDE_SKILL_DIR}/template.html`). Keep its structure, Tailwind classes
  and `dark:` variants; replace `{{…}}` placeholders and sample rows/cards;
  delete samples you don't use (and their nav link if a section is removed).
  Keep the Tailwind and Mermaid script tags as is.
- Escape `<`, `>` and `&` in code blocks, tree, and table cells.
- **Code references** use the template's ref link:
  `<a class="ref" data-ref="path/to/file.ext:42" href="…">file.ext:42</a>`.
  `data-ref` is always the repo-relative `path[:line[-end]]`. For `href`: if
  `origin` is GitHub/GitLab, link to the blob at the HEAD SHA
  (`…/blob/<sha>/<path>#L42`); otherwise a path relative to the output file
  (e.g. `../../src/app.ts`).
- **Mermaid hygiene**: quote labels with punctuation (`A["parse()"]`), don't
  use `end` as a node id, use `#quot;` for quotes inside labels, keep each
  diagram ≲ 15 nodes — split rather than cram. `classDef` for emphasis:
  entry points indigo (`stroke:#4f46e5`), external systems dashed slate,
  error paths red (`stroke:#dc2626`).
- **Style**: same rules as emjay-plan — editorial stone/slate palette, serif
  headings, one indigo accent, sparse prose (bullets over paragraphs),
  diagrams carry the weight, cards for components, tables for specs.
- Output path: `docs/onboarding/codebase-map.html` under the root (create the
  folder if missing). If it exists, update it in place: bump the version,
  set "Updated" to today and the commit chip to the new HEAD.

## 6. Verify

- Run `bash ${CLAUDE_SKILL_DIR}/verify_refs.sh <output.html> <repo root>`.
  It checks every `data-ref` path exists and every line number is in range,
  and flags leftover `{{…}}` placeholders. Fix everything it reports.
- Spot-check that each command in Dev workflow appears in a manifest,
  Makefile, CI file or README.

## 7. Finish

- Reply with the file path, 3–5 bullets on what the doc covers (flows
  diagrammed, tables documented), and the number of open questions with the
  top 1–3 listed.
- Offer (one line) to open it in a browser or publish it as an artifact;
  don't do either unasked.
