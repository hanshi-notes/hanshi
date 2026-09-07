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
        editor.textView.textSelection = NSRange(location: 5, length: 3)
        let selection = editor.textView.textSelection
        let target = try #require(preview.composition?.anchors.first { $0.heading == "block-350" })
        preview.scroll(to: target.rendered.location, fraction: 0)
        sync.synchronize(from: .preview)
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        await Task.yield()
        let manager = editor.textView.textLayoutManager
        let textContent = editor.textView.textContentManager
        let location = try #require(textContent.location(textContent.documentRange.location, offsetBy: target.source.location))
        var frame = NSRect.zero
        manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard) { _, rect, _, _ in frame = rect; return false }
        #expect(abs(frame.minY - editor.scrollView.contentView.bounds.minY) < 28)
        #expect(editor.scrollView.contentView.bounds.minY > 1000)
        #expect(editor.textView.textSelection == selection)
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
        #expect(editor.textView.textSelection == selection)
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
        let bitmap = try #require(session.composition?.attachments.first)
        let originalWidth = bitmap.bitmap.size.width
        window.setContentSize(NSSize(width: 300, height: 500)); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        session.resizeAttachments()
        #expect(bitmap.bitmap.size.width < originalWidth)
        #expect(bitmap.bitmap.size.width <= session.textView.bounds.width)
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
        #expect(session.textView.string.hasPrefix("New note"))
    }
}
