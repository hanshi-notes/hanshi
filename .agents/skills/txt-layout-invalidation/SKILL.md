---
name: txt-layout-invalidation
description: Configure and reason about text layout invalidation across TextKit 1 (NSLayoutManager) and TextKit 2 (NSTextLayoutManager). Covers what triggers invalidation, the lazy-recompute model, ensureLayout / invalidateLayout / invalidateGlyphs / invalidateDisplay scoping, the editing transaction in TextKit 2, NSTextContentStorage element regeneration, viewport-driven layout updates, and why rendering attributes do not invalidate layout. Use when reasoning about how layout gets recomputed after a text edit, after a container size change, or after exclusion-path mutation. Do NOT use for symptom-driven debugging — see txt-textkit-debug. Do NOT use for fallback issues — see txt-fallback-triggers.
license: MIT
---

# Text layout invalidation

Authored against iOS 26.x / Swift 6.x / Xcode 26.x.

This skill is the invalidation model itself: what marks layout dirty, what schedules recomputation, what is lazy and what is eager, and how the two TextKit stacks differ. It is not a debugging guide — for symptom-driven diagnosis, jump to `txt-textkit-debug`. The patterns here describe how layout recomputation is supposed to work; before assuming the model applies to a specific bug, open the actual call site and confirm the edit is going through the path the model describes. If `processEditing` isn't running at all, no amount of `ensureLayout` will fix the symptom.

## Contents

