import AppKit
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test @MainActor func previewScrollSyncJumpsFarBothWaysWithoutChangingEditorState() async throws {
        _ = NSApplication.shared
        let source = (0..<500).map { "## Block \($0)\n\nParagraph \($0) with **bold** and Unicode 😀.\n\n" }.joined()
        let document = PreviewTestFixtures.document(source)
        let preview = MarkdownPreviewSession(debounce: .zero)
        let editor = document.editor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        window.contentView = content
        editor.scrollView.frame = NSRect(x: 0, y: 0, width: 550, height: 600)
        preview.scrollView.frame = NSRect(x: 550, y: 0, width: 550, height: 600)
        content.addSubview(editor.scrollView); content.addSubview(preview.scrollView)
        window.orderFront(nil); content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        defer { preview.hide(); window.contentView = nil; window.close() }
        let snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: source, url: document.url, root: document.url.deletingLastPathComponent())
        preview.show(snapshot, document: document); await preview.waitForRendering()
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let sync = MarkdownScrollSync(editor: editor, preview: preview)
        sync.connect(); defer { sync.disconnect() }
        editor.textView.setSelectedRange(NSRange(location: 5, length: 3))
        let selection = editor.textView.selectedRange()
        let target = try #require(preview.composition?.anchors.first { $0.heading == "block-350" })
        preview.scroll(to: target.rendered.location, fraction: 0)
        sync.synchronize(from: .preview)
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        await Task.yield()
        let frame = try #require(editor.textView.textFrame(at: target.source.location))
        #expect(abs(frame.minY - editor.scrollView.contentView.bounds.minY) < 28)
        #expect(editor.scrollView.contentView.bounds.minY > 1000)
        #expect(editor.textView.selectedRange() == selection)
        #expect(document.text == source)
        for _ in 0..<100 { sync.synchronize(from: .preview) }
        await Task.yield()
        #expect(sync.movementCount <= 105)
        #expect(abs(frame.minY - editor.scrollView.contentView.bounds.minY) < 28)
        let earlier = try #require(preview.composition?.anchors.first { $0.heading == "block-80" })
        editor.textView.scrollRangeToVisible(NSRange(location: earlier.source.location, length: 1))
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        sync.synchronize(from: .editor)
        let position = try #require(preview.readingPosition())
        #expect(position.sourceOffset < target.source.location)
        #expect(abs(position.sourceOffset - earlier.source.location) < 1800)
        #expect(editor.textView.selectedRange() == selection)
        let before = editor.scrollView.contentView.bounds.origin
        document.edit(source + "Changed")
        preview.scroll(to: target.rendered.location, fraction: 0)
        sync.synchronize(from: .preview)
        #expect(editor.scrollView.contentView.bounds.origin == before, "Stale maps must not move the editor")
        // A refreshed preview can arrive before SwiftUI applies a same-length reload to the editor.
        let reloaded = source.replacingOccurrences(of: "Paragraph", with: "Statement")
        document.edit(reloaded)
        let refreshed = PreviewSnapshot(library: snapshot.library, documentID: document.id, text: reloaded,
            url: document.url, root: snapshot.root)
        preview.show(refreshed, document: document); await preview.waitForRendering()
        #expect(preview.isCurrent(refreshed))
        preview.scroll(to: target.rendered.location, fraction: 0)
        sync.synchronize(from: .preview)
        #expect(editor.scrollView.contentView.bounds.origin == before, "Matching lengths do not prove matching content")
        editor.synchronize(reloaded)
        sync.synchronize(from: .preview)
        #expect(editor.scrollView.contentView.bounds.minY > before.y + 1000)
    }
}

