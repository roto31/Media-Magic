# Design-Pattern Prompt Templates (Swift / Media Magic)

Five auditable prompt templates that embed the decision-tree methodology
from `.cursor/rules/design-pattern-decision-tree.mdc`. Each template is
self-contained, references the decision tree explicitly, and produces a
structured output that can be reviewed and audited.

Conventions encoded in every template:

- All Swift examples follow the Media Magic style:
  - `@MainActor final class X: ObservableObject` for view-state holders.
  - `struct` / `enum` for value types.
  - Initializer DI; `@EnvironmentObject` for view-tree distribution.
  - Errors as `enum FooError: Error, LocalizedError` or
    `NSError(domain: "MediaMagic", code:, userInfo:)`.
  - Persistence via `private enum Keys { static let … }` + `UserDefaults`.
  - `// MARK: - Section` separators; `///` doc comments for public API.
- Branch labels are the three roots: **Creational** / **Structural** /
  **Behavioural**.
- Every output ends with an invariant check and an anti-pattern check.

---

## 1. Pattern Detection Prompt

### When to use
A code block has been pasted or referenced. You must enumerate **all active
pain signals** and map each to a single decision-tree branch and named
pattern. Do not suggest a pattern that has no signal.

### Prompt template (copy verbatim, fill `{{...}}`)

```
ROLE: Senior Swift architect operating under
.cursor/rules/design-pattern-decision-tree.mdc.

TASK: Detect design-pattern pain signals in the code below and walk the
decision tree to a named pattern for each. Do NOT propose patterns whose
signal is absent.

CODE UNDER REVIEW:
{{paste swift code here, include file path and line range if known}}

OUTPUT (strict format, no prose outside sections):

## Pain signals
- {{signal 1, quoted with file:line if known}}
- {{signal 2}}
- ...

## Branch traces
| Signal | Root branch | Sub-decision | Candidate pattern |
| --- | --- | --- | --- |
| {{signal 1}} | Creational/Structural/Behavioural | {{decision step}} | {{pattern}} |
| ...

## Per-signal verdicts
For each candidate above:
- Pattern: {{name}}
- Pain phrased in code terms: {{1 sentence quoting the symptom}}
- Branch trace: {{Root → sub-decision → pattern}}
- Invariant check (per design-pattern-decision-tree.mdc):
  - {{invariant 1}}: pass / fail — {{why}}
  - {{invariant 2}}: pass / fail — {{why}}
- Anti-pattern check: pass / fail — {{which rejected anti-pattern was
  considered and why this proposal is not it}}
- Verdict: ACCEPT | REJECT (reject if any invariant or anti-pattern fails)

## Withdrawn proposals (if any)
- {{pattern name}} — withdrawn because {{signal absent OR invariant violated}}
```

### Worked example — input

```swift
// Excerpt of PipelineController.processItem(at:) — Media Magic
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

if runOptions.skipSubler {
    items[index].stageNote = "Skipped by run option"
    log("Subler skipped by run option")
} else {
    try await runSublerCli(input: items[index].finalPath ?? outFile, item: index)
}
```

### Worked example — output

```
## Pain signals
- Repeated "skip vs run" branching keyed by `runOptions.skip*` booleans
  across stages (FileBot, Subler). Same shape, different stage runner.
- Each stage runner is selected and invoked inline; adding a fifth stage
  duplicates the if/else pair again.

## Branch traces
| Signal | Root branch | Sub-decision | Candidate pattern |
| --- | --- | --- | --- |
| Repeated skip/run branching per stage | Behavioural | "Swap interchangeable algorithms per stage" | Strategy |
| New stage ⇒ new conditional block | Behavioural | "Branching by variant" | Strategy (one type per stage) |

## Per-signal verdicts
- Pattern: Strategy
- Pain phrased in code terms: two near-identical `if runOptions.skipX
  { log/skip } else { try await runX(...) }` blocks already exist; each
  new stage would clone the block.
- Branch trace: Behavioural → branching by stage type → Strategy.
- Invariant check:
  - "Strategy eliminates branching, not wraps it": pass — the per-stage
    decision is encoded as one `PipelineStageRunner` per case; the loop
    iterates over stages with no per-stage `if`.
  - "Closure-strategy preferred when local; protocol when ships from
    outside the module": pass — proposed protocol because runners hold
    state (`ToolManager`, log handle).
- Anti-pattern check: pass — not a single-implementation interface
  (FileBot, Subler, and future stages are concrete implementations now).
- Verdict: ACCEPT
```

