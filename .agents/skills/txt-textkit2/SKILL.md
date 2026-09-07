---
name: txt-textkit2
description: Reference for TextKit 2 — NSTextLayoutManager, NSTextContentManager, NSTextContentStorage, NSTextLayoutFragment, NSTextLineFragment. Covers the element-based content model, the editing transaction, viewport-driven layout via NSTextViewportLayoutController, rendering attributes vs storage attributes, fragment enumeration options, range types (NSTextRange / NSTextLocation), and delegate hooks for custom paragraphs and custom layout fragments. Use when the editor uses NSTextLayoutManager, when working on TextKit 2 features (Writing Tools inline, viewport layout, custom fragment rendering), or when bridging an attributed-string backing store into the modern stack. Do NOT use for the picker decision between TK1 and TK2 — see txt-textkit-choice. Do NOT use for symptom-driven debugging — see txt-textkit-debug.
license: MIT
---

# TextKit 2 reference

Authored against iOS 26.x / Swift 6.x / Xcode 26.x.

This is the API reference for TextKit 2 — the element-based, viewport-driven text system introduced in iOS 15 / macOS 12 and the default for `UITextView` and `NSTextView` since iOS 16 / macOS 13. The big shifts from TextKit 1 are: no glyph APIs, layout works in fragments addressed by object-based ranges, and the layout manager only ever lays out what's in (or near) the viewport. Before quoting any signature here as current, fetch the relevant page from Sosumi (`sosumi.ai/documentation/uikit/<class>`) — TextKit 2's enumeration options and viewport-controller surface have grown each release since iOS 15.

## Contents

