---
name: emjay-grill
description: Interview the user about a task with multiple-choice questions (AskUserQuestion), round by round, until every decision is made, sharpening the project's vocabulary as it goes, then hand the answers to emjay-plan to produce the HTML design doc. Use when the user runs /emjay-grill, or gives a vague task and asks to be grilled/questioned before planning.
argument-hint: "<task or feature idea>"
---

# emjay-grill — interrogate, then document

The user gives a task in `$ARGUMENTS` (or the conversation). Your job is to
reach a **shared understanding** of it by asking, then pass the result to the
`emjay-plan` skill. Don't implement anything, and don't enter plan mode — it
pushes toward writing a plan instead of asking.

**Facts are yours, decisions are the user's.** Never ask something the repo,
docs or tools can answer — look it up. Never answer a decision yourself — put
it to the user and wait. A session where you settled the user's decisions has
failed, however complete it looks.

## 1. Prepare (briefly)

- Read the task, then read what grounds it: `GLOSSARY.md`, `docs/adr/`,
  `docs/DESIGN.md`, `docs/REQUIREMENTS.md`, earlier `docs/plans/`, and the
  code in the area the task touches (stack, DB, modules, existing tests).
  Anything this answers is a **known fact**, not a question.
- If the task is clearly too big for one session (several independent
  features, a greenfield system), say so and propose splitting it; grill one
  piece at a time.
- Sketch the **design tree**: every decision the task needs, and which
  decisions hang off which. Use these areas as a checklist so nothing is
  missed — not as a fixed order:
  1. Problem & users — who, why now, success criteria
  2. Scope — must-haves, explicit non-goals, MVP cut
  3. Functional behaviour — main flows, edge cases, failure handling
  4. Data — entities, relationships, retention, volumes, migrations
  5. Interfaces — API/CLI/UI shape, integrations, auth
  6. Non-functional — performance, security, observability, cost
  7. Delivery — rollout, flags, deadlines, and test seams (where tests will
     drive the feature: prefer existing seams, as few and as high as possible)

## 2. Grill in rounds

The **frontier** is every open decision whose prerequisites are already
settled — the questions you can ask now without guessing at answers you
haven't heard. Each round asks the whole frontier, then waits.

- **Always** use the `AskUserQuestion` tool; never ask in plain text. A call
  holds 1–4 questions, so a frontier larger than 4 takes several calls back
  to back in the same round (group related questions per call). If the
  user's `CLAUDE.md` asks for one question at a time, do that instead.
- Two questions never share a round if one's answer could change the other;
  the dependent one waits for a later round.
- Each question has 2–4 concrete, mutually exclusive options with a one-line
  trade-off in `description`. Put your recommended option first, suffixed
  `(Recommended)`. Use `multiSelect: true` only when choices genuinely combine
  (e.g. "which platforms?"). Use `preview` for comparing schemas, API shapes
  or layouts. `header` ≤ 12 chars.
- Don't offer an "Other" option — the tool adds it. If the user picks Other,
  treat their text as the answer and follow up if it's ambiguous. "I don't
  know" is a valid answer: record it as an open question, don't press.
- **Looking up facts:** do it yourself with read/search tools. For a broad
  sweep, dispatch at most one small, narrowly scoped subagent. Don't stall
  the round on it — ask the rest of the frontier now; only questions that
  depend on the lookup wait.
- After each round, recompute the tree: settled decisions unblock new
  questions, and questions whose answers are now implied drop out. If the
  user says an answer should have changed an earlier one, reopen that branch.
- Never re-ask something already answered.

### Sharpen as you go

- **Challenge terms.** If the user's word clashes with `GLOSSARY.md` or the
  code, ask which is right ("Your glossary defines *cancellation* as X; you
  seem to mean Y"). If a term is vague or overloaded ("account" — Customer
  or User?), propose a precise one as a question.
- **Probe with scenarios.** Turn edge cases and failure modes into concrete
  options ("A payment times out after the order is saved — retry, roll back,
  or flag for review?"). This is where most hidden decisions surface.
- **Cross-check the code.** If an answer contradicts what the code does,
  surface it as a question instead of silently picking one.
- **Record the vocabulary.** When a term is resolved, add it to
  `GLOSSARY.md` right away (create it lazily). Definitions only — no
  implementation detail; it's a glossary, not a spec.
- **ADRs, sparingly.** Offer one (via `AskUserQuestion`) only when a
  decision is hard to reverse, surprising without context, **and** the
  result of a real trade-off. If accepted, write it to
  `docs/adr/NNNN-<slug>.md` (Context / Decision / Consequences). Most
  sessions produce none.
- **Ungrillable questions.** Questions about how something should look or
  feel can't be settled by talking. Show an ASCII mockup via `preview` if
  that's enough; otherwise stop on that branch, suggest a quick prototype,
  and carry it as an open question.

The session is done when the frontier is empty: every branch visited, nothing
silently assumed. There is no round limit — if it runs very long, the scope
was too big; offer to split it. If the user says "enough"/"skip", stop and
carry the rest as open questions.

## 3. Confirm

Post a compact summary in chat:

- **Task** — one line
- **Decisions** — `area: decision` bullets, with the user's reason where given
- **Refused** — options the user considered and rejected
- **Test seams** — agreed seams, new or existing
- **Known from codebase** — facts you looked up instead of asking
- **Docs written** — glossary terms added, ADRs created (if any)
- **Still open** — unresolved items + your leaning

Then one final `AskUserQuestion`: "Generate the plan doc from this?" with
options `Generate doc (Recommended)` / `Ask more questions` / `Change something`.
Loop back to step 2 for either of the last two. Don't hand off until the user
confirms.

## 4. Hand off to emjay-plan

Invoke the `emjay-plan` skill via the Skill tool in this same conversation
(it is listed as `emjay-skills:emjay-plan` when installed as a plugin — use
whichever name your skill listing shows),
passing a consolidated plan as `args`: the task, every decision (with the
chosen option and any rationale the user gave), things the user explicitly
refused (they become non-goals), agreed test seams, known facts, glossary
terms and ADRs written, and the still-open items marked as **OPEN QUESTION**.
Keep precise answers precise — numbers, orderings and "must not" rules go
over verbatim, not softened into prose. emjay-plan writes the HTML into
`docs/plans/`; relay its result (path + summary) to the user.

## It's working if

- Rounds are few but full, and later rounds ask things the first couldn't.
- Nothing in a round depends on another question in the same round.
- You looked facts up instead of asking them.
- The user pushed back or picked Other at least once — no disagreement
  usually means the questions were too shallow.
- Every decision in the summary is one the user actually made.
