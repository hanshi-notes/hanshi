# Observation: Granularity and Lifecycle

Traps of the `Observation` framework that aren't apparent when reading the documentation and that decide how you model a store — plus how to observe one from outside a `body`, which on macOS you will need.

---

## 1. Granularity Is Lost When State Is Nested in a Struct

`@Observable` tracks accesses **by stored property**. If all state lives inside a single struct, changing any field invalidates every view that reads *any* other field—and you are back to the Redux-style re-rendering problem, where a central state blob redraws unrelated views.

**Verified with `withObservationTracking`** (Swift 6.2, macOS 15.7):

```swift
struct NestedState { var a = 0; var b = 0 }

@Observable final class Flat   { var a = 0; var b = 0 }
@Observable final class Nested { var state = NestedState() }
```

| Case | Reads | Changes | Invalidates? |
|---|---|---|---|
| Flat | `flat.a` | `flat.b` | **no** |
| Nested | `nested.state.a` | `nested.state.b` | **yes** |

```swift
// Wrong — blob: any change repaints everything that reads the store.
@Observable final class NoteStore {
    struct State { var notes: [Note] = []; var query = ""; var isLoading = false }
    var state = State()
}

// Right — flat properties: each view only invalidates what it reads.
@Observable final class NoteStore {
    private(set) var notes: [Note] = []
    var query = ""
    private(set) var isLoading = false
}
```

**Rule**: Observable properties should be flat in the class. Group in structs only what truly changes together and is consumed together.

Corollary: Do not bring the `StateContainer<State>` from unidirectional architectures into `@Observable`. That form existed because `ObservableObject` with `@Published` lacked granularity; with `Observation` you have it by default, and wrapping the state removes it.

---

## 2. Do not rely on `init` / `deinit`

In SwiftUI **you do not control view lifecycles**: the framework creates and destroys view descriptions whenever it chooses and may evaluate them several times. `@StateObject` (iOS 14) restored some control over when a state object is created and destroyed, but **the `@Observable` macro broke that guarantee again**.

**Practical consequence**: any pattern that depends on `init` and `deinit` is fragile.

```swift
// Wrong — fragile: the subscription is created and cancelled when the framework decides.
@Observable final class NoteStore {
    private var watcher: FSEventStreamRef?
    init() { watcher = startWatching() }
    deinit { stopWatching(watcher) }      // When? You do not know.
}
```

```swift
// Right — explicit: the lifecycle is set by the view, which does expose it.
struct NoteListScreen: View {
    @Environment(NoteStore.self) private var store

    var body: some View {
        NoteListView(notes: store.notes) { … }
            .task { await store.startWatching() }   // Cancels when the view disappears
    }
}
```

`.task` is preferable to `onAppear`/`onDisappear` for asynchronous work: SwiftUI cancels the task when the view disappears, so you do not have to remember to cancel it.

**Exception**: a store injected into the root with `@State` in the `App` lives as long as the app. There, `init` is deterministic. The trap is in objects created by intermediate views.

---

## 3. Where to place an event enum (and where not)

