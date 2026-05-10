# Cursor AI and repository conventions (Media Magic)

This repository ships **Cursor rules** and a **skill** so assistants align with the same standards as human maintainers for the **Media Magic** automation project.

## Files under `.cursor/`

### Rules (`*.mdc`)

| File | Scope | Purpose |
| --- | --- | --- |
| `design-pattern-decision-tree.mdc` | `**/*.tsx`, `**/*.ts`, `**/app/**`, `**/pages/**`, `**/components/**`, `**/*.py`, `**/api/**` | Pain-point-first Gang-of-Four pattern selection; adapters = translation only; Strategy vs branching; Builder validation; anti-pattern list. Activates when TS/Python API code exists. |
| `media-pipeline-shell-conventions.mdc` | `**/*.sh`, `MediaConversionPipeline.sh` | Enforces Facade for tool paths, HandBrake encode chain helper, centralized `populate_sources_from_flow`; bash 3.2 note. |

Rules use `alwaysApply: false` and **globs**—they attach when matching files are edited.

### Skills

| Path | Purpose |
| --- | --- |
| `.cursor/skills/design-pattern-decision-tree/SKILL.md` | Compact decision tree (Creation / Structure / Behaviour), pattern→symptom map, anti-patterns, stack notes for React/FastAPI when present. |

Skills are reference material for assistants; rules are enforceable gates.

## Lessons learned

**`LESSONS_LEARNED.md`** (repository root) records dated outcomes from reviews—for example the 2026-05-07 shell refactor (Facade, encode chain, source-flow decoder) and the reminder to analyze only **observable** layers.

## Adding new documentation

1. Put user-facing content under **`docs/`** and link it from **`README.md`** and **`docs/README.md`**.
2. If you add a new subsystem (e.g. FastAPI backend), consider a new `.cursor/rules/*.mdc` with appropriate globs.
