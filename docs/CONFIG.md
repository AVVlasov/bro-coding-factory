# Configuration reference

All project-specific values live in `config/`. Scripts read these — nothing is hardcoded.

## config/harness.json

| Key | Meaning |
|---|---|
| `engine` | Cosmetic engine name (default `ralph`). |
| `agent.command` | Backend command template. `{model}` is substituted; the prompt is also piped on stdin. Default: opencode. |
| `agent.adapter` | Stream adapter under `loop/lib/adapters/` (default `opencode`). |
| `models.code` / `.tester` / `.vision` / `.judge` | Model ids per role. Empty = backend default. |
| `paths.tasks` / `.verdicts` / `.currentFocus` / `.bugs` | Repo-relative locations of the task system. |
| `productPaths` | Source roots that count as "product code" (no-progress, scope, verify-skip, eslint targets). |
| `taskIdPattern` / `taskIdPrefix` | Regex matching your task ids (default `[A-Za-z][A-Za-z0-9]*-\d+`). |
| `net.probeHost` / `.probePort` | Connectivity watchdog target (your model API host). **Empty = watchdog disabled.** |
| `timeouts.*` | `iterSec`, `streamStallSec`, `netWaitMaxSec`, `netStallRetryMax`, `stepSec`, `silentSec`. |
| `limits.*` | `maxIterations`, `noProgressLimit`, `sprawlFileLimit`, `sprawlIterLimit`. |
| `judge.name` / `.outputSuffix` | Judge role name + output-file suffix. |
| `features.*` | Toggles: `memory`, `bugSupervisor`, `hardCap`, `vision`, `visualContext`, `referenceDigest`, `redoTrigger`. All off by default. |
| `envPrefix` | Env-var prefix for harness toggles (default `BCF`). |

CLI parameters to `loop.ps1` / `verify.ps1` always override config; config overrides the
script's built-in default.

## config/agents.json

Role → `{ file, model }`. `testers` is an array of `{ name, file, model }`. Empty `model`
inherits `harness.json` `models.*`. The `.md` files are generic role templates — put product
specifics in `agents/PROJECT-KNOWLEDGE.md`.

## config/checks.json

Mandatory deterministic checks per task (the authoritative verdict source — the agent cannot
remove them). Key = task id or `_default`; value = array of shell commands (exit 0 = green).
Fill `_default` with your type-check/test command.

## config/triggers.json

Friction triggers that pause the loop for human review. `bigDeletionThreshold` (lines) +
`pathTriggers[]` of `{ pattern, reason, severity }` matched against the iteration diff.

## config/scope-map.json

- `testers[]` — `{ tester, patterns }`: which tester is relevant to which paths (irrelevant
  testers are dropped from a VERIFY-REQUEST based on the diff).
- `vision.rules[]` — `{ slug, patterns }` and `vision.shared.patterns` — scope the visual phase.

## config/memory.config.json

pgvector connection + embedding: `host`, `port`, `database`, `user`, `password_env`,
`password_default` (non-secret local fallback), `schema`, `embedding_dim`/`_model`/`_endpoint`.
The real password comes from the env var named by `password_env` (`BCF_PG_PASSWORD`).

## hooks/hooks-config.json

Optional project-specific gate checks (all no-op until filled): `ipc_*` (handler triple-wiring),
`migration_*` (registration / ALTER-safety), `wrapper_allowed` / `wrapper_key_pattern`
(no-hardcoded-API-key check), `console_check_dirs`, `banned_ui_patterns`, `ts_targets`,
`py_targets`.

## Environment variables

See `.env.example`. Key ones: `BCF_API_KEY` / `BCF_API_HOST` (agent backend), `BCF_PG_PASSWORD`
(pgvector), `MEMORY_EMBED_*` (embedding server), and toggles `BCF_MEMORY_DISABLED`,
`BCF_PROJECT_ROOT`, `BCF_BASH`, `BCF_VISION_*`. **No secrets are committed — keys live only in
`.env` (gitignored).**
