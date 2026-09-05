---
name: macos-app-architecture
description: Architecture and patterns for native macOS apps built with SwiftUI and AppKit—MV vs. MVVM, bounded-context stores, Environment, Screen/View naming, enum-based event grouping, communication between stores, bridging to imperative AppKit views, when to split the app into SwiftPM modules, running external processes under the App Sandbox, and the decisions behind distributing and auto-updating an app outside the Mac App Store. Use when designing a macOS app's structure, deciding where state belongs, creating a store or view, wrapping an NSView in SwiftUI, or planning distribution and Sparkle updates. Includes anti-patterns with examples of what not to do.
license: MIT
metadata:
  version: 3.1.1
---

# macOS App Architecture (SwiftUI + AppKit)

A reusable skill shared across projects. It records **architectural decisions,
their rationale, and code**, not API reference material.

## Admission Rule

To keep this from becoming a dumping ground that duplicates installed skills:

> Include something if it is **(a)** an architectural pattern with its
> rationale, **(b)** a fact verified against real code or measurements, or
> **(c)** an anti-pattern that has already cost time—with code showing what not
> to do.
>
> **Do not include** API reference material already covered by Apple's
> documentation or an installed skill.

## Index

| Document | Contents |
|---|---|
| [architecture.md](references/architecture.md) | MV pattern, bounded-context stores, Environment, Screens vs. Views, view logic, enum-based events, communication between stores |
| [antipatterns.md](references/antipatterns.md) | What not to do, with incorrect and correct code side by side |
| [overrides.md](references/overrides.md) | Where this skill **overrides** an installed skill, and why |
| [navigation.md](references/navigation.md) | Navigation on macOS: selection vs. stack, what does not carry over from iOS, windows |
| [validation.md](references/validation.md) | Five form-validation patterns, from the least to the most machinery |
| [testing.md](references/testing.md) | What deserves a test and which kind. The API is covered by `swift-testing-expert` |
| [observation.md](references/observation.md) | `@Observable` granularity (measured), lifecycle, where an event enum fits, equal-value deduplication, and observing a store from outside a view |
| [project-structure.md](references/project-structure.md) | Chosen folder structure: flat and feature-based, with `Stores/` outside `Features/` |
| [modularization.md](references/modularization.md) | One level above folders: when one SwiftPM target stops being enough, the layer ladder, and the measured cost of a module boundary |
| [previews.md](references/previews.md) | Previews as a design criterion, not a convenience. Narrow inputs, design-time types, named states |
| [text-editing.md](references/text-editing.md) | Text editing on macOS: the silent TextKit 2 → 1 fallback (measured), TextKit 1 vs 2 as a decision, where the parse lives, and AppKit traps with a known cost |
| [swift-idioms.md](references/swift-idioms.md) | Only what `write-swift` does not cover: SOLID in Swift, one type per file, closure vs protocol, `.task` vs `Task { }`, existentials at the SwiftUI boundary, how isolation constrains protocol requirements, and target-wide default isolation |
| [ownership.md](references/ownership.md) | Who owns each piece of data: `@State`, `@Binding`, `@Bindable`, `@Environment`, `@AppStorage`, and ownership anti-patterns |
| [view-composition.md](references/view-composition.md) | Generic `@ViewBuilder`, dedicated views vs. nested stacks, why not to pass the entire model, and the nesting depth at which `body` stops type-checking (measured) |
| [error-handling.md](references/error-handling.md) | Which errors warrant interruption, `LocalizedError`, presentation on macOS, and why typed throws are almost never appropriate |
| [longevity.md](references/longevity.md) | Why Apple's soft-deprecation changes what to worry about, why an `NSViewRepresentable` wrapper is a temporary shape, third-party rot, toolchain drift, and containing fragile dependencies |
| [subprocesses.md](references/subprocesses.md) | Shelling out: what the App Sandbox does and does not allow (measured), why `try` is not the error channel, and what adopting `Subprocess` costs |
| [undo.md](references/undo.md) | `UndoManager` as a system responsibility, and why not to implement Memento by hand on macOS |
| [distribution.md](references/distribution.md) | Shipping outside the Mac App Store: what the sandbox costs the updater, who owns the Sparkle bridge, and why the signing key is decided before the first release |

