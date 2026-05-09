# Skill — Design-pattern decision tree (GoF-aligned)

Apply this skill when refactoring architecture, proposing patterns, reviewing PRs for “pattern smell,” or when the assistant is tempted to name a pattern without a stated problem.

---

## Core flow (mirror the graphic)

Start from: **what problem category is it?**

### A — Creation (“Need to create objects?”)

- **One shared instance globally** → Singleton (justify hard: config, bounded resource — **avoid** if “convenience”).
- **Many instances, complex composition** → **Builder**.
- **Who picks the concrete implementation?**
  - Subclass decides → **Factory Method**.
  - Families of related products → **Abstract Factory**.
  - Copy from prototype → **Prototype**.

### B — Structure (“Need to structure objects/classes?”)

- **What’s the goal?**
  - Incompatible interfaces → **Adapter**.
  - One entry to a messy subsystem → **Facade**.
  - Add responsibilities flexibly → **Decorator** — watch for interdependent wrappers.
  - Controlled access → **Proxy**.
  - Tree / part-whole → **Composite**.
  - Share intrinsic state → **Flyweight**.
  - Decouple abstraction from implementation → **Bridge**.

### C — Behaviour (“Need to handle behavioural algorithms?”)

- **Pass request along a flexible chain** → **Chain of Responsibility**.
- **Encapsulate requests / undo-redo hook** → **Command**.
- **Traverse aggregates** → **Iterator**.
  - Prefer language-native iteration when enough.
- **Coordinate many colleagues** → **Mediator**.
  - Prefer small domain services over god mediators.
- **Snapshot restore** → **Memento**.
- **Many dependents on changes** → **Observer** — avoid UI subscription soup.
- **Behaviour depends on mode** → **State** (modes + transitions well-defined).
- **Swap interchangeable algorithms / policies** → **Strategy**.
- **Template skeleton, variant steps** → **Template Method** / hooks.
- **Operations over a structure without changing nodes** → **Visitor** — rare in CRUD stacks; justify.

---

## Pattern → pain-point map (compact)

| If the symptom is… | Consider… |
| --- | --- |
| Constructor has 12 params + optional flags | Builder / factory hides defaults |
| `if vendor == …` sprawls across handlers | Adapter + Strategy boundary |
| Page components import DB drivers OR raw HTTP details | Structural Facade/service module |
| `switch (status)` in five files | State or Strategy + single owner |
| “Global config object” Singleton everywhere | Prefer explicit DI (`Depends()`, React context scoped to subtree) |

---

## Anti-patterns (reject)

1. Singleton for globals without concurrency/lifecycle rationale.
2. Pattern as resume decoration — refactor without a traced branch.
3. Adapter that encodes pricing rules instead of translating shapes.
4. Decorator nests that communicate through shared mutable side state.
5. Strategy that is just one unused interface (YAGNI until branching appears).

---

## Stack notes (intent)

When **React/Next.js** and **FastAPI** are present:

- **Adapters** sit at boundaries: HTTP schema ↔ pydantic/domain; REST response ↔ hook return type.
- **Facade** hides third-party APIs (payments, CDN) behind one module per bounded context.
- **Strategy / State** belong in backend services first; frontend mirrors minimal policy knobs.

Always **document the branch trace** next to non-trivial pattern use in code reviews.
