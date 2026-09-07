import Foundation
import Testing
@testable import Hanshi

@Test @MainActor func renamingAnOpenNotePreservesItsDraftIdentityAndUndo() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let store = NoteStore(root: library.root)
    await store.refresh()
    await store.open(note)
    let document = try #require(store.documents[note.id])
    let editor = document.editor.textView
    editor.undoManager?.groupsByEvent = false
    editor.insertText("draft 😀 ", replacementRange: NSRange(location: 0, length: 0))
    let selection = editor.textSelection
    #expect(await store.rename(note, to: "  Renamed café  "))
    #expect(document.url.lastPathComponent == "Renamed café.md")
    #expect(store.notes.first?.id == note.id)
    #expect(store.documents[note.id] === document)
    #expect(!FileManager.default.fileExists(atPath: note.url.path))
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "original")
    #expect(document.text == "draft 😀 original")
    #expect(document.isModified)
    #expect(editor.textSelection == selection)
    #expect(editor.undoManager?.canUndo == true)
    #expect(await document.save())
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "draft 😀 original")
    editor.undoManager?.undo()
    #expect(document.text == "original")
    #expect(await store.rename(try #require(store.notes.first), to: "renamed café.MD"))
    #expect(document.url.lastPathComponent == "renamed café.MD")
}

@Test(arguments: ["", "../escape", ".hidden", "folder/note", "a:b", "a\nb", ".md"])
func renamingRejectsInvalidNamesWithoutChangingTheNote(name: String) async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    #expect(throws: LibraryError.invalidName) { try library.files.renameNote(at: note.url, to: name) }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "keep")
    #expect(try await library.files.load().flatMap(\.notes).count == 1)
}

@Test @MainActor func renamingNeverOverwritesAnExistingNoteAndReportsFailures() async throws {
    let library = TestLibrary()
    let note = try await library.note("first")
    let other = note.url.deletingLastPathComponent().appendingPathComponent("Other.md")
    try Data("second".utf8).write(to: other)
    let store = NoteStore(root: library.root)
    await store.refresh()
    await store.open(note)
    let document = try #require(store.documents[note.id])
    #expect(await store.rename(note, to: "Other.md") == false)
    #expect(store.errorMessage != nil)
    #expect(document.url == note.url)
    #expect(try String(contentsOf: other, encoding: .utf8) == "second")
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "first")
    #expect(await store.rename(note, to: note.name))
    try FileManager.default.removeItem(at: note.url)
    #expect(await store.rename(note, to: "Missing") == false)
    #expect(store.documents[note.id] === document)
}

@Test func trashingUsesTheSystemTrashAndPreservesFileContents() async throws {
    let library = TestLibrary()
    let note = try await library.note("Recoverable 😀")
    let trashed = try #require(try library.files.trashNote(at: note.url))
    defer { try? FileManager.default.removeItem(at: trashed) }
    #expect(!FileManager.default.fileExists(atPath: note.url.path))
    #expect(try String(contentsOf: trashed, encoding: .utf8) == "Recoverable 😀")
    #expect(try await library.files.load().flatMap(\.notes).isEmpty)
    #expect(throws: (any Error).self) { try library.files.trashNote(at: note.url) }
}

@Test @MainActor func trashingSavesPendingChangesAndClosesOnlyTheTargetNote() async throws {
    let library = TestLibrary()
    let created = try await library.note("original")
    let url = try library.files.renameNote(at: created.url, to: UUID().uuidString)
    let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
        .appendingPathComponent(url.lastPathComponent)
    try #require(!FileManager.default.fileExists(atPath: trash.path))
    defer { try? FileManager.default.removeItem(at: trash) }
    let otherURL = try await library.files.createNote(in: url.deletingLastPathComponent())
    let store = NoteStore(root: library.root)
    await store.refresh()
    let note = try #require(store.notes.first { $0.url == url })
    let other = try #require(store.notes.first { $0.url == otherURL })
    await store.open(note)
    await store.open(other)
    let otherDocument = try #require(store.documents[other.id])
    let document = try #require(store.documents[note.id])
    document.edit("pending 😀")
    #expect(await store.trash(note))
    #expect(store.notes.map(\.url) == [otherURL])
    #expect(store.documents[note.id] == nil)
    #expect(store.documents[other.id] === otherDocument)
    #expect(!store.hasUnsavedChanges)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try String(contentsOf: trash, encoding: .utf8) == "pending 😀")
}

