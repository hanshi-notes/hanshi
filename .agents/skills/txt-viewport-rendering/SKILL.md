---
name: txt-viewport-rendering
description: Configure TextKit 2 viewport-driven layout, NSTextLayoutFragment / NSTextLineFragment geometry, and rendering attributes vs storage attributes. Covers NSTextViewportLayoutController callbacks, layoutFragmentFrame vs renderingSurfaceBounds, line-fragment local coordinates, the extra trailing line fragment, exclusion paths that split a visual line, lineFragmentPadding vs container insets, font substitution via fixAttributes, and visible/overscroll/estimated regions. Use when working with custom layout fragments, debugging clipped diacritics or descenders, computing document coordinates from a line fragment, integrating with a custom scroll view, or when scroll-bar behavior under estimated heights is the visible problem. Do NOT use for symptom-driven debugging (txt-textkit-debug), the invalidation model (txt-layout-invalidation), or the TextKit 2 API surface in general (txt-textkit2).
license: MIT
---

# Viewport, fragments, and rendering

Authored against iOS 26.x / Swift 6.x / Xcode 26.x.

This skill covers how TextKit 2 actually renders text: the viewport-driven layout pass, the geometry of layout fragments and line fragments, and the rendering-attribute overlay system. The patterns here are a model — before applying them to a specific symptom (text clipped at descenders, scroll bar jiggling, custom drawing disappearing), open the actual fragment subclass or container code and confirm the geometry matches what's described. Before quoting any signature here, fetch the relevant page from Sosumi (`sosumi.ai/documentation/uikit/<class>`); the viewport controller and fragment APIs have grown each release.

## Contents

