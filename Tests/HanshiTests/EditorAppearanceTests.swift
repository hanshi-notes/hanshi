import AppKit
import SwiftUI
import Testing
@testable import Hanshi

@Test @MainActor func changingEditorFontPreservesTextSelectionAndUndo() throws {
    _ = NSApplication.shared
    let document = NoteDocument(note: Note(id: "font", url: URL(filePath: "/unused.md")),
                                contents: NoteContents(data: Data("# Title 😀\n".utf8), text: "# Title 😀\n", fileID: "font")) {
        _, _, _ in throw CocoaError(.fileWriteUnknown)
    }
    let editor = document.editor.textView
    editor.undoManager?.groupsByEvent = false
    editor.insertText("New ", replacementRange: NSRange(location: 2, length: 0))
    let selection = editor.textSelection
    let text = document.text
    let systemFamily = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).familyName
    for (family, requested, expectedFamily, expectedSize) in [
        ("Menlo", 28.0, Optional("Menlo"), 28),
        ("Helvetica", 20, Optional("Helvetica"), 20),
        ("", Double.greatestFiniteMagnitude, systemFamily, 144),
        ("Unavailable-Hanshi-Test-Font", -Double.greatestFiniteMagnitude, systemFamily, 10),
        ("", 14, systemFamily, 14)
    ] {
        document.editor.setFont(family: family, size: requested)
        #expect(editor.font.familyName == expectedFamily)
        #expect(editor.font.pointSize == CGFloat(expectedSize))
        #expect(try #require(editor.gutterView?.font.pointSize) >= 11)
        #expect(editor.textSelection == selection)
        #expect(document.text == text)
    }
    editor.undoManager?.undo()
    #expect(document.text == "# Title 😀\n")
    #expect(!document.isModified)
}

extension AppKitWindowTests {
    @Test @MainActor func editorLoadsAndObservesSavedFontPreferences() async throws {
        _ = NSApplication.shared
        let suite = "HanshiTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Menlo", forKey: EditorFont.familyKey)
        defaults.set(28, forKey: EditorFont.sizeKey)
        defaults.set(1.8, forKey: EditorFont.lineHeightKey)
        defaults.set(false, forKey: EditorFont.ligaturesKey)
        let document = NoteDocument(note: Note(id: "appearance", url: URL(filePath: "/unused.md")),
                                    contents: NoteContents(data: Data(), text: "", fileID: "appearance")) {
            _, _, _ in throw CocoaError(.fileWriteUnknown)
        }
        let host = NSHostingView(rootView: MarkdownEditorView(document: document).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(document.editor.textView.font.familyName == "Menlo")
        #expect(document.editor.textView.font.pointSize == 28)
        #expect(document.editor.textView.defaultParagraphStyle.lineHeightMultiple == 1.8)
        #expect(document.editor.textView.typingAttributes[.ligature] as? Int == 0)
        defaults.set("Helvetica", forKey: EditorFont.familyKey)
        defaults.set(20.5, forKey: EditorFont.sizeKey)
        defaults.set("Helvetica-BoldOblique", forKey: EditorFont.nameKey)
        defaults.set(1.2, forKey: EditorFont.lineHeightKey)
        defaults.set(true, forKey: EditorFont.ligaturesKey)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (document.editor.textView.font.pointSize != 20.5 || document.editor.textView.font.fontName != "Helvetica-BoldOblique" || document.editor.textView.defaultParagraphStyle.lineHeightMultiple != 1.2), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.editor.textView.font.familyName == "Helvetica")
        #expect(document.editor.textView.font.pointSize == 20.5)
        #expect(document.editor.textView.font.fontName == "Helvetica-BoldOblique")
        #expect(document.editor.textView.defaultParagraphStyle.lineHeightMultiple == 1.2)
        #expect(document.editor.textView.typingAttributes[.ligature] as? Int == 1)
        #expect(!document.isModified)
    }
}

