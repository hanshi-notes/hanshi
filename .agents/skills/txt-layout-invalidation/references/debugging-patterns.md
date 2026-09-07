# Layout Invalidation Debugging Patterns

Use this sidecar when `txt-layout-invalidation` needs deeper detail on diagnosing stale layout, profiling invalidation cost, or understanding viewport controller behavior beyond the model overview in the main skill.

## Debugging Stale Layout

### Symptom Decision Tree

```
Layout looks wrong after an edit
    │
    ├─ Text content is correct but visually stale
    │   ├─ TextKit 1: Was `edited()` called with correct mask?
    │   │   Check: .editedCharacters for text changes, .editedAttributes for style changes
    │   └─ TextKit 2: Was the edit inside `performEditingTransaction { }`?
    │
    ├─ Attributes applied but not visible
    │   ├─ Using rendering/temporary attributes? → These never invalidate layout
    │   ├─ Applied after `endEditing()` but before display? → Force display
    │   └─ Range correct? → Check String vs NSString counting
    │
    ├─ Layout correct initially but wrong after scroll
    │   ├─ TextKit 1: `allowsNonContiguousLayout` off? → Stale layout reused
    │   └─ TextKit 2: Viewport controller not configured? → Fragments not recycled
    │
    └─ Layout never updates at all
        ├─ NSTextStorage not connected to any layout manager
        ├─ TextKit 2: NSTextContentStorage not observing text storage
        └─ Text view not in a window (no display cycle)
```

### Breakpoints for Invalidation Tracking

Set symbolic breakpoints to observe invalidation flow:

**TextKit 1:**
```
-[NSLayoutManager processEditingForTextStorage:edited:range:changeInLength:invalidatedRange:]
-[NSLayoutManager invalidateGlyphsForCharacterRange:changeInLength:actualCharacterRange:]
-[NSLayoutManager invalidateLayoutForCharacterRange:actualCharacterRange:]
-[NSLayoutManager textStorage:edited:range:changeInLength:invalidatedRange:]
```

**TextKit 2:**
```
-[NSTextLayoutManager invalidateLayoutForRange:]
-[NSTextLayoutManager invalidateRenderingAttributesForTextRange:]
-[NSTextViewportLayoutController layoutViewport]
```

### Verifying Invalidation Happened

```swift
// TextKit 1: Check if layout is valid for a range
let glyphRange = layoutManager.glyphRange(forCharacterRange: targetRange, actualCharacterRange: nil)
// If this triggers layout generation, layout was invalid (check with breakpoint)

// TextKit 2: Check fragment state
textLayoutManager.enumerateTextLayoutFragments(
    from: textRange.location,
    options: [.ensuresLayout]
) { fragment in
    print("Fragment state: \(fragment.state)")
    // .layoutAvailable = valid, anything else = needs layout
    return true
}
```

## Profiling Invalidation Cost

### Instruments Setup

Use the **Text Layout** instrument (available in Instruments under the CoreText category) or fall back to os_signpost.

### os_signpost Pattern

```swift
import os

private let layoutLog = OSLog(subsystem: "com.app.editor", category: "LayoutInvalidation")

// TextKit 1: Subclass NSLayoutManager
class InstrumentedLayoutManager: NSLayoutManager {
    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorage.EditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        let id = OSSignpostID(log: layoutLog)
        os_signpost(.begin, log: layoutLog, name: "processEditing", signpostID: id,
                    "edited: %{public}@, invalidated: %{public}@",
                    NSStringFromRange(newCharRange),
                    NSStringFromRange(invalidatedCharRange))
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
        os_signpost(.end, log: layoutLog, name: "processEditing", signpostID: id)
    }

    override func ensureLayout(for container: NSTextContainer) {
        let id = OSSignpostID(log: layoutLog)
        os_signpost(.begin, log: layoutLog, name: "ensureLayout", signpostID: id)
        super.ensureLayout(for: container)
        os_signpost(.end, log: layoutLog, name: "ensureLayout", signpostID: id)
    }
}
```

### What to Measure