- [Architecture and design](#architecture-and-design)
- [NSTextContentManager](#nstextcontentmanager)
- [NSTextContentStorage](#nstextcontentstorage)
- [NSTextRange and NSTextLocation](#nstextrange-and-nstextlocation)
- [NSTextElement and NSTextParagraph](#nstextelement-and-nstextparagraph)
- [NSTextLayoutManager](#nstextlayoutmanager)
- [Fragment enumeration](#fragment-enumeration)
- [Rendering attributes](#rendering-attributes)
- [Viewport layout](#viewport-layout)
- [Delegates](#delegates)
- [Common Mistakes](#common-mistakes)
- [References](#references)

## Architecture and design

```
NSTextContentManager  →  NSTextLayoutManager  →  NSTextContainer
   (content model)         (layout controller)      (geometry)
        │                           │
NSTextContentStorage          NSTextLayoutFragment
(wraps NSTextStorage)         NSTextLineFragment
        │                           │
NSTextElement                  NSTextViewportLayoutController
NSTextParagraph                (orchestrates visible layout)
```

Three principles drive the API:

1. **Abstraction.** No glyph APIs. International scripts (Arabic, Devanagari, CJK) are handled correctly without character-glyph mapping assumptions. The trade-off is that glyph-level work has to drop to Core Text or back to TextKit 1.
2. **Safety.** Elements and fragments have value semantics. Reads are thread-safe in a way that `NSLayoutManager` queries are not.
3. **Viewport-first performance.** Layout is always non-contiguous; only fragments in or near the viewport are fully laid out. Off-screen content has estimated geometry only. The layout manager works in O(viewport), not O(document).

## NSTextContentManager

Abstract base class. Manages document content as a tree of `NSTextElement` objects. The concrete subclass you almost always use is `NSTextContentStorage`; subclassing `NSTextContentManager` directly is the path for non-attributed-string backing stores (HTML DOM, AST, CRDT).

```swift
var textLayoutManagers: [NSTextLayoutManager] { get }
var primaryTextLayoutManager: NSTextLayoutManager? { get set }
var automaticallySynchronizesTextLayoutManagers: Bool   // default true
var automaticallySynchronizesToBackingStore: Bool       // default true
var documentRange: NSTextRange { get }
```

All mutations to the underlying store go through an editing transaction:

```swift
textContentManager.performEditingTransaction {
    textStorage.replaceCharacters(in: range, with: newText)
}
// Element regeneration and layout invalidation happen at the close of the block.
```

Skipping the transaction wrapper is one of the standing TextKit 2 bugs: edits go through, but element regeneration and layout invalidation may not, leaving fragments stale.

Element enumeration:

```swift
textContentManager.enumerateTextElements(from: location, options: []) { element in
    if let paragraph = element as? NSTextParagraph {
        // ...
    }
    return true   // continue enumeration
}
```

## NSTextContentStorage

Concrete subclass of `NSTextContentManager`. Wraps `NSTextStorage` and divides its content into `NSTextParagraph` elements automatically.

```swift
let contentStorage = NSTextContentStorage()
contentStorage.textStorage = MyTextStorage()   // any NSTextStorage subclass
let storage = contentStorage.textStorage       // backing store access
```

`NSTextContentStorage` observes the wrapped `NSTextStorage`'s edit notifications and regenerates affected paragraph elements. Paragraph boundaries are determined by paragraph separators (`\n`, `\r\n`, `\r`, `\u{2029}`).

| Aspect | NSTextStorage | NSTextContentStorage |
|---|---|---|
| Role | Backing store (attributed string) | Content manager wrapping a backing store |
| Addressing | `NSRange` (integer-based) | `NSTextRange` / `NSTextLocation` (object-based) |
| Output | Raw attributed string | Tree of `NSTextElement`s |
| Editing | Direct mutations | Wrapped in `performEditingTransaction` |
| Notifications | `processEditing()` | Element change tracking |
| Subclass when | Custom backing-store format | Non-attributed-string content model |

The default architecture is: keep `NSTextStorage` as the backing store, use `NSTextContentStorage` (no subclass) on top of it. Custom backing stores (rope, piece table, gap buffer) subclass `NSTextStorage`. Custom content models (HTML DOM, AST) subclass `NSTextContentManager`. Subclassing `NSTextContentManager` without wrapping an `NSTextStorage` currently crashes during element generation.

## NSTextRange and NSTextLocation

TextKit 2 uses object-based ranges instead of `NSRange`. `NSTextLocation` is an opaque token; `NSTextRange` pairs two of them.

```swift
let nsRange = NSRange(location: 0, length: 10)
let textRange = textContentStorage.textRange(for: nsRange)

let documentStart = textContentStorage.documentRange.location
let offset = textContentStorage.offset(from: documentStart, to: textRange.location)
```

The reason for the indirection: in a non-attributed-string backing store, "location 47" doesn't necessarily correspond to a character index. `NSTextLocation` lets the content manager define what a location is — DOM node + offset, AST path, etc.

For an `NSTextContentStorage`, locations correspond to character indices in the wrapped `NSTextStorage`, and the conversion methods round-trip cleanly.

## NSTextElement and NSTextParagraph

`NSTextElement` is the abstract base. Elements have value semantics and are immutable.

```swift
var elementRange: NSTextRange? { get set }
var textContentManager: NSTextContentManager? { get }
var childElements: [NSTextElement] { get }
weak var parent: NSTextElement? { get }
var isRepresentedElement: Bool { get }
```

`NSTextParagraph` is the only element subclass guaranteed to work. Custom `NSTextElement` subclasses beyond `NSTextParagraph` trigger runtime assertions.

```swift
let paragraph: NSTextParagraph
paragraph.attributedString          // the paragraph's content
paragraph.paragraphContentRange     // range without the separator
paragraph.paragraphSeparators       // the separator characters
```

## NSTextLayoutManager

Replaces `NSLayoutManager`. No glyph APIs. Operates on elements and fragments.

```swift
var textContentManager: NSTextContentManager? { get }
var textContainer: NSTextContainer? { get set }                 // exactly one
var textViewportLayoutController: NSTextViewportLayoutController { get }
var textSelectionNavigation: NSTextSelectionNavigation { get }
var textSelections: [NSTextSelection] { get set }
var usageBoundsForTextContainer: CGRect { get }                  // estimate while scrolling
var documentRange: NSTextRange { get }
```

`NSTextLayoutManager` supports exactly one container. Multi-container layout (multi-page, multi-column, linked text views) requires TextKit 1.

`usageBoundsForTextContainer.height` is unstable while the document is being scrolled — TextKit 2 estimates the height based on partially-laid-out content and the estimate refines as more fragments are laid out. Code that depends on exact document height should either force layout for the full document range (defeating the viewport optimization) or use TextKit 1.

## Fragment enumeration

Layout fragments are roughly one-per-paragraph; each fragment contains one or more `NSTextLineFragment`s for the visual lines the paragraph wraps into.

```swift
textLayoutManager.enumerateTextLayoutFragments(
    from: textLayoutManager.documentRange.location,
    options: [.ensuresLayout, .ensuresExtraLineFragment]
) { fragment in
    let frame = fragment.layoutFragmentFrame
    for line in fragment.textLineFragments {
        let bounds = line.typographicBounds        // local to the fragment
    }
    return true   // continue
}
```

Options:

| Option | Effect |
|---|---|
| `.ensuresLayout` | Force layout computation; expensive over large ranges |
| `.ensuresExtraLineFragment` | Include the trailing empty line fragment after `\n` |
| `.estimatesSize` | Use estimated geometry; cheap, less accurate |
| `.reverse` | Enumerate backwards |

Enumerating from `documentRange.location` to the end with `.ensuresLayout` lays out the entire document — exactly the case TextKit 2 was designed to avoid. Enumerate over the viewport range instead, or only over the range you actually need geometry for.

## Rendering attributes

Replace TextKit 1's temporary attributes. Visual styling overlay that does not modify the storage and does not invalidate layout.

```swift
textLayoutManager.setRenderingAttributes(
    [.foregroundColor: UIColor.red],
    forTextRange: range
)
textLayoutManager.addRenderingAttribute(
    .backgroundColor, value: UIColor.yellow,
    forTextRange: range
)
textLayoutManager.removeRenderingAttribute(.backgroundColor, forTextRange: range)

textLayoutManager.enumerateRenderingAttributes(from: location, reverse: false) {
    manager, attributes, range in
    return true
}
```

Rendering attributes attach to the layout manager, not to the storage. The common mistake is calling `textStorage.addAttribute` for what should be a rendering-only effect — it works but it modifies the document, mutates the editing lifecycle, and shows up in copy/paste and serialization.

Known bug (FB9692714): some rendering attribute combinations have drawing artifacts and the workaround is a custom `NSTextLayoutFragment` subclass that draws the effect itself. This is one of the active reasons to keep syntax highlighting on TextKit 1 (where `setTemporaryAttributes` is well-tested).

## Viewport layout

`NSTextViewportLayoutController` is the orchestrator. Delegate callbacks fire around viewport layout passes:

```swift
// Before layout begins — remove old fragment views
func textViewportLayoutControllerWillLayout(
    _ controller: NSTextViewportLayoutController
)

// For each visible layout fragment — position views/layers
func textViewportLayoutController(
    _ controller: NSTextViewportLayoutController,
    configureRenderingSurfaceFor fragment: NSTextLayoutFragment
)

// After layout completes — update content size
func textViewportLayoutControllerDidLayout(
    _ controller: NSTextViewportLayoutController
)
```

`renderingSurfaceBounds` on a layout fragment can extend beyond `layoutFragmentFrame` for content that draws outside the layout rect (diacritics, large descenders, custom backgrounds). Custom `NSTextLayoutFragment` subclasses that draw outside the default frame must override `renderingSurfaceBounds` or the drawing is clipped.

`NSTextLineFragment.characterRange` is local to the line's own attributed string, not document-relative. Converting to a document range requires going through the parent layout fragment's range and offsetting. This is one of the most common bugs in code that ports from TextKit 1.

Invalidation:

```swift
textLayoutManager.invalidateLayout(for: range)
textLayoutManager.invalidateRenderingAttributes(for: range)

textLayoutManager.textViewportLayoutController.layoutViewport()
```

After `invalidateLayout`, the viewport controller re-runs layout for the affected fragments on the next viewport pass. Manual `layoutViewport()` is rarely necessary — the system runs it after a transaction or a scroll.

## Delegates

`NSTextContentStorageDelegate` for custom paragraph generation:

```swift
// Display-only paragraph modification — does not change the underlying storage
func textContentStorage(
    _ storage: NSTextContentStorage,
    textParagraphWith range: NSRange
) -> NSTextParagraph?
```

Use case: line numbers, code folding, Markdown preview rendering — any time the displayed paragraph differs from the stored attributed string.

`NSTextLayoutManagerDelegate` for custom layout fragments:

```swift
// Custom NSTextLayoutFragment subclass per element
func textLayoutManager(
    _ manager: NSTextLayoutManager,
    textLayoutFragmentFor location: NSTextLocation,
    in textElement: NSTextElement
) -> NSTextLayoutFragment {
    return BubbleLayoutFragment(textElement: textElement, range: textElement.elementRange)
}
```

Use case: chat bubbles, code-block backgrounds, callout boxes — anything that needs custom drawing under or around the text.

## Common Mistakes

1. **`enumerateTextLayoutFragments` over the document range with `.ensuresLayout`.** Forces full-document layout. The viewport optimization is exactly what's being defeated. Either drop `.ensuresLayout` (and accept estimated geometry off-screen) or limit the range to the viewport / the slice you actually need.

2. **Treating `NSTextLineFragment.characterRange` as document-relative.** It is local to the parent layout fragment's attributed string. Convert through the fragment's range to get document coordinates before using it for selection or hit-testing.

3. **Custom layout fragments that draw outside `layoutFragmentFrame` without overriding `renderingSurfaceBounds`.** Drawing is clipped to the layout frame. Diacritics, large descenders, and chat-bubble shadows disappear at the edges.

4. **Direct `NSTextStorage` mutations without `performEditingTransaction`.** The edits go through and `NSTextStorage`'s own delegates fire, but element regeneration and layout invalidation are unreliable. Wrap mutations:

   ```swift
   // CORRECT
   contentStorage.performEditingTransaction {
       textStorage.replaceCharacters(in: range, with: newText)
   }
   ```

5. **Reading `usageBoundsForTextContainer.height` as exact document height while scrolling.** It is unstable by design: the value shifts as the viewport advances and TextKit 2 re-estimates unmeasured ranges. Wiring it directly to a `UIScrollView.contentSize` produces a scroller that jitters during fast scrolls — even Apple's TextEdit demonstrates this. The supported pattern is to update the host scroll view's content size only inside `textViewportLayoutControllerDidLayout(_:)`, after the current pass has settled, and to leave the value alone during the pass itself. If exact, stable height is a hard requirement (proportional minimap, ruler view, scroll-position indicator with absolute fractions), the right answer is TextKit 1.

6. **`ensureLayout(for: documentRange)` to "warm up the layout manager".** It is a trap, and the trap has been confirmed by Apple DTS — the call can take seconds on documents large enough to be worth the optimization in the first place, because it materializes every fragment in the document. The supported pattern when scrolling to a target location is the four-step sequence: identify the target range, call `ensureLayout(for:)` for that range only, read the resulting fragment frame, then call `adjustViewport(byVerticalOffset:)` to move the viewport to it. This pulls in a bounded amount of layout work proportional to the distance from the current viewport, not to the document size.

7. **Disabling line wrap to "speed up scrolling".** It is counterintuitive but `lineBreakMode = .byClipping` (or otherwise turning off wrapping) makes scrolling worse on TextKit 2, not better. Wrapping bounds each fragment's height to a small multiple of the line height, which lets the viewport controller cheaply estimate offscreen space. Turn wrap off and a single 50,000-character paragraph becomes one giant fragment that the controller has to lay out as one unit before it can place anything below it. Keep wrapping enabled on TextKit 2; if horizontal scroll of long lines is a feature, page the content into shorter logical paragraphs at edit time.

8. **Custom `NSTextElement` subclasses other than `NSTextParagraph`.** Triggers runtime assertions. The supported way to get custom rendering is a custom `NSTextLayoutFragment` keyed off `NSTextParagraph`.

9. **Custom `NSTextContentManager` subclass without an `NSTextStorage`.** Crashes during element generation in current SDKs. Subclass `NSTextStorage` and wrap it with `NSTextContentStorage` instead.

10. **Setting rendering effects with `textStorage.addAttribute` instead of `setRenderingAttributes`.** The effect appears, but the modification persists into the document, copy/paste, undo, and serialization. Use rendering attributes for visual-only overlays.

## References

- `txt-textkit1` — the original TextKit stack, for the same problem on `NSLayoutManager`
- `txt-textkit-choice` — picking between TextKit 1 and TextKit 2, including migration risk
- `txt-fallback-triggers` — every API access that flips a TextKit 2 view to TextKit 1
- `txt-viewport-rendering` — viewport behavior, fragment geometry, rendering attributes in depth
- `txt-layout-invalidation` — what invalidates layout and the editing transaction model
- `txt-nstextstorage` — backing-store subclassing and the editing lifecycle
- `references/latest-apis.md` — current TextKit 2 API surface refreshed against Sosumi (signature source of truth)
- [NSTextLayoutManager](https://sosumi.ai/documentation/uikit/nstextlayoutmanager)
- [NSTextContentManager](https://sosumi.ai/documentation/uikit/nstextcontentmanager)
- [NSTextContentStorage](https://sosumi.ai/documentation/uikit/nstextcontentstorage)
- [NSTextLayoutFragment](https://sosumi.ai/documentation/uikit/nstextlayoutfragment)
- [NSTextLineFragment](https://sosumi.ai/documentation/uikit/nstextlinefragment)
- [NSTextViewportLayoutController](https://sosumi.ai/documentation/uikit/nstextviewportlayoutcontroller)
- [NSTextRange](https://sosumi.ai/documentation/uikit/nstextrange)
- [NSTextLocation](https://sosumi.ai/documentation/uikit/nstextlocation)
- [NSTextElement](https://sosumi.ai/documentation/uikit/nstextelement)
- [NSTextParagraph](https://sosumi.ai/documentation/uikit/nstextparagraph)
- [NSTextLayoutManagerDelegate](https://sosumi.ai/documentation/uikit/nstextlayoutmanagerdelegate)
- [NSTextContentStorageDelegate](https://sosumi.ai/documentation/uikit/nstextcontentstoragedelegate)
