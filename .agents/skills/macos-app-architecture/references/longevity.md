# Longevity

The controlling constraint: **the app must still build and ship in ten years.**
That is not achieved by choosing well once. It is achieved by never falling off
the upgrade path.

> **Scope.** The lists of deprecated-to-modern API transitions live in the
> installed skills — `swiftui-expert-skill` (`soft-deprecation.md`,
> `latest-apis.md`) for SwiftUI, and `write-swift`'s Quick Reference for the
> language. They are not duplicated here. This document is the **policy**: what
> to depend on, when to upgrade, and how to contain what you cannot control.

---

## 1. Apple deprecates; it rarely removes

This is the single most important difference from a web framework, and it
changes what you should worry about.

A web framework on a yearly major deprecates an API and **removes it two majors
later**, so writing a deprecated API today schedules migration work for someone
in three years. Apple mostly **soft-deprecates**: the API is marked in the SDK
headers with a placeholder version that suppresses warnings, and it keeps
compiling and working. `NavigationView`, `Alert`, `PresentationMode` still run
years after their replacements shipped.

**What follows from that:**

- **Never introduce a soft-deprecated API in new code.** Not because it will
  break, but because it will not receive new capability, and the gap widens.
- **Do not schedule mass migrations of working code.** A soft-deprecated call in
  a file you are not otherwise touching is not a defect. Migrating it is churn
  with a real regression risk and no user-visible benefit.
- **Do not treat compiler silence as approval.** The absence of a warning is
  deliberate on Apple's part, not evidence the API is current.

### The corollary: an `NSViewRepresentable` wrapper is a temporary shape

Soft-deprecation cuts the other way too. The wrappers you write because SwiftUI
lacks something are the code most likely to acquire a **native successor** — and
unlike a deprecation, nothing warns you when that happens. Two verified against
this SDK, both landing at macOS 26:

| What you wrap today | Native successor | Available from |
|---|---|---|
| `WKWebView` in an `NSViewRepresentable` | SwiftUI `WebView` + `@Observable` `WebPage` | `error: 'WebView' is only available in macOS 26.0 or newer` |
| A hand-rolled re-arming `withObservationTracking` | `Observations` | `error: 'Observations' is only available in macOS 26.0 or newer` |

