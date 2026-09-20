import AppKit
import Testing
import EditorSyntax
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
        let original = try #require(EditorResources.bundle.resourceURL).appendingPathComponent("Syntax").appendingPathComponent(language.name.replacingOccurrences(of: "_", with: ""))
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
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("😀 ", replacementRange: NSRange(location: 2, length: 0))
    editor.undoManager?.endUndoGrouping()
    #expect(document.text == "# 😀 Original\n")
    #expect(document.isModified)
    let selection = editor.selectedRange()
    let firstContainer = NSView()
    firstContainer.addSubview(session.scrollView)
    session.scrollView.removeFromSuperview()
    let secondContainer = NSView()
    secondContainer.addSubview(session.scrollView)
    session.synchronize(document.text)
    #expect(document.editor === session)
    #expect(editor.selectedRange() == selection)
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

extension AppKitWindowTests {
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
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("# Temporary\n", replacementRange: NSRange(location: 0, length: source.utf16.count))
        editor.undoManager?.endUndoGrouping()
        let finalSource = "# Final 😀\n\n```swift\n// comment\nlet value = 42\n```\n"
        editor.undoManager?.beginUndoGrouping()
        editor.insertText(finalSource, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.undoManager?.endUndoGrouping()
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
}

@MainActor private func foregroundColor(in editor: NSTextView, at offset: Int) -> NSColor? {
    guard offset >= 0, offset < (editor.textStorage?.length ?? 0) else { return nil }
    return editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
}

extension AppKitWindowTests {
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
        try #require((editor.textFrame(at: source.utf16.count)?.maxY ?? 0) < clip.bounds.maxY - 40)

        for x in [10.0, clip.bounds.midX, clip.bounds.maxX - 10] {
            window.makeFirstResponder(nil)
            editor.setSelectedRange(NSRange(location: 0, length: min(2, source.utf16.count)))
            let location = clip.convert(NSPoint(x: x, y: clip.bounds.maxY - 20), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let hit = try #require(scrollView.hitTest(parent.convert(location, from: nil)))
            try clickEditor(hit, event: event)
            #expect(window.firstResponder === editor)
            #expect(editor.selectedRange() == NSRange(location: source.utf16.count, length: 0))
            #expect(document.text == source)
            #expect(!document.isModified)
        }

        // Clicking the first text line must still use the editor's normal caret placement.
        if !source.isEmpty, !source.hasPrefix("\n") {
            let location = editor.convert(NSPoint(x: editor.textContainerOrigin.x + 2, y: 5), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let hit = try #require(scrollView.hitTest(parent.convert(location, from: nil)))
            try clickEditor(hit, event: event)
            #expect(editor.selectedRange().location < "First line".utf16.count)
        }
    }
}

// Native tracking needs a mouse-up and may stop its run loop. Isolate it from Swift's async-main loop.
@MainActor private func clickEditor(_ view: NSView, event: NSEvent) throws {
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow,
        modifierFlags: [], timestamp: event.timestamp + 0.01, windowNumber: event.windowNumber,
        context: nil, eventNumber: event.eventNumber + 1, clickCount: 1, pressure: 0))
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        MainActor.assumeIsolated {
            NSApplication.shared.postEvent(up, atStart: true)
            view.mouseDown(with: event)
            NSApplication.shared.discardEvents(matching: .leftMouseUp, before: nil)
        }
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
}

@Test @MainActor func aNewNotesCursorWaitsAtTheEndOfItsHeading() throws {
    _ = NSApplication.shared
    func document(_ text: String) -> NoteDocument {
        NoteDocument(note: Note(id: text, url: URL(filePath: "/unused.md")),
                     contents: NoteContents(data: Data(text.utf8), text: text, fileID: text)) { _, _, _ in
            NoteContents(data: Data(), text: "", fileID: text)
        }
    }
    // "# Note|\n": typing replaces nothing and continues the title.
    #expect(document(NoteTitle.template).editor.textView.selectedRange() == NSRange(location: 6, length: 0))
    for text in ["", "# Note\nwritten already\n", "written already\n"] {
        #expect(document(text).editor.textView.selectedRange() == NSRange(location: 0, length: 0),
                "an edited note should open at its start, not mid-text")
    }
}

