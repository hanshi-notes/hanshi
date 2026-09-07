---
name: txt-nstextstorage
description: Subclass and reason about NSTextStorage, NSTextContentStorage, and NSTextContentManager. Covers the editing lifecycle (beginEditing / edited / processEditing / fixAttributes), the four required primitives for an NSTextStorage subclass, NSTextStorageDelegate hooks (willProcessEditing vs didProcessEditing), edit batching, the TextKit 2 performEditingTransaction wrapper, NSTextContentStorageDelegate for display-only paragraph rewriting, and when to subclass NSTextContentManager directly for non-attributed-string backing stores. Use when implementing a custom backing store (rope, piece table, gap buffer), wiring syntax highlighting through delegate callbacks, debugging missing edited() calls, or routing edits through the TextKit 2 transaction model. Do NOT use for symptom-driven debugging — see txt-textkit-debug.
license: MIT
---

# NSTextStorage subclassing and editing lifecycle

Authored against iOS 26.x / Swift 6.x / Xcode 26.x.

This skill is the storage layer: how text content is stored, how mutations propagate, and how to subclass the storage classes correctly. The lifecycle described here is the same on both TextKit stacks — `NSTextStorage` is the backing store on both — but TextKit 2 adds an element layer (`NSTextContentStorage`) on top that has its own editing transaction. Before quoting any signature here as current, fetch the relevant page from Sosumi (`sosumi.ai/documentation/uikit/<class>`); subclass requirements are stable but delegate signatures pick up small additions each release.

## Contents

