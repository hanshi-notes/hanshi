import AppKit
import Testing
import STTextView
import STPluginTreeSitterCore
import TreeSitterResource
@testable import Hanshi

final class TestLibrary: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var files: LibraryFiles { LibraryFiles(root: root) }

    func note(_ text: String) async throws -> Note {
        _ = try await files.load()
        let folder = try await files.createNotebook(named: "Notes")
        let url = try await files.createNote(in: folder)
        try Data(text.utf8).write(to: url)
        return try #require(try await files.load().first?.notes.first)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Test func syntaxQueriesLoadFromPackagedResources() throws {
    let library = TestLibrary()
    let resources = library.root.appendingPathComponent("Resources")
    let syntax = resources.appendingPathComponent("Syntax")
    try FileManager.default.createDirectory(at: syntax, withIntermediateDirectories: true)
    for language in [TreeSitterLanguage.markdown, .markdownInline, .swift, .yaml] {
        let original = try #require(language.queryDirectoryURL)
        try FileManager.default.copyItem(at: original, to: syntax.appendingPathComponent(language.name.replacingOccurrences(of: "_", with: "")))
    }
    let configuration = try #require(SyntaxResources.configuration(for: .markdown, resources: resources))
    let client = try TreeSitterClient(languageConfiguration: configuration, languageProvider: { name in
        TreeSitterLanguage.injectedLanguage(named: name).flatMap {
            SyntaxResources.configuration(for: $0, resources: resources)
        }
    })
    let tokens = try client.resetDocument(content: "# Title\n\n```swift\nlet value = 42\n```\n")
    #expect(tokens.contains { $0.name == "text.title" })
    #expect(tokens.contains { $0.name == "keyword" })
    #expect(tokens.contains { $0.name == "number" })
    #expect(SyntaxResources.configuration(for: .python, resources: resources) == nil)
}

@Test(arguments: ["", "# Title\n\n**Bold** and `code`\n", "---\r\ntitle: café 😀\r\n---\r\n日本語 e\u{301}\r\n"])
func markdownRoundTripsWithoutChangingItsSource(_ text: String) async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let original = try await library.files.readNote(at: note.url)
    let saved = try await library.files.saveNote(at: note.url, text: text, expected: original.data)
    #expect(saved.text == text)
    #expect(try Data(contentsOf: note.url) == Data(text.utf8))
    #expect(try await library.files.readNote(at: note.url).text == text)
}

@Test func savingRejectsExternalChangesAndKeepsBothVersions() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let original = try await library.files.readNote(at: note.url)
    try Data("external".utf8).write(to: note.url, options: .atomic)
    await #expect(throws: LibraryError.noteConflict) {
        try await library.files.saveNote(at: note.url, text: "local", expected: original.data)
    }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "external")
}

@Test func savingACopyPreservesTheDraftAndNeverOverwritesAnotherFile() async throws {
    let library = TestLibrary()
    let note = try await library.note("external version")
    let copy = note.url.deletingLastPathComponent().appendingPathComponent("copy.md")
    try await library.files.saveCopy(text: "local draft 😀", to: copy)
    #expect(try String(contentsOf: copy, encoding: .utf8) == "local draft 😀")
    await #expect(throws: (any Error).self) {
        try await library.files.saveCopy(text: "local draft", to: note.url)
    }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "external version")
}

@Test func readingAndSavingRejectInvalidFiles() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    try Data([0xFF, 0xFE, 0xFF]).write(to: note.url)
    await #expect(throws: LibraryError.invalidEncoding) { try await library.files.readNote(at: note.url) }
    #expect(try Data(contentsOf: note.url) == Data([0xFF, 0xFE, 0xFF]))
    let alias = note.url.deletingLastPathComponent().appendingPathComponent("alias.md")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: note.url)
    await #expect(throws: LibraryError.invalidNote) { try await library.files.readNote(at: alias) }
    await #expect(throws: LibraryError.invalidNote) {
        try await library.files.saveNote(at: alias, text: "replace", expected: Data([0xFF, 0xFE, 0xFF]))
    }
    let outside = library.root.appendingPathComponent("outside.md")
    try Data("outside".utf8).write(to: outside)
    await #expect(throws: LibraryError.invalidNote) { try await library.files.readNote(at: outside) }
    await #expect(throws: LibraryError.invalidNote) {
        try await library.files.saveNote(at: outside, text: "replace", expected: Data("outside".utf8))
    }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
}

@Test @MainActor func documentsKeepDraftsOnFailureAndCanRetry() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let files = library.files
    let document = NoteDocument(note: note, contents: try await files.readNote(at: note.url)) {
        try await files.saveNote(at: $0, text: $1, expected: $2)
    }
    document.edit("draft")
    try FileManager.default.removeItem(at: note.url)
    #expect(await document.save() == false)
    #expect(document.text == "draft")
    #expect(document.isModified)
    #expect(!document.isSaving)
    #expect(document.errorMessage != nil)
    try Data("original".utf8).write(to: note.url)
    #expect(await document.save())
    #expect(!document.isModified)
    #expect(document.errorMessage == nil)
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "draft")
}

