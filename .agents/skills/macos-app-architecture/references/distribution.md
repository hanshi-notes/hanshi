# Distribution and Updates

An app shipped outside the Mac App Store carries three decisions that are made **before the
first public release** and are expensive or impossible to reverse afterwards: whether it is
sandboxed, who owns the updater, and where the signing key lives. None of them is a build
step, which is why they are here.

The mechanics are not. Signing order, `codesign` flags, `notarytool`, stapling, DMG
assembly and appcast generation belong to `axiom-macos` → `direct-distribution.md` and to
`macos-spm-app-packaging`. See [§5](#5-what-is-not-here) for the split.

---

## 1. The Sandbox Decision Reaches the Updater

[subprocesses.md §1](subprocesses.md) frames sandboxed-vs-direct as a decision about what the
app's value is: a tool run over paths *the user* chooses can be sandboxed, a tool run over
paths *the app* chooses cannot. Sparkle attaches a second consequence to that same choice,
and it is normally discovered after the sandbox is already in the entitlements file.

**Verified** against Sparkle's sandboxing guide, read 2026-09-02:

| The app is | What it needs in order to update itself |
|---|---|
| **Not sandboxed** | Nothing beyond the standard Hardened Runtime configuration |
| **Sandboxed** | `SUEnableInstallerLauncherService` in `Info.plist` **and** a `com.apple.security.temporary-exception.mach-lookup.global-name` entitlement listing `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki` |

The guide is explicit at both ends — *"The Installer XPC Service is required for Sandboxed
applications"*, and *"If you do not sandbox your application, you should skip this guide."*

**The two halves are one decision.** The failure that costs time is shipping half of the
sandboxed row: the `Info.plist` key without the entitlement. The app builds, notarizes and
launches; the updater downloads and then cannot reach its own installer, and it fails at the
one moment you are least able to fix it — on a user's machine, in a build that is already
out. Guides in circulation recommend `SUEnableInstallerLauncherService` unconditionally
while stating that no special entitlements are needed, which produces exactly this pairing.

Read **`temporary-exception`** architecturally. It is not temporary in the app's lifetime: it
is a permanent, reviewable exception carried in every build, and it is part of the price of
the sandbox — not of Sparkle.

An app on the Mac App Store updates through the store and ships no updater at all. That
makes the channel the first decision of the three, not the last.

---

## 2. One File Imports Sparkle, and the App Owns It

The containment rule in [longevity.md §4](longevity.md#4-risk-three-dependencies-you-cannot-isolate)
applies here with more force than usual, because Sparkle's surface is KVO- and
Combine-shaped and **cannot** be expressed with `@Observable` — the exception recorded in
[antipatterns.md](antipatterns.md#exception-bridging-a-kvocombine-api). Uncontained, that
exception stops being an exception: every screen that touches the updater becomes an
`ObservableObject` consumer, and the one place the skill tolerates `@Published` becomes the
app's second data-flow model.

### The shape to avoid

```swift
// UpdaterManager.swift
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()          // ← global
    // …
}

// AboutSettingsPane.swift
struct AboutSettingsPane: View {
    @ObservedObject private var updater = UpdaterManager.shared   // ← not owned, not injected
    // …
}
```

Three separate problems, and the third is the one that ends the argument:

1. **A singleton is not "shared".** The scope of a shared object is the subtree it is
   injected into — [architecture.md](architecture.md#bounded-context-stores). A `static let`
   makes the scope the process.
2. **`@ObservedObject` on an object the view did not create** relies on something else
   keeping it alive. Here that something is the global, so the two defects prop each other
   up.
3. **The settings screen can no longer be previewed.** Touching `UpdaterManager.shared`
   constructs a real `SPUStandardUpdaterController` inside the preview process.
   [previews.md](previews.md) treats that as a design failure rather than an inconvenience,
   and a network-checking auto-updater is about as literal a version of it as exists.

### The shape to use

The app's own vocabulary first, with no `import Sparkle` in it:

```swift
// UpdateChecking.swift
@MainActor
protocol UpdateChecking: ObservableObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}
```

Exactly one type conforms using the dependency:

```swift
// SparkleUpdater.swift — the ONLY file in the app that imports Sparkle.
import Sparkle

@MainActor
final class SparkleUpdater: ObservableObject, UpdateChecking {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController      // kept alive on purpose — §3

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)                 // requires @Published
    }

    private var hasStarted = false

    func startScheduledChecks() {
        guard !hasStarted else { return }     // `.task` runs once per window — see below
        hasStarted = true
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}
```

The App owns it, which is what makes the singleton unnecessary — a `Scene` hierarchy has a
lifetime, and it is the app's:

```swift
@main
struct NotesApp: App {
    @StateObject private var updater = SparkleUpdater()

    var body: some Scene {
        WindowGroup {
            RootScreen()
                .task { updater.startScheduledChecks() }
        }
        Settings { SettingsScreen(updater: updater) }
    }
}
```

Two details that only bite on macOS. `.task` belongs to the root **view**, not to the
`WindowGroup` — `Scene` has no such modifier. And because a macOS `WindowGroup` opens as
many windows as the user asks for, that `.task` runs once per window, which is why
`startScheduledChecks()` guards itself rather than trusting its caller. An iOS-shaped
example gets away without the guard; this one does not.

`@StateObject` rather than `@State` is the KVO exception showing through, and it stops
there: it is the price of the bridge, not a licence to reintroduce `ObservableObject`
elsewhere. The view that renders the control is generic over the protocol, so it previews
against a stub — [previews.md §2](previews.md#2-designtime-implementations-behind-a-protocol):

```swift
struct UpdatesSection<Updater: UpdateChecking>: View {
    @ObservedObject var updater: Updater
    // …
}

#Preview { UpdatesSection(updater: StubUpdater(canCheckForUpdates: true)) }
```

**On the `#if !DEBUG` guard.** A debug build that starts the scheduled check points a
release appcast at a build that is not one, and offers to "update" your working copy to
the last shipped version. Guarding the *schedule* is unambiguous. Guarding the *manual*
check as well — as some guides do — is a real trade-off, not an improvement: it removes the
only path you have for testing the feed before shipping. Guard the schedule; keep the manual
check, and point `SUFeedURL` at a staging appcast when you exercise it.

---

## 3. The Controller Is the Object That Must Stay Alive

`axiom-macos` → `direct-distribution.md:410-430` builds the `SPUStandardUpdaterController`
inside `init`, keeps `controller.updater`, and lets the controller itself go out of scope at
the end of the initializer. Every official Sparkle example — Cocoa, SwiftUI, Catalyst, Qt —
stores it as a property instead (`let updaterController: SPUStandardUpdaterController`).

> **Not measured here**: whether dropping the controller actually breaks the update flow.
> `SPUUpdater` may retain enough of the object graph to survive on its own, and Sparkle's
> documentation does not state a retention rule. The reason to keep it anyway is that one
> stored property removes the question permanently, and the failure mode it would produce —
> an updater that silently stops checking — is invisible until users stop receiving updates.

Recorded as a nuance, not an override, in [overrides.md](overrides.md).

---

## 4. The Public Key Ships in the Binary; the Private Key Is Infrastructure

This is the decision on this page that cannot be corrected later by editing code.

`SUPublicEDKey` is compiled into every copy of the app you ship, and Sparkle verifies each
update against the key **the installed build carries** — not the key on your server. The key
in the first public build is therefore the key every existing user keeps verifying against,
including users who never update again.

**Verified** against Sparkle's documentation, read 2026-09-02: the private key lives in the
Keychain and *"will be erased if your keychain or system is erased"*; it can be exported and
imported to move between Macs; and if it is lost you *"can still sign new updates for
Developer ID signed applications through key rotation."*

The recovery clause is the architectural fact, not the reassurance. Rotation works **because
the app is Developer ID signed** — the code signature is the fallback trust anchor. An app
without that signature has no fallback, and losing the key ends the update channel for every
installed copy.

Three consequences, all decided before the first release:

1. **The EdDSA private key has the same status as the Developer ID certificate.** It is a
   project asset with a backup that lives off the build machine — not a Keychain item on
   whichever laptop happened to cut the last release.
2. **`SUFeedURL` is baked in on the same terms.** It is a URL you must still control years
   from now, which argues for a host you own over a path tied to a repository name you may
   rename or an account you may transfer.
3. **Both belong in the standing-decisions note**, with what was rejected and what would
   change the answer — [longevity.md §6](longevity.md#6-write-down-the-standing-decisions).

**Anti-pattern with a known cost**: locating Sparkle's tools by searching the build cache.

```bash
# Wrong — DerivedData is a cache.
find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f | head -1
```

It is wiped without warning, it holds copies from every Sparkle version the machine has ever
resolved, and `head -1` picks between them arbitrarily. Sparkle's documentation gives the
location for SwiftPM directly: the tools ship in the resolved artifact, under
`artifacts/sparkle/Sparkle/bin/`. A release step that depends on a cache is a release step
that fails on a clean machine — which is usually CI, or the next person.

The scripts that use those tools live in a root-level `Scripts/`, outside `Sources/`
([project-structure.md](project-structure.md#macos-specific-details)).

---

## 5. What Is Not Here

| Subject | Where it lives |
|---|---|
| Signing order (inside-out), `codesign` flags, why not `--deep`, Hardened Runtime exceptions | `axiom-macos` → `direct-distribution.md` |
| `notarytool` submission and credentials, stapling, Gatekeeper troubleshooting | `axiom-macos` → `direct-distribution.md` |
| DMG vs zip vs `pkg`, `ditto` for archiving | `axiom-macos` → `direct-distribution.md` |
| Building and packaging an `.app` from SwiftPM with no Xcode project, `generate_appcast`, tagging a GitHub release | `macos-spm-app-packaging` |
| Appcast item format, `sparkle:version` vs `sparkle:shortVersionString` | Sparkle's own documentation |

`macos-spm-app-packaging` covers the *release* side of Sparkle only — appcast generation and
the build-number rule. It says nothing about the app side, which is why §1 to §4 exist.

---

## Sources

- Sparkle's [sandboxing guide](https://sparkle-project.org/documentation/sandboxing/),
  [documentation](https://sparkle-project.org/documentation/) and
  [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/), read
  2026-09-02. The source for §1's entitlement pair, §3's example pattern and §4's key-loss
  and rotation wording.
- `axiom-macos` → `direct-distribution.md`, read 2026-09-02 — the reference implementation
  for everything in §5, and the source of the retention nuance in §3.
- [fayazara/macos-app-skills](https://github.com/fayazara/macos-app-skills) `auto-update`,
  reviewed 2026-09-02 — the source of the anti-patterns in §1, §2 and §4, all three of which
  it recommends. Nothing was copied from it: the repository states MIT in its README but
  ships no licence file.