### Production-ready Swift sketch (Strategy applied)

```swift
// PipelineStageRunner.swift
// Strategy abstraction so PipelineController iterates stages without
// per-stage `if` ladders. One conformer per stage; the conformer owns
// its own "should I run?" decision.

import Foundation

protocol PipelineStageRunner: Sendable {
    /// Display name (used in logs and the `stageNote` UI line).
    var stageLabel: String { get }

    /// True when this runner should execute for the current run options.
    /// MUST be a pure check over `PipelineRunOptions` and `ToolManager` —
    /// no I/O, no mutation. Invariant: Strategy eliminates branching.
    func shouldRun(options: PipelineRunOptions, tools: ToolManager) -> Bool

    /// Execute the stage. Returns the new working path (or the input
    /// unchanged when the stage does not relocate files).
    func run(
        input: String,
        item: Int,
        context: PipelineStageContext
    ) async throws -> String
}

/// Read-mostly handle the stage needs to reach back into the controller
/// without holding a strong reference. Mirrors how `runProcess(...)` and
/// `applyLine(...)` are currently structured in PipelineController.
struct PipelineStageContext {
    let options: PipelineRunOptions
    let tools: ToolManager
    let outputDir: URL
    let appendLog: @Sendable (String) -> Void
    let updateProgress: @Sendable (Double) -> Void
    let setStageNote: @Sendable (String) -> Void
}
```

```swift
// FileBotStageRunner.swift — concrete Strategy
struct FileBotStageRunner: PipelineStageRunner {
    let stageLabel = PipelineStage.renaming.rawValue

    func shouldRun(options: PipelineRunOptions, tools: ToolManager) -> Bool {
        !options.skipFileBot && tools.hasFileBot
    }

    func run(
        input: String,
        item: Int,
        context: PipelineStageContext
    ) async throws -> String {
        guard let bin = context.tools.filebot else {
            context.setStageNote("Skipped — FileBot not installed")
            return input
        }
        // Existing argv construction lives here, unchanged.
        // ...
        return input
    }
}
```

```swift
// PipelineController+Stages.swift — loop replaces the if-ladder
extension PipelineController {
    static let stageRunners: [PipelineStageRunner] = [
        FileBotStageRunner(),
        FileBotPostScriptStageRunner(),
        SublerStageRunner()
    ]

    func runStages(input initialPath: String, item index: Int) async throws -> String {
        var workingPath = initialPath
        for runner in Self.stageRunners {
            guard runner.shouldRun(options: runOptions, tools: tools) else {
                log("\(runner.stageLabel): skipped")
                continue
            }
            workingPath = try await runner.run(
                input: workingPath,
                item: index,
                context: makeStageContext()
            )
        }
        return workingPath
    }
}
```

Edge cases the example handles:

- Stage absence (FileBot not installed) is internal to the conformer; the
  loop does not branch on it.
- New stage is added by adding one struct + one array entry; no `if`
  ladder is touched.
- `Sendable` + value-type strategies are safe to ship across actors.

---

## 2. Code Review Prompt

### When to use
Reviewing a PR or a chunk of existing code for whether the patterns
in use were chosen through the decision tree. Verdict is one of:
`correct` / `wrong pattern applied` / `pattern missing`.

### Prompt template

```
ROLE: Senior Swift architect performing a pattern-correctness review under
.cursor/rules/design-pattern-decision-tree.mdc.

TASK: For each named or implicit pattern in the code below, decide whether
the choice was correct relative to the decision tree.

CODE UNDER REVIEW:
{{paste code, include file paths}}

OUTPUT (one block per identified pattern, no other prose):

### Pattern: {{name}}
- Where: {{file:line range}}
- Inferred pain (in code terms): {{1 sentence}}
- Required branch trace: {{Root → sub-decision → pattern}}
- Observed branch trace (or "none stated"): {{trace}}
- Invariants (from the rule):
  - {{invariant 1}}: pass / fail
  - {{invariant 2}}: pass / fail
- Anti-pattern proximity: {{which rejected anti-pattern this resembles, or "none"}}
- Verdict: correct | wrong pattern applied | pattern missing
- If "wrong" or "missing": correct pattern is {{name}}, justification
  is {{branch trace}}.
```