private actor PausedWriter {
    var texts: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func write(_ url: URL, text: String, expected: Data) async -> NoteContents {
        texts.append(text)
        if texts.count == 1 {
            await withCheckedContinuation { continuation in
                resume = continuation
                started?.resume()
                started = nil
            }
        } else { #expect(expected == Data(texts[texts.count - 2].utf8)) }
        return NoteContents(data: Data(text.utf8), text: text, fileID: "saved")
    }

    func waitUntilWriting() async {
        if resume != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { resume?.resume(); resume = nil }
}

@Test @MainActor func concurrentSaveRequestsIncludeEditsMadeDuringWriting() async {
    let writer = PausedWriter()
    let document = NoteDocument(note: Note(id: "note", url: URL(filePath: "/unused.md")),
                                contents: NoteContents(data: Data(), text: "", fileID: "original")) {
        await writer.write($0, text: $1, expected: $2)
    }
    document.edit("first")
    let firstSave = Task { await document.save() }
    await writer.waitUntilWriting()
    #expect(document.isSaving)
    document.edit("second")
    let secondSave = Task { await document.save() }
    await writer.release()
    #expect(await firstSave.value)
    #expect(await secondSave.value)
    #expect(await writer.texts == ["first", "second"])
    #expect(document.saved.text == "second")
    #expect(!document.isModified)
}

@Test @MainActor func refreshingKeepsDocumentIdentityAcrossSaveAndRename() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let store = NoteStore(root: library.root)
    await store.refresh()
    await store.open(note)
    let document = try #require(store.documents[note.id])
    document.edit("edited")
    #expect(store.hasUnsavedChanges)
    #expect(await store.saveAll())
    await store.refresh()
    #expect(store.notes.first?.id == note.id)
    #expect(store.documents[note.id] === document)
    let renamed = note.url.deletingLastPathComponent().appendingPathComponent("renamed.md")
    try FileManager.default.moveItem(at: note.url, to: renamed)
    await store.refresh()
    #expect(store.notes.first?.id == note.id)
    #expect(document.url == renamed)
    document.edit("unsaved")
    try Data("external".utf8).write(to: renamed, options: .atomic)
    await store.refresh()
    #expect(document.text == "unsaved")
    #expect(await store.saveAll() == false)
    #expect(store.hasUnsavedChanges)
    await document.reload(using: library.files, discardChanges: true)
    #expect(document.text == "external")
    #expect(!store.hasUnsavedChanges)
    let reopened = NoteStore(root: library.root)
    await reopened.refresh()
    let reopenedNote = try #require(reopened.notes.first)
    await reopened.open(reopenedNote)
    #expect(reopened.documents[reopenedNote.id]?.text == "external")
}

@Test @MainActor func closingCanSaveCancelOrDiscardAndStopsOnSaveFailure() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let store = NoteStore(root: library.root)
    await store.open(note)
    let document = try #require(store.documents[note.id])
    document.edit("draft")
    #expect(await store.finishEditing(.cancel) == false)
    #expect(document.text == "draft")
    #expect(store.hasUnsavedChanges)
    try Data("external".utf8).write(to: note.url)
    #expect(await store.finishEditing(.save) == false)
    #expect(document.text == "draft")
    #expect(store.hasUnsavedChanges)
    #expect(await store.finishEditing(.discard))
    #expect(!store.hasUnsavedChanges)
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "external")
    await document.reload(using: library.files)
    document.edit("final")
    #expect(await store.finishEditing(.save))
    #expect(!store.hasUnsavedChanges)
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "final")
}

@Test @MainActor func editorChangesReachTheDocumentAndUndoSurvivesReattachment() async throws {
    _ = NSApplication.shared
    let library = TestLibrary()
    let note = try await library.note("# Original\n")
    let store = NoteStore(root: library.root)
    await store.open(note)
    let document = try #require(store.documents[note.id])
    let session = document.editor
    let editor = session.textView
    editor.undoManager?.groupsByEvent = false
    editor.insertText("😀 ", replacementRange: NSRange(location: 2, length: 0))
    #expect(document.text == "# 😀 Original\n")
    #expect(document.isModified)
    let selection = editor.textSelection
    let firstContainer = NSView()
    firstContainer.addSubview(session.scrollView)
    session.scrollView.removeFromSuperview()
    let secondContainer = NSView()
    secondContainer.addSubview(session.scrollView)
    session.synchronize(document.text)
    #expect(document.editor === session)
    #expect(editor.textSelection == selection)
    let undo = try #require(editor.undoManager)
    #expect(undo.canUndo)
    undo.undo()
    #expect(document.text == "# Original\n")
    #expect(!document.isModified)
    undo.redo()
    #expect(document.text == "# 😀 Original\n")
    #expect(await document.save())
    #expect(try String(contentsOf: note.url, encoding: .utf8) == document.text)
}

