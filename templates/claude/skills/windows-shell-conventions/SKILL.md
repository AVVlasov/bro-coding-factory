---
name: windows-shell-conventions
description: Use whenever you run shell commands on Windows — tester subagents (api, architecture, db-migration-writer, performance), Phase B self-verification, /verify harness, ad-hoc grep/build/test. The Bash tool here resolves to PowerShell first, with Git tools layered on PATH; cross-shell-safe command forms below.
---

# Windows shell conventions

This project runs on Windows. The Bash tool in this environment resolves commands through PowerShell with `C:\Program Files\Git\usr\bin` and ripgrep on PATH. The cross-shell-safe forms below work in both PowerShell and Git Bash, so subagents and the code agent can share a single command vocabulary.

## What you can rely on being installed

- **ripgrep** — `rg.exe` on PATH (installed via winget `BurntSushi.ripgrep.MSVC`). Preferred over `grep -r` for code search; faster, respects .gitignore.
- **Git POSIX tools** — `head`, `tail`, `grep`, `sed`, `awk`, `tr`, `sort`, `cut`, `wc`, `find`, `xargs` from `C:\Program Files\Git\usr\bin`.
- **Node toolchain** — `node`, `npm`, `npx`, `tsc` (via `npx tsc`).
- **Python 3.12** — `python`, `python -m <module>`.
- **docker / docker compose** — for `bcf-agent-memory` Postgres container.
- **lms** — LM Studio CLI for embedding model loading.

## Cross-shell command patterns

### Search code (ripgrep)

```bash
# Lines matching pattern with file:line — preferred form
rg -n "TODO|FIXME" src/

# Limit output (cross-shell)
rg -n "PATTERN" path/ | Select-Object -First 50      # PowerShell pipeline
rg -n "PATTERN" path/ | head -50                      # Bash pipeline

# Confine to file types
rg -nt ts "channel:" src/
```

`rg` works identically in PowerShell and Bash, runs faster than `grep -r`, and respects `.gitignore` by default.

### Limit pipe output

| Need              | PowerShell                       | Bash / Git tools                |
|-------------------|----------------------------------|---------------------------------|
| First N lines     | `... \| Select-Object -First N`  | `... \| head -N`                |
| Last N lines      | `... \| Select-Object -Last N`   | `... \| tail -N`                |
| Count lines       | `(...).Count` or `\| Measure-Object -Line` | `... \| wc -l`        |

When invoking from the Bash tool prefer `| head -N` (always available now). When invoking from PowerShell scripts (`*.ps1`) use `Select-Object`.

### TypeScript compile

```bash
npx tsc --noEmit                       # Read FULL output; exit code matters
npx tsc --noEmit 2>&1 | head -100      # Truncate for context window
```

### Python type / compile checks

```bash
python -m py_compile backend/main.py
python -m mypy backend/ 2>&1 | head -80
python -m pytest backend/ -x   # stop at first failure
```

### Docker container queries

```bash
# Healthcheck status
docker inspect -f '{{.State.Health.Status}}' bcf-agent-memory

# psql via container (no host psql client required)
docker exec -e PGPASSWORD=local-dev bcf-agent-memory `
  psql -U bcf -d bcf_agent_memory -tAc "SELECT count(*) FROM agent_memory.anti_patterns"
```

Backtick (`` ` ``) is PowerShell line continuation; for Bash use `\`.

### Project-relative paths

Always quote paths with spaces:

```bash
"{{PROJECT_ROOT}}/.claude/hooks/skill-lint.sh"
```

Forward slashes work in both shells for relative paths; backslashes need escaping in Bash strings.

### Reading exit codes

Always inspect exit code, not just stdout:

```bash
npx tsc --noEmit
echo "exit=$?"                          # Bash
# or in PowerShell:
npx tsc --noEmit; "exit=$LASTEXITCODE"
```

A subagent that pipes output and ignores `$?` cannot tell PASS from FAIL.

## When NOT to use

For one-off interactive exploration inside the Glaz bog meta project itself, this skill does not apply — that environment uses Git Bash directly. This skill targets agents acting inside `{{PROJECT_ROOT}}/`.

## Related

- Anti-pattern `subagent-runs-unix-command-without-availability-check` — recalled when a task involves running shell pipelines.
- `skills/self-verification` — uses these commands as the verifiable observables.
