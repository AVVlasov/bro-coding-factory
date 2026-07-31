# Skill template (positive-only)

> M-13 policy: **skills describe capability, not prohibition.** Everything «как НЕ
> надо» lives in `agent_memory.anti_patterns` (vector recall), not in skills.
> Validated by `.claude/hooks/skill-lint.sh`.

```markdown
---
name: <kebab-case-slug>
description: Use when <observable trigger condition>. The skill teaches <one concrete capability>.
---

# Skill: <human-readable name>

## What this skill does

One sentence — what the agent now knows how to do. Positive framing.

## Core mechanic

Concrete steps, code patterns, or invariants the agent maintains while performing
the task. Each bullet is an action the agent takes, not a thing it avoids.

- Use <pattern X> to achieve <outcome Y>.
- Inject <Z> through <interface>.
- After the change, verify <observable>.

## Example

```typescript
// minimal, runnable, shows the positive pattern.
```

## When NOT to use

(Optional, allow-listed by linter.) Lists contexts where this skill's pattern is
inappropriate and another skill applies instead. Frame as *applicability bounds*,
not as «don't ever do X». Example:

- For mock-mode integration tests where deterministic fixtures are required — use
  `skills/mock-mode-test-author` instead.

## Related

- Linked anti-patterns (recalled automatically by `pre-task-memory-inject.sh`
  when the trigger matches): `anti-pattern/<slug>`.
- Related skills: `skills/<slug>`.
```

## Authoring rules

1. **No prohibitions.** Replace «don't / never / avoid / не делай / никогда / избегай»
   with the positive form, or move the warning into an anti-pattern memory entry.
2. **Triggers are observable.** `description:` says when to apply, not how to feel.
3. **One capability per skill.** If you find yourself adding a second mechanic,
   split into a second SKILL.md.
4. **Anti-patterns belong in memory, not in skills.** Use:
   ```bash
   python D:\samanta_project\.claude\memory\memory_client.py upsert <<'JSON'
   {"agent_scope":"code","trigger_summary":"…","what_went_wrong":"…","correct_alternative":"skills/<slug>"}
   JSON
   ```

## Linter

Run before commit:

```bash
D:/samanta_project/.claude/hooks/skill-lint.sh path/to/SKILL.md
```

Exit 0 — clean. Exit 2 — prohibition detected; fix or move to memory.
