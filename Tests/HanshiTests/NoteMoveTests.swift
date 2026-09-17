import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test @MainActor func notebookAcceptsNoteDragsAndDeliversTheDroppedIdentity() async throws {
        _ = NSApplication.shared
        let library = TestLibrary()
        let store = NoteStore(root: library.root)
        var targeted: String?
        var droppedID: String?
        let delegate = NotebookDropDelegate(isBusy: store.isBusy, sessionID: store.sessionID, notebookID: "destination",
            targetedNotebookID: Binding(get: { targeted }, set: { targeted = $0 }), move: { droppedID = $0 })
        let host = NSHostingView(rootView: Color.blue.frame(width: 100, height: 100)
            .onDrop(of: [NoteDrag.type], delegate: delegate))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let drag = NotebookTestDrag(window: window)
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingPasteboard.setData(Data("\(store.sessionID)\n123:456".utf8),
            forType: NSPasteboard.PasteboardType(NoteDrag.type.identifier))
        func dropView(in view: NSView) -> NSView? {
            if !view.registeredDraggedTypes.isEmpty { return view }
            return view.subviews.lazy.compactMap { dropView(in: $0) }.first
        }
        let destination = try #require(dropView(in: host))
        #expect(destination.draggingEntered(drag) != [])
        #expect(targeted == "destination")
        destination.draggingExited(drag)
        #expect(targeted == nil)
        #expect(destination.draggingEntered(drag) != [])
        #expect(destination.performDragOperation(drag))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while droppedID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(droppedID == "123:456")
        #expect(targeted == nil)
    }
}

@MainActor private final class NotebookTestDrag: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    let draggingLocation = NSPoint(x: 50, y: 50)
    let draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(window: NSWindow) { draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Test @MainActor func movingAnOpenNotePreservesDraftSelectionAndUndo() async throws {
    let library = TestLibrary()
    let note = try await library.note("original")
    _ = try await library.files.createNotebook(named: "Destination")
    let store = NoteStore(root: library.root)
    store.usesTitleTemplate = false
    await store.refresh()
    await store.open(note)
    let target = try #require(store.notebooks.first { $0.name == "Destination" })
    let document = try #require(store.documents[note.id])
    let editor = document.editor.textView
    editor.undoManager?.groupsByEvent = false
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("draft 😀 ", replacementRange: NSRange(location: 0, length: 0))
    editor.undoManager?.endUndoGrouping()
    let selection = editor.selectedRange()
    let payload = NoteDrag.provider(noteID: note.id, sessionID: store.sessionID)
    let draggedID = try #require(await NoteDrag.noteID(from: payload, sessionID: store.sessionID))
    #expect(await store.move(noteID: draggedID, to: target.id))
    #expect(store.documents[note.id] === document)
    #expect(store.notes.first?.id == note.id)
    #expect(store.notebooks.first { $0.name == "Notes" }?.notes.isEmpty == true)
    #expect(store.notebooks.first { $0.id == target.id }?.notes.map(\.id) == [note.id])
    #expect(document.url == target.url.appendingPathComponent(note.url.lastPathComponent))
    #expect(!FileManager.default.fileExists(atPath: note.url.path))
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "original")
    #expect(document.text == "draft 😀 original")
    #expect(document.isModified)
    #expect(editor.selectedRange() == selection)
    #expect(editor.undoManager?.canUndo == true)
    #expect(await document.save())
    #expect(try String(contentsOf: document.url, encoding: .utf8) == "draft 😀 original")
    editor.undoManager?.undo()
    #expect(document.text == "original")
}

@Test @MainActor func movingAClosedNoteAndDroppingItInItsOwnNotebookPreservesItsIdentity() async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    _ = try await library.files.createNotebook(named: "Other")
    let store = NoteStore(root: library.root)
    await store.refresh()
    let target = try #require(store.notebooks.first { $0.name == "Other" })
    for _ in 0..<2 {
        #expect(await store.move(noteID: note.id, to: target.id))
        let moved = try #require(store.notes.first)
        #expect(moved.id == note.id)
        #expect(moved.notebookName == "Other")
        #expect(try String(contentsOf: moved.url, encoding: .utf8) == "keep")
        #expect(store.notes.count == 1)
        #expect(store.documents.isEmpty)
        #expect(store.errorMessage == nil)
    }
}

@Test @MainActor func movingNeverOverwritesAnotherNoteOrLosesTheDraftOnFailure() async throws {
    let library = TestLibrary()
    let note = try await library.note("source")
    let folder = try await library.files.createNotebook(named: "Other")
    let other = folder.appendingPathComponent(note.url.lastPathComponent)
    try Data("destination".utf8).write(to: other)
    let store = NoteStore(root: library.root)
    await store.refresh()
    await store.open(note)
    let target = try #require(store.notebooks.first { $0.name == "Other" })
    let document = try #require(store.documents[note.id])
    document.edit("unsaved")
    #expect(await store.move(noteID: note.id, to: target.id) == false)
    #expect(store.errorMessage != nil)
    #expect(!store.isBusy)
    #expect(document.url == note.url)
    #expect(document.text == "unsaved")
    #expect(document.isModified)
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "source")
    #expect(try String(contentsOf: other, encoding: .utf8) == "destination")
    #expect(await store.move(noteID: "missing", to: target.id) == false)
    #expect(await store.move(noteID: note.id, to: "missing") == false)
    try FileManager.default.removeItem(at: note.url)
    #expect(await store.move(noteID: note.id, to: target.id) == false)
    #expect(store.documents[note.id] === document)
    #expect(document.text == "unsaved")
}

@Test func noteMovesRejectInvalidSourcesAndDestinations() async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    let folder = try await library.files.createNotebook(named: "Other")
    let alias = library.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
    for destination in [library.root, note.url, alias, library.root.appendingPathComponent("Missing")] {
        #expect(throws: (any Error).self) { try library.files.moveNote(at: note.url, to: destination) }
        #expect(try String(contentsOf: note.url, encoding: .utf8) == "keep")
    }
    let link = note.url.deletingLastPathComponent().appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: note.url)
    let outside = library.root.appendingPathComponent("outside.md")
    try Data("outside".utf8).write(to: outside)
    for source in [link, outside] {
        #expect(throws: LibraryError.invalidNote) { try library.files.moveNote(at: source, to: folder) }
    }
    #expect(try String(contentsOf: note.url, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
}

@Test func noteDragRejectsForeignSessionsAndMalformedData() async {
    let session = UUID()
    #expect(await NoteDrag.noteID(from: NoteDrag.provider(noteID: "123:456", sessionID: UUID()), sessionID: session) == nil)
    for data in [Data(), Data([0xFF]), Data("\(session)\n".utf8), Data("\(session)\n123:456\nextra".utf8)] {
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: NoteDrag.type.identifier)
        #expect(await NoteDrag.noteID(from: provider, sessionID: session) == nil)
    }
    #expect(await NoteDrag.noteID(from: NSItemProvider(object: "unrelated text" as NSString), sessionID: session) == nil)
}
