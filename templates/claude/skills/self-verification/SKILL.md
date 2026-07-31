---
name: self-verification
description: Use after writing or changing code, before declaring a task complete. Triggers — phrases like "проверь", "протестируй", "убедись что работает", or implicitly at the end of any implementation task. Especially required for UI changes, cross-process channel wiring, DB migrations, and any change that spans more than one architectural layer.
---

# Self-Verification Before "Done"

Treat your output as a hypothesis until proven. "Done" is a claim that requires evidence in THIS session — past green builds are insufficient.

## The 4-step verify loop

### Step 1 — Write the assertions before finishing

If you cannot list the assertions a change must satisfy, "done" is undefined. Write them down BEFORE running anything.

Format:
```
Assertions for "<task>":
[ ] tsc --noEmit exits 0
[ ] <new file> exists at <path>
[ ] grep finds <symbol> in <file>
[ ] curl http://localhost:18790/health returns 200 with {status:"ok"}
[ ] App.tsx renders new route /tasks without console error
```

### Step 2 — Run programmatic checks

Programmatic > eyeballing. Take the commands from the project, not from memory:
`config/harness.json` -> `backpressure.typecheck` and `tests`, plus `config/checks.json`.

Shapes that matter regardless of stack:

- **Compile / type check:** read the FULL output, not just the exit code — a zero exit with warnings still hides the thing you broke.
- **DB migrations:** apply to a scratch database and inspect the resulting schema; "the migration file exists" is not evidence that it applies.
- **HTTP endpoints:** actually call them and check status AND body; a 200 carrying an error payload is a common false green.
- **Cross-process channels:** check EVERY side (registration, bridge, typed client). A channel wired in one place out of three compiles and fails only at runtime.

Capture exit codes and exact output. Paraphrasing the output is where false-success creeps in.

### Step 3 — For UI: observe real state

UI cannot be verified by reading code. The dev server must be running and you must look at it.

- Start dev server (`npm run dev`).
- Navigate to the route you changed.
- Wait for network idle (queries finished, no spinners).
- Take a screenshot OR ask the user to verify.
- Check DevTools console — zero errors, zero warnings about React/keys/missing deps.

When the UI cannot be run in this session (no dev server access), say so explicitly: "I changed code X, types pass, but I have not run the UI. Please verify by..." — only claim success after running it.

### Step 4 — Aggregate and report

Only after every assertion has passed THIS session, mark the task done. Format the report as:

```
Done — verified:
- tsc --noEmit: 0 errors
- new file: src/pages/Tasks.tsx (created, 142 LoC)
- migration: 002_kanban_columns.ts applied, schema_version=2 confirmed
- screenshot: <path or "user verified"> shows new column

Not verified (needs your check):
- drag-drop on touch devices (no test env)
- dark mode contrast on the new card
```

Honesty about what you did NOT verify is itself a quality signal.

## Common failure modes

- **"Should work"** — replace with a verifiable claim. Either you ran it (say what), or you didn't (say what's unverified).
- **Skipping the build** — `tsc --noEmit` is 5 seconds. Run it.
- **Reading your own diff to verify it** — the diff is the hypothesis, not the evidence. Run something.
- **Trusting subagent prose** — see subagent-decomposition skill: open the artifact and verify directly; the prose summary is a hypothesis.
- **Looping on the same broken approach** — if 3 attempts fail, STOP. Re-read the problem statement. The bug is upstream of where you're looking. (CLAUDE.md §7.7)

## Edge cases checklist

For non-trivial changes also walk through:

- **Empty state** — what does the UI do with 0 items? 0-length string? null?
- **Error state** — backend down, fetch fails, migration fails — graceful?
- **Concurrency** — two IPC calls in flight, two SSE events arriving — does state get corrupted?
- **Permissions** — can this run if the user has no API key set, no GPU, no microphone?
- **Cleanup** — open file handles, dangling SSE connections, timers cleared on unmount?

An MVP can defer edge cases, but the deferrals must be conscious and listed.

## Where the commands come from

Do not invent them. This project already declares them:

- `config/harness.json` -> `backpressure.typecheck` — the fast check run after every iteration.
- `config/harness.json` -> `tests` — the test runner and how its output is counted.
- `config/checks.json` -> `_default` and the per-task entries — the mandatory checks that
  decide the verdict. These are authored outside the agent on purpose: they are the one
  thing a task cannot narrow down to something trivially green.

If a check you want to run is not in any of those files, add it there rather than running
it ad hoc — otherwise the next iteration silently stops running it.

When ANY of them fails, keep the task open until the underlying issue is fixed.
Verification must be real, not simulated.
