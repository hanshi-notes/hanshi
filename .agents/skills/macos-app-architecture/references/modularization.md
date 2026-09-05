# Modularization: When One Target Stops Being Enough

[project-structure.md](project-structure.md) decides how to arrange files **inside**
one target. This document is one level up: when to cut the app into several SwiftPM
targets, where the cuts go, and what a cut actually costs.

**Default position: one target.** A module boundary is not tidiness — folders already
provide that, for free, and can be moved in an afternoon. A module is a compilation
contract and a permanent dependency edge. Add one when a named pressure demands it,
and not before.

---

## 1. The Three Pressures That Justify a Module

| Pressure | Symptom you can point at | Modules fix it? |
|---|---|---|
| **Build time** | Editing one file recompiles the whole app, and the wait is now noticeable | Yes, but only under the rules in §2 |
| **Encapsulation** | `internal` is the whole app, so nothing is really private and everything is reachable | Yes. `public` becomes a decision, not a default |
| **Ownership** | Two people or two agents keep colliding on the same files, or the same helper gets written twice | Yes, when the module lines match the ownership lines |

If none of the three applies — a single-developer macOS app that builds in a few
seconds — **splitting makes the codebase worse**: more manifest, more `public`, more
import bookkeeping, and nothing bought.

---

## 2. What a Module Boundary Actually Buys — Measured

Everyone repeats "modules make builds faster". The mechanism is narrower than that,
and knowing it changes where the cuts go.

**Setup**: a SwiftPM package with `Core` ← `Feature` (40 files) ← `AppLayer` (20 files),
Swift 6.2.4, macOS 15.7.9, debug build. Each row is one edit on top of a warm build.

| Edit | What recompiled |
|---|---|
| **A.** Change the *body* of a `public` function in `Core` | `Core` only — 1 file |
| **B.** Add an **`internal`** type to `Core` | `Core` + **all 40** files of `Feature`. `AppLayer` untouched |
| **C.** Add a `public` function to `Core` | `Core` + **all 40** files of `Feature`. `AppLayer` untouched |
| **D.** Change a function body in one `Feature` file | that 1 file |
| **E.** Add a `public` declaration to `Feature` | that file + **all 20** files of `AppLayer` |

Four rules follow, and none of them is obvious from the slogan:

1. **Bodies are free across a module boundary; declarations are not.** Changing what a
   function *does* stops at the module edge (A, D). Changing what a module *declares*
   crosses it (B, C, E).
2. **`internal` counts.** Row B is the surprise, and it is the one that contradicts the
   usual advice: adding a helper nobody outside the module can even *see* invalidated
   dependents exactly as a `public` one did. The `.swiftmodule` carries internal
   declarations too — `@testable import` could not work otherwise — so they are part of
   the artefact dependents are checked against. "Keep the public API stable" is half the
   rule; the whole *declaration set* is the build contract.
3. **Invalidation is all-or-nothing per module.** One new declaration in `Core`
   recompiled all 40 files of `Feature`, including the 39 that never referenced it.
   Inside a module, incremental builds are per file (D); across one, they are per
   module. **A module is the unit of rebuild, so its size is the blast radius.**
4. **Invalidation stops at the first layer whose own declarations did not change.**
   `AppLayer` never rebuilt in B or C. This is the entire payoff of a layered graph,
   and it is lost the moment a top layer imports a bottom one directly to save a hop.

Reproduce it before trusting it — the numbers are toolchain-specific:

```bash
swift build                                   # warm
# make one edit, then:
swift build 2>&1 | grep Compiling | awk '{print $2}' | sort | uniq -c
```

**Practical consequence.** The module you edit hourly should sit *high* in the graph,
where nothing depends on it. The module everything depends on should be the one whose
declarations you almost never touch. A `Core` module that is still growing new types
every week is a `Core` module that buys nothing.

---

## 3. The Layer Ladder

When the split is justified, this is the shape. Its value is not the modules — it is
that **"where does this file go?" stops being a discussion**.

```
App          @main, scenes, dependency wiring, route → screen mapping
  ↓
Features     Screens and Views for one UI area. Never imports a sibling Feature
  ↓
Workflows    Operations that span two or more stores and belong to none
  ↓
Services     One store per bounded context + the I/O it owns
  ↓
Core         Leaf. Model types and extensions. Imports nothing of ours
```

Dependencies point **down only**. Reading it as a placement rule:

| It is… | Layer |
|---|---|
| A `Screen` or a `View` | Features |
| A `…Store` and the `…Repository` it drives | Services |
| A `Note`, a `Tag`, a `String` extension | Core |
| An operation touching two stores that neither one owns | Workflows |
| Deep-link parsing, `NSApplicationDelegateAdaptor`, the scene tree | App |

Two constraints keep it honest:

- **Siblings do not import siblings.** Two Features that need each other are one
  Feature, or they share something that belongs one layer down. Note the compiler only
  catches this once it closes — a one-way sibling import builds fine and quietly becomes
  the edge that makes the *next* one fatal:

  ```
  error: 'app': cyclic dependency declaration found:
         AppLayer -> NotesFeature -> SearchFeature -> NotesFeature
  ```

  So the rule has to be held by review, not by the build. The `grep` in §6 is the check.
