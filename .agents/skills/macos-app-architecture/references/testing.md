# What to Test and What Not to Test

> This document is the **decision layer**: what deserves a test and what kind.
> The Swift Testing API (`@Test`, `#expect`, traits, parameterization) is covered
> by the `swift-testing-expert` skill and is not duplicated here.

## The Framework: Four Pillars That Cannot All Be Maximized at Once

Before deciding what to test, it helps to have a yardstick. From
*Unit Testing Principles, Practices, and Patterns* (Vladimir Khorikov), a test
is evaluated by four traits:

1. **Regression protection** — how much real code it exercises.
2. **Resistance to refactoring** — whether it survives changes that do not alter
   observable behavior.
3. **Feedback speed**.
4. **Maintainability**.

**You cannot maximize all four.** A UI test protects a lot and is refactor
resistant, but it is slow. A unit test of an internal detail is extremely fast
and has no resistance to refactoring. Choosing a test type means choosing what
to sacrifice.

### Resistance to Refactoring Is the Decisive—and Binary—Pillar

Khorikov considers it the most important, and it has a unique property: **you
either have it or you do not**. There is no middle ground to negotiate.

The criterion for having it is one: **treat the component as a black box with
inputs and outputs**. As soon as a test knows the internals—that a particular
property exists, that a particular method was called, and in a particular order—it loses
refactor resistance and starts to break in refactors that do not change anything
observable.

From there most of the rest of this document follows. A view model test fails
this criterion by construction: the view model *is* the interior.

---

## The Principle

**Test behavior, not implementation details.**

The uncomfortable corollary in an architecture without view models is this:
**you cannot write a unit test that validates the UI—and that is fine, because
you could not do so before either.** A view-model test does not validate the UI;
it validates that an object which *supposedly* represents the UI changed state.
Such a test stays green while the screen is broken, then turns red when a
property is renamed even though nothing visible changed.

That is not coverage; it is friction.

```swift
// Wrong — tests the implementation. Zero refactor resistance.
@Test func loadSetsIsLoadingThenClearsIt() async throws {
    let store = NoteStore(repository: InMemoryNoteRepository())
    #expect(store.isLoading == false)
    async let load: Void = store.load()
    #expect(store.isLoading == true)      // ← internal detail
    try await load
    #expect(store.isLoading == false)
}
// Breaks if you rename `isLoading`, derive it from something else, or change internal order —
// even though observable behavior does not change.
```

```swift
// Right — tests behavior. Pure black box: inputs and outputs.
@Test("Loading makes the directory's notes available")
func loadExposesNotesFromDirectory() async throws {
    let store = NoteStore(repository: InMemoryNoteRepository(seed: [
        .init(title: "Ideas"), .init(title: "Notes"),
    ]))

    try await store.load()

    #expect(store.notes.map(\.title) == ["Ideas", "Notes"])
}
// Survives any refactor that does not change what the user observes.
```

The difference is not stylistic: the first knows the interior, the second only
looks at what comes in and what goes out.

## The Practical Pyramid

| What | How | Cost |
|---|---|---|
| Pure extracted logic (validation, ordering, filtering, parsing) | Unit test | Cheap, fast, stable |
| Store logic (domain rules, transitions) | Unit test with fake repository | Cheap |
| The screen looks right | **Xcode Previews** | Manual, but that is their purpose |
| Layout does not break without warning | **Snapshot testing** (separate target) | Slow; refactor resistant |
| Complete workflows | E2E | Expensive and slow, but this is what catches real regressions |

### 1. Extract and Test Pure Logic

If something deserves a test, pull it out of the view. Not for purity: because
logic inside `body` can only be tested by launching the UI.

```swift
struct NewNoteForm {
    var title: String = ""
    func validate() -> [NoteField: String] { … }
}

@Test("A title containing a slash is rejected because it is a filename")
func rejectsSlashInTitle() {
    let form = NewNoteForm(title: "notes/2026")
    #expect(form.validate()[.title] != nil)
}
```

