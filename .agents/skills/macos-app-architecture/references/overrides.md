# Skill Overrides for Installed Skills

This skill **overrides third-party skills** when there is an entry here. Each
override explains which skill claims what, what we do instead, and why.

Rules for adding one:

1. **Cite the source**: skill, file, and line if possible. Without that, it's
   not an override—it's an opinion.
2. **State if it's obsolescence or design disagreement.** They are different:
   obsolete is corrected only when updated; disagreement is permanent.
3. **Check before writing.** If it's "this no longer compiles" or "this is no
   longer the API," verify it, don't assume.

---

## Exceptions That Are Not Overrides

Before adding one, check that it isn't a legitimate case that only *appears*
to contradict this skill:

- **`axiom-macos` → `direct-distribution.md:410`** uses
  `CheckForUpdatesViewModel: ObservableObject` with `@Published`. It seems to
  contradict the rule of "no view models" and "`@Observable` over `ObservableObject`".
  **It is not an override**: it is the official Sparkle bridge, and Combine's
  `.assign(to: &$…)` requires `@Published`. Documented as a legitimate exception
  in [antipatterns.md](antipatterns.md#exception-bridging-a-kvocombine-api).

---

## Active Overrides

### Derived state cached in `@State` and synced with `onChange`

**Claim**: `swiftui-expert-skill` → `references/performance-patterns.md:352-373`
("Heavy Computation in Body") offers, as the default remedy for sorting inside
`body`, storing the sorted array in `@State private var sortedItems` and
refreshing it from `.onChange(of: items)`. Since 5.0.0,
`references/view-structure.md:276` repeats it: *"Cache derived collections on
the model (or in `@State` updated from `.onChange`)"*.

**Our approach**: derive. A computed property (`var visibleNotes: [Note]`) is
the default, as in
[architecture.md](architecture.md#keeping-view-logic-in-the-view) and
[antipatterns.md](antipatterns.md#storing-what-can-be-derived). Caching is a
measured optimization, not a starting point, and when it is warranted it needs
an explicit update rule, not a mirror kept in sync by hand.

**Reason**: design disagreement, plus a defect in that specific snippet.
`.onChange(of:)` defaults to `initial: false`, so it does not run on first
appearance: if `items` already has values when the view appears and never
changes afterwards, the list renders empty. The fix (`initial: true`) restores
the exact class of desynchronization bug that deriving removes. The same file
contradicts itself two sections later—`performance-patterns.md:375-385`
("Unnecessary State") marks storing derived state as BAD.

**Verified**: read in the installed copy at
`.agents/skills/swiftui-expert-skill/references/performance-patterns.md`,
2026-08-31. Re-read at 5.0.0 on 2026-09-15: the snippet is unchanged, only its
lines moved. `onChange(of:initial:)` semantics per Apple's documentation.

**The same claim, from Apple**: the `swiftui-specialist` skill bundled with
Xcode 27 makes the identical recommendation — `references/dataflow.md`, *"Cache
derived `@Observable` values; computed properties still establish dependencies
transitively"* — under a frontmatter declaring that it "unconditionally
supersedes any prior training". Its shape is the better one: the cache lives on
the model and updates from `didSet`, so the `onChange(of:initial:)` defect above
does not apply to it. That retires one of this override's two reasons and leaves
the other standing.

**What the measurement changed**: the mechanism is real. A computed property
over a collection does invalidate on every element edit, and the cached property
does not. So the disagreement is not about whether caching works — it is about
what triggers it. Apple's file presents the cache as *the* fix for a computed
property; this skill treats it as an optimization with a named, permanent cost:
every input feeding the derivation must carry its own update. Both sides of
that, plus the two predicted hazards that turned out not to exist, are in
[antipatterns.md](antipatterns.md#the-trigger-for-caching-is-the-dependency-not-the-cost).

**Verified**: measured 2026-09-16 on Swift 6.2.4, SDK 26.2, macOS 14 deployment
target, at the raw `withObservationTracking` API. `swiftui-specialist` read at
the Xcode 27.2 repack of the same date. It is not installed, and this entry does
not ask for it to be — see
[SKILL.md](../SKILL.md#deliberately-not-installed).

### Passing a whole value struct to a view

**Claim**: `swiftui-expert-skill` → `references/state-management.md:362-386`
("Pass only the fields a view reads") marks a child that accepts an entire
struct as AVOID, because it re-evaluates when any field changes.

**Our approach**: pass the struct when it is a dependency-free value; split it
when the element changes at a high rate. See
[previews.md](previews.md#1-narrow-inputs-not-full-models).

**Reason**: design disagreement about the threshold, not the mechanism. The
mechanism is confirmed: a row handed `note:` re-evaluated on all 50 changes to a
field it never read, and a `title:` row on none. But the cost is bounded to the
row whose element changed — a `ForEach` of 10 cost 50 evaluations, not 500 — while
a parameter per displayed field is paid at every call site and in every preview.
One row body per change is not worth that unless changes are frequent.

**Verified**: measured 2026-09-17, macOS 15.8, Xcode 26.3 (SDK 26.2), Swift
6.2.4, deployment target macOS 14, Release and Debug. Read at 5.0.0 (`00a94e1`).

---

## Nuances (Not Overrides)

Refinements to installed skills that do not contradict them. Recorded here so
they do not get rediscovered.

### From `swiftui-expert-skill`

Three claims about closures, **measured** before deciding whether to override
them. None became an override: two were adopted, one does not apply. The
harness hosts each variant in an `NSHostingView` and counts a child's `body`
evaluations while its parent re-evaluates **50 times** for a reason unrelated
to the child. macOS 15.8, Xcode 26.3 (SDK 26.2), Swift 6.2.4, deployment target
macOS 14, 2026-09-15. The pattern was identical at N = 20.

| The child receives | Release | Debug |
|---|---|---|
| Control: nothing that changes | 0 | 0 |
| Control: the changing value | 50 | 50 |
| `Binding(get:set:)` | **50** | **50** |
| A key-path binding (`$state.isShowingError`, `$model[scoreFor:]`) | 0 | 0 |
| An `@Entry` closure re-created on each parent `body` | 1 | 1 |
| …plus an unrelated environment write in the subtree | **1** | **50** |
| An `@Entry` struct holding an `@Observable` reference, re-created, same writes | 0 | 0 |
| An `onEvent` closure capturing `@State` or a store | 1 | 1 |

A 1 is a single extra evaluation on the first update. It does not grow with N.

- **Closure bindings: confirmed, adopted.** `state-management.md:218-235`
  ("Prefer KeyPath Bindings Over Closure Bindings"). A child handed
  `Binding(get:set:)` re-evaluates on every parent update, in both build
  configurations. [antipatterns.md](antipatterns.md#an-enum-for-all-view-state)
  used one in its *Right* example until 3.2.0.
- **Closures in environment keys: Debug only, adopted anyway.**
  `environment-patterns.md:69-73` ("Never Store Closures in Custom Keys"). In
  Release the reader paid once; in Debug, every environment write in the subtree
  re-evaluated it. Adopted because behaviour that depends on the optimization
  level can change with any toolchain, and the replacement costs nothing. See
  [modularization.md §4](modularization.md#4-crossing-a-feature-boundary-on-macos).
- **Closure parameters are a different case.** An event closure passed to a view
  (Quick Rule 5's `onEvent`) cost one evaluation, once. Do not stretch the two
  rules above to cover it. Content closures (`view-structure.md:359`, "Avoid
  Closure-Based Content") were **not measured**.

One claim about `@Entry` defaults, **compiled** rather than measured, because the
question was whether its fix builds: `environment-patterns.md:95-124` ("Keep
Default Values Stable"). Swift 6.2.4 (Xcode 26.3, SDK 26.2), Swift 6 language
mode, deployment target macOS 14, 2026-09-17.

The premise holds. `-dump-macro-expansions` shows `@Entry var model = Model()`
expanding to a computed getter, `static var defaultValue { get { Model() } }`: a
new instance on every fallback read. The fix does not compile where the problem
does:

| `Model` is | `= Model()` | `static let defaultModel = Model()` (the fix) | `Model?`, `nil` default |
|---|---|---|---|
| `@MainActor @Observable`, explicit `init` | ✗ | ✗ | ✓ |
| A non-`Sendable` class, `@Observable` or not | **✓** | ✗ | ✓ |
| Either, with `.defaultIsolation(MainActor.self)` | ✓ | ✓ | not tested |

The errors are `main actor-isolated default value in a nonisolated context` and
`static property 'defaultModel' is not concurrency-safe because non-'Sendable'
type 'Model' may have shared mutable state`. A file-scope `private let` fails the
same way. A `@MainActor` class with a synthesized `init` compiles in all three,
because a synthesized `init` is nonisolated.

- **Stable defaults: adopted, fix narrowed.** Not an override: the rule is right,
  its fix is incomplete. Nothing here hits it, because
  [architecture.md](architecture.md#dependency-injection-three-mechanisms-one-rule)
  sends an `@Observable` store through `.environment(store)`, which has no
  default, and keeps `@Entry` for stateless values (`FileNoteRepository()` and
  `NavigateAction()` are structs). If a reference type does end up in `@Entry`,
  give it a `nil` default. The `static let` compiles only under `MainActor`
  default isolation, and whether SwiftUI reading that `@MainActor` static off the
  main actor traps like
  [a hand-written key](antipatterns.md#a-callback-or-key-that-silently-inherits-mainactor)
  was **not measured**.

### From `swiftui-performance-audit`

These three come from
[swiftui-performance-audit](https://github.com/Dimillian/Skills/tree/main/swiftui-performance-audit)
(Thomas Ricouard, MIT), which is otherwise not worth installing: it duplicates
`swiftui-expert-skill` and `instruments-profiling`, and its profiling path asks
a human to paste Instruments screenshots instead of reading a trace from the
command line.

- **`equatable()` is conditional.** `performance-patterns.md:63-85` recommends
  conforming expensive views to `Equatable`. The condition it omits: it only
  pays off when comparing is cheaper than recomputing the subtree, and when the
  inputs are value-semantic enough for equality to mean anything. It is not a
  blanket fix for redraws. (`code-smells.md:135`)

- **`@State` is not a general-purpose cache.** Use it for state the view owns.
  Moving an expensive computation into it without defining when and why it
  updates buys a synchronization bug instead of performance. Prefer
  precomputing in the store, or preprocessing in a background task before
  rendering. (`code-smells.md:125`) Related to the override above.

- **Triage order when several smells appear together.**
  `performance-patterns.md:331-341` lists common bottlenecks without ranking
  them. By impact: (1) broad invalidation and observation fan-out,
  (2) unstable identity and list churn, (3) main-thread work during render,
  (4) image decode and resize, (5) layout and animation complexity.
  (`code-smells.md:143`)

### From `axiom-macos`

- **Keep the `SPUStandardUpdaterController`, not just its updater.**
  `direct-distribution.md:410-430` builds the controller inside `init`, stores
  `controller.updater`, and lets the controller go out of scope. Every official
  Sparkle example stores the controller itself as a property. **Not measured
  here** whether dropping it breaks the update flow — `SPUUpdater` may retain
  enough of the graph, and Sparkle's documentation states no retention rule — so
  this is a nuance, not an override. One stored property removes the question,
  and the failure it would cause (an updater that silently stops checking) is
  invisible until users stop receiving updates.
  See [distribution.md §3](distribution.md#3-the-controller-is-the-object-that-must-stay-alive).
  **Verified**: file read at
  `axiom-codex/skills/axiom-macos/skills/direct-distribution.md`, 2026-09-02;
  Sparkle's programmatic-setup documentation read the same day.

---

## Revision Status

**As of 2026-08-31**, for the 11 installed skills; `swiftui-expert-skill`
re-read at 5.0.0 on 2026-09-15:

- **`swiftui-expert-skill`** (AvdLee) — **does not conflict by design**. It
  literally states: *"do not enforce specific architectures (MVVM, VIPER, etc.)"*
  and *"encourage separating business logic from views for testability without
  mandating how"* (`SKILL.md:14-15`). It leaves the architecture gap empty, which
  is exactly what this skill occupies. **At 5.0.0** it gained SDK 27 guidance
  (the `@State` macro, `@ContentBuilder`, `Document`, attributed `TextEditor`,
  toolbars, WebKit). All of it is execution layer, and none of it was verified
  here: no Xcode 27 toolchain was available. Its closure rules had been
  contradicted here since 4.2.0 without an entry; they are now measured and
  adopted, see [the nuances above](#from-swiftui-expert-skill).
- **`swift-concurrency`** (AvdLee), **`swift-testing-expert`** — use `ViewModel`
  as an example object to demonstrate `@MainActor` and tests. Not architectural
  advice.
- **`txt-*`** (5 skills from `apple-text`), **`instruments-profiling`**,
  **`macos-spm-app-packaging`** — zero overlap: they are execution-layer skills.
- **`axiom-macos`** — declares *"You MUST use this skill for ANY macOS-specific
  development including… AppKit bridging"* (`SKILL.md:9`). **Scope notice**:
  when writing `appkit-bridge.md` here, it must address *who owns the state and
  how high-frequency events are bridged* — the decision. The mechanics of
  `NSViewRepresentable` are theirs. The same split now applies to
  distribution: `direct-distribution.md` keeps signing, notarization, packaging
  and the Sparkle API; [distribution.md](distribution.md) takes only the
  decisions those mechanics assume have already been made.

---

## Template

```markdown
### <theme>

**Claim**: `<skill>` → `<file>:<line>` claims that …
**Our approach**: …
**Reason**: [obsolete since <version> | design disagreement]
**Verified**: <how it was verified, date>
```
