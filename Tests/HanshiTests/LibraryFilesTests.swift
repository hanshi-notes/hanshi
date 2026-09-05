import Foundation
import Testing
@testable import Hanshi

@Test func libraryCreatesFoldersAndNumberedNotesWithoutLosingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = LibraryFiles(root: root)
    #expect(try await files.load().isEmpty)
    let tutorial = try await files.createNotebook(named: "tutorial")
    let work = try await files.createNotebook(named: "trabajo")
    #expect(try await files.load().map(\.name) == ["trabajo", "tutorial"])
    let first = try await files.createNote(in: tutorial)
    #expect(first.lastPathComponent == "01.md")
    try Data("# Preserve this note".utf8).write(to: first)
    #expect(try await files.createNote(in: tutorial).lastPathComponent == "02.md")
    #expect(try await files.createNote(in: work).lastPathComponent == "01.md")
    #expect(try String(contentsOf: first, encoding: .utf8) == "# Preserve this note")
    try Data().write(to: tutorial.appendingPathComponent("99.md"))
    #expect(try await files.createNote(in: tutorial).lastPathComponent == "100.md")
    let reloaded = try await files.load()
    #expect(reloaded.first { $0.name == "tutorial" }?.notes.map(\.name) == ["01.md", "02.md", "99.md", "100.md"])
    #expect(try String(contentsOf: first, encoding: .utf8) == "# Preserve this note")
    await #expect(throws: (any Error).self) { try await files.createNotebook(named: "../escape") }
    await #expect(throws: (any Error).self) { try await files.createNotebook(named: "tutorial") }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: tutorial)
    #expect(try await files.load().count == 2)
    await #expect(throws: (any Error).self) { try await files.createNote(in: root.appendingPathComponent("alias")) }
    async let createdA = files.createNote(in: work)
    async let createdB = files.createNote(in: work)
    let concurrentFiles = try await [createdA, createdB]
    #expect(Set(concurrentFiles.map(\.lastPathComponent)) == ["02.md", "03.md"])
    let originalID = try #require(reloaded.first { $0.name == "tutorial" }?.notes.first?.id)
    try FileManager.default.moveItem(at: first, to: tutorial.appendingPathComponent("renamed.md"))
    #expect(try await files.load().flatMap(\.notes).first { $0.name == "renamed.md" }?.id == originalID)
}
