---
name: vertical-slice-decomposition
description: Use when a task has >7 DoD assertions, spans >1 owner agent type, or stretches across multiple architectural layers (DB + IPC + UI + backend). Triggers — phrases like "разбей на слайсы", "слишком большая задача", "много owner'ов", "нарежь vertical slices", or implicitly when reading a taskfile and counting >7 checkboxes / spotting multiple layers.
---

# Vertical-slice decomposition

## Mental model

A **vertical slice** is the smallest meaningful unit that:
- Has **one** owner agent type.
- Has **3-7** verifiable DoD assertions.
- Fits in **≤90 минут** wallclock.
- Can be merged in isolation (or behind feature flag) without breaking main.

Multiple slices that share a parent feature form a **swarm**: each slice is delegated to its specialist agent, runs in parallel where possible, and the parent is closed only when all slices are `[V]`.

## When to apply

- Reading a taskfile с >7 assertions in one DoD block.
- Task description spans more than one architectural layer at once (storage + service + UI).
- Task touches >5 files where some are migrations + some are UI + some are IPC handlers.
- A coarse task written с 10-12 assertions.
- User says «слишком большая, разбей».

## Procedure

1. **Identify owners.** For each assertion in the parent, tag it with the layer that owns it — storage, service, contract, UI. If the project defines specialist agents in `.claude/agents/`, use those names; otherwise the layer name is enough. If an assertion needs 2+ owners, that assertion itself needs decomposition.

2. **Group by owner.** Each owner's assertion set becomes a candidate slice. If a group has >7 assertions — sub-decompose by sub-feature (e.g. «list+search» vs «create+update»).

3. **Identify dependency edges.** Storage/schema usually first (`<id>.a`); the service or channel depends on it (`<id>.b`); UI depends on the channel (`<id>.c`); an external integration depends on both its adapter and the service (`<id>.d`).

4. **Sharpen each assertion as observable** (CLAUDE.md §11.12):
   - command + expected output.
   - file existence + grep.
   - tester verdict.
   - playwright spec name.

5. **Write slice files** in `tasks/<parent-id>.<seq>-<slug>.md` using the frontmatter template:

```markdown
# <parent-id>.<seq> — <slug>

**Parent:** [<parent-id>](<parent-id>.md#<anchor>)
**Owner:** <agent-type>
**Estimate:** ≤90 min
**Depends on:** [<other-id>](...) | none
**Blocks:** <list>

## Context (1 paragraph)
What this slice contributes. Why split out.

## DoD assertions
- [ ] <observable>
- [ ] ...

## Touched files
- NEW / EDIT / DELETE — explicit list

## Verify
- <testers>
```

6. **Update parent** to a slice list (see `task-decomposer` agent prompt for example).

7. **Decision record** if any non-obvious choice was made (e.g. UI before IPC for mock-first development) — add abstract в `docs/decisions.md`.

## Anti-patterns

- ❌ «Decomposition» that just splits one assertion across two files — that's bureaucracy.
- ❌ Slices without dependencies marked — turns into chaos.
- ❌ Slices that share the same files heavily (>50% file overlap) — better кеep them together.
- ❌ Slice with `[ ] implement X` as the only assertion — useless, sharpen.

## Trigger the specialist

If decomposition is itself big (≥3 levels, ≥10 slices), **delegate to `task-decomposer` agent** — it's the specialist that writes consistent slice frontmatter and updates parent atomically.
