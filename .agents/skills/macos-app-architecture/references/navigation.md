# Navigation on macOS

> **Source note.** Almost all widely shared SwiftUI navigation material is
> written for iOS: `NavigationStack`, `NavigationPath`, and `TabView`. The
> article referenced by this document mentions `NavigationStack` 29 times,
> `NavigationSplitView` **once**, and macOS **zero** times. This document
> includes only what carries over and explicitly marks what does not.

## The macOS Model Is Selection, Not a Stack

On iOS, you navigate by stacking destinations. In a three-column macOS
interface, **there is no stack**: there are three selection bindings, and each
column is derived from them.

```swift
struct ContentScreen: View {
    @Environment(NoteStore.self) private var store
    @State private var selectedCategory: Category? = .allNotes
    @State private var selectedNoteID: Note.ID?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedCategory)          // column 1
        } content: {
            NoteListView(category: selectedCategory,           // column 2
                         selection: $selectedNoteID)
        } detail: {
            if let id = selectedNoteID, let note = store.note(id) {
                NoteEditorScreen(note: note)                   // column 3
            } else {
                ContentUnavailableView("No Note Selected",
                                       systemImage: "doc.text")
            }
        }
    }
}
```

Practical consequences:

- **“Navigating” means assigning a selection.**
  `selectedNoteID = note.id`. There is no `push`, so there is no `pop` or
  stack of routes either.
- **Navigation state is almost free to restore**: it consists of two `Codable`
  values, not an opaque `NavigationPath`.
- **The detail column must handle an empty selection.** On iOS there is always
  something on screen; on macOS, the third column initially has no selection.
  `ContentUnavailableView` is the system-provided solution.

## What Does Not Carry Over from iOS

| iOS pattern | On macOS |
|---|---|
| `NavigationStack` + `NavigationPath` | Only within **one** column, and rarely. The split view provides the structure |
| `TabView` as root navigation | Window tabs or a sidebar selector. It is not the primary navigation axis |
| `.sheet` for everything | Many iOS “sheets” should be **windows** (`Window`, `WindowGroup`, `openWindow`) or panels on macOS. A sheet takes over the entire window |
| `.navigationBarTitleDisplayMode`, `.toolbar(placement: .topBarTrailing)` | They do not exist. macOS has different toolbar placements |
| Swipe-to-go-back gesture | It is not available. Menus and keyboard shortcuts provide reversibility |

## Enum Routes Do Carry Over

When a column has its own depth, or when windows must be opened by type, a route
enum is still the right pattern: it is exhaustive, and the compiler flags every
consumer when a case is added.

```swift
enum Route: Hashable, Codable {
    case note(Note.ID)
    case tag(String)
    case settings(SettingsTab)
}
```

On macOS, that feeds `openWindow(value:)` or a selection, not a `push`.

## Reusable Components Do Not Navigate

This is the same rule described in
[Screens vs. Views](architecture.md#screens-vs-views), and this example shows
why it matters.

**Wrong — navigation wired into the component**

```swift
struct NoteRowView: View {
    @Environment(\.navigate) private var navigate
    let note: Note

    var body: some View {
        Button("Open") { navigate(.note(note.id)) }   // ← always the same destination
    }
}
```

`NoteRowView` can no longer be used in a dialog's picker or in a search-results
list that opens items in a new window. Its destination is hard-wired.

**Right — the component emits an event; the screen decides**

```swift
struct NoteRowView: View {
    let note: Note
    let onEvent: (NoteRowEvent) -> Void

    var body: some View {
        Button("Open") { onEvent(.select(note)) }
    }
}
```

If the destination really is part of the component's configuration, pass it
through the initializer (`destination: Route`) instead of reading it from the
environment. What is not acceptable is letting the component **decide** where
to navigate.

## Windows: What iOS Does Not Have

```swift
@main
struct NotesApp: App {
    var body: some Scene {
        WindowGroup { ContentScreen() }

        // One preferences window
        Settings { SettingsScreen() }

        // One window per document, opened with openWindow(value:)
        WindowGroup(for: Note.ID.self) { $id in
            NoteWindowScreen(noteID: id)
        }
    }
}

// From a Screen:
@Environment(\.openWindow) private var openWindow
// openWindow(value: note.id)
```

See `axiom-macos` for details about scenes, state restoration, and `NSWindow`.

## Source

- [Navigation Patterns in SwiftUI](https://azamsharp.com/2024/07/29/navigation-patterns-in-swiftui.html)
  — the source for the enum-route pattern and the rule against wiring navigation
  into components. The rest of the article is iOS-specific and was not carried
  over.
