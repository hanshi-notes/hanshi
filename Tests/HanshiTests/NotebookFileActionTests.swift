import Foundation
import Testing
@testable import Hanshi

@Test @MainActor func renamingNotebookKeepsDraftsIdentityUndoAndAllContents() async throws {
    let library = TestLibrary()
    let first = try await library.note("original")
    let folder = first.url.deletingLastPathComponent()
    let secondURL = try await library.files.createNote(in: folder)
    let attachment = folder.appendingPathComponent("assets/image.bin")
    try FileManager.default.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0, 1, 2]).write(to: attachment)
    let store = NoteStore(root: library.root)
    await store.refresh()
    let notebook = try #require(store.notebooks.first)
    for note in notebook.notes { await store.open(note) }
    let document = try #require(store.documents[first.id])
    let editor = document.editor.textView
    editor.undoManager?.groupsByEvent = false
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("draft ", replacementRange: NSRange(location: 0, length: 0))
    editor.undoManager?.endUndoGrouping()
    let selection = editor.selectedRange()
    #expect(await store.rename(notebook, to: "  Renamed café 😀  "))
    let renamed = try #require(store.notebooks.first)
    #expect(renamed.name == "Renamed café 😀")
    #expect(renamed.id == notebook.id)
    #expect(Set(renamed.notes.map(\.id)) == Set(notebook.notes.map(\.id)))
    #expect(renamed.notes.allSatisfy { $0.notebookName == renamed.name })
    #expect(store.documents[first.id] === document)
    #expect(document.url == renamed.url.appendingPathComponent(first.url.lastPathComponent))
    #expect(editor.selectedRange() == selection)
    #expect(document.text == "draft original")
    #expect(document.isModified)
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "original")
    #expect(try Data(contentsOf: renamed.url.appendingPathComponent("assets/image.bin")) == Data([0, 1, 2]))
    #expect(FileManager.default.fileExists(atPath: renamed.url.appendingPathComponent(secondURL.lastPathComponent).path))
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(await document.save())
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "draft original")
    editor.undoManager?.undo()
    #expect(document.text == "original")
    #expect(await store.rename(renamed, to: renamed.name))
}

@Test(arguments: ["", " ", "../escape", ".hidden", "folder/name", "a:b", "a\nb"])
func notebookNamesRejectInvalidInput(name: String) async throws {
    let library = TestLibrary()
    _ = try await library.note("keep")
    let notebook = try #require(try await library.files.load().first)
    await #expect(throws: LibraryError.invalidName) { try await library.files.createNotebook(named: name) }
    #expect(throws: LibraryError.invalidName) { try library.files.renameNotebook(at: notebook.url, to: name) }
    #expect(try await library.files.load().map(\.name) == ["Notes"])
    #expect(try String(contentsOf: notebook.notes[0].url, encoding: .utf8) == "keep")
}

@Test @MainActor func notebookRenameReportsCollisionsAndMissingFoldersWithoutLosingDrafts() async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    let other = try await library.files.createNotebook(named: "Existing")
    let store = NoteStore(root: library.root)
    await store.refresh()
    let notebook = try #require(store.notebooks.first { $0.name == "Notes" })
    await store.open(note)
    let document = try #require(store.documents[note.id])
    document.edit("draft")
    #expect(await store.rename(notebook, to: "Existing") == false)
    #expect(store.errorMessage != nil)
    #expect(document.url == note.url)
    #expect(document.text == "draft")
    #expect(FileManager.default.fileExists(atPath: other.path))
    try FileManager.default.removeItem(at: notebook.url)
    #expect(await store.rename(notebook, to: "Missing") == false)
    #expect(await store.trash(notebook) == false)
    #expect(store.documents[note.id] === document)
    #expect(document.isModified)
}

@Test(arguments: [false, true]) func notebookTrashIsRecoverableIncludingNestedAndHiddenFiles(empty: Bool) async throws {
    let library = TestLibrary()
    _ = try await library.files.load()
    let folder = try await library.files.createNotebook(named: UUID().uuidString)
    if !empty {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: false)
        for name in ["note.md", ".hidden", "assets/image.bin"] {
            try Data("keep \(name)".utf8).write(to: folder.appendingPathComponent(name))
        }
    }
    let trashed = try #require(try library.files.trashNotebook(at: folder))
    defer { try? FileManager.default.removeItem(at: trashed) }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try await library.files.load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: trashed.path))
    if !empty {
        for name in ["note.md", ".hidden", "assets/image.bin"] {
            #expect(try String(contentsOf: trashed.appendingPathComponent(name), encoding: .utf8) == "keep \(name)")
        }
    }
}

@Test @MainActor func notebookTrashSavesAllItsDraftsAndLeavesOtherNotebooksOpen() async throws {
    let library = TestLibrary()
    let first = try await library.note("original")
    let folder = try library.files.renameNotebook(at: first.url.deletingLastPathComponent(), to: UUID().uuidString)
    _ = try await library.files.createNote(in: folder)
    let otherFolder = try await library.files.createNotebook(named: "Other")
    _ = try await library.files.createNote(in: otherFolder)
    let store = NoteStore(root: library.root)
    await store.refresh()
    for note in store.notes { await store.open(note) }
    let notebook = try #require(store.notebooks.first { $0.name == folder.lastPathComponent })
    let otherNote = try #require(store.notes.first { $0.notebookName == "Other" })
    let otherDocument = try #require(store.documents[otherNote.id])
    otherDocument.edit("other draft")
    for note in notebook.notes { store.documents[note.id]?.edit("draft \(note.name)") }
    let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false)
        .appendingPathComponent(folder.lastPathComponent)
    try #require(!FileManager.default.fileExists(atPath: trash.path))
    defer { try? FileManager.default.removeItem(at: trash) }
    #expect(await store.trash(notebook))
    #expect(store.notebooks.map(\.name) == ["Other"])
    #expect(store.documents.count == 1)
    #expect(store.documents[otherNote.id] === otherDocument)
    #expect(otherDocument.text == "other draft")
    #expect(otherDocument.isModified)
    for note in notebook.notes {
        #expect(try String(contentsOf: trash.appendingPathComponent(note.url.lastPathComponent),
                           encoding: .utf8) == "draft \(note.name)")
    }
}

@Test @MainActor func conflictingNotePreventsNotebookDeletionAndKeepsEverySession() async throws {
    let library = TestLibrary()
    let first = try await library.note("original")
    _ = try await library.files.createNote(in: first.url.deletingLastPathComponent())
    let store = NoteStore(root: library.root)
    await store.refresh()
    let notebook = try #require(store.notebooks.first)
    for note in notebook.notes { await store.open(note); store.documents[note.id]?.edit("draft") }
    try Data("external".utf8).write(to: first.url)
    #expect(await store.trash(notebook) == false)
    #expect(store.documents.count == 2)
    #expect(store.documents[first.id]?.text == "draft")
    #expect(store.documents[first.id]?.isModified == true)
    #expect(store.errorMessage != nil)
    #expect(store.notebooks.first?.id == notebook.id)
    #expect(try String(contentsOf: first.url, encoding: .utf8) == "external")
}

@Test func notebookActionsRejectTheLibraryRootFilesAndSymlinks() async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    let nested = note.url.deletingLastPathComponent().appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let alias = library.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
    for url in [library.root, note.url, alias] {
        #expect(throws: LibraryError.invalidNotebook) { try library.files.renameNotebook(at: url, to: "Renamed") }
        #expect(throws: LibraryError.invalidNotebook) { try library.files.trashNotebook(at: url) }
    }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "keep")
    #expect(FileManager.default.fileExists(atPath: nested.path))
}
