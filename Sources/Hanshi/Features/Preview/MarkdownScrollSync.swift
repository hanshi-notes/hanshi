import AppKit
import STTextView

nonisolated struct MarkdownReadingPosition: Sendable {
    let sourceOffset: Int
    let fraction: Double
}

extension MarkdownPreviewSession {
    func frame(at offset: Int, length: Int = 1) -> NSRect? {
        guard let manager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return nil }
        let range = NSRange(location: min(max(0, offset), storage.length - 1), length: 1)
        let fullRange = NSRange(location: range.location, length: min(max(1, length), storage.length - range.location))
        manager.ensureLayout(forCharacterRange: fullRange)
        let glyphs = manager.glyphRange(forCharacterRange: fullRange, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
    func readingPosition() -> MarkdownReadingPosition? {
        guard let composition, !composition.anchors.isEmpty, let manager = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let y = scrollView.contentView.bounds.minY
        let point = NSPoint(x: 1, y: max(0, y - textView.textContainerOrigin.y + 1))
        let offset = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let anchor = MarkdownScrollSync.anchor(at: offset, anchors: composition.anchors, source: false)
        guard let anchor, let rect = frame(at: anchor.rendered.location, length: anchor.rendered.length) else { return nil }
        return MarkdownReadingPosition(sourceOffset: anchor.source.location, fraction: min(1, max(0, (y - rect.minY) / max(1, rect.height))))
    }
    func restore(position: MarkdownReadingPosition) {
        guard let anchors = composition?.anchors,
              let anchor = MarkdownScrollSync.anchor(at: position.sourceOffset, anchors: anchors, source: true) else { return }
        scroll(to: anchor.rendered.location, length: anchor.rendered.length, fraction: position.fraction)
    }
    func scroll(to offset: Int, length: Int = 1, fraction: Double) {
        guard let rect = frame(at: offset, length: length) else { return }
        let y = rect.minY + rect.height * fraction
        // A far jump can outpace NSTextView's deferred document-size update.
        if y > max(0, textView.bounds.height - scrollView.contentView.bounds.height) { textView.sizeToFit() }
        MarkdownScrollSync.scroll(scrollView, to: y)
    }
}

final class MarkdownScrollSync: NSObject {
    enum Panel { case editor, preview }
    private(set) weak var editor: MarkdownEditorSession?
    private weak var preview: MarkdownPreviewSession?
    private var monitor: Any?
    private var active = Panel.editor
    private var moving = false
    private var generation = 0
    private var expectedEditorY: Double?
    private var expectedPreviewY: Double?
    private(set) var movementCount = 0

