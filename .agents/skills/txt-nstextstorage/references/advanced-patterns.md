# Text Storage Advanced Patterns

Use this sidecar when `txt-nstextstorage` needs deeper detail on custom backing stores, thread-safe access, performance measurement, or TextKit 2 content manager subclassing beyond the basics in the main skill.

## Custom Backing Stores

### When to Subclass NSTextStorage

The default NSTextStorage uses a single NSMutableAttributedString internally. This works for documents up to tens of thousands of characters. Beyond that, or when your editing model does not map to a flat attributed string, subclass NSTextStorage with a different backing store.

Common alternatives:

| Backing Store | Good For | Trade-off |
|---------------|----------|-----------|
| Gap buffer | General editing with cursor locality | Simple but O(n) for random inserts |
| Piece table | Undo-friendly editing, large files | Fast insert/delete, slower attribute queries |
| Rope | Very large documents, concurrent access | Complex implementation, excellent asymptotic performance |
| CRDT | Collaborative real-time editing | Highest complexity, built for multi-user |

### Piece Table Example

A piece table stores the original text plus an append-only buffer of additions. Edits create descriptors pointing into either buffer.

```swift
class PieceTableStorage: NSTextStorage {
    private struct Piece {
        enum Source { case original, additions }
        var source: Source
        var start: Int
        var length: Int
        var attributes: [NSAttributedString.Key: Any]
    }

    private var originalBuffer: String
    private var additionsBuffer: String = ""
    private var pieces: [Piece] = []
    private var cachedString: String?

    init(original: String) {
        self.originalBuffer = original
        self.pieces = [Piece(source: .original, start: 0,
                             length: original.count, attributes: [:])]
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var string: String {
        if let cached = cachedString { return cached }
        let result = pieces.map { piece -> String in
            let buffer = piece.source == .original ? originalBuffer : additionsBuffer
            let start = buffer.index(buffer.startIndex, offsetBy: piece.start)
            let end = buffer.index(start, offsetBy: piece.length)
            return String(buffer[start..<end])
        }.joined()
        cachedString = result
        return result
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        let addStart = additionsBuffer.count
        additionsBuffer.append(str)
        // Split piece at range boundaries, replace middle with new piece
        // (piece splitting logic omitted for brevity)
        cachedString = nil
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    // attributes(at:effectiveRange:) and setAttributes must also be implemented
}
```

The key contract: `string` must always reflect current content, and mutation methods must call `edited()` with the correct mask and delta.

### Invalidating Cached State

Any caching layer (like `cachedString` above) must be invalidated before `edited()` is called. The `edited()` call triggers `processEditing()`, which reads from `string`. If the cache is stale at that point, layout managers receive wrong data.

```swift
// ✅ CORRECT order
cachedString = nil          // 1. Invalidate cache
edited(.editedCharacters, range: range, changeInLength: delta)  // 2. Notify

// ❌ WRONG order
edited(.editedCharacters, range: range, changeInLength: delta)  // 1. Notify (reads stale cache)
cachedString = nil          // 2. Too late
```

## Thread Safety

### The Rule

NSTextStorage is not thread-safe. All reads and writes must happen on the same thread — typically main. This includes:

- `string` property access
- `attributes(at:effectiveRange:)`
- `replaceCharacters(in:with:)`
- `setAttributes(_:range:)`
- Any method that triggers `processEditing()`

### Background Processing Pattern

When you need to do expensive work (syntax parsing, spell checking) off the main thread, copy the data out, process it, then apply results back on main.

```swift
// Copy text content to background
let snapshot = textStorage.string
let snapshotLength = textStorage.length

DispatchQueue.global(qos: .userInitiated).async {
    let highlights = parseSyntax(snapshot)

    DispatchQueue.main.async {
        // Guard: text may have changed while we were parsing
        guard textStorage.length == snapshotLength else { return }

        textStorage.beginEditing()
        for highlight in highlights {
            textStorage.addAttribute(.foregroundColor,
                                     value: highlight.color,
                                     range: highlight.range)
        }
        textStorage.endEditing()
    }
}
```

The length guard is minimal. For production editors, use a version counter or generation token:

```swift
class VersionedTextStorage: NSTextStorage {
    private(set) var version: UInt64 = 0

    override func processEditing() {
        version &+= 1
        super.processEditing()
    }
}
```

Then check `version` before applying background results.

### Actor-Based Pattern (Swift Concurrency)

```swift
@MainActor
final class EditorController {
    let textView: UITextView

    func rehighlight() {
        let snapshot = textView.textStorage.string
        let version = (textView.textStorage as? VersionedTextStorage)?.version

        Task.detached {
            let highlights = await parseSyntax(snapshot)
            await MainActor.run {
                guard (self.textView.textStorage as? VersionedTextStorage)?.version == version else {
                    return  // Text changed, discard stale results
                }
                self.applyHighlights(highlights)
            }
        }
    }
}
```

## NSTextContentManager Subclassing (TextKit 2)

