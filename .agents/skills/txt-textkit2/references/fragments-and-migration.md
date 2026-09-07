# TextKit 2 Fragments, Ranges, and Migration

Use this sidecar when the main `txt-textkit2` skill needs deeper detail on fragment internals, viewport controller hooks, object-based ranges, or TextKit 1 migration mapping.

## NSTextLayoutFragment

Immutable layout information for one or more text elements.

### Key Properties

```swift
var layoutFragmentFrame: CGRect { get }       // Position in container
var renderingSurfaceBounds: CGRect { get }     // Drawing area (may exceed frame)
var textLineFragments: [NSTextLineFragment] { get }
var textElement: NSTextElement? { get }
var rangeInElement: NSTextRange { get }
var state: State { get }  // .none, .estimatedUsageBounds, .calculatedUsageBounds, .layoutAvailable
```

### Custom Drawing

```swift
class BubbleLayoutFragment: NSTextLayoutFragment {
    override func draw(at renderingOrigin: CGPoint, in ctx: CGContext) {
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        let bubbleRect = renderingSurfaceBounds.offsetBy(dx: renderingOrigin.x, dy: renderingOrigin.y)
        let path = UIBezierPath(roundedRect: bubbleRect, cornerRadius: 12)
        path.fill()
        super.draw(at: renderingOrigin, in: ctx)
    }

    override var renderingSurfaceBounds: CGRect {
        return super.renderingSurfaceBounds.insetBy(dx: -8, dy: -4)
    }
}
```

## NSTextLineFragment

Measurement info for a single line within a layout fragment.

```swift
let line: NSTextLineFragment
line.attributedString
line.characterRange
line.typographicBounds
line.glyphOrigin
```

Important: `characterRange` is relative to the line fragment's attributed string, not the document. Convert via the parent layout fragment's element range.

## NSTextViewportLayoutController

Manages viewport-based layout. Only lays out visible text plus overscroll region.

### Delegate Callbacks

```swift
func textViewportLayoutControllerWillLayout(_ controller: NSTextViewportLayoutController)

func textViewportLayoutController(_ controller: NSTextViewportLayoutController,
    configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment)

func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController)
```

### Triggering Viewport Layout

```swift
textLayoutManager.textViewportLayoutController.layoutViewport()
```

### Viewport Range

```swift
let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange
// nil if no viewport is configured
```

## Object-Based Ranges

### NSTextLocation

```swift
protocol NSTextLocation: NSObjectProtocol {
    func compare(_ location: NSTextLocation) -> ComparisonResult
}
```

### NSTextRange

```swift
let range = NSTextRange(location: startLocation, end: endLocation)
range.location
range.endLocation
range.isEmpty
```

### NSRange Conversion

```swift
if let textRange = textContentStorage.textRange(for: nsRange) { ... }

let start = textContentStorage.offset(from: textContentStorage.documentRange.location,
                                       to: textRange.location)
let end = textContentStorage.offset(from: textContentStorage.documentRange.location,
                                     to: textRange.endLocation)
let nsRange = NSRange(location: start, length: end - start)
```

## TextKit 1 to 2 Migration

### API Mapping

| TextKit 1 | TextKit 2 |
|-----------|-----------|
| `NSLayoutManager` | `NSTextLayoutManager` |
| `NSTextStorage` (direct use) | `NSTextContentStorage` wrapping `NSTextStorage` |
| `NSRange` | `NSTextRange` / `NSTextLocation` |
| Glyph APIs | Removed. Use element and fragment APIs |
| `temporaryAttribute` | `renderingAttributes` |
| `ensureLayout(for:)` | `enumerateTextLayoutFragments(options: .ensuresLayout)` |
| `lineFragmentRect(forGlyphAt:)` | `textLayoutFragment.textLineFragments[n].typographicBounds` |
| `boundingRect(forGlyphRange:)` | Enumerate fragments, union frames |
| `characterIndex(for:in:)` | `textLayoutManager.location(interactingAt:inContainerAt:)` |
| `allowsNonContiguousLayout` | Always non-contiguous |
| `drawGlyphs(forGlyphRange:)` | `NSTextLayoutFragment.draw(at:in:)` |

### Heuristic

TextKit 1 APIs use integer offsets like `NSRange` and `Int`. TextKit 2 APIs use `NSTextLocation` objects.

### No Direct Equivalent

- Glyph inspection such as `glyph(at:)` or direct `CGGlyph` access.
- Glyph property mutation hooks.
- `shouldGenerateGlyphs` delegate customization.

For those cases, drop to Core Text or stay on TextKit 1 when glyph-level control is a hard requirement.

## Quick Reference

| Task | TextKit 2 API |
|------|---------------|
| Wrap edits | `textContentManager.performEditingTransaction { ... }` |
| Enumerate elements | `textContentManager.enumerateTextElements(from:options:using:)` |
| Get layout fragments | `textLayoutManager.enumerateTextLayoutFragments(from:options:using:)` |
| Overlay styling | `textLayoutManager.setRenderingAttributes(_:forTextRange:)` |
| Invalidate layout | `textLayoutManager.invalidateLayout(for:)` |
| Trigger viewport relayout | `textViewportLayoutController.layoutViewport()` |
| Hit test | `textLayoutManager.location(interactingAt:inContainerAt:)` |
| Custom drawing | Subclass `NSTextLayoutFragment`, override `draw(at:in:)` |
| Filter elements | `NSTextContentManagerDelegate.shouldEnumerate` |
| Custom paragraphs | `NSTextContentStorageDelegate.textParagraphWith` |
| NSRange <-> NSTextRange | `textContentStorage.textRange(for:)` / manual offset calculation |
