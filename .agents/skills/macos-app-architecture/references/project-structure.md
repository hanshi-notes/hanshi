# Folder Structure

**Decision: use a flat, feature-based organization.** Do not organize by layer.

The authority here is not anyone's personal convention; it is the structure Apple uses in its own sample projects (*Backyard Birds* and *Food Truck*).

---

## The Structure

Adapted for a SwiftPM package without an Xcode project, which is the default for this skill.
**One target**; splitting into several is a separate decision with its own preconditions —
see [modularization.md](modularization.md).


```
MyApp/
├── Package.swift
├── Sources/MyApp/
│   ├── MyAppApp.swift              # @main, scenes, root injection
│   ├── Features/                   # one folder per UI area
│   │   ├── NoteList/
│   │   │   ├── NoteListScreen.swift    # container: reads from environment
│   │   │   ├── NoteListView.swift      # presentation view
│   │   │   └── NoteRowView.swift
│   │   ├── Editor/
│   │   │   ├── NoteEditorScreen.swift
│   │   │   ├── SourceEditorView.swift  # NSViewRepresentable
│   │   │   └── PreviewWebView.swift    # NSViewRepresentable
│   │   └── Sidebar/
│   ├── Stores/                     # ← NOT inside Features. See below
│   │   ├── NoteStore.swift
│   │   └── TagStore.swift
│   ├── Model/                      # domain types, no dependencies
│   │   ├── Note.swift
│   │   └── FrontMatter.swift
│   ├── Services/                   # I/O: disk, network, processes
│   │   ├── NoteRepository.swift        # protocol
│   │   ├── FileNoteRepository.swift    # implementation
│   │   └── DirectoryWatcher.swift
│   ├── Shared/                     # reusable between features
│   │   ├── Components/
│   │   └── Extensions/
│   └── Resources/
└── Tests/MiAppTests/
    ├── ModelTests/
    └── StoreTests/
```

---

## The Three Decisions That Matter

### 1. By Feature, Not by Layer

The alternative—`Views/`, `Models/`, `ViewModels/`, `Services/`—is commonly recommended, but fails for a practical reason: **changing one feature requires opening four folders**, and none of them reveals which features the app contains. With feature folders, adding a feature means creating one folder, and removing it means deleting that folder.

It is no more complex: **the same files are simply grouped along a different axis**.

### 2. `Stores/`, and outside `Features/`

Two differences from what you see in most articles:

- **There are no `ViewModels`.** See
  [antipatterns.md](antipatterns.md#mvvm-one-viewmodel-per-screen).
- **Stores do not live inside a feature**, even in a feature-based structure. This follows directly from the architecture: a store is defined by a **bounded context**, not a screen, and usually serves several features at once. Putting `NoteStore` inside `Features/NoteList/` would become misleading as soon as the editor and sidebar used it—and they will.

Rule: **If two features share it, it does not belong to either of them.**

### 3. Flat, without `Views/ViewModels/Models` inside each feature

There is a popular variant that nests layers inside each feature:

```
Features/Auth/Views/…      ← overengineering for a single-developer app
Features/Auth/ViewModels/…
Features/Auth/Models/…
```

With three or four files per feature, this creates folders containing a single file. The `…Screen` / `…View` naming convention already identifies each file's role. If one feature genuinely grows beyond eight or ten files, subdivide that feature—and only that one.

---

## Conventions That Make Folders Unnecessary

- `…Screen` — screen or container; can read from `Environment`.
- `…View` — reusable presentation component; receives data and emits events.
- `…Store` — one `@Observable` type per bounded context.
- `…Repository` — data access protocol; implementation carries a technology prefix (`FileNoteRepository`, `InMemoryNoteRepository`).

See [architecture.md](architecture.md#screens-vs-views).

## File Conventions

- **One type per file**, with the type name. Exception: tiny private helpers that only that file uses.
- **Every `View` has its preview**, with static fake data. No I/O. See [previews.md](previews.md).
- **Splitting thresholds are signals, not rules**: above roughly 300 lines per file or 30 per function, two responsibilities are almost always mixed together. Do not enforce this by counting lines; treat it as a smell worth investigating.
- **Business logic lives in the model and the store**, never in the view or in a “helpers” file.

---

## macOS-Specific Details

- **AppKit wrappers go with their feature**, not in a separate `AppKit/`. `SourceEditorView.swift` belongs to `Features/Editor/` because it only exists for that screen. A truly reusable `NSViewRepresentable` goes to `Shared/Components/`.
- **`Resources/` with SwiftPM** must be declared in `Package.swift` (`resources: [.copy("Resources")]`) and read via `Bundle.module`, not via `Bundle.main`. This is a common mistake when moving from Xcode projects.
- **No `AppDelegate`/`SceneDelegate` by default.** Add an `NSApplicationDelegateAdaptor` only when AppKit lifecycle hooks are required.
- Signing, notarization, and packaging files belong in a root-level `Scripts/` directory, outside `Sources/`.

---

## What Does Not Carry Over from Published Guides

Most project-structure guides target UIKit projects built with Xcode and carry over things that do not exist here: `AppDelegate.swift`, `SceneDelegate.swift`, `Main.storyboard`, `LaunchScreen.storyboard`, `Pods/`, and a target-level `Info.plist`. None of that applies to SwiftPM and SwiftUI.

## Sources

- [SwiftUI Project Structure Based on Apple Guidance](https://agenthicks.com/research/swiftui-project-structure-apple-guidance)
  — derives the structure from Apple’s official samples. It’s the best baseline of the evaluated options.
- Layer-based variants and variants with layers nested inside each feature were reviewed and rejected for the reasons above.
- When the single target itself becomes the problem, the folders above become module
  candidates — but not one-to-one. See [modularization.md](modularization.md).