- **`Workflows` is earned, not reserved.** [architecture.md](architecture.md#communicating-between-stores)
  puts two-store coordination in the view or in an `AsyncStream`, and that stays the
  default. A `Workflows` module is for the operation that is too large for either —
  "generate the summary, write it, sync it, log it" — and if the app has none, the
  layer does not exist. An empty layer is boilerplate with a name.

**Start with three**: `App` → `Features` → `Core`. `Services` and `Workflows` appear
when a real file has nowhere good to go, which is the same signal that justified the
first split.

---

## 4. Crossing a Feature Boundary on macOS

The hard case in every modular codebase: Search must show a note, and `NoteDetailScreen`
lives in `NotesFeature`. Importing the sibling is a cycle waiting to happen; exposing a
view factory through a protocol is the usual escape and it goes badly.

**Wrong — a shim protocol returning `AnyView`:**

```swift
// Contracts (leaf module)
public protocol NoteScreenProviding {
    func noteScreen(id: UUID) -> AnyView          // ← erasure forced by the boundary
}

extension EnvironmentValues {
    @Entry public var noteScreens: any NoteScreenProviding = MissingNoteScreens()
}

// SearchFeature
public struct SearchScreen: View {
    @Environment(\.noteScreens) private var noteScreens
    @State private var shown: UUID?
    let hits: [UUID]

    public var body: some View {
        List(hits, id: \.self) { id in
            Button(id.uuidString) { shown = id }
        }
        .sheet(item: $shown) { id in noteScreens.noteScreen(id: id) }
        // (plus a retroactive `UUID: Identifiable` conformance, elided)
    }
}
```

It compiles. The costs are that `AnyView` erases the view identity SwiftUI diffs on,
that a default conformance must exist for previews and now silently renders nothing
when wiring is forgotten, and — the real one — that the boundary is being *worked
around* rather than drawn. Note this is not the "existentials at the SwiftUI boundary"
that [swift-idioms.md](swift-idioms.md#existentials-at-the-framework-boundary) accepts:
there the framework leaves no choice, here the architecture does.

**Right — the feature emits a route; the App layer owns the mapping.** This is
[navigation.md](navigation.md#enum-routes-do-carry-over)'s enum route promoted to a
module: the route type is a leaf everyone may depend on, and no Feature ever names
another Feature's screen.

```swift
// AppRoutes (leaf module — declarations only, so it almost never invalidates anyone)
public enum AppRoute: Hashable, Codable, Sendable {
    case note(UUID)
    case tag(String)
}

extension EnvironmentValues {
    @Entry public var navigate: (AppRoute) -> Void = { _ in }
}

// SearchFeature — imports AppRoutes, and nothing else of ours
public struct SearchScreen: View {
    @Environment(\.navigate) private var navigate
    private let hits: [UUID]

    public init(hits: [UUID]) { self.hits = hits }

    public var body: some View {
        List(hits, id: \.self) { id in
            Button(id.uuidString) { navigate(.note(id)) }
        }
    }
}

// AppLayer — the only place that knows both features exist
public struct RootScreen: View {
    @State private var selection: AppRoute?

    public var body: some View {
        NavigationSplitView {
            SearchScreen(hits: hits)
                .environment(\.navigate) { selection = $0 }
        } detail: {
            switch selection {
            case .note(let id): NoteDetailScreen(id: id)     // NotesFeature
            case .tag, nil:     ContentUnavailableView("No Selection", systemImage: "doc")
            }
        }
    }
}
```

**Verified**: both versions compile as separate SwiftPM targets against a macOS 14
deployment target, Swift 6.2.4.

macOS makes this easier than iOS, and the reason is
[navigation.md](navigation.md#the-macos-model-is-selection-not-a-stack): "presenting"
another feature's screen is assigning a selection that the split view resolves, not
pushing a destination the caller must construct. The iOS habit of a
`makeSomethingViewController()` factory per feature exists to hand a caller something
to push. There is nothing to push here.

And most cross-feature traffic is not screens at all: if Search needs a note's *data*,
the store lives in `Services`, one layer down, where both features may import it without
either depending on the other. Only the screen case needs §4 at all.

---

## 5. Anti-Patterns

**Hyper-modularization.** Interface + implementation + mocks + preview app + tests as
five targets per feature buys build-graph precision that a single-developer macOS app
never spends. Eight targets before the first line of a one-screen feature is a tax paid
per feature, forever. It is a real answer to a real problem at a company with dozens of
engineers; it is not this app's problem.

**A `Core` that is a junk drawer.** Anything shared lands there, so it grows a
declaration every week, so by §2 rule 3 every rebuild is a full rebuild — with the
manifest overhead of modularity and none of the benefit. If `Core` cannot be described
in one sentence without "and", it is two modules.

**Business logic drifting between layers.** A store that lives in `App` because it was
written before the split is the tell — every module below it then needs a protocol
declared upward to reach it, and those protocols are the smell, not the fix. Move the
store down to `Services`; the protocols disappear.

**Long thin chains.** `App → A → B → C → D`, each with one type, serialises the build
instead of parallelising it and makes every edit ripple. Modules pay off when they are
*wide and independent*, not deep.

**Splitting a codebase you are still designing.** Module boundaries are expensive to
move — every change is a manifest edit, an access-level pass, and a cycle risk. Folders
are free to move. Split when the shape has stopped changing.

---

## 6. Migrating an Existing App

Never big-bang. **Extract leaves first, upward.**

1. `Core` first — model types and extensions that import nothing of yours. It compiles
   the moment it is extracted, and nothing above needs to change beyond `import Core`.
2. Then `Services`, one bounded context at a time. Each store moves with its repository.
3. `Features` last, and only the ones that are actually stable.
4. `App` is whatever refuses to move — that residue is the honest measure of coupling.

Each step is a mergeable commit and the app builds after every one. The mechanical part
— adding `public` to what crossed the boundary, fixing imports — is exactly the work to
hand to an agent; the layer assignment is not.

Two checks worth running at each step, because both failures are silent — a sibling
import compiles until it closes into a cycle, and a boundary that stops nothing looks
exactly like one that works:

```bash
# 1. No Feature imports a sibling Feature. Only your leaf modules should appear here.
grep -rh "^import " Sources/*Feature/ | awk '{print $2}' | sort -u

# 2. The boundary actually stops invalidation. Edit one declaration in the lowest
#    module, then check how far up the rebuild travelled.
swift build 2>&1 | grep Compiling | awk '{print $2}' | sort | uniq -c
```

If step 2 shows every module rebuilding, the extraction bought nothing and the reason
is in §2 — declaration churn in a module everything depends on.

---

## 7. Tooling

- **SwiftPM is the answer** for a macOS app of this shape. It handles multi-target
  packages natively, and this skill already assumes a package without an Xcode project.
- **Tuist** earns its keep at the scale where the manifest boilerplate is the bottleneck
  — dozens of targets. Below that it is a dependency to maintain.
- **Bazel and Buck** solve a build-farm problem. **CocoaPods and Carthage** are legacy.
  Neither belongs in a new macOS app; see [longevity.md](longevity.md) on what a
  toolchain dependency costs over the app's life.
- **Static vs. dynamic vs. mergeable libraries** is a mostly separate axis: it trades
  launch time against binary size without changing the dependency graph. Decide it after
  the graph — with the one exception below.

### The exception: a second binary in the bundle

SwiftPM links modules **statically** by default, and every module carrying resources
produces its own bundle. **Verified**: a package `FooBar` with modules `Foo` and `Bar`,
each with a `resources:` declaration, builds

```
FooBar_Foo.bundle
FooBar_Bar.bundle
```

— one per module, named `<Package>_<Module>.bundle`.

With a single app target this costs nothing: one copy of each. It stops being free the
moment the product contains **a second binary that links the same modules** — an
extension (Share, Quick Look, Finder Sync, Widget, App Intents), an XPC service, a helper
tool. Each of those is its own binary, so each gets its own copy of the code *and* its
own copy of every resource bundle: images, localised strings, everything.

The fix is a `.dynamic` library product that aggregates the modules, so the code is
linked once and shared. **Verified — and it only solves half the problem**: switching the
product to

```swift
.library(name: "FooBar", type: .dynamic, targets: ["Foo", "Bar"])
```

produces `libFooBar.dylib`, but `FooBar_Foo.bundle` and `FooBar_Bar.bundle` are still
emitted *alongside* it, not inside it. The resource bundles have to be moved into the
framework and deleted from the consumers as a build step; the autogenerated
`Bundle.module` accessor resolves through `Bundle(for:).resourceURL`, which is what makes
finding them inside the framework work at all.

So: **count the binaries before choosing linkage.** One app target — ignore this. An app
plus anything else that links your modules — the linkage decision is part of the module
decision, not a later tuning pass.

---

## Sources

- [Modular iOS Architecture](https://blog.jacobstechtavern.com/p/modular-ios-architecture),
  Jacob Bartlett — the layer ladder (App/Features/Workflows/Services/Core), the
  escalation path through naïve feature modules, and the `AnyView` shim as the symptom
  that a boundary is wrong. Written for iOS and for a team; the placement rules carry
  over, the `UIViewController` factory and the hyper-modular target layout do not.
- [Swift Modules and Code/Assets Duplication](https://pfandrade.me/blog/swift-modules-and-codeassets-duplication/),
  Paulo Andrade — source for §7's exception: the dynamic aggregator product, and the
  detail that resource bundles need moving separately. Written for an iOS app with a
  Share extension; the mechanism is SwiftPM's, so it transfers, and the bundle naming and
  the half-fix were re-measured here.
- §2 is measured in this repository's toolchain, not taken from the article. The
  article claims a stable *public* interface avoids dependent recompilation; the
  measurement shows `internal` declarations invalidate too, and that a single
  declaration rebuilds every file of every direct dependent.
