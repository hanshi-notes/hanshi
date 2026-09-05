# State Ownership

In SwiftUI, **state ownership is the architecture**. Before writing a view,
answer this question: who owns this piece of data? Everything else follows.

## Single Source of Truth: One per Piece of Information, Not One per App

The principle is constantly misinterpreted. “Single Source of Truth” means
that **each piece of information has a single owner** — not that the app has a
single place where everything lives.

A healthy app has **many** sources of truth: the text of a search field belongs
to its screen; the list of notes belongs to the store; the selection belongs to
the split view.

Putting everything in a global store is the opposite error, and is what Redux‑style
architectures commit: any change invalidates everything that reads the blob.
We measure this in
[observation.md](observation.md#1-granularity-is-lost-when-state-is-nested-in-a-struct).

---

## The Four Mechanisms

| Need | Use | Type |
|---|---|---|
| Create data that lives with the view | `@State` | value or `@Observable` object |
| Modify a **value** that lives higher up | `@Binding` | struct / enum |
| Modify an **object** that lives higher up | `@Bindable` | `@Observable` class |
| Read something available throughout the hierarchy | `@Environment` | value or object |
| Only display data | normal property (`let`) | any type |

The last row is the one most often forgotten: **if the view only renders the
data, it needs no property wrapper**. Use a regular `let`.

```swift
// Only displays data: normal property.
struct NoteRowView: View {
    let title: String
    let isFavorite: Bool
    var body: some View { … }
}

// Owns the data: @State.
struct SearchScreen: View {
    @State private var query = ""
    var body: some View { SearchFieldView(query: $query) }
}

// Modifies a value higher up: @Binding.
struct SearchFieldView: View {
    @Binding var query: String
    var body: some View { TextField("Search…", text: $query) }
}

// Modifies an object higher up: @Bindable.
struct NoteEditorScreen: View {
    @Bindable var note: NoteDraft          // class @Observable
    var body: some View { TextField("Title", text: $note.title) }
}

// Available throughout the hierarchy: @Environment.
struct NoteListScreen: View {
    @Environment(NoteStore.self) private var store
    var body: some View { List(store.notes) { NoteRowView(title: $0.title, isFavorite: $0.isFavorite) } }
}
```

Objects stored with `@State`, `@Bindable`, and `@Environment` must be marked with
`@Observable`.

### The Fifth: `@AppStorage` for Preferences

One is missing from the table, because its owner is neither the view **nor** the
store: it is `UserDefaults`.

```swift
struct SidebarView: View {
    @AppStorage("sidebar.isExpanded") private var isExpanded = true
    @AppStorage("notes.sortOrder")    private var sortOrder: SortOrder = .title
    var body: some View { … }
}
```

**Types it accepts** (verified by compiling against a macOS 14 target): `Bool`,
`Int`, `Double`, `String`, `URL`, `Data`, and any `RawRepresentable` whose
`RawValue` is `Int` or `String` — plus their optional variants.

**What it does not accept**: an arbitrary `Codable` type or an array of structs.

```swift
@AppStorage("recents") var recents: [Recent] = []
// error: no exact matches in call to initializer
```

If you need that, either encode it to `Data` yourself or — almost always the
better answer — **it did not belong in `UserDefaults`**. `UserDefaults` is for
preferences, not for data.

**What does belong here in a macOS app**: whether the sidebar is expanded, the
sort order, the editor font size, and the security-scoped **bookmark** for the
directory the user picked (`Data?`).

**What does not**: anything that must stay consistent with what is on disk.
Caching the note list here creates a second source of truth that goes stale the
moment someone edits a file from outside the app.

**Two traps:**

1. **Every `@AppStorage` is a view dependency**: any change to that key
   invalidates the view. It is the same granularity problem described in
   [observation.md](observation.md) — do not put one in a frequently redrawn
   view if the value changes often.
2. **It writes synchronously on every change.** Fine for a preference toggled
   occasionally; wrong for anything that changes per frame, such as a scroll or
   drag position.

The `store:` parameter points at a `UserDefaults(suiteName:)`, which you only
need when sharing preferences with another target (an extension, a widget).

### How to Decide When the Table Doesn’t Help

The table solves the easy case. When you’re unsure, the question isn’t “what
property wrapper?” but **where should the data live**, and that depends on five
things:

1. **How many views need to access** the data.
2. **How far away** they are from its truth source.
3. Whether it is **a value or a reference**—this determines whether to use `@Binding` or
   `@Bindable`.
4. **How it’s persisted and retrieved**: disk, network, sensors.
5. The **app's structure**, which determines where the data can live.

Notice that the property wrapper is the *last* decision, not the first. Choosing
`@State` or `@Environment` before knowing who owns the data is the root of most
data‑flow entanglements.

---

## State Ownership Anti-Patterns

### Using `@State` for Data Received from Outside

```swift
// Wrong — two copies of the same data. If the parent changes the title,
// this view won’t notice: @State only takes the initial value.
struct NoteTitleView: View {
    @State private var title: String

    init(title: String) { _title = State(initialValue: title) }
}
```

```swift
// Right — if it only shows, it’s a normal property. If it edits, it’s a @Binding.
struct NoteTitleView: View {
    let title: String
}
```

Rule: **`@State` is for data the view *creates*, not data it *receives*.**

### Duplicating Data That Already Lives in the Store

```swift
// Wrong — `notes` exists twice and must be manually synchronized.
struct NoteListScreen: View {
    @Environment(NoteStore.self) private var store
    @State private var notes: [Note] = []

    var body: some View {
        List(notes) { … }
            .task { notes = store.notes }   // What happens when the store changes?
    }
}
```

```swift
// Right — read from the owner. Observation takes care of the rest.
struct NoteListScreen: View {
    @Environment(NoteStore.self) private var store
    var body: some View { List(store.notes) { … } }
}
```

### Lifting State Used by Only One View

Whether a pop-up is open, the unsubmitted text in a field, or which row is
hovered: these belong to the view, not the store. Lifting them makes **every
keystroke invalidate every view that reads the store**.

```swift
// Wrong
@Observable final class NoteStore {
    var notes: [Note] = []
    var isSidebarExpanded = true      // ← No one else needs it
    var hoveredRowID: Note.ID?        // ← Invalidates the store on every mouse move
}

// Right — in the view that actually uses it.
struct SidebarView: View {
    @State private var isExpanded = true
    @State private var hoveredRowID: Note.ID?
}
```

This mirrors the rule in [project-structure.md](project-structure.md): if only
one view uses it, it belongs to that view; if two features share it, it belongs
to neither feature.

---

## Source

- [SwiftUI Data Flow](https://matteomanferdini.com/swiftui-data-flow/), Matteo
  Manferdini—the source of the clarification that a source of truth applies per
  piece of information, not per app.
