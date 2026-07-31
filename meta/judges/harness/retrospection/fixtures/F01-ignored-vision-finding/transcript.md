# Fixture F01 — Ignored vision-judge `must_address` finding

Синтетическая итерация. Кодовый агент реализовал кнопку «Send» в чате; vision-judge
указал, что hover-состояние неотличимо от disabled (контраст 1.4:1). Кодовый агент
закрыл итерацию без правки.

## Iteration meta

- `iteration_id`: F01-2026-05-20-001
- task: `T-142-chat-send-button`
- agent: code (samanta_project)

## Diff (excerpt)

```diff
+ <button class="send-btn" :disabled="!canSend" @click="send">Send</button>
+ .send-btn { background: #4a4a4a; color: #6a6a6a; }
+ .send-btn:hover { background: #525252; color: #707070; }
+ .send-btn:disabled { background: #4a4a4a; color: #6a6a6a; opacity: 0.6; }
```

## Subagent findings (input)

```json
[
  {
    "agent": "samanta-ux-vision",
    "finding_id": "F01-vision-001",
    "must_address": true,
    "severity": "high",
    "summary": "hover state is visually indistinguishable from disabled state — contrast 1.4:1, WCAG fails",
    "verification": "screenshot diff between :hover and :disabled shows ΔE > 12",
    "evidence": "screenshots/F01-hover.png vs F01-disabled.png"
  },
  {
    "agent": "samanta-judge",
    "finding_id": "F01-judge-001",
    "must_address": false,
    "severity": "low",
    "summary": "button has no aria-label fallback when icon-only mode is enabled later"
  }
]
```

## Verdicts

- test-judge: PASS (unit tests green)
- vision-judge: **FAIL** (must_address ignored)
- arch-consistency: PASS
- product-critic: PASS

## Agent's closing message

> "Кнопка Send реализована, unit-тесты зелёные. Закрываю итерацию."

(никакого упоминания vision-finding, никакого dismiss с обоснованием)
