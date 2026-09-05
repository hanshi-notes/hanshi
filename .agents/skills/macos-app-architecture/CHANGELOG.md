# Changelog — macos-app-architecture

This file ships **inside the skill**, on purpose. `npx skills update macos-app-architecture`
overwrites `.agents/skills/macos-app-architecture/` in place, so the changelog has to arrive in the
same diff as the rules it describes. A changelog left behind in the source repository is one the
consumer never sees.

## What the version number means

`metadata.version` in [SKILL.md](SKILL.md) is semver, and the question it answers is *"can code that
passed review yesterday fail today?"*

| Bump | Means | Consumer action |
| --- | --- | --- |
| **MAJOR** | A rule got stricter: a new Quick Rule, a new anti-pattern existing code can violate, a new override of a companion skill, or a change to which companion skills must be installed. Compliant code can stop being compliant. | Read the entry. It names what it invalidates and what to do. |
| **MINOR** | New ground covered **that invalidates nothing**: a reference file about a subject the codebase has not touched yet, a rationale made explicit, better examples. | Read at leisure. |
| **PATCH** | Wording, links, formatting, a re-verification date. No rule changed. | None. |

The invalidation test governs, and it beats the category every time. "Previously unspecified" is
**not** a reason to call something MINOR: a first rule about an unaddressed subject is MAJOR the
moment existing code can violate it. If you have to think about whether anything breaks, you already
have your answer — bump MAJOR.

**Every MAJOR entry states what it invalidates and how to comply.** That is the same bar
[overrides.md](references/overrides.md) puts on an override of a third-party skill: a change without
a stated consequence becomes silent drift by accident.

Release procedure: bump `metadata.version` in `SKILL.md` and add the entry here **in the same commit
as the rule change**, then tag `v<version>`.

## 3.1.1 — 2026-09-05

**PATCH: formatting. No rule changed, no companion skill added or removed.**

