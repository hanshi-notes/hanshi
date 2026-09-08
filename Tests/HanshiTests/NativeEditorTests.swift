import AppKit
import Testing
@testable import Hanshi

@Test(arguments: ["sql", "perl", "c_sharp", "haskell", "unknown-language"])
@MainActor func unsupportedFenceLanguagesKeepLiteralColorAndSurroundingMarkdown(language: String) async throws {
    _ = NSApplication.shared
    let source = "# Before\n\n```\(language)\nSELECT 42;\n```\n\n## After\n"
    let document = PreviewTestFixtures.document(source)
    document.editor.setSyntaxTheme(.system)
    await document.editor.waitForHighlighting()
    let layout = try #require(document.editor.textView.layoutManager)
    for (text, expected) in [("42", NSColor.systemBrown), ("Before", .systemBlue), ("After", .systemBlue)] {
        let offset = (source as NSString).range(of: text).location
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor == expected)
    }
    #expect(SyntaxResources.languageProvider(named: language) == nil)
    #expect(document.text == source)
    #expect(!document.isModified)
    #expect(document.editor.textView.undoManager?.canUndo == false)
}

@Test @MainActor func nativeEditorLineNumbersFollowUnicodeEditsAndUndo() throws {
    _ = NSApplication.shared
    let document = PreviewTestFixtures.document("One 😀\r\nTwo\nThree")
    let editor = document.editor.textView
    document.editor.setGutter(true)
    let ruler = try #require(editor.gutterView)
    #expect(ruler.lineStarts == [0, 8, 12])
    #expect(ruler.lineNumber(at: 10) == 2)
    editor.undoManager?.groupsByEvent = false
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("\n", replacementRange: NSRange(location: 17, length: 0))
    editor.undoManager?.endUndoGrouping()
    #expect(ruler.lineStarts == [0, 8, 12, 18])
    editor.undoManager?.undo()
    #expect(ruler.lineStarts == [0, 8, 12])
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("", replacementRange: NSRange(location: 0, length: 17))
    editor.undoManager?.endUndoGrouping()
    #expect(ruler.lineStarts == [0])
}

@Test @MainActor func nativeEditorMarkedTextCommitsWithoutLosingUnicodeOrUndo() throws {
    _ = NSApplication.shared
    let document = PreviewTestFixtures.document("# 😀\n")
    let editor = document.editor.textView
    editor.undoManager?.groupsByEvent = false
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    editor.undoManager?.beginUndoGrouping()
    editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.undoManager?.endUndoGrouping()
    #expect(!editor.hasMarkedText())
    #expect(document.text == "# 😀\n日本語")
    editor.undoManager?.undo()
    #expect(document.text == "# 😀\n")
    #expect(!document.isModified)
}

extension AppKitWindowTests {
    @Test @MainActor func nativeEditorUndoAndRedoUseTheResponderChain() throws {
        let document = PreviewTestFixtures.document("Original")
        let editor = document.editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = document.editor.scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        defer { window.contentView = nil; window.close() }
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        #expect(!editor.validateUserInterfaceItem(undo))
        #expect(!editor.validateUserInterfaceItem(redo))
        editor.undoManager?.groupsByEvent = false
        editor.undoManager?.beginUndoGrouping()
        editor.insertText(" edit", replacementRange: NSRange(location: 8, length: 0))
        editor.undoManager?.endUndoGrouping()
        #expect(document.text == "Original edit")
        #expect(editor.validateUserInterfaceItem(undo))
        #expect(editor.tryToPerform(Selector(("undo:")), with: nil))
        #expect(document.text == "Original")
        #expect(editor.validateUserInterfaceItem(redo))
        #expect(editor.tryToPerform(Selector(("redo:")), with: nil))
        #expect(document.text == "Original edit")
    }