@Test @MainActor func everySyntaxThemePaintsTheSameTokensAsTheSystemOne() {
    let expected = Set(SyntaxTheme.system.colors.keys)
    #expect(expected.contains("keyword") && expected.contains("text.title"))
    for theme in SyntaxTheme.allCases {
        #expect(Set(theme.colors.keys) == expected, "\(theme.name) covers different tokens")
        #expect(theme.swatch.count == 8, "\(theme.name) shows \(theme.swatch.count) swatch colors")
        #expect(!theme.name.isEmpty)
    }
    // The editor's original colors are the System theme; changing them is a visible regression.
    #expect(SyntaxTheme.system.colors["text.title"] == .systemBlue)
    #expect(SyntaxTheme.system.colors["keyword"] == .systemPurple)
    #expect(SyntaxTheme.system.colors["string"] == .systemRed)
    #expect(SyntaxTheme.system.colors["comment"] == .secondaryLabelColor)
    #expect(SyntaxTheme(rawValue: "not a theme") == nil)
}

extension AppKitWindowTests {
    @Test @MainActor func switchingTheSyntaxThemeRecolorsAnOpenNote() async throws {
        _ = NSApplication.shared
        let library = TestLibrary()
        let source = "# Heading\n\n```swift\nlet message = \"Hello\"\nmessage.hasPrefix(\"H\")\n```\n"
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
        let heading = (source as NSString).range(of: "Heading").location
        let keyword = (source as NSString).range(of: "let").location
        try await until { foregroundColor(in: editor, at: heading) == .systemBlue }

        // No theme spells out "function.call": it has to resolve through "function".
        let call = (source as NSString).range(of: "hasPrefix").location
        #expect(foregroundColor(in: editor, at: call) == SyntaxTheme.system.colors["function"])

        document.editor.setSyntaxTheme(.solarized)
        try await until { foregroundColor(in: editor, at: heading) == SyntaxTheme.solarized.colors["text.title"] }
        #expect(foregroundColor(in: editor, at: keyword) == SyntaxTheme.solarized.colors["keyword"])
        #expect(foregroundColor(in: editor, at: call) == SyntaxTheme.solarized.colors["function"])
        #expect(document.text == source)
        #expect(!document.isModified)
        #expect(editor.undoManager?.canUndo == false)

        // Editing after the switch keeps painting with the chosen theme.
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("# Other\n", replacementRange: NSRange(location: 0, length: (source as NSString).range(of: "\n").location + 1))
        editor.undoManager?.endUndoGrouping()
        try await until { foregroundColor(in: editor, at: 2) == SyntaxTheme.solarized.colors["text.title"] }

        document.editor.setSyntaxTheme(.system)
        try await until { foregroundColor(in: editor, at: 2) == .systemBlue }
    }
}

@MainActor private func until(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition(), sourceLocation: sourceLocation)
}

@Test @MainActor func everyCaptureTheParserProducesGetsAColor() throws {
    // Markdown the parser captures widely: front matter, headings, links, HTML, embedded code.
    let source = """
    ---
    title: "Example"
    tags: [a, b]
    ---
    # Heading *emphasis* and **strong**

    Text with `inline code`, a [link](https://example.com), an ![image](pic.png) and <br />.

    > A quote
    - list item
    1. numbered

    <div class="note" id="x">html</div>

    | a | b |
    | - | - |
    | 1 | 2 |

    ```swift
    // comment
    struct Value { let number = 42.0 }
    func run(name: String) -> Bool { name.isEmpty }
    ```

    ```json
    {"key": true, "list": [1, "two\\n"]}
    ```
    """
    let configuration = try #require(SyntaxResources.configuration(for: .markdown))
    let client = try TreeSitterClient(languageConfiguration: configuration,
                                      languageProvider: SyntaxResources.languageProvider(named:))
    // Two captures are deliberately left unpainted, so that whatever encloses them keeps its color:
    // "spell" spans whole paragraphs and code blocks for the spell checker, and "none" is the plain
    // run inside a construct — inside a fenced block that run is the block's own body.
    let unpainted = ["spell", "nospell", "none"]
    let names = Set(try client.resetDocument(content: source).map(\.name)).subtracting(unpainted)
    #expect(names.count > 15, "the parser captured only \(names.count) kinds of token: \(names.sorted())")
    for theme in SyntaxTheme.allCases {
        let colors = theme.colors
        let uncolored = names.filter { SyntaxTheme.color(for: $0, in: colors) == nil }
        #expect(uncolored.isEmpty, "\(theme.name) leaves \(uncolored.sorted()) uncolored")
    }
    // Names the queries may add later resolve through their parent instead of losing their color.
    let colors = SyntaxTheme.system.colors
    #expect(SyntaxTheme.color(for: "text.title.1", in: colors) == colors["text.title"])
    #expect(SyntaxTheme.color(for: "function.method.static", in: colors) == colors["function"])
    #expect(SyntaxTheme.color(for: "unheard.of", in: colors) == nil)
}