The seven companion-skill install commands now also appear as a single `bash` block under the
table in [SKILL.md](SKILL.md#companion-skills), so the whole set can be copied and pasted in one
go. The per-skill commands stay in the table's *Install* column; the block repeats them, it does
not replace them. Same seven skills, same URLs.

## 3.1.0 — 2026-09-02

**MINOR by number, but read it like a MAJOR: a new Quick Rule and a new anti-pattern, and
existing configurations can violate both.**

1. **Quick Rule 20 — distribution is decided before the first release.** New document:
   [distribution.md](references/distribution.md), which fills the `distribution.md` slot
   listed as planned since 1.0.0. It covers only the decisions; signing, notarization,
   packaging and the Sparkle API stay with `axiom-macos` and `macos-spm-app-packaging`,
   and §5 states the split explicitly.

   Two of its facts invalidate existing configurations:

   - **The sandbox reaches the updater.** **Verified** against Sparkle's sandboxing guide,
     2026-09-02: a sandboxed app needs `SUEnableInstallerLauncherService` **and** a
     `com.apple.security.temporary-exception.mach-lookup.global-name` entitlement listing
     `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`; a non-sandboxed app needs neither.
     *Comply*: check that a sandboxed app shipping Sparkle has both halves. Half of the
     pair builds, notarizes, launches and downloads an update, then fails to install it —
     on a user's machine, in a build already shipped.
   - **`SUPublicEDKey` is permanent for every copy already installed.** Sparkle verifies
     against the key the *installed build* carries. **Verified** against Sparkle's
     documentation, 2026-09-02: the private key is erased with the Keychain, and recovery
     by key rotation works *because the app is Developer ID signed*. An app without that
     signature has no fallback. *Comply*: back the private key up off the build machine,
     give it the same status as the Developer ID certificate, and record both it and
     `SUFeedURL` as standing decisions.

2. **[The global updater](references/distribution.md#2-one-file-imports-sparkle-and-the-app-owns-it).**
   New anti-pattern. An `UpdaterManager.shared` singleton read by views through
   `@ObservedObject` breaks three rules at once: a `static let` makes the scope the process
   rather than the injected subtree, `@ObservedObject` on an unowned object leans on the
   global to stay alive, and constructing the singleton in a preview starts a real
   `SPUStandardUpdaterController`. *Comply*: define an `UpdateChecking` protocol in the
   app's own vocabulary, let exactly one type conform to it with `import Sparkle`, and have
   the App own it with `@StateObject`. The `ObservableObject` bridge remains the exception
   [antipatterns.md](references/antipatterns.md#exception-bridging-a-kvocombine-api) already
   allows — contained to one file, which is the point.

Also in this release, invalidating nothing on their own:

- **[overrides.md](references/overrides.md) gains a nuance from `axiom-macos`**:
  `direct-distribution.md:410-430` keeps `controller.updater` but lets the
  `SPUStandardUpdaterController` go out of scope, where every official Sparkle example
  stores the controller itself. It is filed as a **nuance, not an override** — whether
  dropping it breaks the flow was **not measured**, and Sparkle documents no retention
  rule. The Nuances section is now split by source skill.
- The `axiom-macos` entry under *Revision Status* records the distribution split, in the
  same shape as the existing scope notice for the unwritten `appkit-bridge.md`.

**Reviewed for this release, and mostly not taken.** Four skill repositories were read
against the admission rule:

- [fayazara/macos-app-skills](https://github.com/fayazara/macos-app-skills) `auto-update` —
  the source of all three anti-patterns above, which it recommends. Nothing was copied: it
  states MIT in its README and ships no licence file.
- [Dimillian/Skills](https://github.com/Dimillian/Skills) — already a companion. Its
  `references/release.md` is 1.2 KB and covers the appcast side only, which is why §2 to §4
  of the new document had nowhere else to live. The companion table's description of it was
  re-read and is accurate.
- [prisma-labs-dev/apple-skills](https://github.com/prisma-labs-dev/apple-skills) — **not
  adopted**. iOS-first, and its `disabled-skills/README.md` states the opposite editorial
  position to this skill's, disabling a guide for *"mandates MV over MVVM"*. That makes it
  an execution-layer set, like `swiftui-expert-skill`; it does not conflict, it just does
  not answer anything here. Its re-publication of Dimillian's packaging skill, with
  `origin:` and `license:` in the frontmatter, is the model to follow if this skill ever
  vendors third-party material.
- [patrickserrano/skills](https://github.com/patrickserrano/skills) — **not adopted**. An
  acknowledged adaptation of Dimillian's, last touched three minutes after it was created
  on 2026-01-17. Eight of its ten skills declare a `name:` that differs from their
  directory, and one of them declares `name: macos-spm-app-packaging`, which would collide
  with the companion this skill already recommends.

## 3.0.0 — 2026-09-01

**MAJOR: a new Quick Rule and two new anti-patterns. Existing code can violate all three.**

1. **Quick Rule 19 — know which TextKit you are on.** New document:
   [text-editing.md](references/text-editing.md), which fills the `text-editing.md` slot
   that had been listed as planned since 1.0.0. **Measured**, one fresh `NSTextView` per
   probe: a view starts on **TextKit 2**, and reading `.layoutManager` **once** drops it to
   **TextKit 1** — permanently, with no warning and no way back. Reading `.textStorage` or
   `.textContainer` is safe. *Comply*: assert `textView.textLayoutManager != nil` in the
   view's setup, and reach for `textLayoutManager` / `textContentStorage` rather than
   `layoutManager`. Any editor that believes it is on TextKit 2 without asserting it may
   simply not be.

   The document also records the TextKit 1-vs-2 decision with four shipping apps landing on
   both sides and the concrete reason (viewport height estimation destabilises the
   scroller; Apple's response is that this is as-designed), the two-tier attribute
   architecture that keeps the parse out of the styling, four AppKit traps with a known
   cost, and — deliberately — **two widely repeated claims that did not reproduce** on this
   OS: re-applying attributes did *not* move the insertion point, and a plain-text
   `NSTextView` *does* advertise `NSStringPboardType`.

2. **[Watching a directory you also write into](references/antipatterns.md#watching-a-directory-you-also-write-into).**
   When the file system is the model, a `DirectoryWatcher` that reloads on every event, in
   an app that writes output into the folder it watches, is a feedback loop. Measured with
   a `DispatchSource` `.write` source: **one** file written delivers **2** events (an
   atomic write is a temp file plus a rename), 100 files in a burst deliver **200** — no
   coalescing — and the app's own output file delivers 2 more. *Comply*: debounce the burst
   into one reload, and register an expected write **before** performing it so the event it
   produces is ignored. Where the output need not live in the watched folder, moving it
   removes the problem instead of managing it.

3. **[A callback or key that silently inherits `@MainActor`](references/antipatterns.md#a-callback-or-key-that-silently-inherits-mainactor).**
   Reachable only in a target using `.defaultIsolation(MainActor.self)`, which is why it
   lands in the same release as that option. A `DispatchSource` event handler compiles with
   **no error and no warning**, then dies with `Trace/BPT trap: 5`
   (`_dispatch_assert_queue_fail`) the first time it fires. *Comply*: mark both the
   enclosing function and the state the handler touches `nonisolated` — marking only the
   function usefully converts the runtime trap into a compile error. The same failure has a
   second shape with no closure to notice: a hand-written `PreferenceKey` or
   `EnvironmentKey`, whose `defaultValue` SwiftUI reads on its own schedule. Verified that
   both pick up the isolation silently, and that `nonisolated` on the type fixes both.
   `@Entry` generates its own conformance and is unaffected.

### Additional verified guidance

No rule changed in this subsection.

- **[view-composition.md](references/view-composition.md#extraction-is-a-compile-time-requirement-not-a-preference) —
  extraction is a compile-time requirement, not a preference.** Measured: the same shape
  nested five deep type-checks in 0.13 s with `VStack` or `Section` and **fails to compile
  outright** with `Group` (`error: the compiler is unable to type-check this expression in
  reasonable time`), after 0.20 s at depth 3 and 0.95 s at depth 4. The identical depth-5
  structure split into five named subviews: **0.14 s**. The variable is not depth but the
  container's conformance count — `Group` is generic over `View`, `ToolbarContent`,
  `Commands` and more, so every level multiplies the initializers to resolve. The
  readability rule in that document now has a compile-correctness justification behind it.

- **[swift-idioms.md](references/swift-idioms.md#default-isolation-for-the-whole-target) —
  target-wide default isolation.** `.defaultIsolation(MainActor.self)` in the manifest makes
  `@MainActor` the default and `nonisolated` the deliberate mark, which is the right way
  round for a SwiftUI app where nearly everything is main-actor state. Verified that every
  shape this skill prescribes compiles under it unchanged — including a `Sendable` protocol
  satisfied by both a `struct` and an `actor`, which holds only because 2.0.0's
  async-requirement rule is being followed. Costs a `swift-tools-version: 6.2` floor, and
  brings anti-pattern 2 above with it.

- **[longevity.md §3](references/longevity.md#a-concurrency-diagnostic-that-changed-is-usually-the-sdk-not-the-compiler) —
  a concurrency diagnostic that changed is usually the SDK, not the compiler.**
  `NS_SWIFT_SENDABLE` and `NS_SWIFT_NONISOLATED` in Objective-C headers rewrite how a type
  enters Swift, with no compiler change involved. Verified: `NSManagedObjectContext.h` in
  this SDK carries both on its interface line, and 11 AppKit headers carry the first, 7 the
  second. The document now carries the `grep` to run before assuming the compiler changed,
  and the warning that a newly *permitted* thing is not a newly *safe* one.

## 2.0.0 — 2026-09-01

**MAJOR: five new Quick Rules covering module boundaries, observation outside a view,
and external processes. Existing code can violate all five.**

### Additional verified guidance

No rule changed in this subsection. It adds three findings, one of which corrects the
baseline modularization guidance introduced in this release.

- **[swift-idioms.md](references/swift-idioms.md) — *Isolation and Protocol Requirements*.**
  How you declare a service protocol decides whether an `actor` or a `@MainActor` type can
  ever conform to it. Six conformance shapes compiled under `-swift-version 6`: with
  **`async` requirements** a `Sendable` protocol is satisfiable by a struct, an actor and a
  main-actor class alike — which is why this skill's repositories are shaped that way, and
  why nothing existing needs changing. A **synchronous** requirement is not, and the
  widespread explanation for that (`Sendable` on the protocol makes members `nonisolated`)
  is wrong: a protocol with no `Sendable` at all is rejected with the same diagnostic. What
  `Sendable` really does is **forbid the isolated-conformance escape hatch** (`: @MainActor P`,
  Swift 6.2), so marking a protocol `Sendable` out of habit removes an option. The
  `nonisolated(unsafe)` remedy that circulates is recorded as what it is — removing the
  actor's protection from a stored property, not fixing the design.

- **[modularization.md §7](references/modularization.md#7-tooling) — the linkage exception.**
  The baseline says static-vs-dynamic linkage is "a separate axis … decide it after the graph".
  That is right for a single app target and wrong as soon as the product holds a **second
  binary** — an extension, an XPC service, a helper. Measured: SwiftPM links statically by
  default and emits one `<Package>_<Module>.bundle` per resource-bearing module, so each
  extra binary gets its own copy of the code *and* of every resource bundle. A `.dynamic`
  aggregating product fixes the code half only — verified, the bundles are still emitted
  beside `libFooBar.dylib`, not inside it, and have to be relocated by a build step. The
  guidance now reads: count the binaries before choosing linkage.

- **[longevity.md §1](references/longevity.md) — an `NSViewRepresentable` wrapper is a
  temporary shape.** The corollary of soft-deprecation: the wrappers written to fill a
  SwiftUI gap are the code most likely to gain a **native successor**, and nothing warns
  you when it lands. Two verified against the SDK, both at macOS 26 — SwiftUI `WebView` /
  `WebPage` for a wrapped `WKWebView`, and `Observations` for a hand-rolled re-arming
  observer. Neither is reachable at this skill's macOS 14 floor, so the conclusion is about
  *shape*: keep the wrapper deletable, one file, with the app depending on your view rather
  than on `WKWebView`.

### External processes

One new Quick Rule covers external processes. Existing code that shells out can violate it.

New document: [subprocesses.md](references/subprocesses.md) — the App Sandbox rules for
spawning, why `try` is not the error channel, what task cancellation does to a child, and
what adopting the `Subprocess` package costs.

**What it invalidates, and how to comply:**

**Quick Rule 18 — a subprocess's exit status is not an error.** Code shaped
`let r = try await run(…)` followed by `parse(r.standardOutput)` is now non-compliant.
Measured against `Subprocess` 1.0.0: a command that exits non-zero returns **normally**,
carrying whatever partial output it managed to write, and so does a child killed by task
cancellation (`terminationStatus == .signaled(9)`, ~30 ms after `cancel()`, no
`CancellationError`). `run` throws only when the executable cannot be launched.
*Comply*: `guard result.terminationStatus.isSuccess else { … }` before touching the
output, and treat the failure at the severity
[error-handling.md](references/error-handling.md) prescribes — usually informational,
carrying stderr.

The rule's second half — **shelling out does not escape the App Sandbox** — invalidates a
design rather than a line of code. Measured on an ad-hoc-signed sandboxed `.app`: spawning
a system executable **works** with no entitlement, the child **inherits** the app's
sandbox, and the app's file-access grants **do** extend to the child. So an app that runs
a tool over user-chosen paths ships sandboxed, and one that must roam the disk is a
direct-distribution app — a decision that belongs before the feature, not after it.
`HOME` inside the sandbox is the container, which is the usual reason a command behaves
differently in a release build than under Xcode.

**Also recorded, invalidating nothing:**

- **`SIGKILL` sharpens [Quick Rule 11](SKILL.md).** `.task` is the right home for a
  subprocess whose result stops mattering when the view goes away, and the wrong home for
  one that must finish: the child is killed outright and cannot flush or unlock.
- **The terms of adopting `Subprocess`**, read from the 1.0.0 tag and verified by building
  against it: `swift-tools-version: 6.2`, `.macOS(.v13)` with an `.iOS("99.0")` sentinel
  that makes it **macOS-only**, a transitive `swift-system` dependency, and a stated
  policy that *any minor release may raise the required Swift toolchain*. It is past 1.0,
  so [longevity.md](references/longevity.md)'s pre-1.0 warning no longer applies, but its
  containment rule does — one type imports it.

Two other articles were reviewed for this release and **nothing was taken from them**:
a defence of SwiftUI with no code or measurements, and a 2023 data-flow guide whose
content is already in [ownership.md](references/ownership.md) and
[architecture.md](references/architecture.md) (including the `@Bindable var x = env`
mechanic) and whose decision flowchart is the API reference the admission rule excludes.

### Observation outside a view

One new Quick Rule covers reacting to a store from outside a `body`, and corrects a
widely shared technique that does not build under Swift 6.

[observation.md](references/observation.md) gains two sections, both measured against
Swift 6.2.4 / macOS 15.7.9.

**What it invalidates, and how to comply:**

- **Quick Rule 17 — to react to a store from outside a `body`, publish domain events.**
  Code that reaches into a store's properties from a coordinator, a window controller or
  a service using a re-arming `withObservationTracking` helper is now non-compliant when
  the store is yours to change. *Comply*: give the store an `AsyncStream` of domain
  events, per [architecture.md](references/architecture.md#communicating-between-stores).
  The property bridge stays legitimate in two cases the rule names — a type you do not
  own, and "current value now" semantics — and
  [observation.md §5](references/observation.md#5-observing-a-store-from-outside-a-view)
  now carries a version of it that compiles: main-actor-isolated, cancelling itself
  through `.terminated`, verified warning-free under `.swiftLanguageMode(.v6)`.

  The wrapper that circulates for this — `@Sendable @escaping @autoclosure` over the
  property — **does not compile in Swift 6 language mode** at all. A non-`Sendable` store
  fails the capture; making it `@MainActor` fixes that and then fails on reading isolated
  state from a `@Sendable` closure. Both errors are recorded verbatim. If yours builds,
  the package is still in Swift 5 mode, where the check does not run at all — verified,
  the same code builds there with no diagnostic. That makes the wrapper a silent Swift 6
  migration blocker, which is why this is a rule and not a note.

**New facts, invalidating nothing on their own:**

- **[§4](references/observation.md#4-assigning-an-equal-value-does-not-notify) — `@Observable`
  deduplicates equal assignments.** Measured across seven cases: it stays silent when the
  new value compares equal or is the same object, and notifies when it cannot compare
  (a non-`Equatable` payload notifies on every assignment). Two practical corollaries —
  hand-written `guard newValue != value` guards in a store are redundant, and model types
  should be `Equatable` so the deduplication can apply.
- **§5 measures what the property bridge actually delivers**: three synchronous mutations
  produce one callback carrying the final value, the current value is not delivered on
  subscribe, and the stream ends on the first change after the consumer is cancelled. It
  is a "something changed" signal, not an event log — which is the reason Rule 17 points
  at domain events first.
- **`Observations`, the native `AsyncSequence` replacement, requires macOS 26** — verified,
  so it is not an option at this skill's deployment floor. §5 says what to delete when the
  floor moves.

### Module boundaries

Three new Quick Rules cover module boundaries. Existing multi-target code can violate all
three.

New document: [modularization.md](references/modularization.md) — when one SwiftPM target
stops being enough, the App → Features → Workflows → Services → Core ladder, how to cross a
feature boundary on macOS, and how to migrate an existing app leaves-first.

**What it invalidates, and how to comply:**

1. **Quick Rule 14 — one target until a named pressure justifies a second.** A codebase
   split into modules for tidiness rather than for a build wait, an encapsulation need, or
   colliding owners is now non-compliant. *Comply*: either name the pressure the split
   answers, or collapse the targets back into folders. Nothing needs to change in a
   single-target app.
2. **Quick Rule 15 — a module's declaration set is its build contract.** Previously
   unstated, so nothing was written against it, but the measurement in §2 of the new
   document invalidates the common belief that only `public` matters: adding an `internal`
   declaration recompiles every file of every dependent module. *Comply*: a `Core` module
   that gains declarations weekly is not buying build time; treat its declaration churn as
   the metric, not its `public` surface.
3. **Quick Rule 16 — a feature module never imports a sibling feature.** Code that reaches
   a sibling's screens through a shared `AnyView` factory protocol is now an anti-pattern.
   *Comply*: replace it with a route enum in a leaf module plus route → screen mapping in
   the App layer, per
   [modularization.md §4](references/modularization.md#4-crossing-a-feature-boundary-on-macos).

Also in this release, invalidating nothing on their own:

- [antipatterns.md](references/antipatterns.md) gains *Splitting Into Modules Before There
  Is a Build to Save* and *The `AnyView` Shim Across a Feature Boundary*, with wrong/right
  code.
- [project-structure.md](references/project-structure.md) now states that its structure is
  a **single** target and points to the new document for the multi-target decision.

The recompilation table in §2 is measured on Swift 6.2.4 / macOS 15.7.9 with SwiftPM, not
taken from the source article, and the document carries the command to reproduce it. The
SwiftUI examples on both sides of §4 compile as separate targets against a macOS 14
deployment target.

## 1.0.0 — 2026-09-01

First packaged release. The skill moved from the repository root to
`.agents/skills/macos-app-architecture/` so it can be installed with `npx skills add`, and gained
`license` and `metadata.version` in its frontmatter.

No rule changed. The 15 reference documents, the Quick Rules and the companion-skill table are the
content that already existed.
