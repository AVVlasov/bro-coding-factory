# PROJECT-KNOWLEDGE

Single source of project-specific truth for the agent role templates in this folder.
The generic agents (judge, testers, decomposer, retrospector, etc.) point here for
anything concrete: layer names, contract surfaces, banned dependencies, design
reference, personas, and where artifacts live.

Copy this file to `PROJECT-KNOWLEDGE.md` and fill in every section for your project.
Keep it factual and current — the agents treat it as authoritative. Leave a section's
placeholder in place (clearly marked TODO) if it genuinely does not apply, rather than
deleting the heading, so the agents can tell "N/A" from "not yet written".

---

## Architecture & layer boundaries

> Describe the top-level layers/processes (e.g. UI/presentation, logic, data, backend,
> external integrations) and the rule for what each layer may and may not do. State the
> boundaries an auditor should enforce ("layer X must never talk directly to Y").

<!-- TODO: list layers, their directories, and the boundary rules between them. Example:
- presentation (`<dir>`): renders only; no direct data access.
- logic (`<dir>`): owns business rules; the only layer allowed to call the data layer.
- data (`<dir>`): persistence; never imported by presentation.
- cross-process bridge: the ONE module every cross-boundary call must go through.
-->

## Module / contract map (APIs / IPC / routes)

> Enumerate the contract surfaces an API/IPC/route tester must check, and the places
> each contract must be declared (e.g. "every channel must appear in handler + bridge +
> shared types"). Give the directories and the wiring rule.

<!-- TODO: list contract surfaces and the multi-place wiring rule. Example:
- HTTP routes: defined in `<dir>`, registered in `<entrypoint>`; health endpoint = `<url>`.
- Cross-process channels: handler in `<dir>` + bridge in `<file>` + types in `<file>`.
  Missing any one = orphan = blocker.
- Naming convention for channels/routes: `<pattern>`.
-->

## Tech stack & banned deps

> The approved stack (languages, frameworks, state mgmt, test runners, db engine) and the
> explicit ban list a tech-stack auditor flags. Include the manifest files to read.

<!-- TODO: list approved stack + banned alternatives + manifests. Example:
- Manifests to read: `<package manifest>`, `<lockfile>`, `<backend manifest>`.
- Approved: <state lib>, <styling>, <test runner>, <db engine>.
- Banned: <competing libs that must never appear>.
- Native/binary build risks to verify install cleanly: `<list>`.
-->

## Visual / design reference (for vision)

> Where the canonical design reference lives and how it is rendered for comparison. Name
> the design system / token set, the screens/pages in scope, and the themes/variants. A
> vision judge compares rendered output against THIS reference only — never from memory.

<!-- TODO: point at the design reference + tokens + screen list + themes. Example:
- Reference source: `<dir or file>` (the canonical prototype — never judge against older versions).
- How it is rendered for diffing: `<command / harness>`.
- Design-token set / namespace: `<prefix>` (no hardcoded values allowed).
- Screens in scope: `<list>`. Themes/variants: `<list>`.
- Severity thresholds, if the project defines them: `<table>`.
-->

## Personas & product DNA

> The product's target users / personas and the "product-feel" questions a critic should
> answer for UI-touching work (tone, microcopy voice, platform-native expectations).

<!-- TODO: list personas + the product-DNA questions. Example:
- Personas: <persona-1 — who they are, what they need>, <persona-2 ...>.
- Product-DNA questions for UI critique: Does the copy match the intended voice? Does the
  surface feel native to the target platform? Are empty/error states humane?
-->

## Known anti-patterns

> Project-specific mistakes that have recurred and must be caught (false-completion
> patterns, AI-slop tells, wrong-platform idioms, mock-as-reality). These supplement the
> generic anti-patterns already baked into the agent prompts.

<!-- TODO: list recurring project-specific anti-patterns. Example:
- <pattern that keeps reappearing in reviews> — how to detect it.
- AI-slop tells specific to this UI: <list>.
- Forbidden shortcut the team has been burned by: <description + detection>.
-->

## Test layout

> Where tests live, how they are organized (unit / integration / e2e / vision /
> regression), the runners and configs, the fixtures, and where verdict/result artifacts
> are written. Also: where task files, decisions log, and proposals staging live.

<!-- TODO: describe test directories, runners, fixtures, and artifact locations. Example:
- Unit/lib tests: `<dir>` (runner: `<tool>`).
- Integration / e2e: `<dir>` (runner: `<tool>`, config `<file>`, app fixture `<file>`).
- Regression tests for chronic bugs: `<dir>`.
- Vision results: `<dir>`. Verdict artifacts: `<dir>`.
- Task files: `<dir>`. Decisions log: `<file>`. Proposals staging: `<dir>`.
-->
