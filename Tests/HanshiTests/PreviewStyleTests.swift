import AppKit
import SwiftUI
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
    #expect((4...8).contains(first.width(for: .padding, edge: .minY)))
    #expect((4...8).contains(first.width(for: .margin, edge: .minY)))
    #expect(try paragraph("Inline").textBlocks.isEmpty)
    let bodyFont = try #require(result.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(bodyFont.pointSize == 17)
    // Leading lives in lineSpacing, not lineHeightMultiple: a multiple grows the line
    // fragment and `.backgroundColor` fills all of it, so inline code would sit in a slab.
    // The engine restyles this text when the preview is editable, so `EnginePreviewResources`
    // carries the matching `paragraph.lineHeightExtraSpacing`; keep the two in step.
    #expect(try paragraph("Body").lineSpacing >= 4)
    #expect(try paragraph("Body").lineHeightMultiple == 0)
}

@Test @MainActor func previewTaskSymbolsRemainAccessibleAndCopyAsMarkdown() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    session.show(PreviewTestFixtures.snapshot("- [ ] Pending\n- [x] Done\n\nLiteral ☑ stays text."))
    await session.waitForRendering()
    let accessible = try #require(session.textView.accessibilityValue() as? String)
    #expect(accessible.contains("[ ] Pending"))
    #expect(accessible.contains("[x] Done"))
    session.textView.selectAll(nil)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(session.textView.writeSelection(to: pasteboard, types: [.string, .rtf]))
    #expect(pasteboard.string(forType: .string) == "- [ ] Pending\n- [x] Done\n\nLiteral ☑ stays text.")
}

/// ⚠️ This calls `drawBackground` directly. The preview view runs on TextKit 2, whose
/// layout never calls that TextKit 1 method, so the rounded corner does NOT reach the
/// screen — the block renders square. Rounding it for real needs the engine's
/// `MarkdownTextLayoutFragment.drawCodeBlockBackground`, which fills a plain rect.
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
    let corner = try #require(bitmap.colorAt(x: 11, y: 17)?.usingColorSpace(.deviceRGB))
    let margin = try #require(bitmap.colorAt(x: 50, y: 11)?.usingColorSpace(.deviceRGB))
    #expect(margin.redComponent > 0.99, "Outer margins must separate consecutive blocks")
    let center = try #require(bitmap.colorAt(x: 50, y: 30)?.usingColorSpace(.deviceRGB))
    #expect(corner.redComponent > 0.99, "The rounded corner must leave the page visible")
    #expect((0.93...0.97).contains(center.redComponent), "The block must draw its gray background")
}

