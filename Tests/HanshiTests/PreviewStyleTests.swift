import AppKit
import Testing
@testable import Hanshi

@Test @MainActor func previewCodeBlocksHavePaddingAndKeepSeparateBackgrounds() async throws {
    let result = try await PreviewTestFixtures.composition("Body text.\n\n```swift\nlet first = 1\nlet second = 2\n```\n\n```\nOther block\n```\n\nInline `code`.")
    func paragraph(_ word: String) throws -> NSParagraphStyle {
        let range = (result.text.string as NSString).range(of: word)
        return try #require(result.text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }
    let first = try #require(paragraph("let first").textBlocks.first)
    let second = try #require(paragraph("let second").textBlocks.first)
    let other = try #require(paragraph("Other block").textBlocks.first)
    #expect(first === second)
    #expect(first !== other)
    #expect(first.width(for: .padding, edge: .minX) >= 10)
    #expect(first.width(for: .padding, edge: .minY) >= 10)
    #expect(try paragraph("Inline").textBlocks.isEmpty)
    let bodyFont = try #require(result.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(bodyFont.pointSize == 17)
    #expect(try paragraph("Body").lineHeightMultiple > 1)
}

@Test @MainActor func previewTaskSymbolsRemainAccessibleAndCopyAsMarkdown() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    session.show(PreviewTestFixtures.snapshot("- [ ] Pending\n- [x] Done\n\nLiteral ☑ stays text."))
    await session.waitForRendering()
    let storage = try #require(session.textView.textStorage)
    var labels: [String] = []
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if let cell = (value as? NSTextAttachment)?.attachmentCell as? NSCell,
           let label = cell.accessibilityLabel() { labels.append(label) }
    }
    #expect(labels == ["Incomplete task", "Completed task"])
    session.textView.selectAll(nil)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(session.textView.writeSelection(to: pasteboard, types: [.string, .rtf]))
    #expect(pasteboard.string(forType: .string) == "[ ] Pending\n[x] Done\nLiteral ☑ stays text.\n")
}

@Test @MainActor func previewCodeBackgroundHasRoundedCorners() throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 60,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 100, height: 60).fill()
    PreviewCodeBlock().drawBackground(withFrame: NSRect(x: 10, y: 10, width: 80, height: 40),
        in: NSView(), characterRange: NSRange(location: 0, length: 0), layoutManager: NSLayoutManager())
    let corner = try #require(bitmap.colorAt(x: 11, y: 19)?.usingColorSpace(.deviceRGB))
    let margin = try #require(bitmap.colorAt(x: 50, y: 11)?.usingColorSpace(.deviceRGB))
    #expect(margin.redComponent > 0.99, "Outer margins must separate consecutive blocks")
    let center = try #require(bitmap.colorAt(x: 50, y: 30)?.usingColorSpace(.deviceRGB))
    #expect(corner.redComponent > 0.99, "The rounded corner must leave the page visible")
    #expect((0.93...0.97).contains(center.redComponent), "The block must draw its gray background")
}

extension AppKitWindowTests {
    @Test @MainActor func previewCodePaddingSurvivesWrappingAndResize() async throws {
        _ = NSApplication.shared
        let source = """
        # A calmer reading view

        Comfortable paragraphs with **clear emphasis**, *italics* and an [ordinary link](https://example.com).

        - [ ] Write the first draft
        - [x] Keep the useful details

        ```swift
        let message = "Readable code, even when a long line wraps onto another line in a narrow panel."
        print(message)
        ```

        ```python
        def greet(name):
            return f"Hello, {name}"
        ```

        A final paragraph with `inline code`.
        """
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView; window.orderFront(nil)
        defer { session.hide(); window.contentView = nil; window.close() }
        session.show(PreviewTestFixtures.snapshot(source)); await session.waitForRendering()
        let code = (session.textView.string as NSString).range(of: "let message")
        for width in [700.0, 320] {
            window.setContentSize(NSSize(width: width, height: 760))
            session.scrollView.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let frame = try #require(session.frame(at: code.location, length: code.length))
            #expect(frame.minX >= session.textView.textContainerInset.width + 10)
            #expect(frame.maxX <= width - session.textView.textContainerInset.width - 10)
            if let path = ProcessInfo.processInfo.environment["HANSHI_PREVIEW_SNAPSHOT"], width == 700 {
                let bitmap = try #require(session.scrollView.bitmapImageRepForCachingDisplay(in: session.scrollView.bounds))
                session.scrollView.cacheDisplay(in: session.scrollView.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
            }
        }
    }
}
