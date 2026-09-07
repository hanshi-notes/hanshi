# Rendering Pipeline Notes

Use this sidecar when `txt-viewport-rendering` needs the deeper rendering mechanics instead of only the viewport and geometry overview.

## Font Substitution and fixAttributes

### Font Cascading

When a font lacks a glyph, Core Text walks its cascade list and chooses the first font that can render the character.

Example:

- Times New Roman for Japanese text falls through to a Japanese font such as Hiragino Sans.
- Emoji falls through to Apple Color Emoji.

### fixAttributes(in:)

`NSTextStorage.processEditing()` automatically runs `fixAttributes(in:)`:

```text
processEditing()
    -> willProcessEditing delegate
    -> fixAttributes(in:)
    -> didProcessEditing delegate
```

It repairs font fallback, paragraph-style consistency, and attachment cleanup.

Timing matters:

- `willProcessEditing` is the safe place for font edits that should participate in fallback.
- `didProcessEditing` can bypass fallback repair and leave missing glyphs.

### TextKit 2 Font Fallback

The underlying fallback behavior is still Core Text. For display-only font changes in TextKit 2, modify the paragraph presented by `NSTextContentStorageDelegate` rather than mutating storage just to tint rendering.

```swift
func textContentStorage(_ storage: NSTextContentStorage,
                        textParagraphWith range: NSRange) -> NSTextParagraph? {
    let original = storage.textStorage!.attributedSubstring(from: range)
    let modified = NSMutableAttributedString(attributedString: original)
    return NSTextParagraph(attributedString: modified)
}
```

## Rendering Attributes vs Text Storage Attributes

| Aspect | Text Storage Attributes | Rendering or Temporary Attributes |
|--------|------------------------|-----------------------------------|
| Persist | Yes | No |
| Affect layout | Yes | No |
| Trigger invalidation | Yes | No |
| Use case | Document content | Highlights, search results, spell marks |
| Archive or serialize | Yes | No |
| Undo tracked | Yes | No |

### TextKit 1

```swift
layoutManager.setTemporaryAttributes([.foregroundColor: UIColor.red],
                                     forCharacterRange: range)
layoutManager.addTemporaryAttribute(.backgroundColor, value: UIColor.yellow,
                                    forCharacterRange: range)
layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
```

### TextKit 2

```swift
textLayoutManager.setRenderingAttributes([.foregroundColor: UIColor.red],
                                         forTextRange: textRange)
textLayoutManager.addRenderingAttribute(.backgroundColor, value: UIColor.yellow,
                                        forTextRange: textRange)
textLayoutManager.removeRenderingAttribute(.backgroundColor, forTextRange: textRange)
```

## Custom Rendering Hooks

### TextKit 1

```swift
class SyntaxLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawCustomBackgrounds(forGlyphRange: glyphsToShow, at: origin)
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawOverlays(forGlyphRange: glyphsToShow, at: origin)
    }
}
```

### TextKit 2

```swift
class BubbleFragment: NSTextLayoutFragment {
    override func draw(at renderingOrigin: CGPoint, in ctx: CGContext) {
        ctx.saveGState()
        let bubbleRect = renderingSurfaceBounds.offsetBy(
            dx: renderingOrigin.x, dy: renderingOrigin.y)
        let path = UIBezierPath(roundedRect: bubbleRect, cornerRadius: 12)
        UIColor.systemBlue.setFill()
        path.fill()
        ctx.restoreGState()
        super.draw(at: renderingOrigin, in: ctx)
    }

    override var renderingSurfaceBounds: CGRect {
        return super.renderingSurfaceBounds.insetBy(dx: -12, dy: -6)
    }
}
```

Register custom fragments via the `NSTextLayoutManagerDelegate`.

## Core Text Underneath

Both TextKit generations ultimately render through Core Text:

```text
TextKit 1 or 2
    -> Core Text
        -> CTFramesetter -> CTFrame -> CTLine -> CTRun
            -> Core Graphics
```

- `CTRun` is the atomic rendering unit.
- `CTLine` groups runs into a line.
- `CTFrame` fills a shape with lines.

For glyph-level access that TextKit 2 no longer exposes, drop to Core Text:

```swift
let line = CTLineCreateWithAttributedString(attributedString)
let runs = CTLineGetGlyphRuns(line) as! [CTRun]
for run in runs {
    let glyphCount = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
    CTRunGetGlyphs(run, CFRange(location: 0, length: glyphCount), &glyphs)
}
```

## Emoji Notes

Apple Color Emoji uses bitmap-backed glyph data at multiple resolutions and loads glyph images lazily.

That has two practical consequences:

- The first render of a new emoji can cost slightly more than later renders.
- String metrics differ by counting model.

```swift
"👋🏽".count               // 1
("👋🏽" as NSString).length  // 4
"👋🏽".unicodeScalars.count  // 2
"👋🏽".utf8.count            // 8
```
