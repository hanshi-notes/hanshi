# Previews as a Design Engine

> **The principle, from Apple's guide:** *“A previewable app is a testable app, and a testable app is a maintainable app.”*

This reverses the usual order. A preview is not a convenience added at the end;
**it is the criterion that validates the design**. If a view cannot be previewed
without bringing up half the app, the problem is not the preview—it is the view.

Almost every rule in this skill can be checked with one question: **Can I
preview this with fake data and no dependencies?**

- Does a `…View` read from the `Environment`? → It cannot be previewed without setting up the environment. [Rule](architecture.md#who-can-read-from-the-environment).
- Does a store perform I/O in `init`? → The preview touches disk or network. [Rule](observation.md#2-do-not-rely-on-init--deinit).
- Does the logic live inside `body`? → It can only be tested by launching the UI. [Rule](testing.md).

---

## 1. Narrow Inputs, Not Full Models

Pass the view **only what it displays**, not the entire domain object. That
keeps the preview from having to construct an expensive model.

```swift
// Wrong — to preview this you must build a full Note, and if Note has dependencies, drag them in too.
struct NoteRowView: View {
    let note: Note
}

// Right — minimal inputs: the preview is a line.
struct NoteRowView: View {
    let title: String
    let isFavorite: Bool
    let hasAttachments: Bool
    let onEvent: (NoteRowEvent) -> Void
}
```

**An honest caveat**: taken to the extreme, this multiplies parameters. The
practical rule is to pass the model when it is a dependency-free value
`struct`—such as a well-designed `Note`—and break it apart as soon as the type
drags in services, a persistence context, or networking.

**What passing the whole struct costs — measured.** SwiftUI compares a view's
value-type inputs field by field, so a row handed `note:` re-evaluates when *any*
field of that note changes, including fields it never reads. Child `body`
evaluations while the parent re-evaluates 50 times; macOS 15.8, Xcode 26.3
(SDK 26.2), Swift 6.2.4, deployment target macOS 14, 2026-09-17. Identical in
Release and Debug, and at N = 20:

| The row receives | What changes | Row evaluations |
|---|---|---|
| `title:` | `body`, which the row does not read | 0 |
| `note:` | `body`, which the row does not read | **50** |
| `note:`, in a `ForEach` of 10 | `notes[0].body` | **50** — the edited row only, not 500 |
| `note:` | nothing; the parent re-evaluates for another reason | 0 |

Making the struct `Equatable` changed no row. This is SwiftUI comparing view
inputs, a different layer from
[`@Observable`'s own deduplication](observation.md#4-assigning-an-equal-value-does-not-notify).

So the caveat stands, with a price attached: **one row body per change to that
row's element**. Accept it by default. Break the struct apart when the element
changes at a high rate — a model the editor writes on every keystroke, a
progress value — which is Quick Rule 6 applied to a view's inputs.

**When the parameter list really does grow**, the answer is not to return to the
entire model. Recognize the *data clump* smell: a group of values that **always
travel together** is a type you have not written yet.

```swift
// Wrong — five parameters that are never used separately.
struct NoteRowView: View {
    let title: String
    let excerpt: String
    let isFavorite: Bool
    let hasAttachments: Bool
    let modifiedAt: Date
}

// Right — the clump was a type: narrow, without dependencies, trivial to build in a preview or test.
struct NoteSummary: Equatable {
    let title: String
    let excerpt: String
    let isFavorite: Bool
    let hasAttachments: Bool
    let modifiedAt: Date
}

struct NoteRowView: View {
    let summary: NoteSummary
}
```

The difference from passing `Note` is that `NoteSummary` **exists for the view**: it doesn’t carry the full content, file URL, or repository. The test is always: *Can I construct it in a single line inside a `#Preview`?*

## 2. Design‑time Implementations Behind a Protocol

When the view needs a service, define the **minimum** protocol it requires and provide a design‑time implementation.

```swift
protocol NoteSummarySource {
    var title: String { get }
    var excerpt: String { get }
}

struct DesignTimeNote: NoteSummarySource {
    let title: String
    let excerpt: String

    static let sample     = DesignTimeNote(title: "Ideas", excerpt: "A note…")
    static let longTitle  = DesignTimeNote(title: String(repeating: "Title ", count: 12), excerpt: "")
    static let empty      = DesignTimeNote(title: "", excerpt: "")
}
```

Edge cases live **next to the design type**, not duplicated in every preview.

## 3. Intermediate Container for Previewing a `Binding`

A view that receives an `@Binding` cannot be previewed directly: something must
own the state. Wrap it in a container.

```swift
private struct SearchFieldPreview: View {
    @State private var query = "markdown"

    var body: some View {
        SearchFieldView(query: $query)
    }
}

#Preview("Search Field") { SearchFieldPreview() }
```

On macOS 15+ there’s `@Previewable`, which eliminates the wrapper:

```swift
#Preview {
    @Previewable @State var query = "markdown"
    SearchFieldView(query: $query)
}
```

For macOS 14, use the container.

## 4. One Named Preview per State

Do not create one preview for “the view”; create one for every state that could break.

```swift
#Preview("Empty")          { NoteListView(notes: []) { _ in } }
#Preview("One Note")       { NoteListView(notes: [.sample]) { _ in } }
#Preview("Very Long Title") { NoteListView(notes: [.longTitle]) { _ in } }
#Preview("200 Notes")      { NoteListView(notes: .demo(count: 200)) { _ in } }
#Preview("Dark Mode")      { NoteListView(notes: [.sample]) { _ in }
                          .preferredColorScheme(.dark) }
```

These same cases later feed the
[snapshots](testing.md#snapshot-testing-the-missing-piece-for-layout): the
preview checks them by eye today, and the snapshot guards them in CI tomorrow.

## 5. Never Do I/O in a Preview

No network calls, disk reads, or databases. A preview that depends on its
environment fails intermittently and eventually gets ignored—just like a
nondeterministic snapshot.

---

## Performance

- **Move expensive calculations out of `body`.** It is re-evaluated far more often than you expect, and you do not control when.
- **Use granular dependencies:** a view should be invalidated only by what it actually reads. This is the same conclusion demonstrated in [observation.md](observation.md#1-granularity-is-lost-when-state-is-nested-in-a-struct).
- **Watch `Environment` for frequently changing values:** each change invalidates the entire subtree that reads it.
- Use lazy containers (`LazyVStack`, `LazyVGrid`) for long lists.
- To measure real performance, use the SwiftUI performance instrument and `xctrace`; see the installed `instruments-profiling` skill.

## Source

- [Apple's Best Practices for SwiftUI Development](https://agenthicks.com/research/apple-swiftui-best-practices-2025)
  — compilation of Apple documentation and WWDC sessions.