extension AppKitWindowTests {
    @Test @MainActor func fencedBlocksKeepTheirOwnColorAndThemesBringTheirPageColor() async throws {
        _ = NSApplication.shared
        let library = TestLibrary()
        let source = "```\n# fenced\n```\n\n# outside\n"
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
        let inside = (source as NSString).range(of: "fenced").location
        let outside = (source as NSString).range(of: "outside").location
        try await until { foregroundColor(in: editor, at: outside) == SyntaxTheme.system.colors["text.title"] }
        // The block's own color must survive: its contents are captured as "none" over the literal.
        #expect(foregroundColor(in: editor, at: inside) == SyntaxTheme.system.colors["text.literal"])
        #expect(foregroundColor(in: editor, at: inside) != SyntaxTheme.system.colors["text.title"])

        #expect(editor.backgroundColor == .textBackgroundColor)
        document.editor.setSyntaxTheme(.solarized)
        #expect(editor.backgroundColor == SyntaxTheme.solarized.background)
        #expect(SyntaxTheme.solarized.background != nil)
        #expect(SyntaxTheme.system.background == nil, "the System theme follows the window's own background")
        document.editor.setSyntaxTheme(.system)
        #expect(editor.backgroundColor == .textBackgroundColor)
    }
}

@Test @MainActor func autosaveKeepsSavingWhileTypingWithoutPauses() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let files = library.files
    let document = NoteDocument(note: note, contents: try await files.readNote(at: note.url),
                                autosave: { .milliseconds(200) }) {
        try await files.saveNote(at: $0, text: $1, expected: $2)
    }
    // Typing on, never pausing for anything close to the interval. The loop ends when the note
    // reaches the disk by itself; a debounce would restart on every keystroke and run to the cap.
    var typed = ""
    var written = "original"
    var keystrokes = 0
    while written == "original", keystrokes < 600 {
        keystrokes += 1
        typed += "x"
        document.edit(typed)
        try await Task.sleep(for: .milliseconds(1))
        written = try String(contentsOf: note.url, encoding: .utf8)
    }
    #expect(written != "original", "autosave must reach the disk while the typing goes on")
    #expect(typed.hasPrefix(written), "a save must write a state the note actually passed through")
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while document.isModified, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == typed)
    #expect(!document.isModified)
}

@Test @MainActor func autosaveLeavesTheNoteAloneWhenItIsOff() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let files = library.files
    let document = NoteDocument(note: note, contents: try await files.readNote(at: note.url),
                                autosave: { nil }) {
        try await files.saveNote(at: $0, text: $1, expected: $2)
    }
    document.edit("draft")
    try await Task.sleep(for: .milliseconds(120))
    #expect(document.isModified)
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "original")
    #expect(await document.save())
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "draft")
}

@Test func autosaveSettingsDecideTheInterval() throws {
    let preferences = TestPreferences(); defer { preferences.remove() }
    #expect(Autosave.interval(in: preferences.defaults) == .seconds(60))
    preferences.defaults.set(15, forKey: Autosave.secondsKey)
    #expect(Autosave.interval(in: preferences.defaults) == .seconds(15))
    preferences.defaults.set(0, forKey: Autosave.secondsKey)
    #expect(Autosave.interval(in: preferences.defaults) == .seconds(Autosave.secondsRange.lowerBound))
    preferences.defaults.set(99_999, forKey: Autosave.secondsKey)
    #expect(Autosave.interval(in: preferences.defaults) == .seconds(Autosave.secondsRange.upperBound))
    preferences.defaults.set(false, forKey: Autosave.enabledKey)
    #expect(Autosave.interval(in: preferences.defaults) == nil)
}

@Test @MainActor func leavingTheAppSavesEveryOpenNote() async throws {
    let library = TestLibrary()
    _ = try await library.note("# First\n")
    let files = library.files
    let folder = try await files.createNotebook(named: "More")
    try Data("# Second\n".utf8).write(to: folder.appendingPathComponent("Second.md"))
    let store = NoteStore(root: library.root)
    await store.refresh()
    for note in store.notes { await store.open(note) }
    #expect(store.documents.count == 2)
    for document in store.documents.values { document.edit(document.text + "\nEdited.\n") }
    #expect(store.hasUnsavedChanges)

    let lifecycle = LibraryLifecycle()
    lifecycle.store = store
    lifecycle.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.hasUnsavedChanges, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!store.hasUnsavedChanges)
    for document in store.documents.values {
        #expect(try String(contentsOf: document.url, encoding: .utf8).hasSuffix("\nEdited.\n"))
    }
}
