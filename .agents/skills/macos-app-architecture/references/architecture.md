# Architecture: The MV Pattern for SwiftUI

Starting point: the SwiftUI view **already is** the presentation layer.
Everything else follows from that.

## Why There Is No ViewModel

MVVM originated in WPF, where the view was XAML: declarative markup without
state or logic. The ViewModel gave that passive view a place for both.

**In SwiftUI this premise does not hold.** `@State`, `@Binding`, `@Environment`, `@Bindable`, `@AppStorage`, `@FocusState`, and `@Query` only work *inside* a view. Apple designed it this way. A ViewModel is a mute view that does not exist.

This is a language boundary, not a preference: the `Environment` is resolved
against the view tree by property wrappers, so a plain class cannot read it —
everything a ViewModel needs has to be handed to it by hand. Thomas Ricouard
states the same boundary from the other side: he would reconsider ViewModels
the day Apple lets code read the environment outside a view ([Forget
MVVM](https://dimillian.medium.com/swiftui-in-2025-forget-mvvm-262ff2bbd2ed));
a library such as TCA only gets there with machinery of its own. Until then,
whatever reads the environment is a view.

The concrete cost is described in [antipatterns.md](antipatterns.md#mvvm-one-viewmodel-per-screen).

## Bounded-Context Stores

A store is an `@Observable` class that exposes data to views. **It is not a
ViewModel**: there is one per *bounded context*—an area of the domain with a
clear boundary—not one per screen.

In a note‑taking app: `NoteStore` (files and content), `TagStore` (tag hierarchy). In an e‑commerce app: `CatalogStore`, `CheckoutStore`, `ShipmentStore`. The same `NoteStore` feeds the list, editor, and sidebar — and that is what guarantees they all see the same data.

```swift
import Observation

@Observable
final class NoteStore {
    private(set) var notes: [Note] = []
    private let repository: NoteRepository

    init(repository: NoteRepository) {
        self.repository = repository
    }

    func load() async throws {
        notes = try await repository.loadAll()
    }

    func save(_ note: Note) async throws {
        try await repository.save(note)
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            notes[i] = note
        } else {
            notes.append(note)
        }
    }
}
```

The store contains **business logic**, not presentation logic. Sorting a list
according to the header the user just clicked is presentation logic and stays
in the view.

### Injecting the Store

A store used by multiple screens goes into the `Environment`, not through chained initializer calls.

```swift
@main
struct NotesApp: App {
    @State private var noteStore = NoteStore(repository: FileNoteRepository())

    var body: some Scene {
        WindowGroup {
            ContentScreen()
                .environment(noteStore)
        }
    }
}

struct NoteListScreen: View {
    @Environment(NoteStore.self) private var store

    var body: some View {
        List(store.notes) { note in
            Text(note.title)
        }
    }
}
```

If you need a `Binding` over a store property inside the view, declare `@Bindable var store = store` in the `body`.

## Dependency Injection: Three Mechanisms, One Rule

SwiftUI ships with DI built‑in. No third‑party library is required. What you need is to know which of the three to use, and the rule is simple:

| What you inject | Mechanism | Why |
|---|---|---|
| **Data** for a child view | Initializer | Explicit, previewable, and the view becomes reusable |
| **Stateless service** (HTTP client, formatter, repository) | `EnvironmentValues` (`@Entry`) | It’s a value; nothing to observe |
| **Shared state** (`@Observable` store) | `.environment(store)` | You must observe changes and repaint |

### Stateless Service → Environment Value

```swift
extension EnvironmentValues {
    @Entry var noteRepository: any NoteRepository = FileNoteRepository()
}

struct NoteListScreen: View {
    @Environment(\.noteRepository) private var repository
    // …
}
```

**Verified:** the macro `@Entry` compiles on macOS 14 (it’s a compile‑time expansion, requiring Xcode 16+). No old boilerplate of `EnvironmentKey` + `defaultValue` is needed.

The default value that you declare is what previews receive without any configuration. For tests or fake data previews, replace it:

```swift
#Preview {
    NoteListScreen()
        .environment(\.noteRepository, InMemoryNoteRepository(seed: .demo))
}
```

### Shared State → Environment

```swift
@main
struct NotesApp: App {
    @State private var store = NoteStore(repository: FileNoteRepository())

    var body: some Scene {
        WindowGroup { ContentScreen().environment(store) }
    }
}
```

“Shared” does **not** mean singleton: the scope is the subtree where you inject it. Injecting at the root is common, but not mandatory.

#### The store goes in as a concrete type, not behind a protocol

A tempting “improvement” is to inject `any NoteStoring` instead of `NoteStore`,
so views depend on an abstraction. **SwiftUI does not allow it.** Verified by
compiling against a macOS 14 target:

```swift
@Environment(NoteStore.self)   private var store   // compiles
@Environment(NoteStoring.self) private var store   // error: no exact matches in call to initializer
```

```swift
@Bindable var store: NoteStore          // compiles
@Bindable var store: any NoteStoring    // error: 'init(wrappedValue:)' is unavailable:
                                        //    The wrapped value must be an object
                                        //    that conforms to Observable
```

Curiously, **observation itself does survive an existential** — reading a
property through `any NoteStoring` still registers the dependency, and mutating
the concrete instance still fires the change. Also verified. So the restriction
is not in the Observation runtime; it is in the `@Environment` and `@Bindable`
property wrappers, which require the concrete `Observable` type.

**The consequence for the architecture is the important part**: the abstraction
seam does not belong *at* the store, it belongs one level **below** it — at the
repository or service the store depends on.

```swift
// The store is concrete: views and @Bindable need it that way.
@Observable final class NoteStore {
    // The seam lives here. This is what you swap in tests and previews.
    private let repository: any NoteRepository
    init(repository: any NoteRepository) { self.repository = repository }
}
```

You lose nothing: swapping `InMemoryNoteRepository` for `FileNoteRepository`
gives you the same testability that a protocol at the store level would have,
and the views keep their bindings.

### Data Still Travels Through Initializers

The environment complements initializer injection; it does not replace it. A
row that displays *one* note receives that note explicitly:

```swift
List(store.notes) { note in
    NoteRowView(note: note)          // ← initializer, not environment
}
```

### Who Can Read from the Environment

Only `…Screen` types may read from the environment. `…View` types receive data
and emit events.

This is not about purity. Direct environment access gives a leaf view an
invisible dependency and prevents previewing it without constructing that
environment. Keep store access at the screen boundary and pass each reusable
view only the data it displays.

## Screens vs Views

Naming convention borrowed from Flutter and React. It costs nothing and organizes the entire project:

| Suffix | What it is | Examples |
|---|---|---|
| `…Screen` | A full screen. Can read from the `Environment`, launch tasks, navigate | `NoteEditorScreen`, `SettingsScreen`, `WelcomeScreen` |
| `…View` | Reusable component. Receives what it needs, does not touch the `Environment` or navigate | `NoteRowView`, `TagBadgeView`, `SearchFieldView` |

**Underlying rule:** if a component reads from the `Environment`, it stops being reusable because it carries an invisible contract. `View`s receive data and emit events; that’s all.

### Container and Presenter

`Screen`/`View` are naming conventions; the underlying division of labor comes from React:

- **Container** (smart view): loads, sorts, filters, and coordinates data.
- **Presenter** (dumb view): only renders what it receives. It does not know
  where the data came from.

```swift
// Container: knows how to load.
struct NoteListScreen: View {
    @Environment(NoteStore.self) private var store
    @State private var query = ""

    var body: some View {
        NoteListView(notes: visibleNotes) { event in … }
            .task { try? await store.load() }
            .searchable(text: $query)
    }

    private var visibleNotes: [Note] { … }
}

// Presenter: only renders. Previewable with fake data and no store.
struct NoteListView: View {
    let notes: [Note]
    let onEvent: (NoteRowEvent) -> Void

    var body: some View {
        List(notes) { NoteRowView(note: $0, onEvent: onEvent) }
    }
}
```

A container can feed **multiple** nested presenters; that’s the normal case, not an exception.

**Do not make a container for every view.** This is the classic mistake when
discovering the pattern: it adds indirection at every level and fills the tree
with forwarding views. Dan Abramov, who popularized the pattern in React, later
retracted the advice to apply it universally. Use a container where real loading
or coordination occurs; use presenters elsewhere.

## Keeping View Logic in the View

Not everything moves into the store. Filtering, validating a form, and deciding
whether a button is enabled are **presentation logic** and belong in the view as
computed properties.

```swift
struct NoteFilterScreen: View {
    @Environment(NoteStore.self) private var store
    @State private var query = ""
    @State private var onlyFavorites = false

    // Presentation logic: derived, not stored.
    private var visibleNotes: [Note] {
        store.notes.filter { note in
            (!onlyFavorites || note.isFavorite)
            && (query.isEmpty || note.title.localizedStandardContains(query))
        }
    }

    var body: some View {
        VStack {
            TextField("Search…", text: $query)
            Toggle("Only Favorites", isOn: $onlyFavorites)
            List(visibleNotes) { NoteRowView(note: $0) }
        }
    }
}
```

Notice there is **no `@State private var filteredNotes`**. Deriving instead of storing eliminates the class of bug where the filter and list get out of sync. If the calculation becomes expensive, that’s when you measure it with Instruments — not before.

## Events Grouped in an Enum

A reusable component delegates events to its parent. Two closures are fine;
with five, the call becomes unreadable.

**Wrong — one closure per event**

```swift
struct NoteRowView: View {
    let note: Note
    let onSelect: (Note) -> Void
    let onFavorite: (Note) -> Void
    let onDelete: (Note) -> Void
    let onDuplicate: (Note) -> Void
    let onReveal: (Note) -> Void      // …and keeps growing
}

// In the parent:
NoteRowView(note: note,
            onSelect: { … }, onFavorite: { … }, onDelete: { … },
            onDuplicate: { … }, onReveal: { … })
```

**Right — one enum of events, one closure**

```swift
enum NoteRowEvent {
    case select(Note)
    case toggleFavorite(Note)
    case delete(Note)
    case duplicate(Note)
    case revealInFinder(Note)
}

struct NoteRowView: View {
    let note: Note
    let onEvent: (NoteRowEvent) -> Void

    var body: some View {
        HStack {
            Text(note.title)
                .onTapGesture { onEvent(.select(note)) }
            Spacer()
            Button { onEvent(.toggleFavorite(note)) } label: {
                Image(systemName: note.isFavorite ? "star.fill" : "star")
            }
        }
        .contextMenu {
            Button("Duplicate") { onEvent(.duplicate(note)) }
            Button("Show in Finder") { onEvent(.revealInFinder(note)) }
            Button("Delete", role: .destructive) { onEvent(.delete(note)) }
        }
    }
}

// In the parent: one entry point, exhaustive, and the compiler warns
// when you add a new case.
//
// Note: `Task { }` in an action is the idiomatic way — the closure is
// synchronous and there is no async parent — but it is **not** cancelled
// when the view unmounts. For work tied to the view’s lifetime use `.task`.
// See swift-idioms.md.
NoteRowView(note: note) { event in
    switch event {
    case .select(let n):         selection = n.id
    case .toggleFavorite(let n): Task { try await store.toggleFavorite(n) }
    case .delete(let n):         Task { try await store.delete(n) }
    case .duplicate(let n):      Task { try await store.duplicate(n) }
    case .revealInFinder(let n): NSWorkspace.shared.activateFileViewerSelecting([n.url])
    }
}
```

The real benefit is not aesthetic: **adding a case breaks compilation at every
consumer**, instead of letting one be forgotten silently.

## Communicating Between Stores

When multiple stores exist and one must react to another, there are four options with distinct trade‑offs:

| Technique | When to use | Cost |
|---|---|---|
| **Coordination in the view** | Two stores, one point‑of‑interaction | Simple, but ties UI to business logic |
| **Delegate** | One‑to‑one relationship, stable | Doesn’t scale to many listeners |
| **Combine** | Multiple consumers, reactive flow | Another conceptual dependency; not the idiomatic choice today |
| **`AsyncStream`** | Domain events, code already using structured concurrency | One consumer per stream: several subscribers need one stream each |

Of the four, `AsyncStream` is the default today. Note that `events` is a
**function**, not a property: it hands out one stream per subscriber.

```swift
@Observable
final class TagStore {
    private(set) var tags: [Tag] = []

    private var continuations: [UUID: AsyncStream<TagEvent>.Continuation] = [:]

    func events() -> AsyncStream<TagEvent> {
        let id = UUID()
        return AsyncStream { continuations[id] = $0 }
    }

    func rename(_ tag: Tag, to newName: String) {
        // …mutate…
        continuations = continuations.filter { _, continuation in
            // `.terminated` = that subscriber's task is gone; drop it.
            if case .terminated = continuation.yield(.renamed(old: tag.name, new: newName)) {
                return false
            }
            return true
        }
    }
}

// Consumer, from a Screen:
.task {
    for await event in tagStore.events() {   // ← its own stream, cancelled with the view
        if case .renamed(let old, let new) = event {
            await noteStore.rewriteTag(from: old, to: new)
        }
    }
}
```

**Why a stream each and not a stored one.** `AsyncStream` is not a broadcast
channel: two iterators over the same stream divide the events between them —
each event reaches exactly one — and nothing warns you. A single stored stream
is correct only where exactly one consumer is guaranteed, and on macOS that
guarantee is rarely yours: two windows showing the same screen are two
consumers. The `filter` on `yield` also drops subscribers whose task has ended,
so nothing has to be unregistered from the view side.

**Important limitation**: this applies to domain events, not high-frequency
signals. A 60 fps scroll should not travel through this path; see
[antipatterns.md](antipatterns.md#routing-high-frequency-events-through-swiftui).

## References

- [MVVM and the Cost of Carrying Old Patterns Forward](https://azamsharp.com/2026/03/04/mvvm-and-cost-of-old-patterns.html)
- [Building Large-Scale Apps with SwiftUI: A Guide to Modular Architecture](https://azamsharp.com/2023/02/28/building-large-scale-apps-swiftui.html)
- [Effective Communication Between Observable Stores](https://azamsharp.com/2025/08/17/effective-communication-between-observable-stores.html)
- WWDC 2020, *Data Essentials in SwiftUI* — the observable object as the “data dependency surface” of the view.
