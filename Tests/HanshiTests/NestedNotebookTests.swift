import Foundation
import Testing
@testable import Hanshi

@Test func nestedNotebooksLoadInTreeOrderAndKeepNotesInTheirOwnFolder() async throws {
    let library = TestLibrary()
    let parentNote = try await library.note("parent")
    let parent = parentNote.url.deletingLastPathComponent()
    let child = parent.appendingPathComponent("Child/Grandchild", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: child.appendingPathComponent("Nested.md"))
    try FileManager.default.createDirectory(at: parent.appendingPathComponent(".Hidden/Child"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("Loop"), withDestinationURL: parent)
    let loaded = try await library.files.load()
    #expect(loaded.map(\.name) == ["Notes", "Child", "Grandchild"])
    #expect(loaded.first?.notes.map(\.id) == [parentNote.id])
    let grandchild = try #require(loaded.first { $0.name == "Grandchild" })
    #expect(grandchild.notes.map(\.name) == ["Nested"])
    let created = try await library.files.createNote(in: child, text: "new")
    let contents = try await library.files.readNote(at: created)
    _ = try await library.files.saveNote(at: created, text: "saved", expected: contents.data)
    let renamed = try library.files.renameNote(at: created, to: "Renamed")
    let moved = try library.files.moveNote(at: renamed, to: parent)
    #expect(try String(contentsOf: moved, encoding: .utf8) == "saved")
    let renamedFolder = try library.files.renameNotebook(at: child, to: "Renamed child")
    #expect(renamedFolder.deletingLastPathComponent() == child.deletingLastPathComponent())
    #expect(try await library.files.load().first { $0.name == "Renamed child" }?.id == grandchild.id)
}

@Test @MainActor func renamingAncestorPreservesNestedDraftPathsAndIdentity() async throws {
    let library = TestLibrary()
    let parentNote = try await library.note("parent")
    let child = parentNote.url.deletingLastPathComponent().appendingPathComponent("Child/Grandchild")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: child.appendingPathComponent("Nested.md"))
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = false
    await store.refresh()
    let parent = try #require(store.notebooks.first { $0.name == "Notes" })
    let nested = try #require(store.notes.first { $0.name == "Nested" })
    await store.open(nested)
    let document = try #require(store.documents[nested.id])
    document.edit("draft")
    let ids = Set(store.notebooks.map(\.id))
    #expect(await store.rename(parent, to: "Renamed"))
    #expect(Set(store.notebooks.map(\.id)) == ids)
    #expect(store.documents[nested.id] === document)
    #expect(document.url.standardizedFileURL == library.root.appendingPathComponent("Renamed/Child/Grandchild/Nested.md").standardizedFileURL)
    #expect(document.text == "draft")
    #expect(document.isModified)
    #expect(await document.save())
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "draft")
    #expect(!FileManager.default.fileExists(atPath: parent.url.path))
}

@Test func nestedActionsRejectSymlinkAncestorsAndOutsideFolders() async throws {
    let library = TestLibrary()
    let outside = TestLibrary()
    _ = try await library.note("keep")
    let external = try await outside.note("outside")
    let alias = library.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside.root)
    let linkedFolder = alias.appendingPathComponent("Notes")
    for folder in [linkedFolder, external.url.deletingLastPathComponent(), library.root] {
        await #expect(throws: (any Error).self) { try await library.files.createNote(in: folder) }
        #expect(throws: (any Error).self) { try library.files.renameNotebook(at: folder, to: "Renamed") }
        #expect(throws: (any Error).self) { try library.files.trashNotebook(at: folder) }
    }
    await #expect(throws: (any Error).self) {
        try await library.files.readNote(at: linkedFolder.appendingPathComponent(external.url.lastPathComponent))
    }
    #expect(try String(contentsOf: external.url, encoding: .utf8) == "outside")
}