### Worked example — input

```swift
// Excerpt — hypothetical
final class MediaMagicShared {
    static let shared = MediaMagicShared()
    var settings = AppSettings()
    var tools = ToolManager()
    var pipeline: PipelineController!
    private init() {
        pipeline = PipelineController(tools: tools)
    }
}
```

### Worked example — output

```
### Pattern: Singleton
- Where: MediaMagicShared.swift
- Inferred pain (in code terms): wanted one place to access app-wide
  collaborators.
- Required branch trace: none — "easy global access" is not a pain.
- Observed branch trace: none stated.
- Invariants:
  - "Singleton only for bounded resource with explicit lifecycle": fail —
    these collaborators are not bounded resources; they are stateful
    view models with `@MainActor` requirements.
  - "Initializer DI is the default": fail — this prevents init injection.
- Anti-pattern proximity: "Singleton for convenience" (explicitly rejected).
- Verdict: wrong pattern applied
- Correct approach: keep current MediaMagicApp wiring — `@StateObject`
  in the App scene, `@EnvironmentObject` propagation, initializer DI
  in `PipelineController(tools:)`. Delete `MediaMagicShared`. Branch
  trace is Creational → "shared collaborators" → DI, not Singleton.
```

---

## 3. Refactor Prompt

### When to use
The Code Review Prompt returned `wrong pattern applied` or
`pattern missing`. You now implement the correct pattern with full
before/after Swift code that conforms to Media Magic conventions.

### Prompt template

```
ROLE: Senior Swift architect implementing a corrective refactor under
.cursor/rules/design-pattern-decision-tree.mdc.

INPUT:
- Verdict: {{wrong pattern applied | pattern missing}}
- Existing code: {{paste}}
- Required branch trace: {{Root → sub-decision → pattern}}
- Pattern to apply: {{name}}

CONSTRAINTS:
- Swift / SwiftUI / Combine; @MainActor for view-state holders.
- Initializer DI; no service locators; no new singletons.
- Errors: enum Foo: Error, LocalizedError OR NSError(domain: "MediaMagic", ...).
- File header // block + /// doc comments + // MARK: - sections.
- Preserve existing behaviour unless explicitly told to change it.

OUTPUT (strict sections, no other prose):

## Before
```swift
{{minimal excerpt of the offending code}}
```

## After
```swift
{{full replacement with file path comment, MARK sections, doc comments}}
```

## Diff summary
- {{what moved, what was deleted, what was added}}

## Invariant confirmation (from the rule)
- {{invariant 1}}: pass — {{why}}
- {{invariant 2}}: pass — {{why}}

## Behaviour preservation note
- {{what behaviour stayed identical, what edge cases were preserved}}
```

### Worked example

**Before**

```swift
// AppSettings.swift — fragment showing branch-by-string in apply
func applyNamingPreset(_ preset: String) {
    fileBotNamingPresetRaw = preset
    if preset == "movie" {
        fileBotFormat = "{n} ({y})"
    } else if preset == "tv" {
        fileBotFormat = "{s00e00} {n} - {t}"
    } else if preset == "custom" {
        // leave as-is
    } else {
        fileBotFormat = "{n} ({y})"
    }
}
```

Verdict from review: **wrong pattern applied** — branching by raw string is
a Strategy / type-safe-enum opportunity. Branch trace:
Behavioural → branching by variant → Strategy (Swift idiom: type-safe enum).

**After**