    init(editor: MarkdownEditorSession, preview: MarkdownPreviewSession) { self.editor = editor; self.preview = preview }
    func connect() {
        disconnect()
        guard let editor, let preview else { return }
        for clip in [editor.scrollView.contentView, preview.scrollView.contentView] {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self, let window = event.window else { return event }
            if event.type == .keyDown {
                if window.firstResponder === self.preview?.textView { self.active = .preview }
                else if window.firstResponder === self.editor?.textView { self.active = .editor }
            } else {
                let point = event.locationInWindow
                if let scroll = self.preview?.scrollView, scroll.window === window, scroll.bounds.contains(scroll.convert(point, from: nil)) { self.active = .preview }
                else if let scroll = self.editor?.scrollView, scroll.window === window, scroll.bounds.contains(scroll.convert(point, from: nil)) { self.active = .editor }
            }
            return event
        }
    }
    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        generation += 1
    }
    @objc private func boundsChanged(_ notification: Notification) {
        guard !moving, let clip = notification.object as? NSClipView else { return }
        let panel: Panel = clip === editor?.scrollView.contentView ? .editor : .preview
        let expected = panel == .editor ? expectedEditorY : expectedPreviewY
        if let expected, abs(clip.bounds.minY - expected) < 1 { return }
        guard panel == active else { return }
        synchronize(from: panel)
    }
    static func anchor(at offset: Int, anchors: [MarkdownAnchor], source: Bool) -> MarkdownAnchor? {
        let range: (MarkdownAnchor) -> NSRange = { source ? $0.source : $0.rendered }
        let containing = anchors.filter { let r = range($0); return r.location <= offset && (r.upperBound > offset || r.length == 0 && r.location == offset) }
        if let exact = containing.min(by: { range($0).length < range($1).length }) { return exact }
        return anchors.min { abs(range($0).location - offset) < abs(range($1).location - offset) }
    }
    private func editorFrame(offset: Int) -> NSRect? {
        guard let editor else { return nil }
        let manager = editor.textView.textLayoutManager
        let content = editor.textView.textContentManager
        let length = (content as? NSTextContentStorage)?.textStorage?.length ?? 0
        guard offset >= 0, offset <= length,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let end = content.location(location, offsetBy: min(1, length - offset)),
              let range = NSTextRange(location: location, end: end) else { return nil }
        var result: NSRect?
        manager.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in result = frame; return false }
        // STTextView 2.4.0 offsets the content only horizontally for its gutter.
        return result
    }
    private func editorPosition(anchors: [MarkdownAnchor]) -> MarkdownReadingPosition? {
        guard let editor else { return nil }
        let manager = editor.textView.textLayoutManager
        let content = editor.textView.textContentManager
        let top = editor.scrollView.contentView.bounds.minY
        var offset = 0
        manager.enumerateTextLayoutFragments(from: manager.textViewportLayoutController.viewportRange?.location, options: []) { fragment in
            if fragment.layoutFragmentFrame.minY > top { return false }
            offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                if fragment.layoutFragmentFrame.minY + line.typographicBounds.minY > top { break }
                offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location) + line.characterRange.location
            }
            return true
        }
        guard let anchor = Self.anchor(at: offset, anchors: anchors, source: true), let first = editorFrame(offset: anchor.source.location) else { return nil }
        let last = editorFrame(offset: max(anchor.source.location, anchor.source.upperBound - 1)) ?? first
        return MarkdownReadingPosition(sourceOffset: anchor.source.location, fraction: min(1, max(0, (top - first.minY) / max(1, last.maxY - first.minY))))
    }
    func contentDidChange() { synchronize(from: active) }
    func synchronize(from panel: Panel) {
        guard !moving, let editor, let preview, let snapshot = preview.appliedSnapshot,
              preview.isCurrent(snapshot), editor.displayedText == snapshot.text,
              let anchors = preview.composition?.anchors, !anchors.isEmpty else { return }
        active = panel; moving = true
        defer { moving = false }
        generation += 1
        if panel == .editor {
            if let position = editorPosition(anchors: anchors) { preview.restore(position: position) }
            expectedPreviewY = preview.scrollView.contentView.bounds.minY
        } else if let position = preview.readingPosition(), let anchor = Self.anchor(at: position.sourceOffset, anchors: anchors, source: true) {
            let length = (editor.textView.textContentManager as? NSTextContentStorage)?.textStorage?.length ?? 0
            let offset = min(length, anchor.source.location)
            editor.textView.scrollRangeToVisible(NSRange(location: offset, length: min(1, length - offset)))
            alignEditor(anchor: anchor, fraction: position.fraction)
            let current = generation
            Task { [weak self] in
                await Task.yield()
                guard let self, generation == current, active == .preview else { return }
                moving = true
                alignEditor(anchor: anchor, fraction: position.fraction)
                moving = false
            }
        }
        movementCount += 1
    }
    private func alignEditor(anchor: MarkdownAnchor, fraction: Double) {
        guard let editor, let first = editorFrame(offset: anchor.source.location) else { return }
        let last = editorFrame(offset: max(anchor.source.location, anchor.source.upperBound - 1)) ?? first
        Self.scroll(editor.scrollView, to: first.minY + max(1, last.maxY - first.minY) * fraction)
        expectedEditorY = editor.scrollView.contentView.bounds.minY
    }
    static func scroll(_ scrollView: NSScrollView, to y: Double) {
        guard y.isFinite, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), max(0, document.bounds.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
    }
}
