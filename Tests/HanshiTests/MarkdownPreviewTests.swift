import AppKit
import SwiftUI
import Testing
@testable import Hanshi

private actor PreviewRenderGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var arrival: CheckedContinuation<Void, Never>?
    private var started = 0
    func render(_ snapshot: PreviewSnapshot) async throws -> MarkdownRecipe {
        await withCheckedContinuation { continuation in
            continuations.append(continuation); started += 1
            arrival?.resume(); arrival = nil
        }
        // Deliberately ignore cancellation, as a synchronous native engine may finish late.
        return MarkdownRecipe(runs: [PreviewRun(text: snapshot.text)], anchors: [])
    }
    func waitForStart(_ count: Int) async {
        if started >= count { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func finish() { continuations.removeFirst().resume() }
    func count() -> Int { started }
}

@Test @MainActor func previewDropsOldRequestsAndOnlyKeepsLatestPendingSnapshot() async throws {
    let gate = PreviewRenderGate()
    let session = MarkdownPreviewSession(debounce: .zero) { snapshot, _ in try await gate.render(snapshot) }
    var snapshot = PreviewTestFixtures.snapshot("A")
    session.show(snapshot)
    await gate.waitForStart(1)
    snapshot = PreviewSnapshot(library: snapshot.library, documentID: snapshot.documentID, text: "B", url: snapshot.url, root: snapshot.root)
    session.show(snapshot)
    snapshot = PreviewSnapshot(library: snapshot.library, documentID: snapshot.documentID, text: "A", url: snapshot.url, root: snapshot.root)
    session.show(snapshot)
    await gate.finish()
    await gate.waitForStart(2)
    #expect(session.appliedSnapshot == nil, "The first A must not publish after A → B → A")
    #expect(await gate.count() == 2)
    await gate.finish()
    await session.waitForRendering()
    #expect(session.appliedSnapshot == snapshot)
    #expect(session.textView.string == "A")
    session.hide()
}

@Test @MainActor func previewRejectsEditsAfterCaptureAndHiddenResults() async throws {
    let gate = PreviewRenderGate()
    let session = MarkdownPreviewSession(debounce: .zero) { snapshot, _ in try await gate.render(snapshot) }
    let document = PreviewTestFixtures.document("A")
    let snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: document.text, url: document.url, root: document.url.deletingLastPathComponent())
    session.show(snapshot, document: document)
    await gate.waitForStart(1)
    document.edit("B")
    await gate.finish(); await session.waitForRendering()
    #expect(session.appliedSnapshot == nil)
    session.hide()
    document.edit("A")
    session.show(snapshot, document: document)
    await gate.waitForStart(2)
    session.hide()
    await gate.finish(); await session.waitForRendering()
    #expect(session.appliedSnapshot == nil)
    #expect(document.errorMessage == nil)
}

@Test @MainActor func previewRendersUnsavedDraftRefreshesResourcesAndRename() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    try fixture.png().write(to: fixture.root.appendingPathComponent("image.png"))
    let document = PreviewTestFixtures.document("Saved", root: fixture.root)
    document.edit("# Unsaved\n\n![local](image.png)")
    let session = MarkdownPreviewSession(debounce: .zero)
    var snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: document.text, url: document.url, root: fixture.root)
    session.show(snapshot, document: document); await session.waitForRendering()
    #expect(session.textView.string.contains("Unsaved"))
    #expect(document.isModified && document.saved.text == "Saved")
    #expect(previewImages(in: session.textView).first?.size.width == 20)
    try fixture.png(width: 40).write(to: fixture.root.appendingPathComponent("image.png"))
    snapshot.resources += 1
    session.show(snapshot, document: document); await session.waitForRendering()
    #expect(previewImages(in: session.textView).first?.size.width == 40)
    let subfolder = fixture.root.appendingPathComponent("subfolder")
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    try fixture.png(width: 60).write(to: subfolder.appendingPathComponent("image.png"))
    document.url = subfolder.appendingPathComponent("Renamed.md")
    snapshot = PreviewSnapshot(library: snapshot.library, documentID: document.id, text: document.text, url: document.url, root: fixture.root)
    session.show(snapshot, document: document); await session.waitForRendering()
    #expect(previewImages(in: session.textView).first?.size.width == 60)
    #expect(document.errorMessage == nil)
    session.hide()
}

@Test @MainActor func previewLinksAreExplicitAndBlockedSchemesNeverOpen() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    let snapshot = PreviewTestFixtures.snapshot("# Heading\n\n[web](https://example.com)\n")
    var opened: [URL] = []
    session.openExternal = { opened.append($0) }
    session.show(snapshot); await session.waitForRendering()
    #expect(opened.isEmpty)
    session.followLink("https://example.com")
    #expect(opened.map(\.absoluteString) == ["https://example.com"])
    session.followLink("javascript:alert(1)")
    #expect(opened.count == 1)
    #expect(session.message?.contains("not allowed") == true)
    session.followLink("#heading")
    session.hide()
    session.followLink("https://example.com/stale")
    #expect(opened.count == 1)
}

