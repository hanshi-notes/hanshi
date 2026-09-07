import AppKit
import Testing
@testable import Hanshi

@Test @MainActor func previewCompositionBuildsFontsOnceAndWorksOffMainThread() async throws {
    let unit = "# Heading\n\nRegular **bold** *italic* ***both*** `code`.\n\n| A | B |\n|---|---|\n| One | Two |\n\n```\nlet value = 1\n```\n\n"
    let result = try await PreviewTestFixtures.composition(String(repeating: unit, count: 100))
    let onMain = result.composedOnMainThread
    #expect(!onMain)
    #expect(result.fontBuildCount < 32, "Font work must depend on styles, not document length")
    for (word, traits) in [("bold", NSFontDescriptor.SymbolicTraits.bold), ("italic", .italic), ("both", [.bold, .italic])] {
        let range = (result.text.string as NSString).range(of: word)
        let font = try #require(result.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(traits))
        #expect(abs(font.pointSize - PreviewTheme().bodySize) < 0.01)
    }
    // Transfer the disconnected tables and paragraph styles into a real TextKit layout.
    let session = MarkdownPreviewSession(debounce: .zero)
    session.textView.textStorage?.setAttributedString(result.text)
    let cell = (result.text.string as NSString).range(of: "One")
    let frame = try #require(session.frame(at: cell.location, length: cell.length))
    #expect(frame.width > 0 && frame.height > 0)
}

@Test @MainActor func previewCompositionRecordsExactResizableAttachmentRanges() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    try fixture.png(width: 1200, height: 600).write(to: fixture.root.appendingPathComponent("wide.png"))
    let snapshot = PreviewTestFixtures.snapshot("![Missing](missing.png)\n\n- [x] Done\n\n![Wide](wide.png)\n\n" + String(repeating: "**Text**. ", count: 100), root: fixture.root)
    let recipe = try await MarkdownRenderer.render(snapshot)
    let result = try await MarkdownRenderer.compose(recipe, theme: snapshot.theme)
    #expect(result.attachments.count == 1)
    #expect(result.attachmentRanges.count == result.attachments.count)
    for (range, attachment) in zip(result.attachmentRanges, result.attachments) {
        #expect(result.text.attribute(.attachment, at: range.location, effectiveRange: nil) as? PreviewAttachment === attachment)
        #expect((result.text.string as NSString).substring(with: range) == "\u{fffc}")
    }
}

@Test @MainActor func editorSnapshotIsNativeAndTracksTypingUndoAndDeferredReload() {
    let document = PreviewTestFixtures.document(String(repeating: "Text 😀 漢字. ", count: 100))
    let editor = document.editor
    #expect(editor.displayedText.isContiguousUTF8, "Scroll must not repeatedly transcode Cocoa storage")
    editor.textView.insertText("Changed", replacementRange: NSRange(location: 0, length: 4))
    #expect(editor.displayedText == document.text)
    #expect(editor.displayedText.isContiguousUTF8)
    editor.textView.undoManager?.undo()
    #expect(editor.displayedText == document.text)
    #expect(editor.displayedText.isContiguousUTF8)
    let previous = editor.displayedText
    document.edit(previous.replacingOccurrences(of: "Text", with: "Note"))
    #expect(editor.displayedText != document.text, "Same-length reloads must remain distinguishable until applied")
    editor.synchronize(document.text)
    #expect(editor.displayedText == document.text)
    #expect(editor.displayedText.isContiguousUTF8)
}

@Test @MainActor func previewCheckboxImagesAreSharedWithoutDroppingTasks() async throws {
    let result = try await PreviewTestFixtures.composition(String(repeating: "- [x] Done\n- [ ] Pending\n", count: 300))
    var identities: Set<ObjectIdentifier> = []
    var count = 0
    result.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.text.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment {
            identities.insert(ObjectIdentifier(attachment))
            count += 1
        }
    }
    #expect(count == 600)
    #expect(identities.count == 2, "Task lists need only the checked and unchecked symbol cells")
}