```swift
// FileBotOptions.swift
// Type-safe enum encapsulates the naming-preset Strategy. Each case owns
// its format default. Eliminates the string-keyed if-ladder.

import Foundation

enum FileBotNamingPreset: String, CaseIterable, Identifiable {
    case movie
    case tv
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .movie:  return "Movie"
        case .tv:     return "TV"
        case .custom: return "Custom"
        }
    }

    /// Default `--format` string applied when this preset is selected.
    /// `nil` means "keep whatever is currently configured" (custom flow).
    var defaultFormat: String? {
        switch self {
        case .movie:  return "{n} ({y})"
        case .tv:     return "{s00e00} {n} - {t}"
        case .custom: return nil
        }
    }

    static let movieFormatDefault = "{n} ({y})"
    static let tvFormatDefault = "{s00e00} {n} - {t}"
}
```

```swift
// AppSettings.swift — applyNamingPreset becomes a one-liner per case
func applyNamingPreset(_ preset: FileBotNamingPreset) {
    fileBotNamingPresetRaw = preset.rawValue
    if let format = preset.defaultFormat {
        fileBotFormat = format
    }
}
```

**Diff summary**
- `applyNamingPreset(_:)` takes the type-safe enum instead of `String`.
- Format defaults moved onto the enum as `defaultFormat`. Eliminates the
  if-ladder.
- `.custom` returns `nil` ⇒ no implicit overwrite of user-edited format.

**Invariant confirmation**
- "Strategy eliminates branching, not wraps it": pass — caller is a single
  optional assignment; the case logic is owned by each enum case.
- "State is only used with explicit transitions": N/A — this is Strategy,
  not State.

**Behaviour preservation note**
- Movie / TV defaults match the existing constants. Custom path remains
  non-destructive (does not overwrite user-edited format).

---

## 4. Validation Prompt

### When to use
Someone proposed a pattern with a stated pain point. Verify the proposal
against the decision tree. Reject if the branch logic does not support it.

### Prompt template

```
ROLE: Senior Swift architect validating a pattern proposal under
.cursor/rules/design-pattern-decision-tree.mdc.

INPUT:
- Proposed pattern: {{name}}
- Stated pain point: {{text from proposer, ideally with file:line}}
- Stated branch trace (or "missing"): {{Root → sub-decision → pattern}}
- Proposed Swift sketch: {{code}}

OUTPUT (strict sections):

## Pain validity
- Concrete? {{yes/no}} — {{why}}
- Quoted from code? {{yes/no — file:line if yes}}

## Branch validity
- Stated branch: {{...}}
- Does the decision tree actually route this pain to this pattern?
  {{yes/no, walk it step by step}}

## Pattern-resolves-pain check
- Will applying the pattern eliminate the named symptom, or merely move
  it? {{eliminate / move / mask}}
- If "move" or "mask": REJECT.

## Invariant check
- {{invariant 1}}: pass / fail — {{why}}
- {{invariant 2}}: pass / fail — {{why}}

## Anti-pattern proximity
- {{which rejected anti-pattern this resembles, or "none"}}

## Verdict
ACCEPT | REJECT

## If REJECT: corrective recommendation
- Correct pattern: {{name OR "no pattern — keep procedural code"}}
- Branch trace: {{Root → sub-decision → pattern}}
```

### Worked example

```
Proposed pattern: Decorator
Stated pain point: "We want to add logging and retry to runFileBot
without changing its body."
Stated branch trace: missing.
Proposed Swift sketch:
    struct LoggingFileBot { let inner: FileBotRunner }
    struct RetryFileBot   { let inner: FileBotRunner }
    let wrapped = RetryFileBot(inner: LoggingFileBot(inner: RealFileBot()))

## Pain validity
- Concrete? yes — but the symptom ("add logging and retry") is two
  unrelated concerns.
- Quoted from code? no.

## Branch validity
- Stated branch: missing.
- Decision-tree walk: cross-cutting concerns at call sites point to
  Decorator only when wrappers are independent and stateless. Retry needs
  state (attempt count, backoff). Logging is stateless. Mixing them is
  the anti-pattern "Decorator nests that communicate through shared
  mutable side state."

## Pattern-resolves-pain check
- mask — the proposal hides the difference between stateful retry and
  stateless logging.

## Invariant check
- "Decorator chains must not share mutable state across wrappers":
  fail — retry's attempt counter leaks into the chain's correctness.

## Anti-pattern proximity
- "Decorator nests that communicate through shared mutable side state."

## Verdict
REJECT

## If REJECT: corrective recommendation
- Correct decomposition:
  1. Logging — apply at the existing `applyLine(_:progress:item:)` seam
     (Observer / property-observer style). No Decorator.
  2. Retry — a Strategy on the stage runner (`retryPolicy: RetryPolicy?`)
     that owns its own attempt state.
- Branch traces:
  - Logging: Behavioural → "many dependents on changes" → Observer.
  - Retry: Behavioural → "swap interchangeable algorithms" → Strategy.
```

