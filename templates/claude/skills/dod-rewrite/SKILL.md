---
name: dod-rewrite
description: Rewrite DoD assertions from vague language ("works correctly", "no bugs", "implement X") into verifiable observables (command + expected output, grep + expected hits, tester verdict). Use whenever you read or write a DoD list, or when `judge` flagged "needs more evidence" because assertions can't be checked.
---

# DoD-rewrite skill

## Why

«Implement X» / «работает корректно» / «без багов» — это **не** acceptance criteria. Verify такого assertion за <30s невозможно. Каждое такое assertion = ловушка: либо ложный PASS («выглядит ок»), либо ложный FAIL («какие именно баги?»).

CLAUDE.md §11.2 + §11.12 — каждый DoD-пункт обязан быть observable.

## Patterns

### Bad → Good

| Bad | Good |
|-----|------|
| `[ ] Implement the /memory screen` | `[ ] Маршрут `/memory` монтирует компонент `MemoryHub`; UI-тест `tests/memory.spec:smoke` PASS` |
| `[ ] Add integration with <service>` | `[ ] `src/clients/<service>.ts` экспортирует `send(channel, text)`; `client.has('send')` возвращает true в `tests/<service>-handshake.spec`` |
| `[ ] Drag-and-drop works` | `[ ] UI-тест перетаскивает карточку Inbox→Today; запрос `SELECT status FROM tasks WHERE id=?` возвращает 'today'` |
| `[ ] Properly handles errors` | `[ ] `curl POST /api/x -d 'bad'` returns 422 с JSON `{error: "validation_failed", details: [...]}`; `tests/api/x.spec.py:test_validation` PASS` |
| `[ ] No console errors` | `[ ] Playwright captures `page.on('console')` events; assertion `errors.length === 0` PASS for 5s after route mount` |
| `[ ] User can search memory` | `[ ] IPC `workspace:search` с `{query:"foo", mode:"fts"}` returns `Array<{path,title,snippet}>` length≥0; UI `MemoryFeed` renders results within 200ms (perf-tester report)` |

### Categories of observables (preferred)

1. **Programmatic check** — `tsc --noEmit` / `npm run lint` / `python -m mypy` exit 0; `done-gate.sh` exit 0.
2. **HTTP probe** — `curl <endpoint>` returns status N + body matching schema.
3. **File invariant** — `Grep` finds 0 / N hits of pattern; file exists / doesn't exist.
4. **Tester verdict** — named tester subagent (ui/api/design/journey/performance/judge) returns PASS.
5. **Playwright spec** — named spec file passes; preferred for UI flows.
6. **Pytest** — named test passes.
7. **Capability detect** — `client.has('toolName')` returns expected boolean.

## Procedure

1. Read DoD list.
2. For each bullet — categorise as:
   - **Already observable** → leave.
   - **Vague** → rewrite, choose a category from above.
   - **Multi-fact** (compound) → split into two bullets.
3. If you cannot rewrite a bullet (genuinely unclear what success looks like) → escalate с `[X]` + subtask «Acceptance criteria research for <thing>» (see CLAUDE.md §11.11).
4. Update the taskfile с новыми bullets, preserve existing `[V]` markers.
5. If the bullet was previously `[V]` but you couldn't verify with a sharp observable — downgrade to `[~]` с note «verification pending — assertion was reformulated».

## Honesty rule

Маркируй `[V]` только после реального run командой / тестером. Если выясняется в процессе rewrite, что previous `[V]` поставлен на foreign-untested code path — flag отдельно в decision-record «previously claimed done, downgraded to `[~]` 2026-MM-DD because rewrite revealed no verification existed».
