---
name: brainstorm
description: Use when the path forward is unclear — when the plan lacks confidence, when the user's request has multiple plausible interpretations, when there's a tradeoff that should be surfaced. Triggers — phrases like "не понятно как сделать", "какой подход выбрать", "придумай как", "предложи варианты", or implicitly when a request touches architecture/data-model decisions where reversal is expensive.
---

# Brainstorm When Uncertain

Default behavior when uncertain is NOT to start coding. It's to surface the uncertainty cheaply with 3 distinct options before committing.

## Pre-check: do you have enough to brainstorm?

Try to state in 2 sentences:
1. **The goal** — what success looks like for the user.
2. **The hard constraints** — what must be true (CLAUDE.md rules, perf budget, data the user has).

If you cannot, **stop and ask the user one question** instead of generating options. Brainstorming on the wrong premise is wasted output.

## Generate 3 distinct approaches

Three is the magic number. One is anchoring. Two is a false binary. Four+ overwhelms decisions. Three forces real differentiation.

**They must differ on a dimension** — architecture, library, scope, time-cost, or risk. Three flavors of the same idea = one option.

Format:

```
Option A — <name>: <one line: what it is>
  Tradeoff: <main cost or risk>
  Killed by: <single condition that rules it out>
  Time estimate: <rough — hours/days>

Option B — <name>: ...
Option C — <name>: ...

Recommendation: <one of the above> because <one sentence>.
```

## Rules

- **Each option ≤4 lines.** Long options hide weak ideas. If you need a paragraph to explain it, the option is incoherent.
- **The "killed by" line is mandatory.** It forces you to think about what would invalidate the option, which is where most ideas fail anyway.
- **Recommend one.** Take a position on the whole decision. The user can override, but you read the code — you have an opinion.
- **Mark assumptions explicitly.** When you guess at a fact, label `(assumed)`. Lets the user correct cheaply.
- **For trivial reversible choices** (variable name, file location, fields order) — skip brainstorming. Pick and proceed.

## When NOT to use

- Bug fixes with one obvious cause — just fix.
- User has stated their preference — implement as stated.
- Trivial refactors.
- Decisions the user already made in CLAUDE.md / ARCHITECTURE.md / PRD — follow those decisions as fixed.

## When stubborn — branch metaphors

If brainstorming keeps producing variations of one idea, the issue is your framing. **Branch metaphors:**

- Reframe as a different domain — "what would a database engineer do here?" vs "what would a UX designer do?"
- Try the inversion — "what's the dumbest version that could work?"
- Try the extreme — "what if we had infinite resources / zero time?"

Often one of these surfaces a hidden assumption.

## Anti-patterns

- **Pile MUSTs onto a single approach.** When you find yourself adding "and we MUST also handle X, and Y, and Z" to one option, you're rationalizing — that means option lacks margin. Branch out instead of tightening.
- **Three trivially-different options** ("with Tailwind / with CSS modules / with styled-components" when the user said use Tailwind) — wastes their time.
- **Refuse to recommend.** "It depends" is a non-answer. Pick one and explain.
- **Brainstorm in a vacuum.** Surface the user's existing constraints first; options that violate them are dead on arrival.

## Example

Bad:
> "We could store tasks in SQLite. Or maybe in JSON. Or in IndexedDB. What do you prefer?"

Good:
> Goal: persist tasks across app restarts; work offline; support fast filter by status.
> Constraints: better-sqlite3 already in stack; no new DB allowed (CLAUDE.md §2).
>
> Option A — `tasks` table in the app database: standard schema, FTS for search later. Tradeoff: schema migration needed for every field. Killed by: nothing realistic. Time: 2h.
>
> Option B — `tasks_documents` JSON-blob table: schema-flexible, cheap to evolve. Tradeoff: filters become full-table scans. Killed by: >5K tasks (perf). Time: 1h.
>
> Option C — Per-project YAML files in %APPDATA%: trivial diff/backup. Tradeoff: no SQL queries, manual sync logic. Killed by: any cross-task aggregation (we need this for kanban counts). Time: 3h.
>
> **Recommend A** — schema rigidity is fine, kanban counts and filters are the dominant access pattern, and SQLite is already in stack per CLAUDE.md.

## Anchoring options in this project

- Every option must be checked against `CLAUDE.md` (allowed stack, file structure). An option that violates it is dead on arrival — say so instead of ranking it.
- If the project has an architecture doc, cite it whenever an option implies a layer-boundary change: that is the expensive kind of option, and it should not look free.
- If `docs/PRD.md` exists, check the option against "what we explicitly do NOT do in v1" before proposing it.