- [The viewport model](#the-viewport-model)
- [NSTextViewportLayoutController callbacks](#nstextviewportlayoutcontroller-callbacks)
- [Estimated heights and scroll-bar behavior](#estimated-heights-and-scroll-bar-behavior)
- [Layout fragments and line fragments](#layout-fragments-and-line-fragments)
- [Line fragment coordinates](#line-fragment-coordinates)
- [Extra trailing line fragment](#extra-trailing-line-fragment)
- [Exclusion paths and split lines](#exclusion-paths-and-split-lines)
- [Line-fragment padding vs container insets](#line-fragment-padding-vs-container-insets)
- [Rendering attributes](#rendering-attributes)
- [Font substitution and fixAttributes](#font-substitution-and-fixattributes)
- [Comparison: TextKit 1 contiguous vs non-contiguous](#comparison-textkit-1-contiguous-vs-non-contiguous)
- [Common Mistakes](#common-mistakes)
- [References](#references)

## The viewport model

TextKit 2 lays out only what's near the viewport. The document is divided into three regions:

- **Estimated layout (off-screen).** Geometry is approximate. Heights are estimated from the content; positions shift as more fragments lay out.
- **Overscroll buffer.** Computed and ready for scroll, but not visible. Usually one screen-worth in each direction.
- **Viewport (visible).** Fully laid out; rendered.

Scrolling moves fragments between regions. Layout cost is O(viewport), not O(document) — that's the central performance promise of TextKit 2.

`NSTextViewportLayoutController` orchestrates the pass:

1. Determines the visible range from the scroll view.
2. Calls the delegate's `willLayout`.
3. Lays out fragments in the visible range.
4. Calls `configureRenderingSurfaceFor:` once per visible fragment.
5. Calls `didLayout`.
6. Updates `usageBoundsForTextContainer`.

A scroll, a text edit, a container resize, or a manual `layoutViewport()` call kicks the cycle.

## NSTextViewportLayoutController callbacks

```swift
// Before layout begins — remove old fragment views from the rendering surface
func textViewportLayoutControllerWillLayout(
    _ controller: NSTextViewportLayoutController
) {
    fragmentContainer.subviews.forEach { $0.removeFromSuperview() }
}

// For each visible layout fragment — position views/layers
func textViewportLayoutController(
    _ controller: NSTextViewportLayoutController,
    configureRenderingSurfaceFor fragment: NSTextLayoutFragment
) {
    let frame = fragment.layoutFragmentFrame
    let view = makeFragmentView(for: fragment)
    view.frame = frame
    fragmentContainer.addSubview(view)
}

// After layout completes — update content size for the scroll view
func textViewportLayoutControllerDidLayout(
    _ controller: NSTextViewportLayoutController
) {
    let height = textLayoutManager.usageBoundsForTextContainer.height
    scrollView.contentSize = CGSize(width: bounds.width, height: height)
}
```

The `configureRenderingSurface` callback fires once per visible fragment, every layout pass. It's the right place to position views or layers, but a wrong place to allocate them — fragment objects are stable across passes, so cache views by fragment identity.

## Estimated heights and scroll-bar behavior

`usageBoundsForTextContainer.height` is an estimate. It changes during scroll as fragments lay out and the estimate refines. This produces three user-visible artifacts:

- **Scroll-bar jiggle.** The knob's size and position shift as the estimate updates.
- **"Stops mid-scroll as if at document end".** The scroll bar is drawn against the current estimated content size; if scrolling reveals more layout than was estimated, the scroll bar appears to bottom out before it should. Catches up as the estimate refines.
- **Inaccurate jump-to-position.** Fragment positions for off-screen content are approximate. `scrollRangeToVisible` for a far-off range arrives near-but-not-at the target until the surrounding content lays out.

Apple's TextEdit shows all three on long documents. Code that needs exact metrics (line count, exact total height, jump-accurate navigation) either has to force layout for the relevant range first or live with TextKit 1.

## Layout fragments and line fragments

Roughly: one `NSTextLayoutFragment` per paragraph, containing one or more `NSTextLineFragment` for each visual line that paragraph wraps into.

```swift
let fragment: NSTextLayoutFragment
fragment.layoutFragmentFrame      // rect in document coordinates
fragment.renderingSurfaceBounds   // drawing extent — may exceed layout frame
fragment.textLineFragments        // [NSTextLineFragment]
fragment.rangeInElement           // NSTextRange for the fragment
fragment.draw(at: origin, in: cgContext)
```

`renderingSurfaceBounds` exists because drawing can extend past the layout frame: diacritics on top of the first line, descenders below the last line, custom backgrounds, glow effects. Custom `NSTextLayoutFragment` subclasses that draw outside the default frame must override `renderingSurfaceBounds` to expand the dirty rect, or the rendering is clipped at the frame edge.

```swift
class BubbleLayoutFragment: NSTextLayoutFragment {
    override var renderingSurfaceBounds: CGRect {
        layoutFragmentFrame.insetBy(dx: -8, dy: -8)
    }
    override func draw(at origin: CGPoint, in context: CGContext) {
        // draw bubble background
        super.draw(at: origin, in: context)
    }
}
```

## Line fragment coordinates

```swift
let line: NSTextLineFragment
line.typographicBounds    // rect — local to the parent layout fragment
line.glyphOrigin          // point — where glyph drawing starts within the line
line.characterRange       // range — local to line.attributedString, not the document
line.attributedString     // a copy, not the original document substring
```

`characterRange` is the most common bug source. It is local to the line's own attributed string, not document-relative. Code that uses it as a document range will hit the wrong characters as soon as the line isn't at document offset zero.

To convert a point inside a line fragment to document coordinates:

```swift
let docPoint = CGPoint(
    x: layoutFragment.layoutFragmentFrame.origin.x
       + lineFragment.typographicBounds.origin.x
       + localPoint.x,
    y: layoutFragment.layoutFragmentFrame.origin.y
       + lineFragment.typographicBounds.origin.y
       + localPoint.y
)
```

Three coordinate spaces nest: document, layout fragment frame, line fragment typographic bounds. The glyph origin is inside the line.

## Extra trailing line fragment

When text ends with `\n` (or the document is empty), an extra empty line fragment exists for cursor placement at the trailing position.

- TextKit 1: `extraLineFragmentRect`, `extraLineFragmentUsedRect` on `NSLayoutManager`.
- TextKit 2: requires the `.ensuresExtraLineFragment` option in `enumerateTextLayoutFragments`. Known bug FB15131180 makes the frame incorrect in some configurations.

If a custom editor is missing its trailing-empty cursor position, the fix is usually to add `.ensuresExtraLineFragment` to the enumeration that builds the cursor rectangle.

## Exclusion paths and split lines

When `NSTextContainer.exclusionPaths` is non-empty, a single visual line that crosses an exclusion path splits into multiple line fragments — one for the segment before the exclusion, one for the segment after.

The container's `lineFragmentRect(forProposedRect:at:writingDirection:remainingRect:)` returns:

1. The largest available rectangle not intersecting the exclusion paths.
2. A *remainder* rectangle for content on the other side of the exclusion.

Most code never calls this directly — the layout system uses it internally. But when wrap-around-image rendering is broken, the question is usually whether the exclusion path is in the right coordinate space and whether the line fragments produced by the system make sense.

## Line-fragment padding vs container insets

```swift
textContainer.lineFragmentPadding = 5    // default 5 points
textView.textContainerInset = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
```

These are different things and frequently confused:

- `lineFragmentPadding` insets text within each line fragment by the same amount on each end. Purely visual — the fragment rect itself is unchanged. Default 5 points.
- `textContainerInset` is the document-level margin around the entire text. Use this for visual padding around the text view's content.

Neither is paragraph indentation — that's `NSParagraphStyle.headIndent` / `firstLineHeadIndent`.

A common wrong fix: setting `lineFragmentPadding = 16` to add document margins. The padding is per-line, not document-level, and 16-point padding produces visibly inset wrap inside the fragment that isn't what was wanted.

## Rendering attributes

Visual styling overlay that does not modify storage and does not invalidate layout. Replaces TextKit 1's temporary attributes.

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
```

Rendering attributes attach to the layout manager, not to character ranges in storage. Code that uses `textStorage.addAttribute` for what should be a rendering-only effect (find highlight, transient selection color) modifies the document and ends up in copy/paste, undo, and serialization — the rendering attribute is what was wanted.

Known bug FB9692714: certain rendering-attribute combinations have drawing artifacts. The workaround is a custom `NSTextLayoutFragment` subclass that draws the effect itself. This is one of the standing reasons to use TextKit 1 + temporary attributes for production syntax highlighting.

## Font substitution and fixAttributes

Font substitution happens during the editing lifecycle, in `fixAttributes`, before `didProcessEditing` runs. Characters with no glyph in the requested font are reassigned to a fallback font during the fix pass.

If a delegate sets a font in `didProcessEditing`, that change runs *after* `fixAttributes` and bypasses substitution. Characters that don't exist in the new font will not render — they'll show as `.notdef` boxes with no warning.

```swift
// WRONG — bypasses fixAttributes; missing glyphs show as boxes
func textStorage(_ ts: NSTextStorage,
                 didProcessEditing: NSTextStorage.EditActions,
                 range: NSRange, changeInLength: Int) {
    ts.addAttribute(.font, value: customFont, range: range)
}

// CORRECT — set fonts in willProcessEditing; fixAttributes runs after
func textStorage(_ ts: NSTextStorage,
                 willProcessEditing: NSTextStorage.EditActions,
                 range: NSRange, changeInLength: Int) {
    ts.addAttribute(.font, value: customFont, range: range)
}
```

The same applies on TextKit 2 — the storage layer hasn't changed.

## Comparison: TextKit 1 contiguous vs non-contiguous

For context when porting code, TextKit 1's options:

- **Contiguous (default on NSTextView).** Lays out all text from the beginning to the display point. Scrolling to mid-document forces layout of everything before it. O(document) for first display. Exact total height guaranteed.
- **Non-contiguous (`allowsNonContiguousLayout = true`).** Skips ranges that aren't visible. UITextView enables this by default. Less reliable than TextKit 2's viewport — `boundingRect` and `lineFragmentRect` can return slightly wrong coordinates for ranges in the multi-thousand-character region until those ranges are forced to lay out.

`UITextView.isScrollEnabled = false` disables the scroll path entirely. The view expands to its full content size, which neutralizes TextKit 2's viewport optimization — all content gets laid out for Auto Layout intrinsic size. `scrollRangeToVisible` does not work in this configuration.

## Common Mistakes

1. **Treating `NSTextLineFragment.characterRange` as document-relative.** It is local to the line's attributed string. Convert through the parent layout fragment's range before using it for selection, hit-testing, or attribute lookup.

2. **Custom layout fragment that draws outside `layoutFragmentFrame` without overriding `renderingSurfaceBounds`.** Drawing is clipped at the layout frame edge. Diacritics, large descenders, and custom shadows disappear.

3. **Reading `usageBoundsForTextContainer.height` as exact total height while scrolling.** It's an estimate that refines. Scroll-bar metrics tied directly to this value will jiggle. If exact metrics matter, force layout for the document range or move to TextKit 1.

4. **Setting fonts in `didProcessEditing`.** Bypasses `fixAttributes` font substitution. Characters with missing glyphs render as `.notdef` boxes. Move font changes to `willProcessEditing`, or supply explicit fallback fonts in the attribute.

5. **Using `lineFragmentPadding` for document margins.** Padding is per-line and small (5pt default). Document margins go on `textContainerInset` of the text view; paragraph indentation goes on `NSParagraphStyle`.

6. **Allocating fragment views inside `configureRenderingSurfaceFor`.** Cache views by fragment identity and reuse. The callback fires every layout pass.

7. **Setting transient visual effects (find highlight, selection color) via `textStorage.addAttribute`.** The change persists into the document, copy/paste, and undo. Use rendering attributes (`setRenderingAttributes`) instead.

8. **Forgetting `.ensuresExtraLineFragment`.** A custom editor that misses the cursor position after a trailing newline usually isn't requesting the extra trailing line fragment in its enumeration.

## References

- `txt-textkit2` — TextKit 2 API reference covering content manager, layout manager, and the editing transaction
- `txt-layout-invalidation` — what triggers re-layout vs visual-only refresh
- `txt-textkit-debug` — symptom-driven debugging for clipped text, scroll-bar bugs, and missing fragments
- `txt-fallback-triggers` — when viewport behavior is missing because the view fell back to TextKit 1
- `txt-attachments` — how inline views and attachments interact with fragment geometry
- `txt-exclusion-paths` — multi-region containers and exclusion-path layout
- [NSTextViewportLayoutController](https://sosumi.ai/documentation/uikit/nstextviewportlayoutcontroller)
- [NSTextLayoutFragment](https://sosumi.ai/documentation/uikit/nstextlayoutfragment)
- [NSTextLineFragment](https://sosumi.ai/documentation/uikit/nstextlinefragment)
- [NSTextLayoutManager](https://sosumi.ai/documentation/uikit/nstextlayoutmanager)
- [NSTextContainer](https://sosumi.ai/documentation/uikit/nstextcontainer)