@Test @MainActor func creatingSubnotebooksAllowsRepeatedNamesAndUsesTheSelectedParent() async throws {
    let library = TestLibrary()
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = true
    await store.refresh()
    let parentID = try #require(await store.createNotebook(named: "Parent"))
    let parent = try #require(store.notebooks.first { $0.id == parentID })
    let childID = try #require(await store.createNotebook(named: "Notes", in: parent.url))
    let child = try #require(store.notebooks.first { $0.id == childID })
    #expect(child.path(in: library.root) == "Parent/Notes")
    #expect(await store.createNotebook(named: "Notes", in: parent.url) == nil)
    let siblingID = try #require(await store.createNotebook(named: "Notes"))
    let sibling = try #require(store.notebooks.first { $0.id == siblingID })
    let sourceID = try #require(await store.createNote(in: sibling.url))
    let nestedID = try #require(await store.createNote(in: child.url))
    let source = try #require(store.notes.first { $0.id == sourceID })
    await store.open(source)
    let sourceDocument = try #require(store.documents[sourceID])
    sourceDocument.edit("# Shared\n")
    #expect(await sourceDocument.save())
    let nested = try #require(store.notes.first { $0.id == nestedID })
    await store.open(nested)
    let nestedDocument = try #require(store.documents[nestedID])
    nestedDocument.edit("# Shared\n")
    #expect(await nestedDocument.save())
    #expect(nestedDocument.url.lastPathComponent == "Shared.md")
    #expect(sourceDocument.url.lastPathComponent == "Shared.md")
    #expect(await store.rename(source, to: "Move me"))
    #expect(await store.move(noteID: sourceID, to: childID))
    #expect(store.notebooks.first { $0.id == childID }?.notes.count == 2)
    #expect(store.notebooks.first { $0.id == siblingID }?.notes.isEmpty == true)
    let alias = parent.url.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sibling.url)
    for invalidParent in [alias, library.root, library.root.appendingPathComponent("Missing")] {
        await #expect(throws: (any Error).self) {
            try await library.files.createNotebook(named: "Invalid", in: invalidParent)
        }
    }
}

@Test(arguments: [false, true]) @MainActor
func trashingAncestorSavesNestedDraftsAndStopsOnConflicts(conflict: Bool) async throws {
    let library = TestLibrary()
    _ = try await library.files.load()
    let parent = try await library.files.createNotebook(named: UUID().uuidString)
    let child = try await library.files.createNotebook(named: "Child", in: parent)
    let deep = try await library.files.createNotebook(named: "Grandchild", in: child)
    let noteURL = try await library.files.createNote(in: deep, text: "original")
    let sibling = try await library.files.createNotebook(named: parent.lastPathComponent + "-sibling")
    _ = try await library.files.createNote(in: sibling, text: "sibling")
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = false
    await store.refresh()
    let ancestor = try #require(store.notebooks.first { $0.url.standardizedFileURL == parent.standardizedFileURL })
    for note in store.notes { await store.open(note) }
    let nested = try #require(store.notes.first { $0.url.standardizedFileURL == noteURL.standardizedFileURL })
    let document = try #require(store.documents[nested.id])
    document.edit("nested draft")
    let siblingNote = try #require(store.notes.first { $0.url.deletingLastPathComponent().standardizedFileURL == sibling.standardizedFileURL })
    let siblingDocument = try #require(store.documents[siblingNote.id])
    siblingDocument.edit("sibling draft")
    if conflict {
        try Data("external".utf8).write(to: noteURL)
        #expect(await store.trash(ancestor) == false)
        #expect(store.notebooks.count == 4)
        #expect(store.documents[nested.id] === document)
        #expect(document.text == "nested draft")
        #expect(document.isModified)
        #expect(try String(contentsOf: noteURL, encoding: .utf8) == "external")
    } else {
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: parent, create: false)
            .appendingPathComponent(parent.lastPathComponent)
        try #require(!FileManager.default.fileExists(atPath: trash.path))
        defer { try? FileManager.default.removeItem(at: trash) }
        #expect(await store.trash(ancestor))
        #expect(store.notebooks.map { $0.url.standardizedFileURL } == [sibling.standardizedFileURL])
        #expect(store.documents[nested.id] == nil)
        #expect(try String(contentsOf: trash.appendingPathComponent("Child/Grandchild/Note.md"), encoding: .utf8) == "nested draft")
    }
    #expect(store.documents[siblingNote.id] === siblingDocument)
    #expect(siblingDocument.text == "sibling draft")
    #expect(siblingDocument.isModified)
}
