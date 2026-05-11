# Pattern Change Record (template)

Complete this document **every time a design pattern is introduced, replaced,
or removed** in the Media Magic codebase. The completed record lives next to
the PR description (paste it into the PR body) and is referenced from the
commit message. Branch trace is mandatory — see
`.cursor/rules/design-pattern-decision-tree.mdc`.

---

## 1. Scope

- **Date** (`YYYY-MM-DD`): `…`
- **Build ID this change targets** (`<VERSION>+<BUILD_NUMBER>`): `…`
- **Author**: `…`
- **Change type**: `introduce` | `replace` | `remove`
- **Files affected** (one per line, with line ranges where useful):
  - `Sources/MediaMagic/…swift:L…–L…`
  - `Sources/MediaMagic/…swift:L…–L…`
- **Architectural layer(s) touched**:
  - `View` (SwiftUI `View`s)
  - `ViewModel` (`@MainActor final class … : ObservableObject`)
  - `Domain` (value-type models, enums, structs)
  - `Tooling / Boundary` (Process runners, FileManager, URLSession)
  - other: `…`

## 2. Observed pain point (in code terms — NOT abstract)

State the symptom that motivated the change. Quote code or describe the
exact `if`/`switch`/init shape. No "best practices" rationales.

> Example:
> `PipelineController.processItem(at:)` contains two near-identical
> `if runOptions.skipX { log/skip } else { try await runX(…) }` blocks
> (lines 239–268). Adding a fifth stage will duplicate the block again.

Pain (this change):

```
{{quote / describe}}
```

## 3. Decision-tree path followed

Walk the tree from the root. Do not skip a step. The required form is:

```
{Creational | Structural | Behavioural} → {sub-decision} → {pattern}
```

Example: `Behavioural → branching by variant → Strategy`.

This change:

```
{{your trace}}
```

If two patterns are introduced together, list two independent branch
traces — never merge them.

## 4. Pattern selected & Swift implementation approach

- **Pattern name**: `…`
- **Swift idiom used** (pick exactly one and justify):
  - [ ] Protocol with concrete conformers (`Adapter` / `Strategy` shipping
        from another module)
  - [ ] Type-safe `enum` with per-case methods (`Strategy` for finite
        in-module variants)
  - [ ] `@Sendable @escaping` closure parameter (`Strategy` /
        `Command` local to one call)
  - [ ] `struct` value object with `build() throws -> T` (`Builder`)
  - [ ] `final class` wrapper with translation-only methods (`Adapter` /
        `Facade`)
  - [ ] `@Published` + `ObservableObject` / property observer
        (`Observer`)
  - [ ] `enum`-of-states with centralized transition function (`State`)
  - [ ] other: `…`
- **DI mechanism** (must be one of the codebase conventions):
  - [ ] Initializer injection (`init(tools: ToolManager)` style)
  - [ ] `@EnvironmentObject` view-tree propagation
  - [ ] Static `make…(…)` factory returning protocol-typed value
  - [ ] N/A (value type, no DI)
- **Naming conformance**:
  - Domain prefix where applicable (`FileBot…` / `HandBrake…` /
    `Subler…` / `MakeMKV…` / `Pipeline…`): yes / no — `…`
  - `PascalCase` types, `lowerCamelCase` members: yes
  - `// MARK: -` sections added: yes / no
  - `///` doc comments on public API: yes
- **Error handling**:
  - Domain `enum Foo: Error, LocalizedError`: yes / no — name: `…`
  - `NSError(domain: "MediaMagic", code: …, userInfo: …)`: yes / no
  - `async throws` propagation preserved: yes / no
- **Concurrency**:
  - `@MainActor` annotation respected on view-state holders: yes / no
  - `@Sendable` closures and value-type strategies: yes / no

## 5. Confirmation — does the pattern resolve the named pain point?

Answer the three sub-questions explicitly. Anything other than three
"yes" answers is a stop-the-line.

1. **Did the original symptom disappear** from the code? (`if`-ladder
   gone, builder validates, branch collapsed, etc.) — `yes` / `no`
   - Evidence (diff lines): `…`
2. **Was the symptom eliminated rather than relocated** to a wrapper or
   parallel structure? — `yes` / `no`
   - Evidence: `…`
3. **Was no new pattern smuggled in** that the decision tree did not
   sanction? — `yes` / `no`
   - Evidence: `…`

## 6. Pattern invariants (must hold)

Tick the invariants that apply to the selected category. All ticked
boxes MUST be `pass`.

### Creational
- [ ] **Builder validates required fields before returning the object.**
      No half-built instances escape construction (`build()` throws
      or returns `Result`).
- [ ] **Factory hides the concrete choice.** Caller depends on the
      protocol / enum result, not the concrete type.
- [ ] **Singleton (if used) backs a bounded resource with explicit
      lifecycle.** "Easy access" was not the rationale.

### Structural
- [ ] **Adapter contains only translation logic** — no business rules,
      no validation beyond shape conformance, no domain decisions.
- [ ] **Facade is one-way and read-mostly** — small intention-named
      surface, forwards to subsystem, no domain decisions of its own.
- [ ] **Decorator chains do not share mutable state across wrappers.**
      Each decorator is independently testable.

### Behavioural
- [ ] **Strategy eliminates branching, not wraps it.** No `switch` on
      the variant inside the strategy.
- [ ] **State uses explicit modes AND transitions.** Boolean flags do
      not stand in for modes.
- [ ] **Observer notifications are non-circular.** Emit/receive
      direction is documented at the publisher.
- [ ] **Chain of Responsibility handlers each declare their own
      short-circuit condition.**

## 7. Anti-pattern check (must pass)

Confirm that none of the explicitly rejected anti-patterns from the
rule apply:

- [ ] Not a Singleton-for-convenience.
- [ ] Not a Decorator nest with shared mutable side state.
- [ ] Not an Adapter that encodes domain rules.
- [ ] Not a Strategy with a single implementation (YAGNI).
- [ ] Not a Visitor on flat CRUD data.
- [ ] Not a "god Mediator" — view-tree DI was considered first.

## 8. Tests / verification

- New tests added (paths): `…`
- Existing tests touched: `…`
- Manual verification steps (commands, UI flows): `…`
- Build artifact ID where this was first shipped (`<VERSION>+<BUILD_NUMBER>`):
  `…`

## 9. Rollback plan

- Revert commit: `…`
- Build to roll back to: `builds/<VERSION>+<BUILD_NUMBER>/MediaMagic.app`
- Risk of partial revert (data shape, persisted keys, public API): `…`

---

### Minimal example (Strategy, `Behavioural → branching by variant`)

> Use this as a sanity-check; it is not a substitute for the full form.

- Files: `Sources/MediaMagic/AppSettings.swift:L106-L116`,
  `Sources/MediaMagic/FileBotOptions.swift:L34-L51`
- Pain: `applyNamingPreset(_:)` branched on a raw-string preset; adding
  presets required editing the `if`-ladder in `AppSettings`.
- Branch: Behavioural → branching by variant → Strategy (Swift idiom:
  type-safe enum with per-case method).
- Pattern: `FileBotNamingPreset` gained `defaultFormat`; the if-ladder
  was deleted.
- Resolution: symptom eliminated (no `if`-ladder); not relocated (logic
  moved onto the enum case, not into a wrapper).
- Invariants: Strategy eliminates branching — `pass`.
- Anti-patterns: none.