### When Direct Subclassing Makes Sense

Subclass `NSTextContentManager` directly (bypassing `NSTextContentStorage`) when your document model is NOT an attributed string:

- **Database-backed documents** — each paragraph is a database row
- **AST-backed editors** — the syntax tree is the source of truth
- **Collaborative CRDTs** — the CRDT data structure drives content

### Required Overrides

```swift
class ASTContentManager: NSTextContentManager {
    var syntaxTree: SyntaxTree

    // The full document range
    override var documentRange: NSTextRange {
        NSTextRange(location: startLocation, end: endLocation)
    }

    // Enumerate elements in order (or reverse)
    override func enumerateTextElements(
        from textLocation: NSTextLocation?,
        options: EnumerationOptions = [],
        using block: (NSTextElement) -> Bool
    ) {
        let nodes = options.contains(.reverse)
            ? syntaxTree.nodesReversed(from: textLocation)
            : syntaxTree.nodes(from: textLocation)

        for node in nodes {
            let paragraph = NSTextParagraph(attributedString: node.attributedContent)
            paragraph.textContentManager = self
            if !block(paragraph) { break }
        }
    }

    // Apply edits from the layout system
    override func replaceContents(
        in range: NSTextRange,
        with textElements: [NSTextElement]?
    ) {
        syntaxTree.replace(range: range, with: textElements)
    }

    // Location arithmetic
    override func location(_ location: NSTextLocation, offsetBy offset: Int) -> NSTextLocation? {
        syntaxTree.location(location, offsetBy: offset)
    }

    override func offset(from: NSTextLocation, to: NSTextLocation) -> Int {
        syntaxTree.offset(from: from, to: to)
    }
}
```

### Notifying Layout of Changes

When you mutate the backing model outside the normal editing flow, tell the content manager:

```swift
contentManager.performEditingTransaction {
    // Mutate your model
    syntaxTree.insert(node, at: position)
}
// Layout manager now knows to regenerate affected fragments
```

### Edge Cases and Gotchas

These are the non-obvious behaviors that break custom content managers in production.

#### 1. Nil Location in enumerateTextElements

When `textLocation` is nil, the layout system is asking you to start from the very beginning (forward) or very end (reverse) of the document. You must handle this — returning early or crashing on nil is a silent layout failure.

```swift
override func enumerateTextElements(
    from textLocation: NSTextLocation?,
    options: EnumerationOptions = [],
    using block: (NSTextElement) -> Bool
) -> NSTextLocation? {
    let reverse = options.contains(.reverse)
    let startLoc = textLocation as? DatabaseLocation

    // If nil, start from document boundary
    let rows: [Row]
    if let startLoc {
        rows = reverse ? database.rowsBefore(startLoc) : database.rowsAfter(startLoc)
    } else {
        rows = reverse ? database.allRowsReversed() : database.allRows()
    }
    // ...
}
```

#### 2. Return Value of enumerateTextElements

The method returns `NSTextLocation?` — the location where enumeration stopped. The layout system uses this for pagination and viewport management. Return the end location of the last element you vended, or nil if you reached the document boundary. Getting this wrong causes the viewport controller to stop laying out content prematurely.

```swift
var lastEndLocation: NSTextLocation? = nil
for row in rows {
    let paragraph = makeElement(from: row)
    lastEndLocation = paragraph.elementRange?.endLocation
    if !block(paragraph) { break }
}
return lastEndLocation
```

#### 3. Empty Document Must Return a Valid Range

`documentRange` is called constantly. An empty document must still return a valid `NSTextRange` — a zero-length range at a sentinel location. Returning nil or crashing will take down the layout system.

```swift
override var documentRange: NSTextRange {
    guard let first = database.firstRow else {
        let sentinel = DatabaseLocation(rowID: 0, offset: 0)
        return NSTextRange(location: sentinel)  // zero-length range
    }
    // ...
}
```

#### 4. Paragraph Terminators Are Required

Every `NSTextParagraph` must include a paragraph separator (`\n`) at the end of its attributed string. Without it:
- Adjacent paragraphs merge visually into one line
- The layout manager's line break logic produces wrong geometry
- Selection across paragraph boundaries fails

```swift
// ✅ Correct
let text = row.text + "\n"
let paragraph = NSTextParagraph(attributedString: NSAttributedString(string: text))

// ❌ Wrong — missing terminator
let paragraph = NSTextParagraph(attributedString: NSAttributedString(string: row.text))
```

Exception: the very last paragraph in the document does not strictly need a trailing newline, but including one is safer and avoids special-casing.

#### 5. Consistency Contract Between Methods

`documentRange`, `enumerateTextElements`, `location(_:offsetBy:)`, and `offset(from:to:)` must all agree about the document's content. If they are inconsistent, the layout system breaks silently — symptoms include:
- Cursor cannot be placed at certain positions
- Selection jumps or skips paragraphs
- Hit testing returns wrong locations
- Text disappears or duplicates