extension AppKitWindowTests {
    @Test @MainActor func previewTablesAndAttachmentsRelayoutWithoutReparsingOrLosingSelection() async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        try fixture.png(width: 1800, height: 900).write(to: fixture.root.appendingPathComponent("wide.png"))
        let session = MarkdownPreviewSession(debounce: .zero)
        let source = "# Table\n\n| First | Second |\n|---|---|\n| Long text that must wrap onto another line | **Value** |\n\n![Wide](wide.png)\n\nAfter"
        let snapshot = PreviewTestFixtures.snapshot(source, root: fixture.root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = session.scrollView; window.orderFront(nil)
        defer { session.hide(); window.contentView = nil; window.close() }
        session.show(snapshot); await session.waitForRendering()
        session.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let imageRange = (source as NSString).range(of: "![Wide](wide.png)")
        let originalWidth = try #require(session.frame(at: imageRange.location, length: imageRange.length)).width
        window.setContentSize(NSSize(width: 300, height: 500)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let resizedWidth = try #require(session.frame(at: imageRange.location, length: imageRange.length)).width
        #expect(resizedWidth < originalWidth)
        #expect(resizedWidth <= session.textView.bounds.width)
        #expect(session.textView.selectedRange() == NSRange(location: 0, length: 5))
        #expect(session.appliedSnapshot == snapshot)
        let table = (session.textView.string as NSString).range(of: "Value")
        let rect = try #require(session.frame(at: table.location, length: table.length))
        #expect(rect.width > 0 && rect.maxX <= session.textView.bounds.width + 1)
    }
}

extension AppKitWindowTests {
    @Test @MainActor func previewWidthTracksTheViewportAndNewNotesStartAtTheTop() async throws {
        _ = NSApplication.shared
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = session.scrollView; window.orderFront(nil)
        defer { session.hide(); window.contentView = nil; window.close() }
        session.show(PreviewTestFixtures.snapshot(String(repeating: "Long line with words and **bold text**.\n\n", count: 100)))
        await session.waitForRendering()
        session.scroll(to: session.textView.string.utf16.count - 1, fraction: 0)
        for width in [300.0, 900, 400] {
            window.setContentSize(NSSize(width: width, height: 400)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            #expect(abs(session.textView.bounds.width - session.scrollView.contentView.bounds.width) <= 1)
            #expect(abs(session.scrollView.contentView.bounds.minX) <= 1)
        }
        session.hide()
        session.show(PreviewTestFixtures.snapshot("# New note\n\n" + String(repeating: "Readable text. ", count: 50)))
        await session.waitForRendering()
        #expect(session.scrollView.contentView.bounds.minY <= 1)
        #expect(session.textView.string.hasPrefix("# New note"))
    }
}

/// The lookup the scroll sync runs on every scroll event, as it was: a scan over every anchor.
@MainActor private func scannedAnchor(at offset: Int, anchors: [MarkdownAnchor], source: Bool) -> MarkdownAnchor? {
    let range: (MarkdownAnchor) -> NSRange = { source ? $0.source : $0.rendered }
    let containing = anchors.filter { let r = range($0); return r.location <= offset && (r.upperBound > offset || r.length == 0 && r.location == offset) }
    if let exact = containing.min(by: { range($0).length < range($1).length }) { return exact }
    return anchors.min { abs(range($0).location - offset) < abs(range($1).location - offset) }
}

@Test @MainActor func anchorLookupAnswersExactlyWhatAScanAnswers() {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next(_ bound: Int) -> Int {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Int(state % UInt64(bound))
    }
    for _ in 0..<300 {
        // Nested blocks, per-line anchors, duplicates, empty anchors and gaps, sorted as the parse sorts them;
        // rendered ranges shrink after a point, as shortened wiki links shift them.
        var anchors: [MarkdownAnchor] = []
        for _ in 0..<next(40) {
            let location = next(120)
            let length = next(4) == 0 ? 0 : next(30)
            // A link shortened by 5 at 55..<65, mapped as previewRanges maps it: never backwards.
            func shown(_ offset: Int) -> Int { offset <= 55 ? offset : offset >= 65 ? offset - 5 : min(offset, 60) }
            let rendered = NSRange(location: shown(location), length: shown(location + length) - shown(location))
            let heading: String? = next(2) == 0 ? "h\(next(1000))" : nil
            anchors.append(MarkdownAnchor(source: NSRange(location: location, length: length), rendered: rendered, heading: heading))
        }
        anchors.sort { a, b in
            a.source.location == b.source.location ? a.source.length < b.source.length : a.source.location < b.source.location
        }
        let composition = MarkdownComposition(text: "" as NSString, anchors: anchors)
        for offset in 0...160 {
            for source in [true, false] {
                #expect(MarkdownScrollSync.anchor(at: offset, in: composition, source: source) == scannedAnchor(at: offset, anchors: anchors, source: source),
                        "offset \(offset) source \(source) anchors \(anchors.map { source ? $0.source : $0.rendered })")
            }
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HANSHI_PERF"] != nil)) @MainActor
func anchorLookupCostStaysFlatAsAnchorsGrow() throws {
    func milliseconds(_ units: Int) throws -> Double {
        let unit = "## Heading\n\nA paragraph with **bold**.\n\n- item\n- [x] done\n\n```swift\nlet a = 1\nprint(a)\n```\n\n"
        let text = String(repeating: unit, count: units)
        let composition = MarkdownComposition(text: text as NSString, anchors: try MarkdownRenderer.parse(text).anchors)
        let length = (text as NSString).length
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<200 { _ = MarkdownScrollSync.anchor(at: length * index / 200, in: composition, source: index % 2 == 0) }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 200 / 1e6
    }
    let small = try milliseconds(1_000), large = try milliseconds(8_000)
    print("ANCHOR_LOOKUP small=\(small)ms large=\(large)ms ratio=\(large / small)")
    // 8× the anchors: a scan reads about 8× per scroll event, a search barely moves.
    #expect(large / small < 3)
}