This does not mean writing the wrapper was wrong; at a macOS 14 floor there was
no alternative. It means **the wrapper should be shaped so it can be deleted**:
one file, its own type, the rest of the app depending on your view rather than
on `WKWebView`. That is the same containment described in §4 for a fragile
package, applied to a fragile *design* — and a `WebPage` that is `@Observable`
and exposes navigation as an `AsyncSequence` slots into
[observation.md](observation.md#5-observing-a-store-from-outside-a-view)'s
consumption pattern with the call sites unchanged.

Raising the floor to reach a successor is still governed by §3: with evidence,
not with the calendar.

The real longevity risks in an Apple app are **not** Apple's API policy. They
are the three below.

---

## 2. Risk one: third-party rot

Ranked by what actually kills a build, not by how alarming it sounds.

| Risk | Why it bites | What to do about it |
|---|---|---|
| **Vendored C targets** (tree-sitter grammars, C libraries) | A future compiler rejects the C. You do not lose features — **you lose the build** | Fork and patch the C. Budget for it; it is the most likely one |
| **Pre-1.0 dependency** (`0.x`) | API breaks in a minor by definition | Pin `.upToNextMinor`, never `from:`. Wrap it (§4) |
| **Restrictive licence** | Closes a distribution channel permanently | Decide it up front, not when you want to ship |
| **Single-vendor package** | Development follows their product, not your needs | Permissive licence means you can fork. Check the licence *first* |
| **Soft-deprecated Apple API** | Slowly falls behind | Lowest urgency of the five |

**A dependency's star count tells you nothing about any of these.** Check, in
order: licence, last commit, whether it is pre-1.0, and whether you could fork
it if the author disappeared tomorrow.

---

## 3. Risk two: toolchain drift

Three things are routinely confused. They are independent:

| | What it is | When to change it |
|---|---|---|
| **Compiler** | What is installed on the machine | Freely; test before adopting |
| **`swift-tools-version`** | The *minimum* SwiftPM able to build the package | Only when you need a manifest API that does not exist earlier |
| **Deployment target** | The oldest OS the app runs on | Only when a specific API you need requires it |

**`swift-tools-version` is not "the version I use".** Raising it to match your
compiler excludes everyone on the previous version and buys nothing. Raise it
when a manifest feature demands it — and write down which feature, so the next
person can tell whether the constraint still holds.

**A deployment target is raised with evidence, not with the calendar.** Before
raising it, name the API you need and confirm it is not available another way.
Check what your dependencies declare: if they still target the older OS, raising
yours gains you nothing from them.

**Pin the toolchain in CI by its exact identifier.** Convenience aliases can
resolve to the wrong toolchain *silently* — the build passes, with the wrong
compiler. A green build is not evidence that the intended toolchain ran; the
compiler path in a verbose build is.

---

### A concurrency diagnostic that changed is usually the SDK, not the compiler

A specific case of toolchain drift, and the one that wastes the most time because the
instinct is wrong. When code that failed strict-concurrency checking last Xcode compiles
in this one — or the reverse — **the compiler is rarely what changed**. Apple annotates
Objective-C headers over time, and two macros silently rewrite how a framework type
enters Swift:

| Macro | Effect on the Swift import |
|---|---|
| `NS_SWIFT_SENDABLE` | The type comes in as `Sendable`, so it may cross isolation domains |
| `NS_SWIFT_NONISOLATED` | Members import as callable from outside any isolation context |

**Verified** in the SDK this repository builds against — `NSManagedObjectContext.h`
carries both, on the interface line itself:

```
NS_SWIFT_NONISOLATED NS_SWIFT_SENDABLE
@interface NSManagedObjectContext : NSObject <NSCoding, NSLocking>
```

An SDK a version or two older carries neither, and the same code is rejected there. Same
compiler, same language mode, different answer.

**So check the header before you believe the compiler changed:**

```bash
SDK=$(xcrun --show-sdk-path)
grep -n "NS_SWIFT_SENDABLE\|NS_SWIFT_NONISOLATED" \
  "$SDK/System/Library/Frameworks/AppKit.framework/Headers/NSDocument.h"

# Or the definitive Swift-facing view:
ls "$SDK/System/Library/Frameworks/CoreData.framework/Modules/CoreData.swiftmodule/"
# → arm64e-apple-macos.swiftinterface, which shows the imported signatures
```

In this SDK, 11 AppKit headers carry `NS_SWIFT_SENDABLE` and 7 carry
`NS_SWIFT_NONISOLATED`. That number grows with each release, which is precisely the
drift: **an annotation you do not control decides whether your bridging code compiles.**

Two consequences worth holding:

- **A newly permitted thing is not a newly safe thing.** `NS_SWIFT_SENDABLE` is Apple
  asserting thread-safety to the type checker. It does not validate your usage, and the
  framework's own concurrency rules — Core Data's queue confinement, AppKit's main-thread
  requirement — still apply. Compiling is not permission.
- **Do not "fix" an error by widening isolation** until you have read the header. The
  error may be the annotation's absence in *your* SDK rather than a defect in your design,
  and it may disappear on its own next release.

---

## 4. Risk three: dependencies you cannot isolate

The mitigation for a fragile dependency is not avoidance — sometimes it is the
right tool. It is **containment**.

**One file imports it.** If a pre-1.0 package breaks its API, the damage is
bounded to a single file you can fix in an hour, instead of spread across the
view layer.

```swift
// FragileEditorView.swift — the ONLY file that imports the package.
import FragilePackage

struct EditorView: View {                 // the app's own vocabulary
    @Binding var text: String
    var body: some View { FragilePackage.TextView(text: $text) }
}
```

The rest of the app depends on `EditorView`, never on `FragilePackage`. The same
move works for a service: define the protocol you need, and let one adapter
conform to it using the dependency.

**When to fork instead:** when upstream is unresponsive *and* the licence
permits *and* the change is small enough to re-apply on each update. Forking a
large, actively developed package converts a dependency problem into a
maintenance problem — usually a worse one.

---

## 5. Prefer the boring, standard thing

Every dependency is a bet that someone else will keep maintaining it. The system
frameworks are the only ones with a ten-year guarantee.

Before adding a package, ask what it saves versus what the platform already
does. Fuzzy matching, file watching, PDF export, undo, preference storage — all
of these have a system answer, and each avoided dependency is one fewer thing
that can stop compiling in 2036.

That is not an argument for writing everything yourself. It is an argument for
making the cost visible **before** adding, when it is still free to decline.

---

## 6. Write down the standing decisions

A decision without its reason gets re-litigated every year, usually by someone
with less context.

Record, for each significant dependency: **what it is, what was rejected instead,
why, and what would change the answer.** That last clause is what makes the note
useful later — "we chose X because Y; if Y stops being true, revisit" beats "we
use X".

The project's own risk register belongs with the project, not here.

---

## Sources

- [Sendable NSManagedObjectContext](https://fatbobman.com/en/posts/sendable-nsmanagedobjectcontext/),
  Fatbobman — traced a concurrency behaviour change to two SDK macros rather than to the
  compiler. Its Core Data specifics are out of scope for this skill; the diagnostic
  technique in §3 is not, and was re-verified against this SDK.
- [The SwiftUI WebView](https://troz.net/post/2025/swiftui-webview/), Sarah Reichelt —
  the walkthrough of `WebView`/`WebPage` that prompted §1's corollary. Its API surface is
  reference material and stays out of this skill; the availability floor above was
  re-checked against the SDK.