See [validation.md](validation.md#4-extract-the-form-into-a-type-the-important-pattern).

### 2. Test the Store Against a Fake Repository

The store carries domain rules, and those matter.

```swift
@Test("Renaming to a name already used in the same folder fails")
func rejectsDuplicateNameInFolder() async throws {
    let store = NoteStore(repository: InMemoryNoteRepository(seed: [
        .init(title: "Ideas", folder: "/a"),
        .init(title: "Notes", folder: "/a"),
    ]))
    try await store.load()

    await #expect(throws: NoteError.duplicateName) {
        try await store.rename(store.notes[1], to: "Ideas")
    }
}
```

A fake **in‑memory** repository is preferable to a mock with expectations:
test behavior, not call sequence.

### 3. Previews Are the UI Tool

A well-designed presentation component—with no `Environment` dependency and
data passed through its initializer—can be previewed without launching the app:

```swift
#Preview("Empty list")   { NoteListView(notes: []) { _ in } }
#Preview("Very long title") { NoteListView(notes: [.longTitle]) { _ in } }
#Preview("200 notes")     { NoteListView(notes: .demo(count: 200)) { _ in } }
```

This alone is the best reason to enforce that `…View`s do not read from the
environment. See [architecture.md](architecture.md#who-can-read-from-the-environment).

### 4. E2E: Few, Long, Happy-Path Tests

E2E tests are costly and slow, so their value is to cover **a lot** per test, not
to verify isolated rules.

- Long happy path: create note → write → tag → search → open.
- A few edge cases that have truly broken something before.
- **Do not** write a test per validation rule: that’s work for level 1.

## Isolating Tests That Touch the File System

Swift Testing runs test functions **in parallel by default, in randomized
order**. For an app whose model is a directory of files, that is a trap: two
tests sharing one temporary directory will pass alone and flake together.

The fix is not `.serialized` — that hides the coupling and slows the suite. It
is to give **each test its own directory**. Swift Testing instantiates the suite
struct once per test, so an `init` is all you need:

```swift
import Testing
import Foundation

struct NoteDirectoryTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "notes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func writesNoteToOwnDirectory() throws {
        let file = directory.appending(path: "Ideas.md")
        try "# Ideas".write(to: file, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func otherTestDoesNotSeeIt() throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)   // isolated from the test above
    }
}
```

**Verified**: both tests pass together, in parallel, on Swift 6.2.

Reserve `.serialized` for suites that genuinely cannot be isolated — one shared
external resource, a global the framework owns. If you reach for it because
tests interfere, the interference is the bug.

Randomized order is a feature, not noise: a test that only passes after another
one ran has a hidden dependency, and you want to know now rather than in CI.

---

## Snapshot Testing: The Missing Piece for Layout

Previews validate layout visually. Snapshot testing validates it **in CI**:
it renders the view, compares it to a reference image, and fails if it changes.

`pointfreeco/swift-snapshot-testing` (MIT, ~4.3k stars, active) supports macOS 10.15+
and includes strategies for `NSView`, `NSViewController`, and SwiftUI views —
so it works for an AppKit panel wrapped as well as a plain `View`.

```swift
import SnapshotTesting
import Testing

@Test("Empty list layout looks as intended")
@MainActor
func emptyListLayout() {
    let view = NoteListView(notes: []) { _ in }
    assertSnapshot(of: NSHostingView(rootView: view.frame(width: 320, height: 480)),
                   as: .image)
}
```

**Why it fits the four pillars:** it protects a lot (covering the view, layout,
and typography) and
**resists refactor** because it only looks at the rendered result — a pure black
box. The cost is speed and maintenance (you must regenerate references when the
design changes purposefully).

**Two conditions to avoid it becoming a burden:**

1. **Determinism.** Fix size, appearance (light/dark mode), and fonts in the test.
   A snapshot that depends on the environment fails in CI but passes locally, and
   you end up disabling it.
2. **Separate target.** Snapshots are slow. Keep them in a separate target so the
   suite you run on every save remains instantaneous while the image suite runs in CI.

Don’t snapshot full screens with network data: snapshot **presenters** with
fixed data. This is another reason to enforce that `…View`s do not read from the
environment.

---

## Coverage

The coverage percentage is a metric, not a goal. A suite at 90 % may catch fewer
regressions than a 40 % suite with well‑tested domain logic and four E2E tests.
Pursue **confidence**, and measure it by how often the suite has stopped a real
failure.

## Tests Written by the Same Agent Who Wrote the Code

Documented real-world case: an agent refactored a `ViewController` to
`@Observable` and **also wrote the tests**. It compiled, the suite was green,
and the change was merged. Production failed.

The reason is not that the agent writes poorly; it is that **tests derived
from the same understanding as the code only verify that the code is consistent
with itself**. If the underlying requirement was wrong, the test codifies the same
error and passes in green. It’s a consistency check, not a correctness check.

Applied to the four pillars, these tests appear to protect against regressions
but have **zero resistance to refactoring**, because they are usually coupled to
the exact form the agent just produced.

**Rule**: define the acceptance criterion yourself, in domain language, before
implementation—for example, “two notes cannot share a name in the same folder.”
The agent may write the test, but it must test a requirement the agent did not
invent.

---

## Rules

1. If testing seems to require a view model, the test design is the problem—not
   the absence of a view model.
2. Any logic worth testing must be callable without constructing a view.
3. A test that breaks when a property is renamed, despite no observable change,
   is testing implementation. Delete it.
4. Prefer in-memory test doubles to mocks with call expectations.

## References

- [Introduction to Container Pattern](https://azamsharp.com/2023/01/24/introduction-to-container-pattern.html)
- [Pragmatic Testing and Avoiding Common Pitfalls](https://azamsharp.com/2012/12/23/pragmatic-testing.html)
- [SwiftUI Testing: A Pragmatic Approach](https://medium.com/better-programming/swiftui-testing-a-pragmatic-approach-aeb832107fe7)
  — Luis Recuenco. The source for applying the four pillars to SwiftUI and for
  snapshot testing.
- *Unit Testing Principles, Practices, and Patterns*, Vladimir Khorikov — source
  of the four pillars.
- [I Let Claude Code Refactor My ViewModel. The Tests Passed. Production Didn't](https://medium.com/@dhruvinbhalodiya752/i-let-claude-code-refactor-my-viewmodel-the-tests-passed-production-didnt-1d4a94ef3578)
- Installed skill `swift-testing-expert` (AvdLee) — for the API.
