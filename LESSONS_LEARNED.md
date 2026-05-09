# Lessons learned

Short-lived notes from reviews and refactors. Prefer concrete “do / don’t” tied to this repository.

---

## 2026-05-07 — Design-pattern review and `MediaConversionPipeline.sh` corrections

**Context:** A decision-tree review (Creation / Structure / Behaviour) was applied to the codebase. The repo at that time contained the macOS bash pipeline only (no React/Next.js or FastAPI yet). Corrections were applied to the shell orchestrator; generic pattern gates were added under `.cursor/rules/` and `.cursor/skills/`.

### What we learned

1. **Facade for tool discovery**  
   Centralize resolution of `makemkvcon`, `HandBrakeCLI`, `filebot`, and Subler paths in a single function (`init_tool_paths`). Scattered path logic makes installs harder to reason about and breaks when Homebrew vs `/Applications` layouts differ.

2. **Chain of responsibility for HandBrake**  
   When encoding uses “try default preset, then retry with `--preset-import-gui`,” implement that as one ordered helper (e.g. `_try_handbrake_encode`) instead of nested or duplicated `if` blocks in `run_handbrake_one`. New retry steps belong in that chain, not as one-off branches.

3. **Strategy-style decoding for source flow**  
   `prompt_source_flow` returns different string shapes (`DVD\t…`, `FILES\n…`, plain multiline). Decode into `SOURCES` in a single place (`populate_sources_from_flow` with `case` on prefixes). Avoid `if/elif` source parsing inside `main` so new source types don’t sprawl.

4. **Stack honesty**  
   Pattern and layer analysis must be grounded in **observable** files. Claiming “API” or “frontend” findings without those layers in the repo is misleading; document N/A explicitly when the stack is not present.

### Enforced going forward

- Cursor rule: `.cursor/rules/media-pipeline-shell-conventions.mdc` (bash / `MediaConversionPipeline.sh`).  
- Broader pattern gate (when TS/Python land): `.cursor/rules/design-pattern-decision-tree.mdc`.

### References

- Skill summary: `.cursor/skills/design-pattern-decision-tree/SKILL.md`
