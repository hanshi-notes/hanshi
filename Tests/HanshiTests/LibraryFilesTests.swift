import Foundation
import Testing
@testable import Hanshi

@Test func libraryCreatesFoldersAndNamedNotesWithoutLosingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = LibraryFiles(root: root)
    #expect(try await files.load().isEmpty)
    let tutorial = try await files.createNotebook(named: "tutorial")
    let work = try await files.createNotebook(named: "trabajo")
    #expect(try await files.load().map(\.name) == ["trabajo", "tutorial"])
    let first = try await files.createNote(in: tutorial)
    #expect(first.lastPathComponent == "Note.md")
    try Data("# Preserve this note".utf8).write(to: first)
    let second = try await files.createNote(in: tutorial)
    #expect(second.lastPathComponent == "Note (1).md")
    #expect(try await files.createNote(in: work).lastPathComponent == "Note.md")
    #expect(try String(contentsOf: first, encoding: .utf8) == "# Preserve this note")
    // A freed name is taken again instead of counting past it.
    try FileManager.default.removeItem(at: second)
    #expect(try await files.createNote(in: tutorial).lastPathComponent == "Note (1).md")
    #expect(try await files.createNote(in: tutorial).lastPathComponent == "Note (2).md")
    let reloaded = try await files.load()
    // The library lists notes by the name it shows, without the .md the files keep on disk.
    #expect(reloaded.first { $0.name == "tutorial" }?.notes.map(\.name) == ["Note (1)", "Note (2)", "Note"])
    #expect(reloaded.first { $0.name == "tutorial" }?.notes.map { $0.url.lastPathComponent }
            == ["Note (1).md", "Note (2).md", "Note.md"])
    #expect(try String(contentsOf: first, encoding: .utf8) == "# Preserve this note")
    await #expect(throws: (any Error).self) { try await files.createNotebook(named: "../escape") }
    await #expect(throws: (any Error).self) { try await files.createNotebook(named: "tutorial") }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: tutorial)
    #expect(try await files.load().count == 2)
    await #expect(throws: (any Error).self) { try await files.createNote(in: root.appendingPathComponent("alias")) }
    async let createdA = files.createNote(in: work)
    async let createdB = files.createNote(in: work)
    let concurrentFiles = try await [createdA, createdB]
    #expect(Set(concurrentFiles.map(\.lastPathComponent)) == ["Note (1).md", "Note (2).md"])
    let originalID = try #require(reloaded.first { $0.name == "tutorial" }?.notes.first { $0.name == "Note" }?.id)
    try FileManager.default.moveItem(at: first, to: tutorial.appendingPathComponent("renamed.md"))
    #expect(try await files.load().flatMap(\.notes).first { $0.name == "renamed" }?.id == originalID)
}
