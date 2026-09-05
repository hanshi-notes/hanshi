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

**Claim**: `swiftui-expert-skill` → `references/performance-patterns.md:366-386`
("Heavy Computation in Body") offers, as the default remedy for sorting inside
`body`, storing the sorted array in `@State private var sortedItems` and
refreshing it from `.onChange(of: items)`.

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
contradicts itself two sections later—`performance-patterns.md:389-399`
("Unnecessary State") marks storing derived state as BAD.

**Verified**: read in the installed copy at
`.agents/skills/swiftui-expert-skill/references/performance-patterns.md`,
2026-08-31. `onChange(of:initial:)` semantics per Apple's documentation.

---

## Nuances (Not Overrides)

Refinements to installed skills that do not contradict them. Recorded here so
they do not get rediscovered.

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

**As of 2026-08-31**, for the 11 installed skills:

- **`swiftui-expert-skill`** (AvdLee) — **does not conflict by design**. It
  literally states: *"do not enforce specific architectures (MVVM, VIPER, etc.)"*
  and *"encourage separating business logic from views for testability without
  mandating how"* (`SKILL.md:13-14`). It leaves the architecture gap empty, which
  is exactly what this skill occupies.
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
