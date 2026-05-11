# MediaVault Swift codebase audit — design-pattern decision tree

**Rule:** `.cursor/rules/design-pattern-decision-tree.mdc`  
**Method:** Pattern Detection Prompt (template #1) in `docs/design-patterns/PROMPT_TEMPLATES.md`  
**Scope:** `Sources/MediaVault/*.swift` (nine files)

## Summary table

| File | Violations found | Verdict | Files changed this audit |
| --- | --- | --- | --- |
| `MediaVaultApp.swift` | 0 | No action — `MediaVaultDocumentation` is already a small Facade for URLs | — |
| `ContentView.swift` | 0 | No commit this audit (working tree retained); Blu-ray wire comment aligned with `PipelineQueuedWire` | — |
| `SettingsView.swift` | 0 | Observer bindings only; no absent-pattern signal | — |
| `AppSettings.swift` | 0 | Many `@Published` + `didSet { save }` is **Observer** for persistence, not Builder (Builder signal requires ≥7 inputs **and** conditional field inclusion in construction) | — |
| `AutomationPreset.swift` | 0 | Value types + `AutomationPresetStore` persistence — no Facade invariant breach | — |
| `FileBotOptions.swift` | 0 | Finite enum menus — idiomatic Strategy; no cross-file repeated `switch` | — |
| `FileBotScriptLibrary.swift` | 0 | Facade: argv / descriptor lookup; `NSError` for unknown id is boundary shape validation, not domain policy | — |
| `PipelineController.swift` | 2 accepted | **Refactored** — Strategy table for post-HandBrake steps; typed wire parse for Blu-ray + **bugfix** (see below) | Yes |
| `ToolManager.swift` | 0 | `locateUserTool` is a single loop, not vendor branching; **Observer doc** added for `DownloadDelegate` | Yes |

---

## `PipelineController.swift`

### Violation A — repeated skip/run branching (ACCEPT → Strategy)

**Pain (quoted):**

```239:268:Sources/MediaVault/PipelineController.swift
        if runOptions.skipFileBot {
            items[index].stageNote = "Skipped by run option"
            log("FileBot skipped by run option")
        } else if tools.hasFileBot {
            let renamed = try await runFileBot(input: outFile, item: index)
            items[index].finalPath = renamed
        } else {
            items[index].stageNote = "Skipped — FileBot not installed"
            log("FileBot not available; skipping rename stage")
        }
        …
        if runOptions.skipSubler {
            items[index].stageNote = "Skipped by run option"
            log("Subler skipped by run option")
        } else {
            try await runSublerCli(input: items[index].finalPath ?? outFile, item: index)
        }
```

**Branch trace:** Behavioural → branching keyed by stage / skip flags → **Strategy** (table of `PipelinePostHandBrakeStep` rows: `skipMessages` + `run`).

**Pattern chosen:** Strategy (Swift idiom: struct rows + closures, no `switch` over stage variant inside a single runner).

**Invariant check (Behavioural → Strategy):** Pass — orchestration is `for step in postHandBrakeSteps(…) { if skip…; else run }`; per-step policy lives in the row’s `skipMessages` / `run`, not in a central `switch` on stage id.

**Anti-pattern check:** Pass — not a single-implementation “Strategy”; multiple concrete rows (FileBot rename, optional FileBot script, Subler, optional Apple TV copy).

#### Pattern change record (inline)

- **Scope:** `Sources/MediaVault/PipelineController.swift` — `processItem`, new `postHandBrakeSteps`, `PipelinePostHandBrakeStep`.
- **Pain:** Same as quoted block; optional post-rename script and Apple TV copy repeated the same control-flow shape.
- **Branch:** `Behavioural → branching by variant → Strategy`.
- **Swift idiom:** Struct table + `@MainActor` async `run` closures; initializer DI unchanged (`init(tools:)`).
- **Resolution:** Symptom eliminated in `processItem` (no parallel `if skipFileBot` / `if skipSubler` ladder); optional steps appended in `postHandBrakeSteps(for:)` only when options require them.
- **Invariants:** Strategy does not reintroduce a variant `switch` inside one runner.
- **Anti-patterns:** None of the rejected list.

---

### Violation B — Blu-ray wire discriminator + dead branch (ACCEPT → typed wire + bugfix)

**Pain (quoted):**

```207:218:Sources/MediaVault/PipelineController.swift
        if workingPath.hasSuffix(".bluray-pending") {
            let parts = workingPath.components(separatedBy: "::")
            guard parts.count == 2 else {
                throw NSError(domain: "MediaVault", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid Blu-ray source spec"])
            }
            let ripDir = parts[1]
```

Queued sources are `bluray.bluray-pending::<ripDir>` (see `ContentView`); the **full string does not end with** `.bluray-pending`, so this branch never ran — MakeMKV was skipped for Blu-ray.

**Branch trace:** Structural → awkward encoding / fragile boundary between UI queue and controller → **typed wire helper** (`PipelineQueuedWire`) at the boundary (not a GOF State machine — no explicit transition table requirement for `PipelineStage` labels).

**Pattern chosen:** Facade-like **wire codec** (`PipelineQueuedWire`) — single place for marker + parse; pairs with queue producers.

**Invariant check (Structural):** Pass — `PipelineQueuedWire` only encodes/decodes the wire string; rip policy remains in `runMakeMKV`.

**Anti-pattern check:** Pass — not an Adapter mixing domain rules.

#### Pattern change record (inline)

- **Scope:** `PipelineQueuedWire` enum; `processItem` stage-1 guard.
- **Pain:** `hasSuffix(".bluray-pending")` does not match `bluray.bluray-pending::/path`; Blu-ray rip never triggered.
- **Branch:** Structural → boundary encoding → named wire helper (`PipelineQueuedWire`).
- **Behaviour:** Blu-ray queue items now run MakeMKV as intended (behavioural **fix**, not a regression).

---

## `MediaVaultApp.swift`

**Signals:** None triggering Creational / Structural / Behavioural patterns beyond existing structure.

**Verdict:** No change. `MediaVaultDocumentation` is a minimal URL table + opener — acceptable.

---

## `ContentView.swift`

**Signals:** `switch sourceKind` for setup UI is normal view branching, not “algorithm swapped by variant” across the codebase.

**Verdict:** No pattern refactor. Blu-ray source string remains the literal compatible with `PipelineQueuedWire.bluRayRipPendingMarker` (comment updated in working tree only if present).

---

## `SettingsView.swift`

**Signals:** Bindings to `AppSettings`; no 4+ subsystem Facade call sequence in one logical action.

**Verdict:** No change.

---

## `AppSettings.swift`

**Candidate:** 21+ `@Published` properties with `didSet { save(Keys…) }`.

**Analysis:** Matches decision-tree trigger **Observer** (“Multiple observers must react when a value changes”). Builder trigger requires **≥7 constructor inputs with conditional inclusion** — not present (each property loads/saves independently).

**Verdict:** **REJECT Builder** — no refactor. Repetition is persistence boilerplate, not half-built object construction.

---

## `AutomationPreset.swift`

**Signals:** `AutomationPresetStore` is persistence + sort — not “Facade adds domain decisions” (sort order is presentation of stored list).

**Verdict:** No change.

---

## `FileBotOptions.swift`

**Verdict:** Enums with `switch` for `menuLabel` / `matchingStored` are single-site; not “same `switch` in 3+ files”.

---

## `FileBotScriptLibrary.swift`

**Verdict:** Confirmed **Facade** — surfaces `scriptProcessArguments`, `allDescriptors`; forwards to `Bundle` / `FileManager`. Unknown descriptor → `NSError` at argv boundary — acceptable shape validation.

---

## `ToolManager.swift`

### `Process.runShell`

**Verdict:** **Adapter-shaped** helper — argv/stdout assembly only; no domain policy. No change.

### `locateUserTool`

**Verdict:** Single `for path in candidates` loop — not “`if vendor == A` across files”. No Strategy table required.

### `DownloadDelegate`

**Verdict:** Observer. Added `///` documentation for **emit/receive direction** (decision-tree Observer invariant).

---

## `enum PipelineStage`

**Verdict:** Used as **progress labels**, not an explicit State pattern with a transition table. Converting to formal State without listed transitions would violate the rule’s “Reject … Convert this enum to a State pattern (without listing transitions)”. **No refactor.**

---

## Deferred / blocked

- **Fine-grained `git diff HEAD~1 -- Sources/MediaVault/PipelineController.swift`:** This branch’s `PipelineController` already contained settings/FileBot-script extensions before this audit; the committed file is the full working-tree version after the audit refactor. Isolating only audit hunks in git history would require interactive staging or a temporary reset of that file to `HEAD` and manual replay of non-audit features — out of scope for a single safe commit without losing co-located WIP.

---

## Verification

- `./build.sh` (debug) — **pass** after refactor; build ID written to `BUILD_NUMBER` for that run.
