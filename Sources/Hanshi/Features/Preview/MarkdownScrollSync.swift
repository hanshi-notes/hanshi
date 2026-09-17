import AppKit

nonisolated struct MarkdownReadingPosition: Sendable {
    let sourceOffset: Int
    let fraction: Double
}

extension MarkdownPreviewSession {
    func frame(at offset: Int, length: Int = 1) -> NSRect? {
        engine.previewFrame(for: NSRange(location: offset, length: length))
    }
    func readingPosition() -> MarkdownReadingPosition? {
        guard let composition, !composition.anchors.isEmpty else { return nil }
        let y = scrollView.contentView.bounds.minY
        guard let offset = engine.previewCharacter(at: NSPoint(x: textView.textContainerOrigin.x + 1, y: y + 1)) else { return nil }
        let anchor = MarkdownScrollSync.anchor(at: offset, in: composition, source: false)
        guard let anchor, let rect = frame(at: anchor.rendered.location, length: anchor.rendered.length) else { return nil }
        return MarkdownReadingPosition(sourceOffset: anchor.source.location, fraction: min(1, max(0, (y - rect.minY) / max(1, rect.height))))
    }
    func restore(position: MarkdownReadingPosition) {
        guard let composition,
              let anchor = MarkdownScrollSync.anchor(at: position.sourceOffset, in: composition, source: true) else { return }
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
    }
    @objc private func boundsChanged(_ notification: Notification) {
        guard !moving, let clip = notification.object as? NSClipView else { return }
        let panel: Panel = clip === editor?.scrollView.contentView ? .editor : .preview
        let expected = panel == .editor ? expectedEditorY : expectedPreviewY
        if let expected, abs(clip.bounds.minY - expected) < 1 { return }
        guard panel == active else { return }
        synchronize(from: panel)
    }
    /// The shortest anchor containing `offset`, else the one starting nearest it; ties go to the earlier anchor.
    /// Runs on every scroll event, so it searches instead of scanning all anchors (50,000 on a 1 MB note).
    static func anchor(at offset: Int, in composition: MarkdownComposition, source: Bool) -> MarkdownAnchor? {
        let anchors = composition.anchors
        let reach = source ? composition.sourceReach : composition.renderedReach
        let range: (Int) -> NSRange = { source ? anchors[$0].source : anchors[$0].rendered }
        // Anchors are in source order, and rendered ranges keep it: count those starting at or before the offset.
        var low = 0, high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if range(mid).location <= offset { low = mid + 1 } else { high = mid }
        }
        let started = low
        if started > 0, reach[started - 1] > offset || range(started - 1).location == offset {
            var best: Int?
            var index = started - 1
            while index >= 0 {
                let r = range(index)
                let gap = offset - r.location
                // Anything starting this far back that contains the offset is longer than the best.
                if let best, gap > range(best).length || gap == range(best).length && gap > 0 { break }
                if r.upperBound > offset || r.length == 0 && gap == 0, best.map({ r.length <= range($0).length }) ?? true {
                    best = index
                }
                index -= 1
            }
            if let best { return anchors[best] }
        }
        // Nearest start: the last run of starts below the offset or the first start after it.
        func firstIndex(startingAt location: Int) -> Int {
            var low = 0, high = anchors.count
            while low < high {
                let mid = (low + high) / 2
                if range(mid).location < location { low = mid + 1 } else { high = mid }
            }
            return low
        }
        let below = started > 0 ? firstIndex(startingAt: range(started - 1).location) : nil
        let above = started < anchors.count ? started : nil
        switch (below, above) {
        case let (below?, above?):
            return offset - range(below).location <= range(above).location - offset ? anchors[below] : anchors[above]
        case let (below?, nil): return anchors[below]
        case let (nil, above?): return anchors[above]
        case (nil, nil): return nil
        }
    }
    private func editorFrame(offset: Int) -> NSRect? {
        editor?.textView.textFrame(at: offset)
    }
    private func editorPosition(in composition: MarkdownComposition) -> MarkdownReadingPosition? {
        guard let editor, let offset = editor.textView.firstVisibleCharacter() else { return nil }
        let top = editor.scrollView.contentView.bounds.minY
        guard let anchor = Self.anchor(at: offset, in: composition, source: true), let first = editorFrame(offset: anchor.source.location) else { return nil }
        let last = editorFrame(offset: max(anchor.source.location, anchor.source.upperBound - 1)) ?? first
        return MarkdownReadingPosition(sourceOffset: anchor.source.location, fraction: min(1, max(0, (top - first.minY) / max(1, last.maxY - first.minY))))
    }
    func contentDidChange() { synchronize(from: active) }
    func synchronize(from panel: Panel) {
        guard !moving, let editor, let preview, let snapshot = preview.appliedSnapshot,
              preview.isCurrent(snapshot), editor.displayedText == snapshot.text,
              let composition = preview.composition, !composition.anchors.isEmpty else { return }
        active = panel; moving = true
        defer { moving = false }
        if panel == .editor {
            if let position = editorPosition(in: composition) { preview.restore(position: position) }
            expectedPreviewY = preview.scrollView.contentView.bounds.minY
        } else if let position = preview.readingPosition(), let anchor = Self.anchor(at: position.sourceOffset, in: composition, source: true) {
            alignEditor(anchor: anchor, fraction: position.fraction)
        }
        movementCount += 1
    }
    private func alignEditor(anchor: MarkdownAnchor, fraction: Double) {
        guard let editor, let first = editorFrame(offset: anchor.source.location) else { return }
        let last = editorFrame(offset: max(anchor.source.location, anchor.source.upperBound - 1)) ?? first
        let y = first.minY + max(1, last.maxY - first.minY) * fraction
        if y > max(0, editor.textView.bounds.height - editor.scrollView.contentView.bounds.height) {
            editor.textView.sizeToFit()
        }
        Self.scroll(editor.scrollView, to: y)
        expectedEditorY = editor.scrollView.contentView.bounds.minY
    }
    static func scroll(_ scrollView: NSScrollView, to y: Double) {
        guard y.isFinite, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(0, y), max(0, document.bounds.height - clip.bounds.height))))
        scrollView.reflectScrolledClipView(clip)
    }
}
