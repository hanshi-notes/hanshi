# Error Handling

The question that matters is not *how* to throw an error, but **which errors
warrant interrupting the user**. Swift documents the former; the latter is not
documented anywhere.

## 1. Decide the Severity First, Not the Mechanism

| Level | What it is | What you do |
|---|---|---|
| **Ignorable** | Expected failure with no consequences: no cache, optional file does not exist | Nothing; perhaps log it |
| **Informational** | Something failed, but the app remains usable with existing data: a reload failed | **Inline and non-blocking** |
| **Blocking** | The user would lose data or be left with misleading state: saving is impossible | Modal alert |
| **Fatal** | A program invariant is broken due to our own bug | `preconditionFailure`, not an error |

**The most common mistake is treating everything as blocking.** A modal alert
for a failed reload interrupts the user's work to deliver information that does
not help them.

---

## 2. Model the Error So It Can Be Displayed

An enum conforming to `LocalizedError` connects directly to the UI without an
intermediate mapping layer.

```swift
enum NoteError: LocalizedError, Equatable {
    case duplicateName(String)
    case directoryUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .duplicateName(let name): "A note with that name already exists in this folder."
        case .directoryUnavailable:    "Cannot access the notes folder."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .duplicateName:        "Choose a different name."
        case .directoryUnavailable: "Make sure the disk is mounted."
        }
    }
}
```

`Equatable` is not decorative: it lets tests compare errors and allows the
error to be used as an `onChange` value.

`recoverySuggestion` is not filler: it is the difference between a message that
merely informs and one that **tells the user what to do**. If no suggestion
comes to mind, the error may not warrant an alert.

---

## 3. The Error Lives in State, Not in Thin Air

```swift
// The error is part of the state, alongside data that survives.
struct NoteListState {
    var notes: [Note] = []
    var isLoading = false
    var lastError: NoteError?
}
```

Notice that `notes` **is not cleared** when an error occurs. This is the same
reason a view's state should not be an enum: after a reload fails, you still
want to display the data you already had. See
[antipatterns.md](antipatterns.md#an-enum-for-all-view-state).

---

## 4. Presenting Errors on macOS

```swift
// Blocking: alert. `alert(isPresented:error:)` uses LocalizedError directly — no manual strings.
.alert(isPresented: .constant(state.lastError != nil), error: state.lastError) { _ in
    Button("OK") { state.lastError = nil }
} message: { error in
    Text(error.recoverySuggestion ?? "")
}
```

**Verified**: compiles with a macOS 14 deployment target.

```swift
// Informative: inline, non-blocking. The list stays usable.
.safeAreaInset(edge: .bottom) {
    if let error = state.lastError {
        Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
            .padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
            .transition(.move(edge: .bottom))
    }
}
.animation(.default, value: state.lastError)
```

**Modal presentation is more disruptive on macOS than on iOS.** An alert or
sheet takes over **the entire window**, and the user may have several windows
open while working on something else. On iOS an alert interrupts one task; on
macOS it interrupts a desktop workflow. Reserve modal presentation for truly
blocking failures.

---

## 5. Typed Throws: Almost Never

Swift 6 allows declaring the error type (`throws(NoteError)`), which is why it appears in all recent articles. **The official guide is explicitly conservative**:

> *“Most Swift code doesn’t specify the type for the errors it throws.”*

And lists the three cases where it makes sense:

1. **Embedded systems without dynamic memory allocation**: throwing `any Error` requires a heap allocation; a concrete type avoids it.
2. **Errors that are implementation details of a library**, with an exhaustive list and always handled inside.
3. **Code that only propagates errors described by generic parameters**.

**None of the three applies to a macOS app.** The underlying reason is that a
closed error type stops being closed as soon as a dependency throws something
new, forcing a signature change throughout the call chain. Use untyped `throws`
unless one of those three cases applies.

---

## Anti-Patterns

### `try?` That Swallows the Failure

```swift
// Wrong — if it fails, the list becomes empty and the user has no idea why.
let notes = try? await repository.loadAll()
```

```swift
// Right — decide the level. Here it is informative: keep what you had.
do {
    state.notes = try await repository.loadAll()
} catch let error as NoteError {
    state.lastError = error          // previous data stays on screen
} catch {
    state.lastError = .directoryUnavailable(directory)
}
```

`try?` is legitimate when the failure is truly ignorable and you state it explicitly: `let cached = try? cache.read()` followed by a default value.

### `catch { print(error) }`

No one sees that console in a signed, distributed app. Either expose the error
in state, record it with `Logger`, or deliberately ignore it—but a `print` is
all three and none of them at once.

### One `case unknown(String)` for Everything

```swift
// Wrong — the enum adds nothing; it’s just a String with extra steps.
enum AppError: Error { case unknown(String) }
```

If you cannot enumerate the failures, you do not yet understand the domain. An
error enum is valuable precisely because its `switch` is exhaustive and **the
compiler warns you** when a new case is added.

### A Modal Alert for a Recoverable Failure

See §1. If the user can keep working, do not block their window.

---

## Sources

- [Error Handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/),
  *The Swift Programming Language* — canonical source and basis for the stance on typed throws.
- [Best way to present errors in SwiftUI](https://holyswift.app/best-way-to-present-error-in-swiftui/)
  — source of the three presentation styles (alert, sheet, inline notice).