### Planned, not written yet

These files do not exist. Do not link to them, and do not cite them as if they had content.

| Document | Will cover |
|---|---|
| `references/appkit-bridge.md` | Wrapping imperative AppKit views: state ownership, high-frequency events, observer lifecycle |

## Quick Rules

1. **The SwiftUI view is the presentation layer.** Do not create a ViewModel
   for every screen. → [anti-patterns](references/antipatterns.md#mvvm-one-viewmodel-per-screen)
2. **One store per bounded context**, not per screen. And **one source of truth
   per piece of data**, not one for the entire app. → [ownership](references/ownership.md) → [architecture](references/architecture.md#bounded-context-stores)
3. **Use `Screen` for full screens and `View` for reusable components.**
   → [architecture](references/architecture.md#screens-vs-views)
4. **Logic specific to a view stays in that view.** Only business logic moves
   into the store.
5. **Represent a reusable component's events with one enum, not N closures.**
   → [architecture](references/architecture.md#events-grouped-in-an-enum)
6. **Do not route high-frequency events through SwiftUI's update cycle.** A
   `@Binding` is not a 60 fps event channel.
7. **Keep observable properties flat rather than nesting them in a struct.**
   Nesting removes `@Observable`'s granularity. → [observation](references/observation.md#1-granularity-is-lost-when-state-is-nested-in-a-struct)
8. **Do not rely on `init`/`deinit`** for subscriptions; use `.task`.
9. **If it cannot be previewed without dependencies, the design is wrong.**
   → [previews](references/previews.md)
10. **Default to `struct`; if it is a class, make it `final`.** → [Swift idioms](references/swift-idioms.md)
11. **Use `.task` for work tied to the view; use `Task { }` only for actions
    that must finish even if the user leaves.**
12. **`swift-tools-version` is the minimum SwiftPM that can build the package**,
    not the version you use. → [longevity](references/longevity.md)
13. **Before handling an error, decide its severity**: ignorable,
    informational, blocking, or fatal. → [error handling](references/error-handling.md)
14. **One SwiftPM target until a named pressure justifies a second**: a build
    wait, encapsulation `internal` cannot give, or two owners colliding. Folders
    first. → [modularization](references/modularization.md)
15. **A module's declaration set is its build contract.** Adding any declaration
    — `internal` included — recompiles every file of every dependent module.
    Bodies are free. → [modularization](references/modularization.md#2-what-a-module-boundary-actually-buys--measured)
16. **A feature module never imports a sibling feature.** It emits a route; the
    App layer maps routes to screens. → [modularization](references/modularization.md#4-crossing-a-feature-boundary-on-macos)
17. **To react to a store from outside a `body`, publish domain events.**
    `withObservationTracking` is one-shot, and the re-arming wrapper that
    circulates does not compile in Swift 6 language mode. If you must observe a
    property, use the main-actor-isolated `AsyncStream` bridge — and know that it
    coalesces. → [observation](references/observation.md#5-observing-a-store-from-outside-a-view)
18. **A subprocess's exit status is not an error.** `try` catches only a failure
    to launch: a command that exits non-zero, or a child killed by cancellation,
    returns normally. Check `terminationStatus`. And shelling out does **not**
    escape the App Sandbox — the child inherits it.
    → [subprocesses](references/subprocesses.md)
19. **An `NSTextView` starts on TextKit 2 and drops to TextKit 1 the first time
    anything reads `.layoutManager`** — permanently, silently. Assert which one
    you are on. → [text editing](references/text-editing.md#1-know-which-textkit-you-are-on--it-is-not-a-given)
20. **Distribution is decided before the first release, not after.** The
    sandbox decision reaches the updater's entitlements, exactly one file
    imports Sparkle and the App owns it — never a singleton — and the
    `SUPublicEDKey` shipped in build 1 is the key every installed copy keeps
    verifying against. → [distribution](references/distribution.md)

## Companion Skills

This skill is the **decision layer**. It deliberately does not cover API
reference, and expects the skills below to be installed alongside it. Do not
duplicate their content here.

| Skill | Covers | Install |
|---|---|---|
| **write-swift** | The Swift language itself: value semantics and copy-on-write, `~Copyable` and ownership, `some` vs `any`, `@concurrent` and the Swift 6.2 concurrency model, ARC, performance. Baseline Swift 6.3, with the items it flags as unreleased 6.4 | `npx skills add https://github.com/emilkowalski/skills --skill write-swift` |
| **swiftui-expert-skill** | SwiftUI APIs, `@Observable` data flow, view invalidation, migrating deprecated APIs. Explicitly declines to impose an architecture, which is why it does not clash with this skill | `npx skills add https://github.com/avdlee/swiftui-agent-skill --skill swiftui-expert-skill` |
| **swift-concurrency** | Actors, `Sendable`, task cancellation, Swift 6 migration. Checks the real `Package.swift` before advising | `npx skills add https://github.com/avdlee/swift-concurrency-agent-skill --skill swift-concurrency` |
| **swift-testing-expert** | The Swift Testing API: `@Test`, `#expect`, traits, parameterised tests, parallelisation and `@MainActor` isolation | `npx skills add https://github.com/avdlee/swift-testing-agent-skill --skill swift-testing-expert` |
| **axiom-macos** | Windows, menus and `CommandGroup`, sandboxing and security-scoped bookmarks, direct distribution, `NSViewRepresentable` mechanics | `npx skills add https://github.com/CharlesWiltgen/Axiom --skill axiom-macos` |
| **instruments-profiling** | `xctrace` and Time Profiler from the command line, with no Xcode project required | `npx skills add https://github.com/steipete/agent-scripts --skill instruments-profiling` |
| **macos-spm-app-packaging** | Assembling the `.app`, signing, notarising and the Sparkle appcast, from SwiftPM without an Xcode project | `npx skills add https://github.com/Dimillian/Skills --skill macos-spm-app-packaging` |

Install all seven:

```bash
npx skills add https://github.com/emilkowalski/skills --skill write-swift
npx skills add https://github.com/avdlee/swiftui-agent-skill --skill swiftui-expert-skill
npx skills add https://github.com/avdlee/swift-concurrency-agent-skill --skill swift-concurrency
npx skills add https://github.com/avdlee/swift-testing-agent-skill --skill swift-testing-expert
npx skills add https://github.com/CharlesWiltgen/Axiom --skill axiom-macos
npx skills add https://github.com/steipete/agent-scripts --skill instruments-profiling
npx skills add https://github.com/Dimillian/Skills --skill macos-spm-app-packaging
```

For a text-editing app, add the relevant parts of `apple-text` — TextKit 2,
fragment geometry, layout invalidation, `NSTextStorage`, AppKit vs. UIKit:

```bash
npx skills add sitapix/apple-text --skill txt-viewport-rendering
npx skills add sitapix/apple-text --skill txt-layout-invalidation
npx skills add sitapix/apple-text --skill txt-textkit2
npx skills add sitapix/apple-text --skill txt-appkit-vs-uikit
npx skills add sitapix/apple-text --skill txt-nstextstorage
```

### Deliberately not installed

- **twostraws `swiftui-pro`** — a review skill whose core instruction sets iOS 26
  as the default deployment target and pushes away from UIKit/AppKit. On a
  macOS 14 project with two `NSViewRepresentable` panes it would flag deliberate
  decisions as defects.
- **`swift-testing-pro`** — superseded by `swift-testing-expert`, which is
  markedly stronger on the three axes that matter here: parameterised tests,
  `@MainActor` isolation, and parallel execution with randomised order.
- **Coordinator, VIPER, MVVM-C and Clean Architecture skills** — they solve an
  iOS navigation-stack problem that does not exist in a macOS split view. See
  [navigation.md](references/navigation.md).
- **SwiftData skills** — this architecture keeps the file system as the model.

If content in those skills is **outdated or unsuitable**, do not debate it in
the abstract. Record the override in [overrides.md](references/overrides.md),
citing the file and line, and this skill takes precedence.

This skill is the **decision layer**: which structure to choose and why. The
skills above are the **execution layer**: how to call the API.