// Regression: the engine prefixed scheme-less targets with https://, so clicks bypassed followLink's routing.
@Test @MainActor func previewLinkClicksReachTheDestinationAsWritten() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    try Data("# Other\n".utf8).write(to: fixture.root.appendingPathComponent("Other.md"))
    let session = MarkdownPreviewSession(debounce: .zero)
    let snapshot = PreviewTestFixtures.snapshot("""
    # Heading

    [note](Other.md#part) [mail](mailto:a@b.com) [anchor](#heading) [web](https://example.com) [call](tel:911)
    """, root: fixture.root)
    var external: [String] = [], notes: [String] = []
    session.openExternal = { external.append($0.absoluteString) }
    session.openNote = { url, fragment in notes.append(url.lastPathComponent + "#" + (fragment ?? "")); return true }
    session.show(snapshot); await session.waitForRendering()
    func click(_ label: String) throws {
        let range = (session.textView.string as NSString).range(of: "[\(label)]")
        try #require(range.location != NSNotFound)
        let index = range.location + 1
        let link = try #require(session.textView.textStorage?.attribute(.link, at: index, effectiveRange: nil))
        #expect(session.engine.textView(session.textView, clickedOnLink: link, at: index))
    }
    for label in ["note", "mail", "anchor", "web"] {
        try click(label)
        #expect(session.message == nil, "\(label): \(session.message ?? "")")
    }
    #expect(notes == ["Other.md#part"])
    #expect(external == ["mailto:a@b.com", "https://example.com"])
    try click("call")
    #expect(session.message?.contains("not allowed") == true)
    #expect(external.count == 2)
    session.hide()
}

@Test @MainActor func previewSelectionCopyAndStyleChangesPreserveReadableContent() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    var snapshot = PreviewTestFixtures.snapshot("**Bold** and $x^2$\n\n| A | B |\n|---|---|\n| Tea | 2 |")
    session.show(snapshot); await session.waitForRendering()
    #expect(session.textView.textLayoutManager != nil)
    #expect(!session.textView.isEditable && session.textView.isSelectable)
    session.textView.setSelectedRange(NSRange(location: 0, length: session.textView.string.utf16.count))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(session.textView.writeSelection(to: pasteboard, types: [.string, .rtf]))
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.contains("**Bold** and $x^2$"))
    #expect(copied.contains("Tea"))
    let rtf = try #require(pasteboard.data(forType: .rtf))
    let richCopy = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    #expect(richCopy.string.contains("Bold and $x^2$"))
    let copiedFont = try #require(richCopy.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: copiedFont).contains(.boldFontMask))
    let selection = session.textView.selectedRange()
    snapshot.theme.bodySize = 18
    session.show(snapshot); await session.waitForRendering()
    #expect(session.textView.selectedRange() == selection)
    #expect(session.textView.accessibilityLabel() == "Markdown preview")
    session.hide()
}

extension AppKitWindowTests {
    @Test @MainActor func previewModeSwitchPreservesEditorUndoAndRedo() async throws {
        _ = NSApplication.shared
        let document = PreviewTestFixtures.document("Original")
        let session = MarkdownPreviewSession(debounce: .zero)
        let files = LibraryFiles(root: document.url.deletingLastPathComponent())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 550), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NoteEditorContentView(document: document, files: files, mode: .source, preview: session))
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { session.hide(); window.contentView = nil; window.close() }
        let editor = document.editor.textView
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping()
        editor.insertText(" changed", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        #expect(document.text == "Original changed")
        host.rootView = NoteEditorContentView(document: document, files: files, mode: .preview, preview: session)
        host.layoutSubtreeIfNeeded()
        await session.waitForRendering()
        host.rootView = NoteEditorContentView(document: document, files: files, mode: .split, preview: session)
        host.layoutSubtreeIfNeeded()
        #expect(document.editor.textView === editor)
        #expect(undo.canUndo)
        undo.undo()
        #expect(document.text == "Original")
        #expect(undo.canRedo)
        undo.redo()
        #expect(document.text == "Original changed")
    }
}

@Test @MainActor func previewRemountRereadsImagesWithoutATextChange() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("image.png")
    try fixture.png(width: 20).write(to: path)
    let snapshot = PreviewTestFixtures.snapshot("![image](image.png)", root: fixture.root)
    let session = MarkdownPreviewSession(debounce: .zero)
    session.show(snapshot); await session.waitForRendering()
    #expect(previewImages(in: session.textView).first?.size.width == 20)
    session.hide()
    try fixture.png(width: 40).write(to: path)
    session.show(snapshot); await session.waitForRendering()
    #expect(previewImages(in: session.textView).first?.size.width == 40)
    session.hide()
}

@MainActor func previewImages(in view: NSTextView) -> [NSImage] {
    guard let storage = view.textStorage else { return [] }
    var images: [NSImage] = []
    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
        for value in attributes.values {
            if let image = value as? NSImage, !images.contains(where: { $0 === image }) { images.append(image) }
        }
    }
    return images
}
