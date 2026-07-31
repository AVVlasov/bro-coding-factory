# /evolve

> Запуск цикла эволюции системы разработки. Каждый прогон оставляет систему **более продвинутой** по 7 осям одновременно.
> Ось и критерии зрелости описывает `docs/EVOLUTION.md` фабрики (`bcf meta wiki evolution`).

## Usage

```
/evolve                      # full 5-step cycle, all 7 axes
/evolve --axis=A4            # focused cycle on product value
/evolve --axis=A2,A6         # multi-axis
/evolve --observe-only       # only OBSERVE+REFLECT, no proposal write
/evolve --close-iter <NNNN>  # close current iter: measure + verify deltas shipped
```

## What it does (5 steps)

### 1. OBSERVE
Spawns `/evolve command` with current period scope. It harvests:
- git log, decisions.md tail, red-team reports, iteration-log history, test outcomes, hook firings, tasks/ state, harness inventory.

Output: `docs/archive/v3/iteration-log/<NNNN>-<slug>.signals.md`.

### 2. REFLECT
Spawns `/evolve command`. It:
- reads signal report + previous iteration log + maturity scorecard (`docs/archive/v3/`);
- computes new scorecard;
- identifies top 3 bottlenecks.

### 3. PROPOSE
Same `/evolve command` continues:
- proposes 1-3 concrete deltas per bottleneck axis;
- each delta has owner, DoD, predicted scorecard impact, anti-decay protection;
- writes proposal section into iteration-log entry.

If axis A4 in scope — `supervisor` ALSO runs in parallel to write A4 section (routines removed, tender moments, persona quotes, A4 deltas).

If A7 in scope — `ux-vision` + `ux-vision` outputs feed in (or are re-run via `/red-team` if stale).

### 4. APPLY (out-of-band)
**Not automated.** Andrey reads proposal, approves / amends / rejects deltas. Approved deltas become `tasks/D-<seq>-*.md` task files. Owner agents implement.

### 5. MEASURE (next `/evolve` run)
At cycle close, `/evolve --close-iter <NNNN>` runs. It:
- re-runs analytics-scout;
- updates iteration-log with «After» scorecard;
- verifies each proposed delta was shipped (DoD check) or carried over with reason;
- checks for regressions (any axis lower than «Before» → blocker);
- writes final entry and tags iter as `CLOSED`.

## Triggers (mandatory)

- After 30 commits OR 14 days since last cycle.
- After any Andrey-reported regression.

## Sample session

```
User: /evolve

Главный агент:
  1. Reads prev iter log → iter 002 closed scorecard.
  2. Spawn /evolve command → writes signals.md.
  3. Spawn /evolve command + supervisor (parallel) → reflect & propose.
  4. Aggregates iter 003 entry; reports to user.
  5. User: "Approve D-003.1, D-003.4. Reject D-003.2 (touches §14, write decision first).
            Defer D-003.3 to next iter."
  6. Главный агент: decomposes approved deltas into tasks via task-decomposer.
```

## Outputs

- `docs/archive/v3/iteration-log/<NNNN>-<slug>.md` — main entry (PROPOSAL).
- `docs/archive/v3/iteration-log/<NNNN>-<slug>.signals.md` — signal report.
- At close: same files updated with «After» scorecard + verification of shipped deltas.

## Hard rules

- Never invent scorecard numbers. Always derive from criteria + evidence cited.
- Never skip OBSERVE. Reflection without signals is opinion-only.
- Never propose >9 deltas per cycle. If you have more — you didn't prioritize.
- Never close a cycle with regress on any axis without decision-record.
- Never modify charter sections (CLAUDE.md §11/§12/§13.7/§14) inside a cycle without separate decision-log entry.

## When to skip /evolve

- Trivial commits (typo, docs-only).
- Hot-fix that doesn't touch process.
- Mid-phase progress check (use individual testers instead).

Otherwise default to running it — process gets better only when measured.
