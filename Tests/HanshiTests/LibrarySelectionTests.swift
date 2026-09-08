import AppKit
import SwiftUI
import Testing
@testable import Hanshi

// NSApplication focus and SwiftUI window mounting are process-wide.
@Suite(.serialized) struct AppKitWindowTests {}

extension AppKitWindowTests {
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
        #expect(first.name == "2")
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
        secondDocument.editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        window.makeFirstResponder(nil)
        try clickRow(panel: 1, top: 110, in: host, window: window)
        try await eventually { window.firstResponder === secondDocument.editor.textView }
        #expect(secondDocument.editor.textView.selectedRange() == NSRange(location: 2, length: 0))

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

extension AppKitWindowTests {
    @Test(arguments: [Hanshi.ContentMode.preview, .split], [false, true]) @MainActor
    func previewInternalLinksKeepReadingModeAndFocus(mode: Hanshi.ContentMode, cached: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let notebook = fixture.root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notebook, withIntermediateDirectories: true)
        try Data("# First\n\n[Next](Second.md#destination)".utf8).write(to: notebook.appendingPathComponent("First.md"))
        try Data(("# Second\n\n## Destination\n\nArrived.\n\n" + (0..<150).map { "## Block \($0)\n\nParagraph \($0).\n\n" }.joined()).utf8).write(to: notebook.appendingPathComponent("Second.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let first = try #require(store.notes.first)
        let second = try #require(store.notes.last)
        // Cached navigation reuses the representable; uncached navigation unmounts it while opening.
        if cached { await store.open(second) }
        let host = NSHostingView(rootView: LibraryScreen(mode: mode, noteID: first.id).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func previewView(in view: NSView) -> PreviewTextView? {
            if let preview = view as? PreviewTextView { return preview }
            return view.subviews.lazy.compactMap { previewView(in: $0) }.first
        }
        try await eventually { previewView(in: host)?.string.contains("First") == true }
        let preview = try #require(previewView(in: host))
        let session = try #require(preview.delegate as? MarkdownPreviewSession)
        try await eventually { !session.isRendering }
        window.makeFirstResponder(preview)
        session.followLink("Second.md#block-120")
        try await eventually { previewView(in: host)?.string.contains("Arrived.") == true }
        try await eventually { window.firstResponder === previewView(in: host) }
        let document = try #require(store.documents[second.id])
        #expect((document.editor.textView.window != nil) == (mode == .split))
        let anchor = try #require(session.composition?.anchors.first { $0.heading == "block-120" })
        #expect(abs((session.readingPosition()?.sourceOffset ?? 0) - anchor.source.location) < 100)
        if mode == .split {
            try await eventually { document.editor.scrollView.contentView.bounds.minY > 1000 }
        }
        #expect(!store.hasUnsavedChanges)
        try clickRow(panel: 1, top: 80, in: host, window: window)
        try await eventually { store.documents[first.id]?.editor.textView === window.firstResponder }
        #expect(store.documents[first.id]?.editor.textView.window != nil)
    }
}
