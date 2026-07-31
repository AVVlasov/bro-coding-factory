---
name: subagent-decomposition
description: Use when a task is large or parallelizable and would benefit from being split across subagents. Triggers — phrases like "разбей на подагентов", "делегируй", "распараллель", "разбей задачу", or whenever the user asks to plan a multi-step implementation. Also auto-trigger when a single task touches >3 unrelated files, has >3 independent investigation streams, or contains the word "research" alongside "implement".
---

# Subagent Task Decomposition

Use this skill before starting any non-trivial implementation. The cost of decomposing wrong is ~2 minutes of your time; the cost of running with a bad split is hours of rework.

## When to spawn a subagent

Spawn when ALL three are true:

1. **Independent** — the work doesn't depend on context that's only in your head right now.
2. **Verifiable artifact** — the subagent returns a file path, a JSON blob, a test result, or a structured report you can inspect. NOT a vague summary.
3. **Self-contained prompt is feasible** — you can write the goal, inputs, and output format in <250 words without losing fidelity.

If any one fails, do it inline.

**Handle inline when:**
- Single-file edits where you already understand the code
- Decisions that need conversation with the user
- Tasks depend on another in-flight subagent's output (chain them — launch step N+1 only after N returns)

## Heuristic for splitting

- **Investigations** (read-only) — split by file/area. One subagent per investigation stream. All can run in parallel.
- **Implementations** — split by architectural layer ONLY when boundaries are clean (DB migration / IPC / UI / backend endpoint). If the boundary leaks, do it inline.
- **Research** — one subagent per source class (official docs / GitHub examples / blog posts). Parallel.
- **Test/grade** — one subagent for the build, one for the grader. Parallel.

## Subagent prompt template

Every subagent prompt MUST include these fields. Missing any field = the subagent will hallucinate or under-deliver.

```
Goal: <one sentence — what success looks like>

Context: <2-5 bullet points — WHY, what's already been ruled out,
         what surrounding constraints matter. Treat the subagent as a smart
         colleague who walked into the room with no memory.>

Inputs: <absolute paths, URLs, exact symbols. "the auth module" is too vague —
         "src/auth/session.ts:checkSession" is right.>

Tools/skill: <which agent type, which tools, which skills the subagent
              should use. Be explicit when default tools are insufficient.>

Output: <exactly what to return. "report under 800 words" or
         "the absolute path to the file you wrote" or
         "JSON with fields {passed, evidence}".
         If you cannot specify output format, the prompt is not ready.>

Out of scope: <what NOT to do. Subagents over-deliver if not bounded.>
```

## Launching peers in parallel

When you have N independent subagents, launch ALL N in the SAME tool-use turn (multiple tool calls in one assistant message). Sequential launches waste a round-trip per subagent.

```
[BAD]   spawn A → wait → spawn B → wait → spawn C
[GOOD]  spawn A, B, C all in one turn → wait once
```

Same applies to WebFetch, Read, Grep when you have independent inputs.

## Verifying subagent output

Subagents return prose summaries. **The prose is not the artifact.** Always:

1. Read the actual file the subagent wrote.
2. Run the build/test the subagent claims passed.
3. Spot-check 1-2 of the subagent's claims against ground truth.

If verification fails, the bug is often in the prompt (ambiguous output spec) — fix the prompt, then retry.

## Anti-patterns

- **Subagents that spawn subagents** — depth > 1 is almost always a sign your decomposition is wrong. Flatten it.
- **"Do everything for module X"** — too broad. Split by deliverable.
- **No output spec** — "investigate and report" lets the subagent define its own success criteria. Bad.
- **Trusting the prose summary** — agents will say "completed successfully" while leaving holes.
- **Re-spawning instead of fixing the prompt** — when a subagent under-delivers, edit the prompt and retry the same single subagent. Adding more subagents to patch gaps signals prompt design failure.

## Choosing the subagent

- Research streams: `general-purpose` with WebSearch/WebFetch.
- Codebase exploration: `codebase-explorer` (read-only, faster, cannot damage anything).
- Verification: the tester matching the surface under change — `api`, `architecture`,
  `performance`, `ux-vision`. A tester pointed at the wrong surface reports "clean" for free.
- Implementation slices: the specialist for that layer if the project defines one in
  `.claude/agents/`; otherwise keep the work in the main agent rather than inventing a role.
  - `python-backend-developer` — FastAPI, SSE, memory
  - `db-migration-writer` — new SQLite migrations
- After implementation subagents return, ALWAYS run `tsc --noEmit` and check `git status` yourself before reporting done.
