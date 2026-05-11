# Pattern Reference Index

Reference table covering every Gang-of-Four pattern addressed by
`.cursor/rules/design-pattern-decision-tree.mdc`. Use this table only
**after** the decision-tree branch has been walked from the root — never
as a shopping list. Every row includes:

- **Pain category** — Creational / Structural / Behavioural
- **Branch logic** — the exact sub-decision that selects this pattern
- **Code-level detection signals** — observable triggers in source
- **Swift implementation note** — matches MediaVault conventions
- **Framework notes** — React/Next.js and Python/FastAPI for legacy
  compatibility with the prior `.cursor/rules` work
- **Common misuse to avoid**

Conventions abbreviation key for the Swift column:

- `@MainActor final class … : ObservableObject` — view-state holders.
- `init(dep: Dep)` — initializer DI. No service locator. No new
  singletons.
- `enum Foo: Error, LocalizedError` — typed errors. Ad-hoc throws use
  `NSError(domain: "MediaVault", code:, userInfo: [NSLocalizedDescriptionKey: …])`.
- `// MARK: - Section` separators; `///` doc comments for public API.

---

## Creational

| Pattern | Branch logic | Detection signals | Swift (MediaVault style) | React/Next.js | Python/FastAPI | Common misuse |
| --- | --- | --- | --- | --- | --- | --- |
| **Builder** | Creation → many instances, complex composition, conditional fields | `init(...)` with 7+ params; many optional flags; same `init` called with subtly different shapes; partially-initialized objects passed around | `struct FooBuilder { … func with…(…) -> Self … func build() throws -> Foo }`. `build()` is `throws`; partial state is unreachable. Use only when ≥7 inputs or conditional inclusion exists — otherwise pass a parameter `struct` (mirrors `PipelineRunOptions`). | Builder is rare; a typed config object or a factory hook is more idiomatic. | Pydantic model + dependency that constructs the domain object (`Depends(make_foo)`). | Builder that returns a non-throwing partial object; "chainable setters" on a class shared mutably; `build()` that performs domain logic. |
| **Factory Method** | Creation → subclass / strategy picks the concrete implementation | One construction site, several concrete subclasses returned via a single function | `static func makeRunner(for: Kind) -> some PipelineStageRunner`. Caller depends on the protocol, never on the concrete struct. | Custom hook returning the right component per variant. | `Depends()` resolving to one of several concrete services. | Factory that returns a concrete (defeats the abstraction); factory whose only purpose is to call `init` once. |
| **Abstract Factory** | Creation → families of related products that vary together | Two or more co-varying objects constructed together per environment | Protocol with multiple `make…` methods, one conformer per family. Inject via `init`. | Context provider that yields a family of related hooks. | Settings class returning a related set of repositories. | Splitting one factory into two when only one product family exists. |
| **Prototype** | Creation → cheap copy of a configured instance | Need to duplicate a configured value with one or two tweaks | Value types in Swift copy automatically; this pattern is usually free. If a reference type needs cloning, conform to a project-local `Cloneable` protocol with an explicit `clone()` method. | `useMemo`/structuralClone of a config object. | `model_copy(update={…})` on Pydantic models. | Adding `Cloneable` to a value type that already copies for free. |
| **Singleton** | Creation → bounded resource with explicit lifecycle (config, OS service handle) | A single shared resource must be unique for correctness | **Prefer not to introduce new ones.** Use `URLSession.shared` etc. when wrapping OS primitives; never create `static let shared` for view models. Initializer DI is the default. | `React.Context` at the app root with one provider. | Module-level constant for stateless config; `lru_cache` for memoized factories. | "Easy global access"; singletons holding mutable app state; replacing DI. |

## Structural