@Test @MainActor func typographyAffectsExistingAndNewTextWithoutEditingTheDocument() throws {
    _ = NSApplication.shared
    let original = "Office fi fl\nSecond line\n"
    let document = NoteDocument(note: Note(id: "typography", url: URL(filePath: "/unused.md")),
                                contents: NoteContents(data: Data(original.utf8), text: original, fileID: "typography")) {
        _, _, _ in throw CocoaError(.fileWriteUnknown)
    }
    let editor = document.editor.textView
    editor.undoManager?.groupsByEvent = false
    editor.textSelection = NSRange(location: 3, length: 0)
    document.editor.setFont(name: "Helvetica-BoldOblique", size: 18.5)
    document.editor.setTypography(lineHeight: 1.8, ligatures: false)
    #expect(editor.font.fontName == "Helvetica-BoldOblique")
    #expect(editor.font.pointSize == 18.5)
    #expect(editor.textSelection == NSRange(location: 3, length: 0))
    #expect(document.text == original)
    #expect(!document.isModified)
    let storage = try #require((editor.textContentManager as? NSTextContentStorage)?.textStorage)
    for offset in [0, storage.length - 1] {
        #expect((storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1.8)
        #expect(storage.attribute(.ligature, at: offset, effectiveRange: nil) as? Int == 0)
    }
    editor.textSelection = NSRange(location: 0, length: 0)
    editor.insertText("ffi", replacementRange: NSRange(location: 0, length: 0))
    #expect(storage.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == 0)
    #expect((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1.8)
    editor.undoManager?.undo()
    #expect(document.text == original)
    #expect(!document.isModified)
    document.editor.setTypography(lineHeight: 1, ligatures: true)
    #expect(storage.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == 1)
    #expect((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1)
}

@Test @MainActor func emptyEditorKeepsTypographyAfterMovingTheCaret() throws {
    _ = NSApplication.shared
    let document = NoteDocument(note: Note(id: "empty-typography", url: URL(filePath: "/unused.md")),
                                contents: NoteContents(data: Data(), text: "", fileID: "empty-typography")) {
        _, _, _ in throw CocoaError(.fileWriteUnknown)
    }
    document.editor.setTypography(lineHeight: 2, ligatures: false)
    let editor = document.editor.textView
    editor.textSelection = NSRange(location: 0, length: 0)
    editor.insertText("ffi", replacementRange: NSRange(location: 0, length: 0))
    let storage = try #require((editor.textContentManager as? NSTextContentStorage)?.textStorage)
    #expect(storage.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == 0)
    #expect((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 2)
    #expect(EditorFont.clampedLineHeight(.nan) == 1)
    #expect(EditorFont.clampedLineHeight(0) == 1)
    #expect(EditorFont.clampedLineHeight(100) == 3)
    #expect(EditorFont.clampedSize(.infinity) == 14)
}

extension AppKitWindowTests {
    @Test @MainActor func settingsFontPickerOpensNativePanelAndPersistsSelection() async throws {
        _ = NSApplication.shared
        let suite = "HanshiTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Monaco", forKey: EditorFont.familyKey)
        defaults.set(12, forKey: EditorFont.sizeKey)
        let host = NSHostingView(rootView: EditorSettingsView().defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func findButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Select…" { return button }
            return view.subviews.lazy.compactMap { findButton(in: $0) }.first
        }
        let button = try #require(findButton(in: host))
        #expect(button.visibleRect.width >= 60)
        #expect(button.visibleRect.height >= 20)
        func findSizeField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.stringValue == "12" { return field }
            return view.subviews.lazy.compactMap { findSizeField(in: $0) }.first
        }
        let sizeField = try #require(findSizeField(in: host))
        let buttonFrame = button.convert(button.bounds, to: host)
        let sizeFrame = sizeField.convert(sizeField.bounds, to: host)
        #expect(abs(buttonFrame.midY - sizeFrame.midY) <= 2, "Font size and selection button must share one row")
        let manager = NSFontManager.shared
        let previousTarget = manager.target
        let previousFont = manager.selectedFont
        defer {
            NSFontPanel.shared.orderOut(nil)
            manager.target = previousTarget
            if let previousFont { manager.setSelectedFont(previousFont, isMultiple: false) }
        }
        button.performClick(nil)
        #expect(NSFontPanel.shared.isVisible)
        #expect(manager.selectedFont?.fontName == "Monaco")
        let selected = try #require(NSFont(name: "Helvetica-BoldOblique", size: 18.5))
        NSFontPanel.shared.setPanelFont(selected, isMultiple: false)
        manager.modifyFontViaPanel(NSFontPanel.shared)
        #expect(defaults.string(forKey: EditorFont.nameKey) == "Helvetica-BoldOblique")
        #expect(defaults.double(forKey: EditorFont.sizeKey) == 18.5)
    }
}

