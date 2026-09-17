import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test(arguments: [false, true]) @MainActor
    func editButtonRespondsAcrossItsEntireFrame(disabled: Bool) async throws {
        var clicks = 0
        let host = NSHostingView(rootView: BarButton(title: "Edit", icon: "highlighter") { clicks += 1 }
            .disabled(disabled)
            .barControl().barGlassContainer()
            .padding(20))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 74.5, height: 64),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: host.bounds.midX, y: host.bounds.midY),
                      NSPoint(x: host.bounds.midX - 15, y: host.bounds.midY - 10),
                      NSPoint(x: host.bounds.midX + 15, y: host.bounds.midY + 10)] {
            let before = clicks
            let location = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            await Task.yield()
            #expect(clicks == before + (disabled ? 0 : 1), "Click at \(point) must respect the button's enabled state")
        }
    }

    @Test @MainActor func pairCompletionPreferenceReconfiguresTheMountedPreview() async throws {
        let suite = "HanshiTests.Pairs.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PreviewSettings.autoClosePairsKey)
        let document = PreviewTestFixtures.document("Text ")
        let session = MarkdownPreviewSession(debounce: .zero)
        let snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: document.text,
            url: document.url, root: document.url.deletingLastPathComponent())
        let host = NSHostingView(rootView: NoteEditorContentView(document: document,
            files: LibraryFiles(root: snapshot.root), mode: .preview, libraryID: snapshot.library,
            preview: session).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { session.hide(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await session.waitForRendering()
        for enabled in [false, true, false] {
            defaults.set(enabled, forKey: PreviewSettings.autoClosePairsKey)
            host.layoutSubtreeIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while session.appliedSnapshot?.settings.autoClosePairs != enabled, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(session.appliedSnapshot?.settings.autoClosePairs == enabled)
            for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}")] {
                let before = session.textView.string
                let end = before.utf16.count
                session.textView.setSelectedRange(NSRange(location: end, length: 0))
                session.textView.insertText(opening, replacementRange: NSRange(location: end, length: 0))
                #expect(session.textView.string == before + opening + (enabled ? closing : ""))
                #expect(session.textView.selectedRange().location == end + 1)
                await Task.yield()
                await session.waitForRendering()
            }
        }
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: PreviewSettings.autoClosePairsKey) == false)
    }

    @Test(arguments: [1.0, 2.0], [false, true]) @MainActor
    func gutterLabelsAlignWithBlankAndWrappedLines(lineHeight: Double, monaco: Bool) throws {
        let document = PreviewTestFixtures.document("One\n\n \n\t\n\tIndented\n" + String(repeating: "wrapped ", count: 15) + "\nLast\n")
        let session = document.editor
        session.setGutter(true)
        session.setFont(name: monaco ? "Monaco" : "", size: monaco ? 12 : 14)
        session.setTypography(lineHeight: lineHeight, ligatures: true)
        let editor = session.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        let manager = try #require(editor.layoutManager)
        manager.ensureLayout(for: try #require(editor.textContainer))
        let ruler = try #require(editor.gutterView)
        editor.backgroundColor = .white
        editor.textColor = .black
        let attributes: [NSAttributedString.Key: Any] = [.font: ruler.font,
            .foregroundColor: NSColor.black.withAlphaComponent(0.6)]
        func render(_ draw: () -> Void) throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(ruler.bounds.width)), pixelsHigh: Int(ceil(ruler.bounds.height)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
            context.cgContext.scaleBy(x: 1, y: -1)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
            draw()
            NSGraphicsContext.restoreGraphicsState()
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        for scrollOffset in [0.0, 30.0, 90.0] {
            session.scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollOffset))
            session.scrollView.reflectScrolledClipView(session.scrollView.contentView)
            let actual = try render { ruler.drawHashMarksAndLabels(in: ruler.bounds) }
            let expected = try render {
                for (index, start) in ruler.lineStarts.enumerated() {
                    let baseline: CGFloat
                    if start == editor.string.utf16.count {
                        baseline = manager.extraLineFragmentRect.minY + manager.defaultBaselineOffset(for: editor.font!)
                    } else {
                        let glyph = manager.glyphIndexForCharacter(at: start)
                        // Blank and indented lines must use the same typographic baseline
                        // as the visible letters in the first line, not a control glyph's position.
                        baseline = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                            + manager.location(forGlyphAt: 0).y
                    }
                    let y = ruler.convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + baseline), from: editor).y
                    let label = String(index + 1) as NSString
                    label.draw(at: NSPoint(x: ruler.ruleThickness - label.size(withAttributes: attributes).width - 8,
                        y: y - manager.defaultBaselineOffset(for: ruler.font)), withAttributes: attributes)
                }
            }
            #expect(actual.elementsEqual(expected), "Each label must share its text baseline at scroll offset \(scrollOffset)")
        }
    }
}

extension AppKitWindowTests {
    @Test @MainActor func lineNumberPreferenceUpdatesTheMountedEditorWithoutEditingTheNote() async throws {
        let suite = "HanshiTests.LineNumbers.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = PreviewTestFixtures.document("One\nTwo\n")
        let host = NSHostingView(rootView: MarkdownEditorView(document: document).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let scroll = document.editor.scrollView
        let selection = NSRange(location: 4, length: 3)
        document.editor.textView.setSelectedRange(selection)
        for visible in [false, true, false, true] {
            defaults.set(visible, forKey: EditorFont.gutterKey)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while scroll.rulersVisible != visible, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(scroll.rulersVisible == visible)
            #expect(scroll.hasVerticalRuler == visible)
            #expect(document.editor.textView.selectedRange() == selection)
            #expect(!document.isModified)
            #expect(document.editor.textView.undoManager?.canUndo == false)
        }
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: EditorFont.gutterKey) == true)
    }
}

/// The gutter rebuilds its line index on every edit. It must find exactly the lines NSString does,
/// terminators TextKit breaks on included, whichever chunk a CR or CRLF straddles.
@Test(arguments: ["", "a", "a\n", "\n\n", "a\r\nb", "a\rb", "a\r", "\r\n\r\n", "a\u{85}b\u{2028}c\u{2029}d", "no terminator at the end"]
      + [String(repeating: "x", count: 4095) + "\r\n" + "y", String(repeating: "x", count: 4095) + "\ry",
         String(repeating: "é\r\n", count: 3000)])
@MainActor func gutterLineIndexMatchesNSString(_ text: String) {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let scroll = NSScrollView(frame: view.frame)
    scroll.documentView = view
    view.string = text
    let ruler = LineNumberView(textView: view, scrollView: scroll)
    ruler.invalidateLineNumbers()
    let ns = text as NSString
    var expected = [0], offset = 0
    while offset < ns.length {
        offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
        expected.append(offset)
    }
    if ns.length > 0, ns.lineRange(for: NSRange(location: ns.length, length: 0)).length > 0 { expected.removeLast() }
    #expect(ruler.lineStarts == expected)
}