| Pattern | Branch logic | Detection signals | Swift (MediaVault style) | React/Next.js | Python/FastAPI | Common misuse |
| --- | --- | --- | --- | --- | --- | --- |
| **Adapter** | Structure → external interface incompatible with internal one | External API JSON / DTO types referenced from `View`s or domain models; argv translation for a CLI; URLSession delegate methods | **Protocol at the boundary** + a `final class` or `struct` conformer that contains argv/JSON translation only. Mirrors `Process.runShell(_:_:)` extension and `URLSessionDownloadDelegate`. **No business rules** in the adapter. | Hook or service module that maps REST responses to typed view models. | Pydantic schema in routers; mappers in `adapters/` modules. | Adapter that validates pricing, applies discounts, or makes domain decisions. |
| **Facade** | Structure → caller invokes 4+ subsystem APIs in sequence for one logical task | Long sequences of low-level calls; subsystem types leaking into call sites | `enum` of `static func`s **or** a small `final class` exposing intention-named methods. Mirrors `FileBotScriptLibrary` and the `tools.handbrakeCLI` accessors. | One module per bounded context wrapping third-party SDKs. | One service class per domain that orchestrates repo + external calls. | Facade that grows domain decisions; "god facade" hiding everything. |
| **Decorator** | Structure → add a cross-cutting concern that wraps a stable interface | Logging / retry / caching duplicated at call sites and the wrappers are **independent** | Protocol + value-type wrapper conforming to the same protocol. Each decorator is independently testable; no shared mutable state. | Higher-order components or composable hooks. | ASGI/HTTP middleware (one concern per layer). | Decorator stacks with shared counters or interleaved retries; mixing stateful and stateless concerns in one chain. |
| **Proxy** | Structure → controlled access / lazy / remote stand-in | Caller needs auth / rate-limit / lazy materialization without changing the call site | `final class` conforming to the same protocol as the real implementation, with policy in the proxy. | Server Action wrapping client-side fetch. | Decorated FastAPI dependency that wraps the real service. | Proxy that mutates behaviour beyond access control (then it's an Adapter or Strategy). |
| **Composite** | Structure → uniform treatment of part / whole tree | Recursive data (folders/files, UI groups, AST nodes) with shared operations | `enum Node { case leaf(Leaf); case branch([Node]) }` with methods using `switch`. SwiftUI views compose naturally. | Component tree composition. | Recursive Pydantic models with discriminated unions. | Forcing Composite onto flat lists. |
| **Flyweight** | Structure → many objects share intrinsic state | Large object counts; intrinsic state easily de-duplicated | Static dictionary keyed by intrinsic key; consumers receive a reference. Rare in this app. | Memoization (`useMemo`, stable selectors). | Module-level constant pool; `functools.lru_cache`. | Premature optimization; Flyweight where extrinsic state also leaks shared. |
| **Bridge** | Structure → decouple an abstraction from a swappable implementation hierarchy | Two orthogonal axes of variation (`{Stage} × {Runner backend}`) growing into a class explosion | Two protocols, composition between them (one held inside the other). Inject via `init`. | Hook + adapter pairing. | Service protocol + repo backend, wired by Depends. | Using Bridge for a single backend; treating it as Adapter. |

## Behavioural

| Pattern | Branch logic | Detection signals | Swift (MediaVault style) | React/Next.js | Python/FastAPI | Common misuse |
| --- | --- | --- | --- | --- | --- | --- |
| **Strategy** | Behaviour → swap interchangeable algorithms / policies at runtime | `switch enumValue { … }` repeated in 3+ files; `if vendor == …` sprawling across handlers; per-stage parsers with different shapes | **Prefer closures or type-safe enums in-module** (mirrors `parseLine: @Sendable @escaping (String) -> Double?` in `PipelineController.runProcess`). **Promote to protocol** when strategies ship from outside the module or carry state. | Custom hook per strategy; component prop selecting an injected handler. | Protocol class + registry resolved via `Depends()`. | Strategy with one implementation (YAGNI); strategy that still contains the original `switch` internally. |
| **State** | Behaviour → object behaviour depends on internal mode AND transitions are explicit | Multiple boolean flags that together imply a mode; `switch state { ... }` whose cases enable / disable other operations | `enum Stage { … }` with associated values for stage-local data (mirrors `enum PipelineStage`). Transitions centralized in a single method on the owning `@MainActor` view model; illegal transitions throw. | Reducer + discriminated-union state. | Finite-state machine class with explicit transition table. | State pattern with implicit transitions; using State when Strategy fits (no mode involved). |
| **Observer** | Behaviour → many dependents react when a value changes | Multiple components watch a shared value; manual "notify everyone" loops | `@Published` on an `ObservableObject` + `@EnvironmentObject` / `@ObservedObject` consumers. Property observers (`didSet`) for in-class side effects. Combine `Publisher` for time-shifted streams. `NotificationCenter` only for OS events. | Context + `useEffect` subscribers. | `asyncio.Event` / pub-sub via a message bus. | Hand-rolled `NotificationCenter` for in-process events; circular notification chains. |
| **Command** | Behaviour → encapsulate a request as an object (undo, queue, schedule, log) | Operation must be queued, retried, persisted, or undone | `struct FooCommand: Sendable { func run() async throws -> Output }`. Closures acceptable for one-shot fire-and-forget. | Redux/Zustand actions; React Query mutations. | Celery/Arq task struct; CQRS command object. | Command used where a plain method call works; Command that mutates global state without identity. |
| **Chain of Responsibility** | Behaviour → request flows through handlers, each may short-circuit | Sequential handlers, each with a "should I handle?" check; current code: `if runOptions.skipX … else …` for each stage | Array of strategy structs iterated in `runStages(…)`. Each runner declares `shouldRun(options:tools:)` and either runs or yields. | Middleware stack. | ASGI/FastAPI middleware. | Chain with hidden ordering dependencies; handler that always runs (then it's not a chain). |
| **Mediator** | Behaviour → many-to-many coordination needs a hub | Multiple components mutate or read shared state via ad-hoc back-channels | **Prefer not to introduce.** Use `@EnvironmentObject` view-tree injection or a single coordinator view model owning narrow `@Published` state. Only escalate to Mediator when ≥3 collaborators have bidirectional needs. | React Context scoped to a subtree. | Application service that orchestrates domain services. | "God mediator" that becomes the de facto Singleton; bypassing DI. |
| **Iterator** | Behaviour → traversal over an aggregate, decoupled from its shape | Custom sequence shapes that need element-by-element consumption | `Sequence` / `IteratorProtocol` conformance, or `for await … in` over an `AsyncSequence`. **Prefer language-native iteration**; introduce a custom iterator only when shape genuinely needs hiding. | `for ... of` / generators. | Generators / async generators. | Custom iterator over a plain `Array` (use the language). |
| **Template Method** | Behaviour → algorithm skeleton fixed, individual steps vary | Same outer loop / pre/post in many siblings, only middle differs | Generic algorithm + `@Sendable @escaping` closure step parameter; or a base implementation with a protocol requirement for the variant step. | Custom hook with injected callback steps. | Base class with abstract method overrides. | Template Method using subclassing where injection of a closure suffices. |
| **Memento** | Behaviour → capture / restore snapshots of state | Undo/redo or "preview before commit" semantics | `struct Snapshot: Codable, Sendable` storing the relevant state; restore is a simple assignment. | Time-travel state libraries. | DB rows or `dataclasses.replace`. | Memento that exposes private fields broadly. |
| **Visitor** | Behaviour → operations over a heterogeneous structure without changing the nodes | Stable node hierarchy; many disjoint operations that must traverse uniformly | **Rare in app code — justify.** Swift's typed enums + exhaustive `switch` usually suffice and are checked by the compiler. | Renderer functions over a typed tree. | `singledispatch` over node classes. | Visitor on flat CRUD models. |

---

## Quick-pick crosswalk (signal → pattern)

| Symptom (quoted from code) | Branch | Pattern | Why |
| --- | --- | --- | --- |
| `init(...)` with 12 parameters and four optional flags | Creational | Builder (or parameter `struct`) | Parameter object first; Builder only if conditional inclusion exists. |
| `static let shared` accessed for "easy access" | Creational | **None** — replace with initializer DI | Singleton-for-convenience is rejected. |
| `if runOptions.skipX { skip } else { try await runX() }` repeated per stage | Behavioural | Strategy + Chain of Responsibility | One runner per stage; the loop iterates without per-stage `if`. |
| URL/JSON shapes appearing inside `View`s | Structural | Adapter | Translation-only protocol conformer at the boundary. |
| `switch settingsKeyString { case "movie": … case "tv": … }` | Behavioural | Strategy via type-safe `enum` | `FileBotNamingPreset` with per-case `defaultFormat` (already in this codebase). |
| `@Published` not used; multiple views poll a class for changes | Behavioural | Observer | `@Published` + `ObservableObject` is the Swift-native Observer. |
| Caller invokes `Process(…)`, `Pipe()`, `proc.run()`, drains stdout, parses errors in five places | Structural | Facade | `Process.runShell(_:_:)` extension (already in this codebase). |
| `if mode == .ready && hasOutput && !isErrored { … }` triplets across the file | Behavioural | State | `enum Stage` + centralized transition method. |
| Cross-cutting logging + retry around a CLI call | Behavioural × 2 | Observer (logging) **and** Strategy (retry policy) | Two distinct pains, two branch traces. **Do not** combine into a Decorator chain. |

---

## How to use this index

1. **Walk the decision tree first.** This table is not a menu.
2. **Cite the row.** When you propose a pattern in a PR description or
   commit, reference the row plus the branch trace, e.g.
   "Strategy (Behavioural → branching by variant)".
3. **Verify invariants** from
   `.cursor/rules/design-pattern-decision-tree.mdc` for the pattern's
   category. Note the result in `PATTERN_CHANGE_TEMPLATE.md`.
4. **Pass the anti-pattern check** in the same template.
5. **Match the conventions column.** New Swift code MUST match
   MediaVault style (initializer DI, `@MainActor` view models, value-
   type domain models, typed errors, MARK sections, doc comments).