extension AppKitWindowTests {
    @Test(arguments: [14.0, 17.0, 24.0], [false, true]) @MainActor
    func previewNumberedTasksKeepCheckboxesAndTextAligned(bodySize: Double, checked: Bool) async throws {
        let labels = ["Most important outcome", "Second outcome", "Third outcome"]
        let source = "# Daily planner\n\n" + (1...12).map {
            "\($0). [\(checked ? "x" : " ")] [\(labels[($0 - 1) % labels.count])]"
        }.joined(separator: "\n")
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { session.hide(); window.contentView = nil; window.close() }
        var snapshot = PreviewTestFixtures.snapshot(source)
        snapshot.theme = PreviewTheme(bodySize: bodySize, lineHeight: 1.2)
        session.show(snapshot)
        await session.waitForRendering()
        window.layoutIfNeeded()
        let matches = try NSRegularExpression(pattern: #"\[[ x]\] \["#)
            .matches(in: source, range: NSRange(location: 0, length: source.utf16.count))
        #expect(matches.count == 12)
        let bitmap = try #require(session.scrollView.bitmapImageRepForCachingDisplay(in: session.scrollView.bounds))
        session.scrollView.cacheDisplay(in: session.scrollView.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / session.scrollView.bounds.width
        func inkCenterY(in rect: NSRect) throws -> Double {
            let rows = (Int(rect.minY * scale)..<Int(ceil(rect.maxY * scale))).filter { y in
                (Int(rect.minX * scale)..<Int(ceil(rect.maxX * scale))).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent > 0.25
                        && min(color.redComponent, color.greenComponent, color.blueComponent) < 0.74
                }
            }
            return Double(try #require(rows.first) + #require(rows.last)) / (2 * scale)
        }
        var column: CGFloat?
        for match in matches {
            let frame = try #require(session.frame(at: match.range.location + 4, length: 1))
            if let column { #expect(abs(frame.minX - column) < 0.5) }
            else { column = frame.minX }
            let boxRegion = NSRect(x: frame.minX - bodySize * 2, y: frame.minY,
                width: bodySize * 2 - 3, height: frame.height)
            let difference = try inkCenterY(in: frame) - inkCenterY(in: boxRegion)
            #expect(abs(difference) <= (checked ? 0.5 : 0.01),
                    "The visible checkbox and label must share a center: offset \(difference) pt")
        }
        if let path = ProcessInfo.processInfo.environment["HANSHI_TASK_SNAPSHOT"], bodySize == 14, !checked {
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(filePath: path))
        }
    }

    @Test(arguments: [17.0, 24.0], [false, true]) @MainActor
    func previewCodeMatchesBodySizeAndUsesCompactSpacing(bodySize: Double, editable: Bool) async throws {
        let source = #"""
        Body text with `inline code`.

        ```bash
        alias uniqc="uniq -c | sed 's/^[ ]*//;s/ /\t/'"
        alias barsep="sed 's/\t/ | /g'"
        ```

        ## Encoding

        ### Detect encoding
        """#
        let document = PreviewTestFixtures.document(source)
        let session = MarkdownPreviewSession(debounce: .zero)
        defer { session.hide() }
        var snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: source,
            url: document.url, root: document.url.deletingLastPathComponent())
        snapshot.theme = PreviewTheme(bodySize: bodySize)
        snapshot.settings = PreviewSettings(allowsEditing: editable)
        session.show(snapshot, document: document)
        await session.waitForRendering()
        let storage = try #require(session.textView.textStorage)
        func attributes(_ text: String) throws -> [NSAttributedString.Key: Any] {
            let range = (storage.string as NSString).range(of: text)
            try #require(range.location != NSNotFound)
            return storage.attributes(at: range.location, effectiveRange: nil)
        }
        for text in ["Body text", "inline code", "alias uniqc", "alias barsep"] {
            let font = try #require(attributes(text)[.font] as? NSFont)
            #expect(Double(font.pointSize) == bodySize)
            if text != "Body text" { #expect(font.isFixedPitch) }
        }
        for text in ["alias uniqc", "alias barsep"] {
            let style = try #require(attributes(text)[.paragraphStyle] as? NSParagraphStyle)
            #expect(style.paragraphSpacingBefore <= 2)
            #expect(style.paragraphSpacing <= 2)
        }
        let heading = try #require(attributes("Detect encoding")[.paragraphStyle] as? NSParagraphStyle)
        #expect((1...12).contains(heading.paragraphSpacingBefore))
        #expect(document.text == source)
    }

    @Test(arguments: [1.0, 1.5, 2.0], ["\n", "\n\n"]) @MainActor
    func previewTypedLinesMatchEditorLineHeight(lineHeight: Double, separator: String) async throws {
        let document = PreviewTestFixtures.document("Line 1")
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { session.hide(); window.contentView = nil; window.close() }
        var snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: document.text,
            url: document.url, root: document.url.deletingLastPathComponent())
        snapshot.theme = PreviewTheme(bodySize: 17, fontName: "Menlo-Regular", lineHeight: lineHeight)
        snapshot.settings = PreviewSettings(allowsEditing: true)
        session.show(snapshot, document: document)
        await session.waitForRendering()
        window.makeFirstResponder(session.textView)
        session.textView.setSelectedRange(NSRange(location: document.text.utf16.count, length: 0))
        for line in 2...6 {
            for _ in separator { session.textView.insertNewline(nil) }
            session.textView.insertText("Line \(line)", replacementRange: session.textView.selectedRange())
            await Task.yield()
            await session.waitForRendering()
        }
        let expected = (1...6).map { "Line \($0)" }.joined(separator: separator)
        #expect(document.text == expected)
        let last = (expected as NSString).range(of: "Line 6").location
        let previewHeight = try #require(session.frame(at: last)).minY - #require(session.frame(at: 0)).minY
        let editor = document.editor
        editor.setFont(name: "Menlo-Regular", size: 17)
        editor.setTypography(lineHeight: lineHeight, ligatures: true)
        window.contentView = editor.scrollView
        window.layoutIfNeeded()
        let editorHeight = try #require(editor.textView.textFrame(at: last)).minY
            - #require(editor.textView.textFrame(at: 0)).minY
        let intervals = 5 * separator.count
        #expect(abs(previewHeight - editorHeight) / Double(intervals) <= 1,
                "Matching font and line-height settings must not add paragraph gaps after each Return: preview \(previewHeight), editor \(editorHeight)")
    }

    @Test(arguments: ["# First **heading**", "First paragraph", "\n\n# First **heading**"])
    @MainActor func previewStartsNearTheTopWithoutCrowdingLaterHeadings(_ opening: String) async throws {
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { session.hide(); window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        session.show(PreviewTestFixtures.snapshot(opening + "\n\n# Later heading\n"))
        await session.waitForRendering()
        let first = try #require(session.frame(at: 0))
        // Read the margins from the theme rather than pinning numbers: these are taste
        // values that move, and what matters is that the configured inset reaches the screen.
        let inset = PreviewTheme().inset
        #expect(abs(first.minY - inset.height) < 4, "The preview should start at the configured top margin, got \(first.minY) pt")
        #expect(first.minX == inset.width, "The configured reading margin should reach the screen")
        let storage = try #require(session.textView.textStorage)
        let later = (storage.string as NSString).range(of: "Later heading")
        let style = try #require(storage.attribute(.paragraphStyle, at: later.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect((1...12).contains(style.paragraphSpacingBefore), "Headings should keep a compact separation")
    }

    @Test(arguments: [false, true], [NSScroller.Style.overlay, .legacy]) @MainActor
    func shortPreviewDoesNotGainAScrollbarWhenShrinkingTheWindow(editable: Bool, scrollerStyle: NSScroller.Style) async throws {
        _ = NSApplication.shared
        let source = "# Note\n\nTwo short lines.\n"
        let document = PreviewTestFixtures.document(source)
        let session = MarkdownPreviewSession(debounce: .zero)
        let preferences = TestPreferences(); defer { preferences.remove() }
        preferences.defaults.set(editable, forKey: PreviewSettings.allowsEditingKey)
        let host = NSHostingView(rootView: NoteEditorContentView(document: document,
            files: LibraryFiles(root: document.url.deletingLastPathComponent()), mode: .preview, preview: session)
            .defaultAppStorage(preferences.defaults))
        session.scrollView.scrollerStyle = scrollerStyle
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { session.hide(); window.contentView = nil; window.close() }
        await session.waitForRendering()
        let content = try #require(session.scrollView.documentView)
        for size in [NSSize(width: 700, height: 760), NSSize(width: 700, height: 540), NSSize(width: 700, height: 539),
                     NSSize(width: 450, height: 300), NSSize(width: 700, height: 760)] {
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(abs(session.scrollView.contentView.bounds.height - size.height) <= 1)
            #expect(abs(content.frame.height - session.scrollView.contentView.bounds.height) <= 0.5)
            #expect(session.scrollView.verticalScroller?.isHidden == true)
        }
        #expect(document.text == source)
    }

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

@Test @MainActor func previewThemeDerivesCodeSizeAndKeepsItsOtherSettingsIndependent() {
    let standard = PreviewTheme()
    #expect(standard.bodySize == 17)
    #expect(standard.codeSize == standard.bodySize)
    #expect(standard.inset == NSSize(width: 38, height: 14))
    #expect(standard.bodyLineSpacing == 5, "The default line height reproduces the old fixed leading")

    #expect(PreviewTheme(bodySize: 24).codeSize == 24, "Code matches the body size")
    // `Double(...)` throughout: `#expect` compares a CGFloat against a Double bound through
    // the implicit bridge and reports 14.0 != 14.0.
    #expect(Double(PreviewTheme(margin: 60).inset.height) == PreviewTheme.defaultVerticalMargin,
            "The vertical margin is its own setting, not a fraction of the side one")
    #expect(PreviewTheme(verticalMargin: 40).inset == NSSize(width: 38, height: 40))

    // Leading scales with the multiple, and stays out of lineHeightMultiple so inline
    // code backgrounds keep hugging the glyphs.
    #expect(PreviewTheme(lineHeight: 1.0).bodyLineSpacing == 0)
    #expect(PreviewTheme(lineHeight: 1.5).bodyLineSpacing > standard.bodyLineSpacing)

    // A face this Mac no longer has must not leave the preview without a font, and a name
    // that no longer resolves still finds its family. `NSFont(name: ".NewYork-Regular")`
    // returns nil even though the panel can offer that face, which is why both are stored.
    #expect(PreviewTheme(fontName: "NoSuchFontHere").bodyFont(size: 17) == .systemFont(ofSize: 17))
    #expect(PreviewTheme(fontName: "Menlo-Regular").bodyFont(size: 17).fontName == "Menlo-Regular")
    #expect(PreviewTheme(fontName: "NoSuchFontHere", fontFamily: "Georgia").bodyFont(size: 17).familyName == "Georgia")

    // A stored default can be anything; it must never produce an unusable preview.
    #expect(PreviewTheme(bodySize: 999, margin: 9_999).bodySize == PreviewTheme.bodySizeRange.upperBound)
    #expect(Double(PreviewTheme(bodySize: 1, margin: 0).inset.width) == PreviewTheme.marginRange.lowerBound)
    #expect(PreviewTheme(bodySize: .nan, margin: .nan, verticalMargin: .nan, lineHeight: .nan) == PreviewTheme())
}

@Test @MainActor func previewAppliesTheConfiguredSizeAndMargin() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    var snapshot = PreviewTestFixtures.snapshot("# Heading\n\nBody text.\n")
    snapshot.theme = PreviewTheme(bodySize: 22, margin: 60, verticalMargin: 30,
                                  fontName: "Menlo-Regular", lineHeight: 1.8)
    session.show(snapshot)
    await session.waitForRendering()
    #expect(session.textView.textContainerInset.width == 60)
    #expect(session.textView.textContainerInset.height == 30)
    let storage = try #require(session.textView.textStorage)
    let body = (storage.string as NSString).range(of: "Body text")
    let font = try #require(storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)
    #expect(font.pointSize == 22)
    #expect(font.familyName == "Menlo", "The chosen reading face reaches the screen, got \(font.familyName ?? "?")")
    // The engine restyles the text and expresses leading as a minimum line height. Compare
    // against the same render at the default multiple rather than against font metrics.
    func lineBox() throws -> CGFloat {
        let style = try #require(storage.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle)
        return style.minimumLineHeight
    }
    let loose = try lineBox()
    snapshot.theme = PreviewTheme(bodySize: 22, margin: 60, verticalMargin: 30,
                                  fontName: "Menlo-Regular", lineHeight: PreviewTheme.defaultLineHeight)
    session.show(snapshot)
    await session.waitForRendering()
    #expect(loose > (try lineBox()), "A 1.8× line height gives a taller line box than the default")
}

extension AppKitWindowTests {
    /// ⌘N creates a note holding just the title template. Whichever surface takes focus
    /// must leave the caret after the title, ready to type over it.
    @Test @MainActor func newNoteOpensWithTheCaretAfterItsTitle() async throws {
        let document = PreviewTestFixtures.document(NoteTitle.template)
        let sourceCaret = document.editor.textView.selectedRange()
        #expect(sourceCaret == NSRange(location: NoteTitle.template.utf16.count - 1, length: 0),
                "The source editor puts the caret at the end of the title line")

        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        window.makeKeyAndOrderFront(nil)
        defer { session.hide(); window.contentView = nil; window.close() }
        window.layoutIfNeeded()

        // `isCurrent` drops a render whose document id, text and url do not all match, so
        // the snapshot has to describe this very document.
        var snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: document.text,
                                       url: document.url, root: document.url.deletingLastPathComponent())
        snapshot.settings = PreviewSettings(allowsEditing: true, showsMarkdownMarkers: false)
        session.focusDocumentID = snapshot.documentID
        session.show(snapshot, document: document)
        await session.waitForRendering()
        session.focusIfNeeded()
        await Task.yield()

        // The editable preview keeps the source in storage and only shrinks the `# ` out of
        // sight, and it drops the trailing break. Assert on the line it actually holds so a
        // change to either of those shows up here instead of passing on an empty string.
        let rendered = session.textView.string as NSString
        let firstBreak = rendered.range(of: "\n").location
        let titleEnd = firstBreak == NSNotFound ? rendered.length : firstBreak
        let templateFirstLine = NoteTitle.template.split(separator: "\n").first.map(String.init) ?? ""
        #expect(rendered.substring(to: titleEnd) == templateFirstLine,
                "The preview holds the template's first line, got \(rendered)")
        #expect(session.textView.selectedRange() == NSRange(location: titleEnd, length: 0),
                "The preview puts the caret at the end of the rendered title, got \(session.textView.selectedRange())")
    }
}