@Test @MainActor func failedSavePreventsTrashingAndKeepsTheDraft() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    let store = NoteStore(root: library.root)
    await store.refresh()
    await store.open(note)
    let document = try #require(store.documents[note.id])
    document.edit("draft")
    try Data("external".utf8).write(to: note.url)
    #expect(await store.trash(note) == false)
    #expect(store.documents[note.id] === document)
    #expect(store.notes.first?.id == note.id)
    #expect(store.errorMessage != nil)
    #expect(document.text == "draft")
    #expect(document.isModified)
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "external")
}

@Test func fileActionsRejectPathsOutsideTheLibraryAndSymbolicLinks() async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    let alias = note.url.deletingLastPathComponent().appendingPathComponent("alias.md")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: note.url)
    let outside = library.root.appendingPathComponent("outside.md")
    try Data("outside".utf8).write(to: outside)
    for url in [alias, outside] {
        #expect(throws: LibraryError.invalidNote) { try library.files.renameNote(at: url, to: "renamed") }
        #expect(throws: LibraryError.invalidNote) { try library.files.trashNote(at: url) }
    }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
}

@Test(arguments: [("# Título\ntexto", "Título"), ("texto\n# Título", nil), ("#Título", nil),
                  ("# \n", nil), ("# a/b:c", "a-b-c"), ("# .oculta. ", "oculta"),
                  ("# " + String(repeating: "x", count: 200), String(repeating: "x", count: 100))])
func headingNamesAreSafeToPutOnDisk(text: String, expected: String?) {
    #expect(NoteTitle.filename(for: text) == expected)
}

@Test @MainActor func newNotesFollowTheirHeadingUntilTheFileIsRenamedByHand() async throws {
    let library = TestLibrary()
    _ = try await library.files.load()
    let folder = try await library.files.createNotebook(named: "Notes")
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = true
    await store.refresh()
    // A temporary directory is reached through a symbolic link: the new note must still be found.
    let id = try #require(await store.createNote(in: folder))
    let note = try #require(store.notes.first { $0.id == id })
    #expect(note.name == "Note")
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "# Note\n")
    await store.open(note)
    let document = try #require(store.documents[id])
    document.edit("# Recetas / pan: 😀\nprimera línea\n")
    #expect(await document.save())
    #expect(document.url.lastPathComponent == "Recetas - pan- 😀.md")
    #expect(store.notes.first { $0.id == id }?.name == "Recetas - pan- 😀")
    #expect(!FileManager.default.fileExists(atPath: note.url.path))
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "# Recetas / pan: 😀\nprimera línea\n")
    // Renaming the file by hand unhooks it: the heading stops moving it.
    #expect(await store.rename(try #require(store.notes.first { $0.id == id }), to: "cocina"))
    document.edit("# Otra cosa\n")
    #expect(await document.save())
    #expect(document.url.lastPathComponent == "cocina.md")
    #expect(store.notes.first { $0.id == id }?.name == "cocina")
    #expect(store.errorMessage == nil)
}

@Test @MainActor func headingRenamesSidestepNamesAlreadyTakenInTheNotebook() async throws {
    let library = TestLibrary()
    _ = try await library.files.load()
    let folder = try await library.files.createNotebook(named: "Notes")
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = true
    await store.refresh()
    let first = try #require(await store.createNote(in: folder))
    let second = try #require(await store.createNote(in: folder))
    #expect(store.notes.first { $0.id == second }?.name == "Note (1)")
    for id in [first, second] { await store.open(try #require(store.notes.first { $0.id == id })) }
    for id in [first, second] {
        let document = try #require(store.documents[id])
        document.edit("# Recetas\n")
        #expect(await document.save())
    }
    #expect(store.documents[first]?.url.lastPathComponent == "Recetas.md")
    #expect(store.documents[second]?.url.lastPathComponent == "Recetas (1).md")
    #expect(store.errorMessage == nil)
    #expect(try await library.files.load().flatMap(\.notes).map(\.name).sorted() == ["Recetas", "Recetas (1)"])
}

@Test @MainActor func withTheTemplateOffNewNotesAreBlankAndKeepTheirName() async throws {
    let library = TestLibrary()
    _ = try await library.files.load()
    let folder = try await library.files.createNotebook(named: "Notes")
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = false
    await store.refresh()
    let id = try #require(await store.createNote(in: folder))
    let note = try #require(store.notes.first { $0.id == id })
    #expect(try Data(contentsOf: note.url).isEmpty)
    await store.open(note)
    let document = try #require(store.documents[id])
    document.edit("# Recetas\n")
    #expect(await document.save())
    #expect(document.url.lastPathComponent == "Note.md")
    #expect(store.notes.first { $0.id == id }?.name == "Note")
}