---

## 5. Pattern Selection Prompt

### When to use
A problem is described; no pattern named yet. Walk the three root
questions in sequence and produce a single justified recommendation.

### Prompt template

```
ROLE: Senior Swift architect selecting a pattern under
.cursor/rules/design-pattern-decision-tree.mdc.

PROBLEM:
{{describe the problem in plain language, include relevant code if any}}

OUTPUT (must answer all three root questions in order — do NOT skip
ahead even if you "know" the answer):

## Q1 — Creation pain?
- Symptom (yes/no, with code evidence if yes): {{...}}
- Sub-decision (if yes): single instance / many w/ complex init /
  subclass picks impl / families / prototype clone.

## Q2 — Structure pain?
- Symptom (yes/no, with code evidence if yes): {{...}}
- Sub-decision (if yes): incompatible interfaces / messy subsystem /
  add responsibilities / controlled access / part-whole tree / share
  intrinsic state / decouple abstraction from impl.

## Q3 — Behaviour pain?
- Symptom (yes/no, with code evidence if yes): {{...}}
- Sub-decision (if yes): chain / encapsulate request / traversal /
  many-to-many coordination / snapshot / publish change / mode-keyed
  behaviour / swap algorithms / step skeleton / cross-tree op.

## Single recommendation
- Pattern: {{name OR "no pattern — keep current code"}}
- Branch trace: {{exact path you walked through Q1/Q2/Q3}}
- Swift implementation sketch (matches Media Magic conventions):
```swift
{{ready-to-ship snippet with file path comment, MARK sections, /// docs}}
```

## Invariant confirmation
- {{invariant 1}}: pass — {{why}}
- {{invariant 2}}: pass — {{why}}

## Anti-pattern rejection
- {{which anti-pattern was considered, why this proposal is not it}}
```

### Worked example

```
Problem: PipelineController.runProcess parses output lines into a
progress percentage. Each stage (MakeMKV, HandBrake, FileBot, Subler)
parses differently. The current implementation passes a per-call
closure: `parseLine: @Sendable @escaping (String) -> Double?`.
Should this be refactored into a protocol?

## Q1 — Creation pain?
- Symptom: no. Parsers are constructed at the call site with one-line
  closures; no complex constructors, no missing defaults.

## Q2 — Structure pain?
- Symptom: no. The closure does not leak Process / Pipe types into
  domain layers.

## Q3 — Behaviour pain?
- Symptom: yes — algorithm (line→progress) varies per stage. Already
  resolved by closure-Strategy.
- Sub-decision: swap interchangeable algorithms at runtime → Strategy.

## Single recommendation
- Pattern: keep current Strategy-via-closure.
- Branch trace: Behavioural → "swap interchangeable algorithms" →
  Strategy. Swift idiom for module-local variation is the closure.
- Swift implementation sketch (already in the codebase):
```swift
private func runProcess(
    launch: String,
    args: [String],
    stage: PipelineStage,
    item: Int,
    parseLine: @Sendable @escaping (String) -> Double?
) async throws { /* unchanged */ }
```

## Invariant confirmation
- "Strategy eliminates branching, not wraps it": pass — the runner has
  no `switch stage` for parsing; each call ships its own parser.
- "Closure-Strategy preferred when local": pass — the parsers do not
  ship from outside the module.

## Anti-pattern rejection
- "Strategy that is just one unused interface (YAGNI)": not applicable —
  multiple concrete strategies exist (MakeMKV PRGV, HandBrake percent,
  FileBot/Subler no-op). A protocol would add a layer for no caller.
```