    @Test @MainActor func nativeEditorMillionByteCorpusMeasuresTypingHighlightingAndLayout() async throws {
        _ = NSApplication.shared
        let unit = "## Heading 😀\n\nA paragraph with **bold**, *emphasis*, [a link](https://example.com), and Unicode 漢字.\n\n- First item\n- [x] Completed\n\n```swift\nlet message = \"Hello 😀\"\nprint(message)\n```\n\n| Item | Value |\n| :--- | ---: |\n| Tea | 2 |\n\n"
        let source = String(repeating: unit, count: 1_000_000 / unit.utf8.count)
        let clock = ContinuousClock()
        let start = clock.now
        let document = PreviewTestFixtures.document(source)
        let session = document.editor
        let editor = session.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        editor.layoutManager?.ensureLayout(for: try #require(editor.textContainer))
        let layoutTime = start.duration(to: clock.now)
        await session.waitForHighlighting()
        let coldTime = start.duration(to: clock.now)
        let offset = (source as NSString).range(of: "Heading", options: .backwards).location
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        let editStart = clock.now
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("New ", replacementRange: NSRange(location: offset, length: 0))
        editor.undoManager?.endUndoGrouping()
        let typingTime = editStart.duration(to: clock.now)
        await session.waitForHighlighting()
        let highlightTime = editStart.duration(to: clock.now)
        let layoutStart = clock.now
        let frame = try #require(editor.textFrame(at: offset))
        #expect(frame.minY > 1000)
        #expect(document.text.contains("## New Heading"))
        #expect(editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor == .systemBlue)
        print("EDITOR_BENCH bytes=\(source.utf8.count) initial_layout=\(layoutTime) cold_highlight=\(coldTime) typing=\(typingTime) edit_highlight=\(highlightTime) edit_layout=\(layoutStart.duration(to: clock.now))")
    }
}

@Test @MainActor func cotEditorThemesLoadAndApplyWithoutChangingTheDocument() async throws {
    let document = PreviewTestFixtures.document("# Heading\n\nText **bold**\n")
    let editor = document.editor.textView
    let selection = NSRange(location: 2, length: 3)
    editor.setSelectedRange(selection)
    var count = 0
    for theme in SyntaxTheme.allCases {
        if let cot = theme.cotTheme {
            count += 1
            #expect(cot.metadata["license"] == "Same as CotEditor (Apache, ver.2)")
        }
        document.editor.setSyntaxTheme(theme)
        await document.editor.waitForHighlighting()
        #expect(editor.backgroundColor == (theme.background ?? .textBackgroundColor))
        #expect(editor.textColor == theme.plain)
        #expect(editor.insertionPointColor == theme.insertionPoint)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == theme.selection)
        #expect(editor.lineHighlightColor == theme.lineHighlight)
        #expect((editor.layoutManager as? EditorLayoutManager)?.invisiblesColor == theme.invisibles)
        #expect(editor.selectedRange() == selection)
        #expect(!document.isModified)
        #expect(editor.undoManager?.canUndo == false)
        #expect(editor.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == theme.plain)
        #expect(editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 2, effectiveRange: nil) as? NSColor == theme.colors["H1"])
    }
    #expect(count == 13)
}

@Test @MainActor func cotThemeRejectsMalformedColorsAndUndeclaredLicenses() throws {
    let valid = ##"{"metadata":{"license":"Same as CotEditor (Apache, ver.2)"},"text":{"color":"#123456"},"background":{"color":"#abcdef80"},"selection":{"color":"#ffffff","usesSystemSetting":true}}"##
    let theme = try CotTheme(data: Data(valid.utf8))
    #expect(theme.color("selection", system: .selectedTextBackgroundColor) == .selectedTextBackgroundColor)
    #expect(abs(try #require(theme.color("background")).alphaComponent - 128.0 / 255) < 0.001)
    for invalid in ["{}", "[]", valid.replacingOccurrences(of: "#123456", with: "#xyz123"),
                    valid.replacingOccurrences(of: "Same as CotEditor (Apache, ver.2)", with: "All rights reserved")] {
        #expect(throws: (any Error).self) { try CotTheme(data: Data(invalid.utf8)) }
    }
}

extension AppKitWindowTests {
    @Test @MainActor func nativeEditorInvisiblesChangePixelsWithoutChangingGeometryOrText() throws {
        let document = PreviewTestFixtures.document("One \tTwo\nThree\n")
        let editor = document.editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = document.editor.scrollView
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        func pixels() throws -> Data {
            let rect = NSRect(x: 0, y: 0, width: 350, height: 90)
            let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: rect))
            editor.cacheDisplay(in: rect, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        document.editor.setInvisibles(false)
        let frame = try #require(editor.textFrame(at: 6))
        let hidden = try pixels()
        document.editor.setInvisibles(true)
        #expect(try pixels() != hidden)
        #expect(editor.textFrame(at: 6) == frame)
        document.editor.setInvisibles(false)
        #expect(try pixels() == hidden)
        #expect(!document.isModified)
        #expect(editor.undoManager?.canUndo == false)
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        let line = try #require(editor.currentLineRect())
        #expect(line.minY > frame.minY)
        #expect(line.width > 300)
    }
}

extension AppKitWindowTests {
    @Test @MainActor func nativeEditorExposesAccessiblePlainTextSelectionAndCopy() async throws {
        _ = NSApplication.shared
        let source = "# Title\n\n日本語 😀 e\u{301}\n"
        let document = PreviewTestFixtures.document(source)
        let editor = document.editor.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = document.editor.scrollView
        defer { window.contentView = nil; window.close() }
        window.makeFirstResponder(editor)
        await document.editor.waitForHighlighting()
        let selected = "日本語 😀 e\u{301}"
        editor.setSelectedRange((source as NSString).range(of: selected))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let types = editor.writablePasteboardTypes
        pasteboard.declareTypes(types, owner: nil)
        #expect(editor.writeSelection(to: pasteboard, types: types))
        #expect(pasteboard.string(forType: .string) == selected)
        #expect(editor.accessibilityLabel() == "Markdown editor")
        #expect(editor.accessibilityRole() == .textArea)
        #expect(editor.accessibilitySelectedText() == selected)
        #expect(editor.textLayoutManager == nil)
        #expect(!document.isModified)
        #expect(editor.undoManager?.canUndo == false)
    }

}

@Test @MainActor func darkEditorThemesKeepTheSystemCursorVisibleInsideALightWindow() throws {
    let document = PreviewTestFixtures.document("# Heading\n")
    let session = document.editor
    session.scrollView.appearance = NSAppearance(named: .aqua)
    session.setSyntaxTheme(.anuraDark)
    var brightness: CGFloat = 0
    session.textView.effectiveAppearance.performAsCurrentDrawingAppearance {
        brightness = session.textView.insertionPointColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
    }
    #expect(brightness > 0.5)
    session.setSyntaxTheme(.system)
    #expect(session.scrollView.appearance == nil)
}
