import AppKit

final class MarkdownTextView: NSTextView {
    var indentsWithTabs = false
    var indentWidth = EditorFont.defaultTabWidth
    private let editUndoManager = UndoManager()
    override var undoManager: UndoManager? { editUndoManager }

    // This editor has a per-note history without an NSDocument in the responder chain.
    @objc func undo(_ sender: Any?) { editUndoManager.undo() }
    @objc func redo(_ sender: Any?) { editUndoManager.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): editUndoManager.canUndo
        case #selector(redo(_:)): editUndoManager.canRedo
        default: super.validateUserInterfaceItem(item)
        }
    }

    var gutterView: LineNumberView? { enclosingScrollView?.verticalRulerView as? LineNumberView }
    var showsLineNumbers = false {
        didSet {
            guard let scroll = enclosingScrollView else { return }
            if showsLineNumbers, gutterView == nil {
                scroll.verticalRulerView = LineNumberView(textView: self, scrollView: scroll)
            }
            scroll.hasHorizontalRuler = false
            scroll.hasVerticalRuler = showsLineNumbers
            scroll.rulersVisible = showsLineNumbers
        }
    }
    var showsInvisibleCharacters: Bool {
        get { (layoutManager as? EditorLayoutManager)?.showsInvisibles ?? false }
        set { (layoutManager as? EditorLayoutManager)?.showsInvisibles = newValue }
    }
    var highlightSelectedLine = true
    var lineHighlightColor = NSColor.quaternaryLabelColor

    override func insertTab(_ sender: Any?) {
        insertText(indentsWithTabs ? "\t" : String(repeating: " ", count: indentWidth),
                   replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let manager = layoutManager, let container = textContainer,
           convert(event.locationInWindow, from: nil).y >= manager.usedRect(for: container).maxY + textContainerOrigin.y {
            setSelectedRange(NSRange(location: textStorage?.length ?? 0, length: 0))
            return
        }
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        gutterView?.invalidateLineNumbers()
        needsDisplay = true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        gutterView?.needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightSelectedLine, selectedRange().length == 0,
              let line = currentLineRect(), line.intersects(rect) else { return }
        lineHighlightColor.setFill()
        line.intersection(rect).fill()
    }
}