This skill recommends [grouping the events of a component in an enum](architecture.md#events-grouped-in-an-enum). That **is not** the same as modeling the entire app flow as events, in the style of Redux/TCA.

| | Event enum of a view | App‑wide events |
|---|---|---|
| Scope | Outputs of **one** component | Entire control flow |
| Where resolved | Immediate parent, adjacent `switch` | Central reducer, far away |
| Cost | None | The “ping‑pong” problem |

The ping-pong problem: modeling actions as values splits a flow that should read from top to bottom into N cases that call one another.

```swift
// Split flow: you have to jump between cases to understand it.
func handle(event: Event) {
    switch event {
    case .onAppear:
        state = .loading
        return .task { await send(.numbersDownloaded(try await api.numbers())) }
    case .numbersDownloaded(let values):
        state = .loaded(values)
        return .none
    }
}

// Cohesive and readable in one go.
func onAppear() async {
    state = .loading
    state = .loaded(try await api.numbers())
}
```

Use the enum to **cross a component boundary**. Do not use it to express asynchronous sequences.

---

## 4. Assigning an Equal Value Does Not Notify

`@Observable` deduplicates. Assigning a property a value that compares equal to the
one it already holds fires **nothing** — no view invalidation, no
`withObservationTracking` callback.

**Verified** at the raw API (Swift 6.2, macOS 15.7), each row a fresh registration:

| Property type | Assigned | `onChange` fires? |
|---|---|---|
| `Int` = 0 | `1` | **yes** |
| `Int` = 0 | `0` | no |
| `String` = `"same"` | `"same"` | no |
| `[Int]` = `[]` | `[]` | no |
| Non-`Equatable` struct | an identical value | **yes** |
| Class reference | the *same* instance | no |
| Class reference | a *different* instance | **yes** |

The rule the table describes: **it deduplicates when it can compare, and notifies when
it cannot.** Two consequences:

1. **Do not hand-write `guard newValue != value else { return }` guards** in a store.
   They are already there, and one written by hand on a property Observation could not
   compare is a bug waiting to happen.
2. **Make model types `Equatable`.** A non-`Equatable` payload in an observable property
   re-notifies on every assignment even when nothing changed, which turns an idempotent
   "reload and assign" into a repaint. `Note: Identifiable, Equatable, Codable, Sendable`
   is not decoration; the `Equatable` earns its place here.

A registration that does *not* fire stays armed — the same registration fired correctly
on the next assignment that did differ.

---

## 5. Observing a Store From Outside a View

macOS needs this far more than iOS does, because it has more non-view observers: an
`NSWindow`'s `isDocumentEdited`, a toolbar or menu item's enabled state, an
`NSViewRepresentable` coordinator that has to push state into an imperative view, a
service that reacts to a settings change. None of those is a `body`.

The framework entry point is `withObservationTracking`, and it has **one-shot
semantics**: the `onChange` closure fires for the *first* change to any property read
inside `apply`, and then the registration is spent. Continuous observation means
re-arming it.

### The wrapper that circulates does not compile in Swift 6 language mode

The widely shared solution wraps the API and recurses, with this signature:

```swift
public func withObservationTracking<T: Sendable>(
    of value: @Sendable @escaping @autoclosure () -> T,
    execute: @Sendable @escaping (T) -> Void
) { … }
```

`@Sendable` on the autoclosure is the problem: the closure captures the store, and
**no realistic store can satisfy it**. Verified, both ways:

```swift
@Observable final class Model { var value = 0 }
withObservationTracking(of: model.value) { print($0) }
// error: implicit capture of 'model' requires that 'Model' conforms to 'Sendable'

@MainActor @Observable final class Model { var value = 0 }   // now Sendable…
withObservationTracking(of: model.value) { print($0) }
// error: main actor-isolated property 'value' can not be referenced from a Sendable closure
```

Making the store `Sendable` fixes the first error and produces the second. The signature
is unusable under `.swiftLanguageMode(.v6)`.

Under `.swiftLanguageMode(.v5)` the same code builds **with no diagnostic at all** and
works — the check simply does not run there. So "it compiles for me" locates your
language mode, not a flaw in the analysis: the wrapper is a Swift 6 migration blocker
sitting in code that currently looks clean.

### The version that works

Keep the whole thing on the main actor — an `@Observable` store in this architecture is
main-actor state anyway — and hand the result to the app as an `AsyncStream`, so it is
consumed by `.task` like every other asynchronous source in this skill and cancels with
the view.

```swift
/// Re-arms `withObservationTracking` and yields the current value on every change.
@MainActor
func changes<T>(of read: @escaping @Sendable @MainActor () -> T) -> AsyncStream<T> {
    AsyncStream { continuation in
        arm(read, continuation)
    }
}

@MainActor
private func arm<T>(
    _ read: @escaping @Sendable @MainActor () -> T,
    _ continuation: AsyncStream<T>.Continuation
) {
    withObservationTracking {
        _ = read()
    } onChange: {
        Task { @MainActor in
            // `.terminated` = the consumer is gone; stop re-arming.
            if case .terminated = continuation.yield(read()) { return }
            arm(read, continuation)
        }
    }
}
```

```swift
struct EditorScreen: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        EditorView(text: store.text)
            .task {
                for await dirty in changes(of: { store.isDirty }) {
                    NSApp.keyWindow?.isDocumentEdited = dirty       // not a `body`
                }
            }
    }
}
```

`.terminated` is the same self-unregistering trick the stores in
[architecture.md](architecture.md#communicating-between-stores) use, and it is what keeps
the recursion from running forever: nothing has to be cancelled from the consumer side.

**Verified**: compiles with no warnings under `.swiftLanguageMode(.v6)`, macOS 14
deployment target, Swift 6.2.4.

### What this gives you, measured

| Behaviour | Result |
|---|---|
| Three synchronous mutations (`1`, `2`, `3`) | **one** callback, value `3` |
| The same three, spaced apart | three callbacks |
| The current value on subscribe | **not delivered** — first emission is on first change. Add `continuation.yield(read())` inside `changes(of:)` if you want it |
| After the consuming task is cancelled | the next change ends the stream; nothing is delivered |

The first row is the one that decides whether you may use this at all: **it is a
"something changed, here is the value now" signal, not an event log.** Intermediate
values are lost, so you cannot count changes, drive an undo stack, or react to a
transition through a state with it.

### Prefer domain events when you own the store

If the type is yours, do not observe its properties from outside — publish what happened:

| | `changes(of:)` | The store's own `AsyncStream` of events |
|---|---|---|
| Delivers | The current value, coalesced | Every event, in order |
| Says | *that* something changed | *what* changed, typed |
| Couples the observer to | the property's existence | a domain vocabulary |
| Needs re-arming | yes | no |

`changes(of:)` earns its place in exactly two cases: the type is not yours to change, or
you genuinely want "current value now" rather than a history. For everything else the
domain-event stream in
[architecture.md](architecture.md#communicating-between-stores) is the better tool, and
it was already the skill's default.

### `Observations` supersedes all of this — on macOS 26

Swift 6.2 ships `Observations`, an `AsyncSequence` that does this natively and without
the re-arming. It is **unavailable below macOS 26**, verified:

```
error: 'Observations' is only available in macOS 26.0 or newer
```

So it is the answer for a future deployment target, not this one. When the floor moves,
`changes(of:)` is the thing to delete; its call sites are already `for await` loops and
will not change.

---

## Sources

- [SwiftUI Observation Framework: State Containers](https://medium.com/the-swift-cooperative/swiftui-observation-framework-state-containers-56133d8a8751) — Luis Recuenco
- [SwiftUI View Models: Lifecycle Quirks](https://medium.com/the-swift-cooperative/swiftui-view-models-lifecycle-quirks-8dd967e84e31) — Luis Recuenco
- [The Dark Side of Unidirectional Architectures in Swift](https://medium.com/the-swift-cooperative/the-dark-side-of-unidirectional-architectures-in-swift-e4acf243ff1c) — Luis Recuenco
- [Observing changes to an Observable outside of a SwiftUI view](https://www.polpiella.dev/observable-outside-of-a-view),
  Pol Piella — source for §5's problem statement and the re-arming idea. Its wrapper
  does not build under Swift 6 language mode; §5 records the failure and the
  main-actor-isolated replacement, both verified here.
