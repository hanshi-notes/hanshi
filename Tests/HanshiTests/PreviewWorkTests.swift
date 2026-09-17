import AppKit
import Testing
@testable import Hanshi

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