- [Architecture: TK1 and TK2 storage](#architecture-tk1-and-tk2-storage)
- [NSTextStorage](#nstextstorage)
- [The editing lifecycle](#the-editing-lifecycle)
- [Edit masks and batching](#edit-masks-and-batching)
- [Subclassing NSTextStorage](#subclassing-nstextstorage)
- [NSTextStorageDelegate](#nstextstoragedelegate)
- [NSTextContentStorage](#nstextcontentstorage)
- [The TextKit 2 editing transaction](#the-textkit-2-editing-transaction)
- [NSTextContentStorageDelegate](#nstextcontentstoragedelegate)
- [Subclassing NSTextContentManager directly](#subclassing-nstextcontentmanager-directly)
- [Storage as view cache at scale](#storage-as-view-cache-at-scale)
- [Common Mistakes](#common-mistakes)
- [References](#references)

## Architecture: TK1 and TK2 storage

```
TextKit 1
  NSTextStorage  →  NSLayoutManager(s)
  (attributed string + change tracking)

TextKit 2
  NSTextStorage  →  NSTextContentStorage  →  NSTextLayoutManager(s)
  (backing store)   (element generator)
                          │
                    NSTextParagraph(s)
```

The key difference is the element layer. On TextKit 1, layout managers read the attributed string directly. On TextKit 2, `NSTextContentStorage` regenerates `NSTextParagraph` elements from the wrapped `NSTextStorage` and the layout manager works with those, not with raw attributed strings.

A custom `NSTextStorage` subclass works on both stacks — it's the backing store either way. Subclassing is for backing-store format changes (rope, piece table, gap buffer). For non-attributed-string content models (HTML DOM, AST, CRDT) you subclass `NSTextContentManager` instead.

## NSTextStorage

`NSTextStorage` is a subclass of `NSMutableAttributedString`. It is an attributed string with edit tracking and notifications.

```swift
class NSTextStorage: NSMutableAttributedString {
    var layoutManagers: [NSLayoutManager] { get }

    var editedMask: EditActions { get }
    var editedRange: NSRange { get }
    var changeInLength: Int { get }

    func addLayoutManager(_ layoutManager: NSLayoutManager)
    func removeLayoutManager(_ layoutManager: NSLayoutManager)

    func edited(_ mask: EditActions, range: NSRange, changeInLength delta: Int)
    func processEditing()

    var delegate: NSTextStorageDelegate?
}
```

The `edited` / `processEditing` machinery is what every subclass must integrate with correctly.

## The editing lifecycle

A single mutation flows through these phases:

1. **External mutation.** Caller invokes `replaceCharacters(in:with:)` or `setAttributes(_:range:)`.
2. **`edited(_:range:changeInLength:)`.** Subclass override calls `edited` with the right mask and delta. Internally this accumulates `editedMask`, `editedRange`, and `changeInLength` and adjusts ranges across the change.
3. **`endEditing()` (or implicit single-mutation close).** Triggers `processEditing()`.
4. **`processEditing()`.** The post-edit pipeline:
   - **`willProcessEditing` delegate callback.** Both characters and attributes are writable. Used for auto-correct, text transforms, syntax detection that may insert text.
   - **`fixAttributes(in:)`.** System pass for font substitution and paragraph-style fixing.
   - **`didProcessEditing` delegate callback.** Attributes only — characters are committed and changing them re-enters the lifecycle with stale ranges. Used for syntax highlighting that applies color attributes based on the just-committed text.
   - **Layout manager notification.** Each attached `NSLayoutManager` (TK1) or each `NSTextContentStorage` (TK2) receives `processEditing(for:edited:range:changeInLength:invalidatedRange:)`.

The character-vs-attribute split between `willProcessEditing` and `didProcessEditing` is what decides where syntax highlighting and text transforms go. Mutating characters in `didProcessEditing` is the most common storage-related crash — the storage has committed but ranges captured before are stale, mutation re-enters the lifecycle, and the crash usually surfaces far away in `objc_release` rather than near the offending mutation.

The other timing nuance is font substitution. `fixAttributes(in:)` runs *between* `willProcessEditing` and `didProcessEditing`. That pass replaces fonts the renderer can't satisfy — emoji ranges get `AppleColorEmoji`, missing-glyph ranges get fallback fonts. A font set in `willProcessEditing` is subject to that substitution; a font set in `didProcessEditing` runs after substitution and "sticks". This decides which delegate you use:

- Use `willProcessEditing` for transforms whose output should still be subject to substitution (auto-correct, snippet expansion, text inserts).
- Use `didProcessEditing` when you want your font to override substitution (forcing a specific monospace face across emoji and CJK in a code editor).

Picking the wrong one is the typical "why isn't my font sticking?" bug.

### Don't run syntax highlighting inside the edit transaction

Highlighting *from inside* `processEditing` looks correct — the edited range is right there in the delegate signature — but it produces a subtle UX failure. The layout manager merges your highlight pass's `editedMask` with the user's edit and runs `_fixSelectionAfterChange()` over the union range. The caret jumps to the end of the line and the scroll view bounces.

The fix is to run highlighting *outside* the edit transaction — from `textViewDidChange(_:)` (UIKit) or `NSText.didChangeNotification` (AppKit), which fire after the storage has fully committed and the layout manager has finished. Wrap the highlight pass itself in `beginEditing()` / `endEditing()` so the attribute-only mutations coalesce into one layout invalidation:

```swift
func textViewDidChange(_ textView: UITextView) {
    let storage = textView.textStorage
    let nsText = storage.string as NSString
    let paragraph = nsText.paragraphRange(for: textView.selectedRange)
    storage.beginEditing()
    applyHighlights(in: paragraph, of: storage)
    storage.endEditing()
}
```

Per-keystroke pipelines benefit from scoping to the affected paragraph, not the whole document. The cost difference is O(paragraph) versus O(document) per keystroke.

## Edit masks and batching

```swift
NSTextStorage.EditActions.editedCharacters    // text changed
NSTextStorage.EditActions.editedAttributes    // attributes changed
[.editedCharacters, .editedAttributes]        // both
```

The mask must match the kind of edit. A character replacement uses `.editedCharacters`. An attribute-only change uses `.editedAttributes`. A change that does both passes both flags. Setting `.editedCharacters` for an attribute-only change misleads layout managers into invalidating glyphs unnecessarily; setting `.editedAttributes` for a character change leaves layout state stale.

Batched edits coalesce into one `processEditing()` pass:

```swift
textStorage.beginEditing()
textStorage.replaceCharacters(in: r1, with: "new text")
textStorage.addAttribute(.font, value: bold, range: r2)
textStorage.deleteCharacters(in: r3)
textStorage.endEditing()
// processEditing() runs once with the union of edits
```

Without `beginEditing()` / `endEditing()`, each individual mutation triggers a separate `processEditing()` and a separate layout invalidation pass. Beyond performance, ranges captured outside the batch can become stale mid-batch as earlier mutations shift content; "range out of bounds" crashes during multi-step updates are usually unbatched mutations.

## Subclassing NSTextStorage

A custom backing store (rope, piece table, gap buffer) requires subclassing. Four primitives are required:

```swift
class RopeTextStorage: NSTextStorage {
    private var rope = Rope()

    // 1. Read string content
    override var string: String {
        rope.string
    }

    // 2. Read attributes at a location
    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        rope.attributes(at: location, effectiveRange: range)
    }

    // 3. Replace characters — MUST call edited()
    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        rope.replaceCharacters(in: range, with: str)
        let delta = (str as NSString).length - range.length
        edited(.editedCharacters, range: range, changeInLength: delta)
        endEditing()
    }

    // 4. Set attributes — MUST call edited()
    override func setAttributes(
        _ attrs: [NSAttributedString.Key: Any]?,
        range: NSRange
    ) {
        beginEditing()
        rope.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }
}
```

The rules:

- `replaceCharacters` and `setAttributes` must call `edited(_:range:changeInLength:)` with the correct mask. Without the call, layout managers never learn the storage changed; the visible symptom is "edits go through but the view doesn't update".
- `changeInLength` must be in NSString units (UTF-16). `String.count` counts grapheme clusters, which diverges on emoji and combining marks. Mixing them produces silent corruption — bookkeeping diverges from the actual content and subsequent edits clobber data.
- The `string` property must always reflect current content. Out-of-sync `string` and `attributes(at:effectiveRange:)` produces `EXC_BAD_ACCESS` deep inside `NSLayoutManager` queries.
- `attributes(at:effectiveRange:)` must handle the entire valid range. Returning a partial range or asserting on out-of-bounds queries crashes during layout.

`NSTextStorage` is main-thread-confined. Background mutations crash sporadically with no obvious stack frame. Wrap all access in `DispatchQueue.main` or hop to a `@MainActor` context.

### Swift subclasses are pathologically slow

`NSTextStorage` subclasses written in Swift become CPU and memory bombs around 2k lines. The reason is the `String ↔ NSString` bridge: every layout query that reads `.string` triggers an O(n) bridge of the entire backing store, and the layout manager hammers `.string` on every keystroke. A naive Swift subclass with a `String` backing store ends up bridging the whole document tens of times per character typed.

The two production fixes:

- **Write the subclass in Objective-C.** `NSString` is the native type; no bridge happens. Foreign-language friction in a Swift project, but the perf gap is large enough that several shipping apps have done it.
- **Wrap a real `NSTextStorage` and forward.** ChimeHQ's `TextStory` pattern: keep `NSTextStorage` as the actual storage, expose a Swift-native API on top, and forward primitives to the wrapped instance. The bridge cost moves from per-query to per-mutation.

This is tracked as SR-6197 / `swiftlang/swift#48749`. Code that subclasses `NSTextStorage` in Swift and feels fine on small documents is a latent perf hazard — the failure mode appears only when a real document is opened.

## NSTextStorageDelegate

```swift
protocol NSTextStorageDelegate: NSObjectProtocol {
    // BEFORE fixAttributes — characters AND attributes writable
    func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    )

    // AFTER fixAttributes — attributes only
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    )
}
```

Use `willProcessEditing` for changes that affect characters, fonts, or anything that needs `fixAttributes` to run after — auto-correct, text transforms, font substitution, syntax detection that inserts text. Use `didProcessEditing` for syntax highlighting that applies color attributes based on the just-committed text.

For per-keystroke syntax highlighting, scope the re-highlighting to the affected paragraph rather than the full document. The cost difference is the difference between O(paragraph) per keystroke and O(document) per keystroke.

## NSTextContentStorage

Concrete subclass of `NSTextContentManager` that bridges `NSTextStorage` to TextKit 2's element model.

```swift
class NSTextContentStorage: NSTextContentManager {
    var textStorage: NSTextStorage? { get set }
    var attributedString: NSAttributedString? { get set }

    func textRange(for range: NSRange) -> NSTextRange?
    func offset(from: NSTextLocation, to: NSTextLocation) -> Int

    var delegate: NSTextContentStorageDelegate?
}
```

`NSTextContentStorage` observes `NSTextStorage` edit notifications and regenerates affected `NSTextParagraph` elements. Paragraph boundaries are determined by paragraph separators (`\n`, `\r\n`, `\r`, `\u{2029}`). Each paragraph becomes one `NSTextParagraph` carrying the paragraph's attributed text.

A custom `NSTextStorage` subclass plugs in directly:

```swift
let contentStorage = NSTextContentStorage()
contentStorage.textStorage = RopeTextStorage()
```

The text view uses `NSTextLayoutManager` over the content storage; the rope is the backing store; no fallback occurs.

## The TextKit 2 editing transaction

All TextKit 2 edits should go through `performEditingTransaction`:

```swift
// CORRECT
contentStorage.performEditingTransaction {
    textStorage.replaceCharacters(in: range, with: newText)
}

// WRONG — element regeneration may not run
textStorage.replaceCharacters(in: range, with: newText)
```

Without the transaction wrapper, the storage mutation goes through and the storage's own delegates fire, but element regeneration and layout invalidation are unreliable. The bug presents as "view didn't update after edit" — the storage is current, the elements are stale.

The transaction also coalesces multiple mutations into one element-regeneration pass:

```swift
contentStorage.performEditingTransaction {
    textStorage.beginEditing()
    textStorage.replaceCharacters(in: r1, with: "x")
    textStorage.addAttribute(.font, value: bold, range: r2)
    textStorage.endEditing()
}
```

## NSTextContentStorageDelegate

```swift
protocol NSTextContentStorageDelegate: NSTextContentManagerDelegate {
    // Display-only paragraph modification — does not change the underlying storage
    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph?
}
```

Returning a custom `NSTextParagraph` here changes only what's displayed. The underlying `NSTextStorage` is untouched. Use cases: line numbers as paragraph prefixes, code folding (return a placeholder paragraph for collapsed regions), Markdown preview rendering (return a styled paragraph for displayed text without modifying the source).

Returning `nil` leaves the default behavior intact.

## Subclassing NSTextContentManager directly

When the backing store is not an attributed string at all — HTML DOM, AST, CRDT — subclass `NSTextContentManager` directly instead of using `NSTextContentStorage`.

```swift
class DOMContentManager: NSTextContentManager {
    override var documentRange: NSTextRange { … }

    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: NSTextContentManager.EnumerationOptions,
        using block: (NSTextElement) -> Bool
    ) { … }

    override func replaceContents(
        in range: NSTextRange,
        with textElements: [NSTextElement]?
    ) { … }

    override func location(
        _ location: NSTextLocation,
        offsetBy offset: Int
    ) -> NSTextLocation? { … }

    override func offset(
        from: NSTextLocation,
        to: NSTextLocation
    ) -> Int { … }
}
```

Two constraints to be aware of in current SDKs:

- A custom `NSTextContentManager` subclass that doesn't wrap an `NSTextStorage` crashes during element generation. The supported pattern is to keep `NSTextStorage` as a synthesized backing store and translate to/from the actual model in the overrides.
- Custom `NSTextElement` subclasses beyond `NSTextParagraph` trigger runtime assertions. Custom rendering for non-paragraph content goes through a custom `NSTextLayoutFragment` subclass keyed off `NSTextParagraph`, not a custom element type.

## Storage as view cache at scale

For documents past ~100K lines, production code editors stop treating `NSTextStorage` as the source of truth and start treating it as a view cache. The document model lives in a rope, piece table, or red-black tree (Runestone ports AvalonEdit's line manager; CodeEditTextView abandons TextKit entirely for Core Text); the `NSTextStorage` instance attached to the text view holds only the visible viewport plus a reasonable buffer. Edits go to the model first, then a windowing layer projects a slice into the storage.

This isn't a refinement of the subclassing recipe above — it's a different architecture, and most editors don't need it. Mentioned here so the recipe doesn't read as a one-size-fits-all answer. The detail of when the trade-off becomes worth it lives in `txt-textkit-choice`.

## Common Mistakes

1. **Forgetting `edited()` in an `NSTextStorage` subclass mutation primitive.** Layout managers never learn the storage changed. The most common subclassing bug; the symptom is "edits go through but the view doesn't update".

2. **Wrong `changeInLength` units.** Must be NSString length (UTF-16), not `String.count`. Mixing them corrupts the bookkeeping silently — diverges on emoji, ZWJ sequences, and combining marks. Subsequent edits clobber data and "range out of bounds" crashes appear far from the actual bug.

3. **Mutating characters in `didProcessEditing`.** The storage has committed; ranges captured before are stale; mutating re-enters the editing lifecycle and the resulting crash typically surfaces deep in `objc_release`, not near the offending mutation. Move character changes to `willProcessEditing`, or use attribute-only changes.

4. **Setting fonts in the wrong delegate.** `fixAttributes` runs between `willProcessEditing` and `didProcessEditing` and substitutes fonts the renderer can't satisfy (emoji, missing glyphs). Fonts set in `willProcessEditing` are subject to substitution; fonts set in `didProcessEditing` override it. The "my custom monospace font isn't sticking on emoji" bug is this in disguise.

5. **Running syntax highlighting inside `processEditing`.** The layout manager merges your highlight pass with the user's edit, runs `_fixSelectionAfterChange()` over the union range, and the caret jumps to end-of-line with a scroll bounce. Highlight from `textViewDidChange(_:)` or `NSText.didChangeNotification` instead, and wrap the highlight pass itself in `beginEditing()` / `endEditing()`.

6. **Subclassing `NSTextStorage` in Swift for a >2k-line use case.** The `String ↔ NSString` bridge runs on every `.string` query, the layout manager hammers `.string` per keystroke, and CPU plus memory degrade O(document). Either write the subclass in Objective-C, or keep a real `NSTextStorage` instance internally and forward to it (the TextStory pattern).

7. **Direct `NSTextStorage` mutations on TextKit 2 without `performEditingTransaction`.** Element regeneration is unreliable; the view shows stale content. Wrap all mutations in the transaction.

8. **Background-thread `NSTextStorage` access.** Main-thread-confined. Background mutations crash sporadically with no obvious stack frame. Hop to `DispatchQueue.main` or `@MainActor`.

9. **Re-highlighting the entire document on every keystroke.** Single-character edits become O(document). Scope re-highlighting to the affected paragraph; `(textStorage.string as NSString).paragraphRange(for: editedRange)` gives the right range.

10. **Custom `NSTextContentManager` subclass without an `NSTextStorage`.** Crashes during element generation in current SDKs. Keep `NSTextStorage` as a synthesized backing store and translate in the overrides, or use `NSTextContentStorage` and subclass `NSTextStorage` instead.

11. **Custom `NSTextElement` subclasses beyond `NSTextParagraph`.** Triggers runtime assertions. Use a custom `NSTextLayoutFragment` subclass for custom rendering, not a custom element type.

## References

- `txt-textkit1` — TextKit 1 layout-manager API surface that consumes the storage notifications
- `txt-textkit2` — TextKit 2 layout-manager API surface and the editing transaction in context
- `txt-layout-invalidation` — what gets invalidated when storage edits go through processEditing
- `txt-fallback-triggers` — when a custom storage subclass is fine but a separate layoutManager access flips the view
- `txt-textkit-debug` — symptom-driven debugging when storage-layer behavior is one of several plausible causes
- [NSTextStorage](https://sosumi.ai/documentation/uikit/nstextstorage)
- [NSTextStorageDelegate](https://sosumi.ai/documentation/uikit/nstextstoragedelegate)
- [NSTextContentStorage](https://sosumi.ai/documentation/uikit/nstextcontentstorage)
- [NSTextContentStorageDelegate](https://sosumi.ai/documentation/uikit/nstextcontentstoragedelegate)
- [NSTextContentManager](https://sosumi.ai/documentation/uikit/nstextcontentmanager)
- [NSTextElement](https://sosumi.ai/documentation/uikit/nstextelement)
- [NSTextParagraph](https://sosumi.ai/documentation/uikit/nstextparagraph)