extension AppKitWindowTests {
    @Test @MainActor func textEditingSettingsReachTheEditor() throws {
        _ = NSApplication.shared
        let document = NoteDocument(note: Note(id: "editing", url: URL(filePath: "/unused.md")),
                                    contents: NoteContents(data: Data(), text: "", fileID: "editing")) { _, _, _ in
            NoteContents(data: Data(), text: "", fileID: "editing")
        }
        let session = document.editor
        let editor = session.textView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()

        session.setGutter(false)
        #expect(editor.showsLineNumbers == false)
        session.setGutter(true)
        #expect(editor.showsLineNumbers)
        #expect(editor.gutterView != nil, "the gutter must come back with its own font")

        // A tab is as wide as `width` spaces in the editor's font, and follows the font.
        session.setFont(size: 14)
        session.setIndentation(width: 4, usesTabs: false)
        let space = (" " as NSString).size(withAttributes: [.font: editor.font]).width
        #expect(abs(editor.defaultParagraphStyle.defaultTabInterval - space * 4) < 0.01)
        #expect(editor.defaultParagraphStyle.tabStops.isEmpty)
        session.setIndentation(width: 8, usesTabs: false)
        #expect(abs(editor.defaultParagraphStyle.defaultTabInterval - space * 8) < 0.01)
        session.setFont(size: 28)
        let wideSpace = (" " as NSString).size(withAttributes: [.font: editor.font]).width
        #expect(abs(editor.defaultParagraphStyle.defaultTabInterval - wideSpace * 8) < 0.01)
        #expect(wideSpace > space)

        // Tab inserts spaces or a tab character, as Settings asks.
        session.setIndentation(width: 3, usesTabs: false)
        editor.insertTab(nil)
        #expect(editor.text == "   ")
        session.setIndentation(width: 3, usesTabs: true)
        editor.insertTab(nil)
        #expect(editor.text == "   \t")

        // The text always wraps, so a horizontal scroller would only take up room.
        #expect(session.scrollView.hasHorizontalScroller == false)
    }
}

@Test @MainActor func editingSettingsClampAndFallBackToTheirDefaults() {
    #expect(EditorFont.clampedTabWidth(0) == 1)
    #expect(EditorFont.clampedTabWidth(99) == 8)
    #expect(EditorFont.clampedTabWidth(4) == 4)
}

@Test @MainActor func letterSpacingAndInvisibleCharactersFollowTheirSettings() throws {
    _ = NSApplication.shared
    let original = "Office fi fl\n"
    let document = NoteDocument(note: Note(id: "spacing", url: URL(filePath: "/unused.md")),
                                contents: NoteContents(data: Data(original.utf8), text: original, fileID: "spacing")) {
        _, _, _ in throw CocoaError(.fileWriteUnknown)
    }
    let session = document.editor
    let editor = session.textView
    let storage = try #require((editor.textContentManager as? NSTextContentStorage)?.textStorage)
    let space = (" " as NSString).size(withAttributes: [.font: editor.font]).width

    session.setTypography(lineHeight: 1, ligatures: true, letterSpacing: 1)
    #expect(storage.attribute(.kern, at: 0, effectiveRange: nil) as? Double == 0)

    // Spacing is a multiple of the font's space, so it survives a font change.
    session.setTypography(lineHeight: 1, ligatures: true, letterSpacing: 1.5)
    let kern = try #require(storage.attribute(.kern, at: 0, effectiveRange: nil) as? Double)
    #expect(abs(kern - space * 0.5) < 0.01)
    editor.insertText("ffi", replacementRange: NSRange(location: 0, length: 0))
    let typed = try #require(storage.attribute(.kern, at: 0, effectiveRange: nil) as? Double)
    #expect(abs(typed - space * 0.5) < 0.01, "text typed after the change keeps the spacing")
    #expect(document.text == "ffi" + original)

    // Out-of-range values are clamped instead of stretching the text arbitrarily.
    session.setTypography(lineHeight: 1, ligatures: true, letterSpacing: 99)
    let clamped = try #require(storage.attribute(.kern, at: 0, effectiveRange: nil) as? Double)
    #expect(abs(clamped - space * (EditorFont.letterSpacingRange.upperBound - 1)) < 0.01)
    #expect(EditorFont.clampedLetterSpacing(.nan) == 1)
    #expect(EditorFont.clampedLetterSpacing(0) == EditorFont.letterSpacingRange.lowerBound)

    #expect(editor.showsInvisibleCharacters == false)
    session.setInvisibles(true)
    #expect(editor.showsInvisibleCharacters)
    session.setInvisibles(false)
    #expect(editor.showsInvisibleCharacters == false)
}
