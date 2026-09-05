# Undo and Redo

**On macOS, undo is not a feature you implement; it is a system responsibility
you hook into.** This is the biggest difference from iOS, and why almost all
material about using the Memento pattern with SwiftUI does not apply here.

## Why Not to Implement It by Hand

`UndoManager` is more than a stack of states. Registering actions with it gives
you all of this for free:

- **The Edit menu**, including “Undo Rename Note” and its ⌘Z / ⇧⌘Z shortcuts,
  with the action name and everything else.
- **Responder-chain integration**: undo applies to the focused window, not the
  entire app.
- **Document dirty state** and a warning when closing without saving.
- **Grouping** of rapid changes, so typing does not create one undo step per
  keystroke.

A custom stack does not appear in the Edit menu. A macOS app in which ⌘Z does
not work feels broken, however well its Undo button works.

## How to Hook Into It

```swift
@Observable final class NoteDocument { var title = "" }

struct TitleEditor: View {
    @Environment(\.undoManager) private var undoManager
    @Bindable var document: NoteDocument

    func rename(to newTitle: String) {
        let previous = document.title
        document.title = newTitle

        undoManager?.registerUndo(withTarget: document) { target in
            target.title = previous
        }
        undoManager?.setActionName("Rename Note")
    }

    var body: some View { TextField("Title", text: $document.title) }
}
```

**Verified**: compiles with a macOS 14 deployment target.

Three API details worth knowing up front:

1. **The target must be a class.** `registerUndo(withTarget:)` requires an
   `AnyObject`. That fits stores and documents already implemented as
   `@Observable` classes, but not registration against a struct.
2. **The target is captured weakly**, so the closure must not retain the
   document itself. Use the `target` parameter, not `self`.
3. **`setActionName` supplies the menu text.** Without it, the menu simply says
   “Undo,” and users cannot tell what will be undone.

## Redo Comes for Free

There is nothing else to register: if the undo block registers the inverse
operation again, `UndoManager` builds the redo stack. The usual pattern is to
factor the mutation into a method that registers itself.

## Group Rapid Changes

Typing in an editor produces a change for every keystroke. Without grouping,
⌘Z would remove one character at a time, which is unusable.

```swift
undoManager?.beginUndoGrouping()
// … several mutations the user perceives as a single change …
undoManager?.endUndoGrouping()
```

`NSTextView` already handles this: the text view registers and groups its own
edits with the window's `UndoManager`. **Do not duplicate that work**—if you
also register the same edit, each ⌘Z will undo it twice.

## Anti-Pattern: A Custom State Stack

```swift
// Wrong — hand-rolled Memento. It works and is still wrong on macOS.
@Observable final class NoteStore {
    private var history: [[Note]] = []

    func snapshot() { history.append(notes) }
    func undo() { if let last = history.popLast() { notes = last } }
}
```

What you lose: the Edit menu, ⌘Z, dirty state, grouping, and per-window scope.
You also keep full copies of the state in memory instead of inverse operations.

**When a custom stack is appropriate**: for state that **is not a document
edit**—a panel's navigation history or the steps in a wizard. Users do not
expect ⌘Z to affect those, and mixing them into `UndoManager` would be worse.

## Source

- [Memento Pattern with SwiftUI](https://holyswift.app/memento-pattern-with-swiftui/)
  — implements the pattern by hand and **never mentions `UndoManager`**. It is
  representative of iOS material on this topic: technically correct, but on
  macOS it solves the wrong problem.