The most common cause of inconsistency: your database changes between calls (e.g., a background sync fires mid-layout). Use `performEditingTransaction` to bracket mutations so the layout system sees a consistent snapshot.

#### 6. Location Arithmetic Crossing Row Boundaries

`location(_:offsetBy:)` must handle offsets that cross row boundaries. If you only handle offsets within a single row, cursor movement across paragraph breaks will fail.

```swift
override func location(
    _ location: NSTextLocation,
    offsetBy offset: Int
) -> NSTextLocation? {
    guard let loc = location as? DatabaseLocation else { return nil }
    var remaining = offset
    var currentRow = loc.rowID
    var currentOffset = loc.offset

    if remaining > 0 {
        // Walk forward across rows
        while remaining > 0 {
            let rowLength = database.rowLength(currentRow) + 1  // +1 for \n
            let spaceInRow = rowLength - currentOffset
            if remaining < spaceInRow {
                return DatabaseLocation(rowID: currentRow, offset: currentOffset + remaining)
            }
            remaining -= spaceInRow
            guard let nextRow = database.nextRow(after: currentRow) else {
                return nil  // Past end of document
            }
            currentRow = nextRow
            currentOffset = 0
        }
    }
    // Handle negative offsets similarly (walk backward)
    return DatabaseLocation(rowID: currentRow, offset: currentOffset)
}
```

#### 7. hasEditingTransaction and Reentrancy

Check `hasEditingTransaction` to avoid nesting transactions. Nested `performEditingTransaction` calls do not crash, but the inner transaction's completion does not trigger a separate layout pass — only the outermost transaction's completion does. If you rely on layout being updated between nested transactions, your assumptions will be wrong.

```swift
func applyChange(_ change: Change) {
    if hasEditingTransaction {
        // Already inside a transaction — just mutate the model
        database.apply(change)
    } else {
        performEditingTransaction {
            database.apply(change)
        }
    }
}
```

#### 8. Thread Safety Is Your Responsibility

Unlike `NSTextContentStorage` (which inherits NSTextStorage's main-thread requirement implicitly), a custom `NSTextContentManager` subclass has no built-in thread safety. All of these must happen on the main thread:
- `documentRange` reads
- `enumerateTextElements` calls
- `performEditingTransaction` calls
- Any mutation that changes what enumeration or documentRange would return

If your database can be written from a background queue (sync, import), either serialize mutations through the main thread or use a snapshot isolation pattern where enumeration reads from an immutable snapshot while writes prepare the next version.

#### 9. Testing a Custom Content Manager

Unit test by creating an instance, attaching an `NSTextLayoutManager`, and verifying enumeration and location arithmetic without needing a text view.

```swift
func testEnumerationReturnsAllRows() {
    let db = MockDatabase(rows: ["Hello", "World", "Test"])
    let cm = DatabaseContentManager(database: db)
    let lm = NSTextLayoutManager()
    cm.addTextLayoutManager(lm)

    var paragraphs: [String] = []
    cm.enumerateTextElements(from: nil, options: []) { element in
        if let p = element as? NSTextParagraph {
            paragraphs.append(p.attributedString.string)
        }
        return true
    }
    XCTAssertEqual(paragraphs, ["Hello\n", "World\n", "Test\n"])
}

func testOffsetCrossesRowBoundary() {
    let db = MockDatabase(rows: ["AB", "CD"])  // "AB\nCD\n"
    let cm = DatabaseContentManager(database: db)
    let start = DatabaseLocation(rowID: 0, offset: 1)  // 'B'
    let result = cm.location(start, offsetBy: 3)        // should land at 'D'
    let expected = DatabaseLocation(rowID: 1, offset: 1)
    XCTAssertEqual(cm.offset(from: start, to: result!), 3)
}
```

This catches consistency bugs between `offset(from:to:)` and `location(_:offsetBy:)` before they manifest as selection or cursor bugs at runtime.

## Performance Measurement

### Profiling Storage Operations

Use `os_signpost` to measure editing lifecycle cost:

```swift
import os

private let storageLog = OSLog(subsystem: "com.app.editor", category: "TextStorage")

class InstrumentedTextStorage: NSTextStorage {
    override func processEditing() {
        let id = OSSignpostID(log: storageLog)
        os_signpost(.begin, log: storageLog, name: "processEditing", signpostID: id,
                    "range: %{public}@, delta: %d",
                    NSStringFromRange(editedRange), changeInLength)
        super.processEditing()
        os_signpost(.end, log: storageLog, name: "processEditing", signpostID: id)
    }
}
```

View results in Instruments with the `os_signpost` instrument or the Points of Interest track.

### What to Watch For

| Symptom | Likely Cause | Measurement |
|---------|-------------|-------------|
| Typing lag on long documents | `processEditing` too slow | Signpost duration per keystroke |
| Scroll hitch after paste | Full-document attribute enumeration | Profile `didProcessEditing` delegate |
| Memory spike on large paste | Unbatched edits creating intermediate strings | Allocations instrument during paste |