@Test @MainActor func editorColorsMarkdownAndEmbeddedLanguagesWithoutChangingText() async throws {
    _ = NSApplication.shared
    let library = TestLibrary()
    let source = "---\ntitle: \"Example\"\n---\n# Heading\n\n```swift\nlet message = \"Hello\"\n```\n"
    let note = try await library.note(source)
    let store = NoteStore(root: library.root)
    await store.open(note)
    let document = try #require(store.documents[note.id])
    let editor = document.editor.textView
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = document.editor.scrollView
    defer { window.contentView = nil; window.close() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while foregroundColor(in: editor, at: (source as NSString).range(of: "Heading").location) == nil,
          ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    for (token, expectedColor) in [("Heading", NSColor.systemBlue), ("let", .systemPurple), ("\"Hello\"", .systemRed), ("\"Example\"", .systemRed)] {
        let color = try #require(foregroundColor(in: editor, at: (source as NSString).range(of: token).location))
        #expect(color == expectedColor, "Color for \(token)")
    }
    #expect(document.text == source)
    #expect(!document.isModified)
    #expect(editor.undoManager?.canUndo == false)

    // Replace and edit again before earlier highlighting completes: only the final source may win.
    editor.undoManager?.groupsByEvent = false
    editor.insertText("# Temporary\n", replacementRange: NSRange(location: 0, length: source.utf16.count))
    let finalSource = "# Final 😀\n\n```swift\n// comment\nlet value = 42\n```\n"
    editor.insertText(finalSource, replacementRange: NSRange(location: 0, length: (editor.text ?? "").utf16.count))
    let commentOffset = (finalSource as NSString).range(of: "// comment").location
    let numberOffset = (finalSource as NSString).range(of: "42").location
    let finalDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while foregroundColor(in: editor, at: commentOffset) != .secondaryLabelColor
            || foregroundColor(in: editor, at: numberOffset) != .systemOrange {
        if ContinuousClock.now >= finalDeadline { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(foregroundColor(in: editor, at: commentOffset) == .secondaryLabelColor)
    #expect(foregroundColor(in: editor, at: numberOffset) == .systemOrange)
    #expect(document.text == finalSource)
    #expect(document.isModified)
}

@MainActor private func foregroundColor(in editor: STTextView, at offset: Int) -> NSColor? {
    guard let location = editor.textContentManager.location(editor.textContentManager.documentRange.location, offsetBy: offset) else { return nil }
    var color: NSColor?
    editor.textLayoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
        color = attributes[.foregroundColor] as? NSColor
        return false
    }
    return color
}

@Test(arguments: ["", "First line\nLast 😀 e\u{301}", "First line\nLast line\n", "\n\n"])
@MainActor func clickingBlankEditorSpaceFocusesTheEndOfTheDocument(source: String) throws {
    _ = NSApplication.shared
    let document = NoteDocument(note: Note(id: "click", url: URL(filePath: "/unused.md")),
                                contents: NoteContents(data: Data(source.utf8), text: source, fileID: "click")) {
        _, _, _ in throw CocoaError(.fileWriteUnknown)
    }
    let scrollView = document.editor.scrollView
    let editor = document.editor.textView
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    defer { window.contentView = nil; window.close() }
    scrollView.layoutSubtreeIfNeeded()
    editor.layoutSubtreeIfNeeded()
    let clip = scrollView.contentView
    let parent = try #require(scrollView.superview)
    try #require(editor.frame.maxY < clip.bounds.maxY - 40)

    for x in [10.0, clip.bounds.midX, clip.bounds.maxX - 10] {
        window.makeFirstResponder(nil)
        editor.textSelection = NSRange(location: 0, length: min(2, source.utf16.count))
        let location = clip.convert(NSPoint(x: x, y: clip.bounds.maxY - 20), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let hit = try #require(scrollView.hitTest(parent.convert(location, from: nil)))
        hit.mouseDown(with: event)
        #expect(window.firstResponder === editor)
        #expect(editor.textSelection == NSRange(location: source.utf16.count, length: 0))
        #expect(document.text == source)
        #expect(!document.isModified)
    }

    // Clicking the first text line must still use the editor's normal caret placement.
    if !source.isEmpty, !source.hasPrefix("\n") {
        let location = editor.convert(NSPoint(x: (editor.gutterView?.frame.width ?? 0) + 2, y: 5), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let hit = try #require(scrollView.hitTest(parent.convert(location, from: nil)))
        hit.mouseDown(with: event)
        #expect(editor.textSelection.location < "First line".utf16.count)
    }
}
