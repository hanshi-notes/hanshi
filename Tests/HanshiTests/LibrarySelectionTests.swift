import AppKit
import SwiftUI
import Testing
@testable import Hanshi

@Test @MainActor func librarySelectionOpensNotesAndFocusesTheEditor() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = LibraryFiles(root: root)
    _ = try await files.load()
    let notebook = try await files.createNotebook(named: "Writing")
    _ = try await files.createNotebook(named: "Empty")
    for name in ["10.md", "2.md"] {
        try Data("# \(name)\n".utf8).write(to: notebook.appendingPathComponent(name))
    }
    try Data("Not a Markdown note".utf8).write(to: notebook.appendingPathComponent("1.txt"))
    let store = NoteStore(root: root)
    await store.refresh()
    let first = try #require(store.notes.first)
    let second = try #require(store.notes.last)
    #expect(first.name == "2.md")
    let host = NSHostingView(rootView: LibraryScreen().environment(store))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()

    try clickRow(panel: 0, top: 150, in: host, window: window)
    try await eventually { store.documents[first.id]?.editor.textView === window.firstResponder }
    let firstDocument = try #require(store.documents[first.id])
    #expect(firstDocument.text == "# 2.md\n")

    try clickRow(panel: 1, top: 110, in: host, window: window)
    try await eventually { store.documents[second.id]?.editor.textView === window.firstResponder }
    let secondDocument = try #require(store.documents[second.id])
    secondDocument.editor.textView.textSelection = NSRange(location: 2, length: 0)
    window.makeFirstResponder(nil)
    try clickRow(panel: 1, top: 110, in: host, window: window)
    try await eventually { window.firstResponder === secondDocument.editor.textView }
    #expect(secondDocument.editor.textView.textSelection == NSRange(location: 2, length: 0))

    try clickRow(panel: 0, top: 118, in: host, window: window)
    try await eventually { secondDocument.editor.textView.window == nil }
    #expect(window.firstResponder !== secondDocument.editor.textView)
    #expect(store.documents.count == 2)
    try clickRow(panel: 0, top: 150, in: host, window: window)
    try await eventually { window.firstResponder === firstDocument.editor.textView }
    // Consecutive selections must leave the last requested note focused.
    try clickRow(panel: 1, top: 110, in: host, window: window)
    try clickRow(panel: 0, top: 150, in: host, window: window)
    try await eventually { window.firstResponder === firstDocument.editor.textView }
    #expect(!store.hasUnsavedChanges)
}

// Exercise the real SwiftUI button actions through mouse events in the library's fixed-height rows.
@MainActor private func clickRow(panel: Int, top: CGFloat, in host: NSView, window: NSWindow) throws {
    func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }
    let split = try #require(splitView(in: host))
    let column = split.arrangedSubviews[panel]
    let point = NSPoint(x: 60, y: column.isFlipped ? top : column.bounds.height - top)
    let location = column.convert(point, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(event)
    }
}

@MainActor private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), sourceLocation: sourceLocation)
}
