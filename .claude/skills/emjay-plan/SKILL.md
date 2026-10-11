---
name: emjay-plan
description: Turn a detailed plan from the user into a single self-contained HTML design doc covering what will be implemented, user stories, high-level design, DB schemas, testing seams and open questions. Use when the user runs /emjay-plan, pastes a plan and asks for it to be documented, or when emjay-grill hands off a finished interview.
argument-hint: "<detailed plan text, or a path to a file containing it>"
---

# emjay-plan — plan → HTML design doc

You receive a plan (in `$ARGUMENTS`, in the conversation, or in a file the user
points to) and produce **one self-contained HTML document** that documents it.
You are documenting, not implementing: do not write or change product code.

**The doc is a decision record.** It records what the user already decided so a
fresh session can build from it without re-explaining. It does not make new
decisions. Every statement must trace to the plan, the grill transcript or the
codebase; anything you'd have to invent is an Open Question instead. A
statement the user never made is a defect.

**Synthesise, don't interview.** The deciding is done (that's `emjay-grill`'s
job). The only question you ask is the seam check in step 3. If the plan is
too vague to document at all, say so and suggest `/emjay-grill` instead.

## 1. Gather the input

- If `$ARGUMENTS` is a path to a readable file, read it. Otherwise treat
  `$ARGUMENTS` plus the recent conversation as the plan.
- If the plan came from `emjay-grill`, use its decisions as the source of
  truth; items marked **OPEN QUESTION** go straight to Open Questions.
- Read the project's own vocabulary and prior decisions if present:
  `GLOSSARY.md`, `docs/adr/`, `docs/DESIGN.md`, `docs/REQUIREMENTS.md`,
  earlier docs in `docs/plans/`. Use their nouns throughout; don't contradict
  an ADR — if the plan does, flag it in Risks.
- Skim the repo only as far as needed to ground the doc: existing modules and
  their interfaces, existing schemas/migrations, existing tests (prior art).
  Don't sweep the whole codebase.

## 2. Work out the content

Fill these sections, in this order:

1. **Summary** — 2–4 sentences from the user's perspective: the problem they
   face, then the outcome they get.
2. **Goals / Non-goals** — bullet lists. Non-goals are explicit exclusions;
   things the user considered and refused are the most valuable lines here,
   so list every one of them.
3. **User stories** — a long, numbered list covering every actor and flow,
   each `As a <actor>, I want <capability>, so that <benefit>`. Skip the
   section with one line ("Not applicable — <refactor/infra change>") when the
   work is architectural and stories would be invented.
4. **What will be implemented** — a table of deliverables:
   `# | Deliverable | Description | Module/area | Priority (P0/P1/P2)`.
   Name modules, not file paths — paths go stale; cite a path only for an
   existing file that is certainly touched. Then an ordered list of phases,
   each one shippable on its own.
5. **High-level design**
   - Architecture diagram as a Mermaid `flowchart` (modules + data flow);
     highlight new/changed nodes.
   - One Mermaid `sequenceDiagram` for the main happy path, if there's a
     request/flow worth showing.
   - Components: name, responsibility, interface it exposes/consumes.
   - Key design decisions as a table: `Decision | Choice | Alternatives | Why`.
     "Why" is the user's reason; if none was given, write "—" and add an Open
     Question rather than supplying one.
   - Cross-cutting concerns that apply: error handling, performance,
     security/auth, observability, config, migration/rollout. Skip any that
     genuinely don't apply rather than padding.
   - No code snippets, except an interface/type shape or state machine the
     user decided precisely — trim it to the decision-rich part.
6. **DB schemas**
   - For each table/collection: name, purpose, and a column table
     `Column | Type | Null | Default | Constraints/Notes`, plus indexes.
   - A Mermaid `erDiagram` showing relationships.
   - The DDL (SQL dialect from the plan or repo; default PostgreSQL).
   - Migration notes if existing tables change.
   - If the plan has no persistent storage, say so in one line
     ("No database changes — <reason>") and keep the section.