| Metric | Where to Look | Red Flag |
|--------|--------------|----------|
| processEditing duration | Signpost per keystroke | > 8ms (drops below 120fps) |
| ensureLayout calls | Count per edit | > 1 per edit = redundant invalidation |
| invalidatedRange size | Signpost metadata | Full document range on single char edit |
| Viewport layout duration | TextKit 2 layoutViewport signpost | > 16ms per scroll frame |

## Viewport Controller Deep Patterns

### Understanding the Layout Cycle

The viewport layout controller runs a three-phase cycle:

```
scrollViewDidScroll / layoutViewport()
    │
    ├── 1. willLayout
    │   Delegate: textViewportLayoutControllerWillLayout(_:)
    │   Purpose: Prepare rendering surfaces, clear stale views
    │
    ├── 2. configureRenderingSurface (called per visible fragment)
    │   Delegate: configureRenderingSurfaceFor textLayoutFragment:
    │   Purpose: Position and populate each fragment's view or layer
    │
    └── 3. didLayout
        Delegate: textViewportLayoutControllerDidLayout(_:)
        Purpose: Update content size, adjust scroll indicators
```

### Fragment Recycling

The viewport controller does NOT recycle fragments automatically. When a fragment scrolls out of the viewport, its rendering surface becomes orphaned. The delegate is responsible for cleanup:

```swift
func textViewportLayoutControllerWillLayout(
    _ controller: NSTextViewportLayoutController
) {
    // Remove fragment views that are no longer visible
    for view in fragmentViews where !isInViewport(view) {
        view.removeFromSuperview()
        fragmentViews.remove(view)
    }
}

func textViewportLayoutController(
    _ controller: NSTextViewportLayoutController,
    configureRenderingSurfaceFor fragment: NSTextLayoutFragment
) {
    let view = fragmentView(for: fragment)  // Reuse or create
    view.frame = fragment.layoutFragmentFrame
    contentView.addSubview(view)
    fragmentViews.insert(view)
}
```

### Controlling the Viewport Range

The viewport controller determines what is "visible" by querying the text view's visible rect plus an overdraw region. You cannot set the overdraw directly, but you can influence it:

```swift
// Force a specific range to be laid out (use sparingly)
textLayoutManager.ensureLayout(for: targetRange)

// Trigger a re-layout of the current viewport
textLayoutManager.textViewportLayoutController.layoutViewport()
```

### Scroll Performance Checklist

1. **Never call `ensureLayout` for the full document range.** This defeats the viewport optimization entirely.
2. **Keep `configureRenderingSurfaceFor` fast.** This runs per visible fragment per layout pass. No network calls, no heavy computation.
3. **Clean up in `willLayout`.** Fragment views from previous layout passes must be removed or recycled.
4. **Avoid triggering layout inside layout.** Modifying text storage or invalidating layout from within a viewport layout delegate callback causes reentrancy.
5. **Use rendering attributes for visual overlays.** They do not trigger layout invalidation. Storage attribute changes do.

## Common Bugs By Symptom

### "Text flickers after every keystroke"

**Cause:** Redundant invalidation. A delegate or observer is modifying attributes in response to the same edit that already invalidated layout, causing a second layout pass.

**Fix:** Check `didProcessEditing` and any notification observers. Make sure they are not re-applying attributes that `processEditing` already handled.

### "Scroll position jumps after an edit above the viewport"

**Cause:** TextKit 1 without `allowsNonContiguousLayout`. Editing above the viewport recalculates all layout from the top, shifting everything.

**Fix:** Enable `allowsNonContiguousLayout = true` on the layout manager.

### "Syntax highlighting disappears during fast scrolling"

**Cause:** TextKit 2 viewport controller is recycling fragments faster than highlighting can be applied. The highlight runs asynchronously but the fragment is gone before results arrive.

**Fix:** Apply highlights via rendering attributes (which survive fragment recycling) rather than text storage attributes. Or use the `NSTextContentStorageDelegate.textParagraphWith` delegate to bake highlights into the paragraph before layout.

### "Content size is wrong after programmatic edit"

**Cause:** Content size calculation happens before layout is finalized. The edit triggers `processEditing`, but `usedRect` or content size is read before the layout pass runs.

**Fix:** For TextKit 1, call `ensureLayout(forCharacterRange:)` for the affected range before reading `usedRect`. For TextKit 2, wait until `didLayout` to read content dimensions.
