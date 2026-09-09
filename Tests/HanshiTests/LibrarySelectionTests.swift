import AppKit
import SwiftUI
import Testing
@testable import Hanshi

// NSApplication focus and SwiftUI window mounting are process-wide.
@Suite(.serialized) struct AppKitWindowTests {}

extension AppKitWindowTests {
    @Test(arguments: Hanshi.ContentMode.allCases) @MainActor
    func librarySelectionOpensNotesAndKeepsTheChosenMode(mode: Hanshi.ContentMode) async throws {
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
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(mode: mode, defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func isFocused(_ note: Note) -> Bool {
            guard let document = store.documents[note.id] else { return false }
            let preview = previewView(in: host)
            if mode == .preview {
                let session = previewSession(in: host)
                return session?.appliedSnapshot?.documentID == note.id
                    && session?.isRendering == false && preview?.window === window
                    && window.firstResponder === preview && document.editor.textView.window == nil
            }
            return window.firstResponder === document.editor.textView
                && (preview != nil) == (mode == .split)
        }

        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { isFocused(first) }
        let firstDocument = try #require(store.documents[first.id])
        #expect(firstDocument.text == "# 2.md\n")

        try clickRow(panel: 1, top: 110, in: host, window: window)
        try await eventually { isFocused(second) }
        let secondDocument = try #require(store.documents[second.id])
        secondDocument.editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        window.makeFirstResponder(nil)
        try clickRow(panel: 1, top: 110, in: host, window: window)
        try await eventually { isFocused(second) }
        #expect(secondDocument.editor.textView.selectedRange() == NSRange(location: 2, length: 0))

        try clickRow(panel: 0, top: 118, in: host, window: window)
        try await eventually { secondDocument.editor.textView.window == nil && previewView(in: host) == nil }
        #expect(window.firstResponder !== secondDocument.editor.textView)
        #expect(store.documents.count == 2)
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { isFocused(first) }
        // Consecutive selections must leave the last requested note focused.
        try clickRow(panel: 1, top: 110, in: host, window: window)
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { isFocused(first) }
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
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(mode: mode, noteID: first.id, defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await eventually { previewView(in: host)?.string.contains("First") == true }
        let preview = try #require(previewView(in: host))
        let session = try #require(previewSession(in: host))
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
        if mode == .preview {
            try await eventually { previewView(in: host)?.string.contains("First") == true }
            try await eventually { window.firstResponder === previewView(in: host) }
            #expect(store.documents[first.id]?.editor.textView.window == nil)
        } else {
            try await eventually { store.documents[first.id]?.editor.textView === window.firstResponder }
            #expect(store.documents[first.id]?.editor.textView.window != nil)
        }
    }
}

@MainActor private func previewView(in view: NSView) -> NSTextView? {
    if let preview = view as? NSTextView, preview.accessibilityLabel() == "Markdown preview" { return preview }
    return view.subviews.lazy.compactMap { previewView(in: $0) }.first
}

@MainActor private func previewSession(in view: NSView) -> MarkdownPreviewSession? {
    if let container = view as? PreviewContainerView { return container.session }
    return view.subviews.lazy.compactMap { previewSession(in: $0) }.first
}

struct TestPreferences {
    let suite = "HanshiTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    func remove() { defaults.removePersistentDomain(forName: suite) }
}

extension AppKitWindowTests {
    @Test @MainActor func selectedNotebookSurvivesRelaunchAndRename() async throws {
        let preferences = TestPreferences(); defer { preferences.remove() }
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let files = LibraryFiles(root: fixture.root)
        let alpha = try await files.createNotebook(named: "Alpha")
        let writing = try await files.createNotebook(named: "Writing")
        try Data("Alpha note".utf8).write(to: alpha.appendingPathComponent("A.md"))
        try Data("Writing note".utf8).write(to: writing.appendingPathComponent("B.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let target = try #require(store.notebooks.first { $0.name == "Writing" })
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == target.id }
        window.contentView = nil
        _ = try files.renameNotebook(at: writing, to: "Renamed")

        let reopenedDefaults = try #require(UserDefaults(suiteName: preferences.suite))
        let reopenedStore = NoteStore(root: fixture.root)
        let reopened = NSHostingView(rootView: LibraryScreen(defaults: reopenedDefaults).environment(reopenedStore))
        window.contentView = reopened; reopened.layoutSubtreeIfNeeded()
        // Mount before the asynchronous catalog load, as at real application startup.
        await Task.yield()
        #expect(reopenedDefaults.string(forKey: Notebook.selectionKey) == target.id)
        await reopenedStore.refresh()
        try await eventually { reopenedStore.notebooks.count == 2 }
        reopened.layoutSubtreeIfNeeded()
        try clickRow(panel: 1, top: 80, in: reopened, window: window)
        let note = try #require(reopenedStore.notes.first { $0.name == "B" })
        try await eventually { reopenedStore.documents[note.id]?.editor.textView.window === window }
        #expect(reopenedDefaults.string(forKey: Notebook.selectionKey) == target.id)
        #expect(reopenedStore.documents[note.id]?.text == "Writing note")
        try clickRow(panel: 0, top: 54, in: reopened, window: window)
        try await eventually { reopenedDefaults.string(forKey: Notebook.selectionKey) == "all" }
        window.contentView = nil
        let allNotes = NSHostingView(rootView: LibraryScreen(defaults: reopenedDefaults).environment(reopenedStore))
        window.contentView = allNotes; allNotes.layoutSubtreeIfNeeded()
        try clickRow(panel: 1, top: 80, in: allNotes, window: window)
        let alphaNote = try #require(reopenedStore.notes.first { $0.name == "A" })
        try await eventually { reopenedStore.documents[alphaNote.id]?.editor.textView.window === window }
    }

    @Test(arguments: [false, true]) @MainActor
    func missingNotebookFallsBackAfterSuccessfulCatalogLoad(preloaded: Bool) async throws {
        let preferences = TestPreferences(); defer { preferences.remove() }
        preferences.defaults.set("deleted-notebook", forKey: Notebook.selectionKey)
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let store = NoteStore(root: fixture.root)
        if preloaded { await store.refresh() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        if !preloaded {
            await Task.yield()
            #expect(preferences.defaults.string(forKey: Notebook.selectionKey) == "deleted-notebook")
            await store.refresh()
        }
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == "all" }
    }

    @Test(arguments: ["Editor", "Preview", "Split", "", "obsolete-value"]) @MainActor
    func startupViewSettingAppliesOnLaunchAndKeepsTheCurrentSession(_ saved: String) async throws {
        let preferences = TestPreferences(); defer { preferences.remove() }
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let folder = try #require(await store.createNotebook(named: "Notes"))
        let notebook = try #require(store.notebooks.first { $0.id == folder })
        let noteID = try #require(await store.createNote(in: notebook.url))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let settings = NSHostingView(rootView: GeneralSettingsView().defaultAppStorage(preferences.defaults))
        window.contentView = settings; window.orderFront(nil); settings.layoutSubtreeIfNeeded()
        func picker(in view: NSView) -> NSSegmentedControl? {
            if let picker = view as? NSSegmentedControl { return picker }
            return view.subviews.lazy.compactMap { picker(in: $0) }.first
        }
        let control = try #require(picker(in: settings))
        #expect(control.selectedSegment == 0)
        #expect((0..<control.segmentCount).compactMap { control.label(forSegment: $0) } == ["Editor", "Preview", "Split"])
        if let mode = Hanshi.ContentMode(rawValue: saved) {
            let index = try #require(Hanshi.ContentMode.allCases.firstIndex(of: mode))
            control.selectedSegment = index
            control.sendAction(control.action, to: control.target)
            try await eventually { preferences.defaults.string(forKey: Hanshi.ContentMode.startupKey) == saved }
        } else if !saved.isEmpty {
            preferences.defaults.set(saved, forKey: Hanshi.ContentMode.startupKey)
        }
        let expected = Hanshi.ContentMode(rawValue: saved) ?? .source
        let host = NSHostingView(rootView: LibraryScreen(noteID: noteID, defaults: preferences.defaults).environment(store))
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        func matches(_ mode: Hanshi.ContentMode, in host: NSView) -> Bool {
            guard let document = store.documents[noteID] else { return false }
            let preview = previewSession(in: host)
            return (document.editor.textView.window === window) == (mode != .preview)
                && (preview?.appliedSnapshot?.documentID == noteID) == (mode != .source)
        }
        try await eventually { matches(expected, in: host) }
        let next: Hanshi.ContentMode = expected == .preview ? .source : .preview
        preferences.defaults.set(next.rawValue, forKey: Hanshi.ContentMode.startupKey)
        host.rootView = LibraryScreen(noteID: noteID, defaults: preferences.defaults).environment(store)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(matches(expected, in: host), "A startup preference must not change the open note's mode")
        window.contentView = nil
        let relaunched = NSHostingView(rootView: LibraryScreen(noteID: noteID, defaults: preferences.defaults).environment(store))
        window.contentView = relaunched; relaunched.layoutSubtreeIfNeeded()
        try await eventually { matches(next, in: relaunched) }
    }
}

extension AppKitWindowTests {
    /// The notebook already survived a relaunch; the note has to as well, or reopening the
    /// app drops the reader back at "Select a note to start writing".
    @Test @MainActor func selectedNoteSurvivesRelaunch() async throws {
        let preferences = TestPreferences(); defer { preferences.remove() }
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let files = LibraryFiles(root: fixture.root)
        // Two notebooks so the sidebar rows land where `clickRow` expects them.
        let alpha = try await files.createNotebook(named: "Alpha")
        let writing = try await files.createNotebook(named: "Writing")
        try Data("Alpha note".utf8).write(to: alpha.appendingPathComponent("A.md"))
        try Data("# First\n".utf8).write(to: writing.appendingPathComponent("B.md"))
        try Data("# Second\n".utf8).write(to: writing.appendingPathComponent("C.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let notebook = try #require(store.notebooks.first { $0.name == "Writing" })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == notebook.id }
        host.layoutSubtreeIfNeeded()
        try clickRow(panel: 1, top: 80, in: host, window: window)
        // Which row the click lands on depends on list geometry; what matters is that
        // whatever it selected is what comes back, so read the selection instead of guessing.
        try await eventually { preferences.defaults.string(forKey: Note.selectionKey) != nil }
        let selectedID = try #require(preferences.defaults.string(forKey: Note.selectionKey))
        let target = try #require(store.notes.first { $0.id == selectedID })
        window.contentView = nil

        // Relaunch: a fresh store whose catalog is still empty when the screen mounts, which
        // is where a naive restore loses the selection.
        let reopenedStore = NoteStore(root: fixture.root)
        let reopened = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(reopenedStore))
        window.contentView = reopened; reopened.layoutSubtreeIfNeeded()
        await Task.yield()
        await reopenedStore.refresh()
        try await eventually { reopenedStore.notes.count == 3 }
        reopened.layoutSubtreeIfNeeded()
        try await eventually { reopenedStore.documents[target.id] != nil }
        #expect(preferences.defaults.string(forKey: Note.selectionKey) == target.id,
                "The reopened screen keeps the remembered note selected")
    }
}