7. **Testing** — the agreed seams (from step 3), and for each: what behaviour
   is tested through it, which modules sit behind it, and prior-art tests in
   the repo to copy. Tests exercise external behaviour, not implementation
   details.
8. **Open questions** — table: `# | Question | Why it matters | Options/leaning | Owner | Status`.
   Status is `Open` unless the plan answers it. Include every assumption you
   had to make, phrased as a question to confirm.
9. **Risks** (optional) — only real ones the plan or codebase surfaces,
   including ADR conflicts.

## 3. Check the seams with the user

Before writing the file, sketch where the feature will be tested — the
**seams**: interfaces where a test can drive the behaviour and observe the
result. Prefer existing seams to new ones, pick the highest one possible, and
propose as few as you can (the ideal is one). Post them in chat as
`seam — what it covers — new/existing`, then ask one `AskUserQuestion`:
`Seams look right (Recommended)` / `Change them`. Skip this step if the grill
transcript already settled the test seams.

## 4. Write the HTML

- Start from `template.html` in this skill's directory
  (`${CLAUDE_SKILL_DIR}/template.html`). Keep its structure and Tailwind
  classes; replace the `{{…}}` placeholders and the sample rows/cards. Remove
  sample content you don't use. Keep the Tailwind and Mermaid script tags as
  is — they are the only scripts; the doc is otherwise static.
- Escape `<`, `>` and `&` inside code blocks and table cells.
- Output path: `docs/plans/<yyyy-mm-dd>-<kebab-slug>.html` in the repo root
  (create `docs/plans/` if missing). If a file for the same plan exists, update
  it in place and bump the version and "Updated" date in the header.
- Header metadata: title, date (today), status (`Draft`), author (git
  `user.name`), version.

### Style (adapted from mattpocock/skills `improve-codebase-architecture/HTML-REPORT.md`)

- **Editorial, not corporate-dashboard.** Stone/slate palette, generous
  whitespace, `font-serif` for headings and the summary lead, small
  `text-xs uppercase tracking-wider` labels for section and diagram captions.
- **Colour sparingly.** One accent (indigo) plus fixed semantic badges:
  P0 = red, P1 = amber, P2 = slate; Open = amber, Resolved = emerald;
  chosen option in decisions = emerald; new seam = indigo, existing seam =
  slate; risks = red left border; migration and warnings = amber callout.
  Every coloured element has a `dark:` variant — keep them when adding markup.
- **Diagrams carry the weight.** Wrap each Mermaid diagram in the template's
  `<figure>` card so it doesn't feel parachuted in. Use `classDef` to
  highlight new or changed nodes (indigo) and risky edges (red,
  `stroke:#dc2626`). When Mermaid's layout fights you (layered architecture,
  before/after of an existing system), hand-build it with Tailwind `<div>`s:
  stacked `border-l-4` bands for layers, two columns side by side for
  before/after. Keep diagrams roughly ≤360px tall.
- **Prose is sparse.** One sentence where one will do; if a sentence could be
  a bullet, make it a bullet. No intro paragraph in the header, no hedging or
  "it's worth noting that…". If a diagram needs a paragraph to be understood,
  redraw the diagram.
- Components and seams are cards (one `<article>` each); decisions,
  deliverables, column specs and open questions are tables.

## 5. Self-check, then finish

Before replying, re-read the doc and fix anything that fails:

- Every decision traces to the plan, transcript or codebase — nothing was
  invented to fill a section.
- It uses the project's nouns, not generic boilerplate.
- Non-goals list the real things the user refused.
- Seams are few, high, and were agreed.
- No placeholder `{{…}}` or sample rows remain.

Then reply with: the file path, a 3–5 bullet summary of what the doc covers,
the agreed seams, and the count of open questions with the top 1–3 listed.
Offer (one line) to open it in a browser or publish it as an artifact; don't
do either unasked.