- [TextKit 1 invalidation model](#textkit-1-invalidation-model)
- [Forcing layout in TextKit 1](#forcing-layout-in-textkit-1)
- [Manual invalidation in TextKit 1](#manual-invalidation-in-textkit-1)
- [TextKit 2 invalidation model](#textkit-2-invalidation-model)
- [Forcing layout in TextKit 2](#forcing-layout-in-textkit-2)
- [Manual invalidation in TextKit 2](#manual-invalidation-in-textkit-2)
- [What does not invalidate layout](#what-does-not-invalidate-layout)
- [What rebuilds storage and elements](#what-rebuilds-storage-and-elements)
- [Forcing a complete re-render](#forcing-a-complete-re-render)
- [Common patterns](#common-patterns)
- [Common Mistakes](#common-mistakes)
- [References](#references)

## TextKit 1 invalidation model

`NSLayoutManager` exposes glyph generation and layout as separately invalidatable. A text mutation invalidates both; a container resize invalidates layout but not glyphs; manual calls let you invalidate one without the other.

| Trigger | Invalidates | Automatic? |
|---|---|---|
| Character edit in `NSTextStorage` | Glyphs and layout in edited range | Yes — through `processEditing` |
| Attribute change in `NSTextStorage` | Layout in changed range | Yes — through `processEditing` |
| Text container size change | All layout in container | Yes |
| Exclusion path change | All layout in container | Yes |
| `invalidateGlyphs(forCharacterRange:…)` | Glyphs for range | Manual |
| `invalidateLayout(forCharacterRange:…)` | Layout for range | Manual |

The flow on a text edit:

```
NSTextStorage edit
  → processEditing()
    → NSLayoutManager.processEditing(for:edited:range:changeInLength:invalidatedRange:)
      → marks glyphs invalid in affected range
      → marks layout invalid in affected range
      → defers actual recomputation (lazy)
```

Layout is rebuilt lazily — only when something queries the invalidated range. Display, hit-testing, and rect calculation all force recomputation; reads of unrelated ranges do not.

## Forcing layout in TextKit 1

```swift
// Entire container — O(document); avoid on large docs
layoutManager.ensureLayout(for: textContainer)

// Specific character range — preferred for measurement
layoutManager.ensureLayout(forCharacterRange: range)

// Specific glyph range — when you already have one
layoutManager.ensureLayout(forGlyphRange: glyphRange)

// Specific rect — best for visible content
layoutManager.ensureLayout(forBoundingRect: visibleRect, in: textContainer)
```

Glyph generation is similarly explicit:

```swift
layoutManager.ensureGlyphs(forCharacterRange: range)
layoutManager.ensureGlyphs(forGlyphRange: glyphRange)
```

The `_NSLayoutTreeLineFragmentRectForGlyphAtIndex` console warning means a layout query was made for a glyph index that hadn't been laid out. The fix is `ensureLayout(forCharacterRange:)` or `ensureLayout(forBoundingRect:in:)` covering the queried range before the query runs.

## Manual invalidation in TextKit 1

```swift
layoutManager.invalidateGlyphs(
    forCharacterRange: range,
    changeInLength: 0,
    actualCharacterRange: nil
)
layoutManager.invalidateLayout(
    forCharacterRange: range,
    actualCharacterRange: nil
)
layoutManager.invalidateDisplay(forCharacterRange: range)
layoutManager.invalidateDisplay(forGlyphRange: glyphRange)
```

`invalidateGlyphs` regenerates glyphs (use after attribute changes that affect glyph mapping — fonts, ligatures, custom glyph substitution). `invalidateLayout` keeps glyphs and re-lays them out (use after container geometry changes that the system didn't catch). `invalidateDisplay` only marks pixels dirty for redraw and does not recompute layout — useful after temporary-attribute changes when only the visible rect needs to refresh.

## TextKit 2 invalidation model

The model is similar but addresses different objects: elements regenerate, layout fragments invalidate, and the viewport controller orchestrates re-layout.

| Trigger | Invalidates | Automatic? |
|---|---|---|
| Edit via `performEditingTransaction` | Elements and layout fragments in range | Yes |
| `invalidateLayout(for: NSTextRange)` | Layout fragments in range | Manual |
| Rendering attribute change | Visual only — no layout | Partial |
| Text container size change | All layout fragments | Yes |

The flow on a text edit:

```
contentStorage.performEditingTransaction {
    textStorage.replaceCharacters(...)
}
  → NSTextContentStorage regenerates affected NSTextParagraph elements
    → NSTextLayoutManager invalidates layout fragments for the changed elements
      → NSTextViewportLayoutController re-runs viewport layout
        → delegate callbacks: willLayout → configureRenderingSurface(×N) → didLayout
```

The transaction wrapper is load-bearing. Direct `NSTextStorage` mutations outside `performEditingTransaction` produce inconsistent element regeneration: the storage edit goes through, the storage's own delegates fire, but elements may not regenerate and layout may not invalidate. The bug presents as stale fragments after an edit — text changed, view didn't.

## Forcing layout in TextKit 2

```swift
// Force layout for a range — EXPENSIVE for large ranges
textLayoutManager.ensureLayout(for: textRange)

// Enumerate with layout guarantee
textLayoutManager.enumerateTextLayoutFragments(
    from: location,
    options: [.ensuresLayout]
) { fragment in
    return true
}

// Trigger a viewport layout pass — preferred for visible content
textLayoutManager.textViewportLayoutController.layoutViewport()
```

`ensureLayout` over `documentRange` is the equivalent of TextKit 1's `ensureLayout(for: textContainer)` — it forces the viewport optimization to do the very thing it exists to avoid. Limit the range to the viewport or to the slice you actually need.

## Manual invalidation in TextKit 2

```swift
// Invalidate layout for range — fragments will re-lay out on next viewport pass
textLayoutManager.invalidateLayout(for: textRange)

// Invalidate rendering only — visual overlay refresh, no layout recalc
textLayoutManager.invalidateRenderingAttributes(for: textRange)
```

Manual invalidation is rarely necessary on TextKit 2. The transaction model handles it; `invalidateLayout` is mostly a workaround for cases where the system didn't catch a change (custom content manager, bridged data source).

## What does not invalidate layout

The same on both stacks: visual-only overlays, read-only queries, and view-frame changes that don't change the container.

- Setting temporary attributes (TextKit 1 `setTemporaryAttributes`) — visual only.
- Setting rendering attributes (TextKit 2 `setRenderingAttributes`) — visual only.
- Reading layout information — bounding rects, line fragments, used rects.
- Changing the text view's frame without changing the text container size.
- Scrolling the text view (TextKit 2 viewport controller handles this internally).

## What rebuilds storage and elements

`NSTextStorage` is rebuilt only by content mutations: `replaceCharacters(in:with:)`, `setAttributes(_:range:)`, setting `text` or `attributedText` on the view, user typing, paste/drop, undo/redo. Layout invalidation does not rebuild storage; container geometry changes do not rebuild storage; scrolling does not rebuild storage.

`NSTextContentStorage` regenerates `NSTextParagraph` elements when the wrapped `NSTextStorage` is edited inside a `performEditingTransaction`, and when the entire storage is replaced. Element regeneration is paragraph-scoped: only affected paragraphs are rebuilt, not the entire tree. `invalidateLayout(for:)` only invalidates layout fragments, not elements; rendering attribute changes do not regenerate elements; viewport scrolling does not regenerate elements.

## Forcing a complete re-render

Sometimes you need to invalidate everything — typically after a global font or theme change.

```swift
// TextKit 1: invalidate everything
let fullRange = NSRange(location: 0, length: textStorage.length)
layoutManager.invalidateGlyphs(
    forCharacterRange: fullRange,
    changeInLength: 0,
    actualCharacterRange: nil
)
layoutManager.invalidateLayout(
    forCharacterRange: fullRange,
    actualCharacterRange: nil
)

// Or trigger via the storage path (preferred — keeps the lifecycle clean)
textStorage.beginEditing()
textStorage.edited(.editedAttributes, range: fullRange, changeInLength: 0)
textStorage.endEditing()
```

```swift
// TextKit 2
textLayoutManager.invalidateLayout(for: textLayoutManager.documentRange)
textLayoutManager.textViewportLayoutController.layoutViewport()
```

The TextKit 1 storage-path approach (a no-op `edited(.editedAttributes, …)` over the full range) goes through `processEditing` and gives layout managers a chance to update their own caches. Direct `invalidateLayout` calls work but are blunter.

## Common patterns

### Syntax highlighting after an edit

```swift
// TextKit 1: in NSTextStorageDelegate
func textStorage(
    _ textStorage: NSTextStorage,
    didProcessEditing editedMask: NSTextStorage.EditActions,
    range editedRange: NSRange,
    changeInLength delta: Int
) {
    guard editedMask.contains(.editedCharacters) else { return }
    let paragraphRange = (textStorage.string as NSString).paragraphRange(for: editedRange)
    highlightSyntax(in: paragraphRange, textStorage: textStorage)
}
```

Re-highlighting the affected paragraph (extended to paragraph boundaries) keeps per-keystroke work bounded. Re-highlighting the entire document on every edit turns single-character edits into O(document).

### Deferred layout queries

```swift
// Don't query layout during editing
textStorage.beginEditing()
textStorage.replaceCharacters(in: r1, with: "x")
textStorage.addAttribute(.font, value: font, range: r2)
textStorage.endEditing()
// NOW it's safe to query
let rect = layoutManager.usedRect(for: textContainer)
```

Layout state between `beginEditing()` and `endEditing()` is in flux. Measurements taken inside the batch see partial state.

### Content size calculation

```swift
// TextKit 1
layoutManager.ensureLayout(for: textContainer)
let usedRect = layoutManager.usedRect(for: textContainer)
let contentSize = CGSize(
    width: usedRect.width + textContainer.lineFragmentPadding * 2,
    height: usedRect.height
        + textView.textContainerInset.top
        + textView.textContainerInset.bottom
)
```

TextKit 2 has no equivalent for "exact total used height" until the entire document is laid out. `usageBoundsForTextContainer` is an estimate that refines while scrolling.

## Common Mistakes

1. **Querying layout during editing.** Layout state is invalid between `beginEditing()` and `endEditing()`. Move the query after `endEditing()`, or use a deferred dispatch to the next runloop tick.

2. **Full-document `ensureLayout` on TextKit 2.** Defeats the viewport optimization. Either limit the range to the viewport, or accept estimated geometry via `.estimatesSize`. If exact total layout is genuinely required, the question is really "should this be on TextKit 1?" — see `txt-textkit-choice`.

3. **Expecting rendering attributes to invalidate layout.** They don't. Rendering attributes are visual-only overlays. If a change needs to affect line breaking or wrap, it has to go through the storage attributes (font, paragraph style, attachment), not rendering attributes.

4. **Not wrapping TextKit 2 edits in `performEditingTransaction`.** The edit goes through, the symptom is "view didn't update" but the storage did. Wrap mutations:

   ```swift
   contentStorage.performEditingTransaction {
       textStorage.replaceCharacters(in: range, with: newText)
   }
   ```

5. **Manual `invalidateLayout` after every keystroke.** The text-storage editing lifecycle invalidates layout automatically through `processEditing`. Manual invalidation is for non-storage changes (container geometry the system didn't observe, custom content manager updates) — not for normal edits.

6. **`ensureLayout(for: textContainer)` on TextKit 1 large documents.** O(document_size). Use the rect-scoped variant `ensureLayout(forBoundingRect:in:)` over the visible rect, or the range-scoped variant.

7. **Wrong `changeInLength` in `edited(_:range:changeInLength:)`.** The delta must be in NSString units (UTF-16). `String.count` is wrong on emoji and combining marks. The bookkeeping diverges silently and subsequent edits clobber data. Normalize at the boundary.

## References

- `txt-textkit-debug` — symptom-driven debugging when stale layout is one of several plausible causes
- `txt-fallback-triggers` — when invalidation isn't running because the view fell back to TextKit 1
- `txt-nstextstorage` — storage subclassing and the editing lifecycle that drives invalidation
- `txt-textkit1` — TextKit 1 layout-manager API surface
- `txt-textkit2` — TextKit 2 layout-manager API surface and the editing transaction
- `txt-viewport-rendering` — viewport behavior and fragment geometry
- [NSLayoutManager](https://sosumi.ai/documentation/uikit/nslayoutmanager)
- [NSTextLayoutManager](https://sosumi.ai/documentation/uikit/nstextlayoutmanager)
- [NSTextContentStorage](https://sosumi.ai/documentation/uikit/nstextcontentstorage)
- [NSTextViewportLayoutController](https://sosumi.ai/documentation/uikit/nstextviewportlayoutcontroller)
