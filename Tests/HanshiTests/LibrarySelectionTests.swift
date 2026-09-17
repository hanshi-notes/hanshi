import AppKit
import SwiftUI
import Testing
@testable import Hanshi

// NSApplication focus and SwiftUI window mounting are process-wide.
@Suite(.serialized) struct AppKitWindowTests {}

extension AppKitWindowTests {
    @Test(arguments: SidebarTheme.allCases) @MainActor
    func sidebarPlusButtonCreatesANotebookAtTheLibraryRoot(theme: SidebarTheme) async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        _ = try await LibraryFiles(root: fixture.root).createNotebook(named: "Writing")
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let writing = try #require(store.notebooks.first)
        let preferences = TestPreferences(); defer { preferences.remove() }
        preferences.defaults.set(theme.rawValue, forKey: SidebarTheme.key)
        // A selected notebook must not become the new notebook's parent.
        preferences.defaults.set(writing.id, forKey: Notebook.selectionKey)
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let (window, lifecycle) = appWindow(host)
        defer { window.contentView = nil; window.close(); withExtendedLifetime(lifecycle) {} }
        host.layoutSubtreeIfNeeded()
        let sidebar = try #require(librarySplit(in: host)).arrangedSubviews[0]
        // Like the bar's buttons, the "+" is outlined while its surface blends with the colour behind
        // it, so it weighs the same as the hide sidebar button instead of reading as a solid block.
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try layerBitmap(host)
        let buttonLeft = sidebar.bounds.width - BarMetrics.margin - BarMetrics.buttonWidth
        func brightness(atX x: Double) -> CGFloat {
            bitmap.colorAt(x: Int(x), y: bitmap.pixelsHigh - Int(BarMetrics.height / 2))?
                .usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        let background = brightness(atX: buttonLeft - 20)
        let edge = (-2...2).map { abs(brightness(atX: buttonLeft + Double($0)) - background) }.max() ?? 0
        #expect(edge > 0.05, "On the \(theme) sidebar, the + button has no border")
        #expect(abs(brightness(atX: buttonLeft + 4) - background) < 0.1, "On the \(theme) sidebar, the + button's surface stands out")
        try clickRow(panel: 0, top: BarMetrics.height / 2,
                     x: sidebar.bounds.width - BarMetrics.margin - BarMetrics.buttonWidth / 2, in: host, window: window)
        try await eventually { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet?.contentView)
        func nameField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { nameField(in: $0) }.first
        }
        let field = try #require(nameField(in: sheet))
        #expect(field.stringValue.isEmpty)
        #expect(sheet.window?.makeFirstResponder(field) == true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Ideas", replacementRange: NSRange(location: 0, length: 0))
        try await eventually { field.stringValue == "Ideas" }
        editor.insertNewline(nil)
        try await eventually { store.notebooks.contains { $0.name == "Ideas" } }
        #expect(store.notebooks.first { $0.name == "Ideas" }?.path(in: store.files.root) == "Ideas")
    }

    @Test @MainActor func notebookDisclosureHidesRowsAndPreservesTheOpenNote() async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let files = LibraryFiles(root: fixture.root)
        _ = try await files.createNotebook(named: "Empty")
        let writing = try await files.createNotebook(named: "Writing")
        try Data("# Draft\n".utf8).write(to: writing.appendingPathComponent("Draft.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let notebook = try #require(store.notebooks.first { $0.name == "Writing" })
        let note = try #require(store.notes.first)
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { store.documents[note.id]?.editor.textView.window === window }
        let document = try #require(store.documents[note.id])
        document.edit("# Unsaved draft\n")

        try clickRow(panel: 0, top: 86, in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        try #require(window.sheets.isEmpty, "The disclosure must not open the New Notebook sheet")
        #expect(preferences.defaults.string(forKey: Notebook.selectionKey) == notebook.id)
        #expect(document.editor.textView.window === window)
        #expect(document.text == "# Unsaved draft\n")

        try clickRow(panel: 0, top: 54, in: host, window: window)
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == "all" }
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(preferences.defaults.string(forKey: Notebook.selectionKey) == "all",
                "Collapsed notebook rows must no longer be clickable")

        try clickRow(panel: 0, top: 86, in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == notebook.id }
        #expect(document.text == "# Unsaved draft\n")
        #expect(document.isModified)
    }

    @Test(arguments: [false, true]) @MainActor
    func changingContentModeFocusesTheVisibleSurface(allowsEditing: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let folder = try await LibraryFiles(root: fixture.root).createNotebook(named: "Notes")
        try Data("# Focus\n\nBody text.\n".utf8).write(to: folder.appendingPathComponent("Focus.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let note = try #require(store.notes.first)
        let preferences = TestPreferences(); defer { preferences.remove() }
        preferences.defaults.set(allowsEditing, forKey: PreviewSettings.allowsEditingKey)
        let control = ContentModeTestControl()
        let host = NSHostingView(rootView: LibraryScreen(mode: .source, noteID: note.id, defaults: preferences.defaults)
            .environment(store).defaultAppStorage(preferences.defaults)
            .overlay { ContentModeBindingProbe(control: control).frame(width: 0, height: 0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await eventually { control.mode != nil && store.documents[note.id]?.editor.textView.window === window }
        let document = try #require(store.documents[note.id])
        try await eventually { window.firstResponder === document.editor.textView }
        for mode in [Hanshi.ContentMode.preview, .source, .preview, .split, .preview, .source, .preview] {
            control.mode?.wrappedValue = mode
            try await eventually {
                if mode == .preview {
                    return previewView(in: host) != nil && window.firstResponder === previewView(in: host)
                        && document.editor.textView.window == nil
                }
                return window.firstResponder === document.editor.textView
                    && (previewView(in: host) != nil) == (mode == .split)
            }
        }
        #expect(previewView(in: host)?.isEditable == allowsEditing)
        #expect(document.text == "# Focus\n\nBody text.\n")
    }

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

@MainActor private final class ContentModeTestControl {
    var mode: Binding<Hanshi.ContentMode>?
}

private struct ContentModeBindingProbe: View {
    @FocusedValue(\.contentMode) private var mode
    let control: ContentModeTestControl
    var body: some View {
        Color.clear.onChange(of: mode?.wrappedValue, initial: true) { control.mode = mode }
    }
}

// Exercise the real SwiftUI button actions through mouse events in the library's fixed-height rows.
@MainActor private func clickRow(panel: Int, top: CGFloat, x: CGFloat = 60, in host: NSView, window: NSWindow) throws {
    func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }
    let split = try #require(splitView(in: host))
    let column = split.arrangedSubviews[panel]
    let point = NSPoint(x: x, y: column.isFlipped ? top : column.bounds.height - top)
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
        // The store has the catalog before SwiftUI draws its rows, and a click sent in between lands
        // on nothing. Repeat it until the selection takes; selecting the same row again changes nothing.
        try await eventually {
            (try? clickRow(panel: 1, top: 80, in: reopened, window: window)) != nil
                && reopenedDefaults.string(forKey: Note.selectionKey)?.hasSuffix("/Renamed/B.md") == true
        }
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
        let selectedPath = try #require(preferences.defaults.string(forKey: Note.selectionKey))
        let target = try #require(store.notes.first { $0.url.path == selectedPath })

        // Saving rewrites the file atomically, so its inode — and with it the id the catalog
        // will report at the next launch — changes under the running selection.
        try await eventually { store.documents[target.id] != nil }
        let document = try #require(store.documents[target.id])
        document.edit("# Edited\n")
        #expect(await document.save())
        #expect(preferences.defaults.string(forKey: Note.selectionKey) == selectedPath)
        // Renaming moves the file, so the remembered place has to follow it.
        #expect(await store.rename(target, to: "Renamed"))
        let renamedPath = target.url.deletingLastPathComponent().appendingPathComponent("Renamed.md").path
        try await eventually { preferences.defaults.string(forKey: Note.selectionKey) == renamedPath }
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
        let restored = try #require(reopenedStore.notes.first { $0.url.path == renamedPath })
        #expect(restored.id != target.id, "The save must have changed the id the catalog reports")
        try await eventually { reopenedStore.documents[restored.id]?.text == "# Edited\n" }
        #expect(preferences.defaults.string(forKey: Note.selectionKey) == renamedPath,
                "The reopened screen keeps the remembered note selected")
    }
}


extension AppKitWindowTests {
    @Test @MainActor func subnotebookDisclosureKeepsSelectionAndDrafts() async throws {
        _ = NSApplication.shared
        let library = TestLibrary()
        _ = try await library.files.load()
        let parent = try await library.files.createNotebook(named: "Parent")
        let child = try await library.files.createNotebook(named: "Child", in: parent)
        let deep = try await library.files.createNotebook(named: "Grandchild", in: child)
        _ = try await library.files.createNote(in: deep, text: "original")
        _ = try await library.files.createNotebook(named: "Sibling")
        let store = NoteStore(root: library.root)
        await store.refresh()
        let nested = try #require(store.notebooks.first { $0.name == "Grandchild" })
        let sibling = try #require(store.notebooks.first { $0.name == "Sibling" })
        let note = try #require(nested.notes.first)
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        try clickRow(panel: 0, top: 182, x: 95, in: host, window: window)
        try await eventually { store.documents[note.id]?.editor.textView.window === window }
        let document = try #require(store.documents[note.id])
        document.edit("nested draft")
        try clickRow(panel: 0, top: 118, x: 23, in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(preferences.defaults.string(forKey: Notebook.selectionKey) == nested.id)
        #expect(document.editor.textView.window === window)
        try clickRow(panel: 0, top: 150, in: host, window: window)
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == sibling.id }
        try clickRow(panel: 0, top: 118, x: 23, in: host, window: window)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        try clickRow(panel: 0, top: 182, x: 95, in: host, window: window)
        try await eventually { preferences.defaults.string(forKey: Notebook.selectionKey) == nested.id }
        #expect(store.documents[note.id] === document)
        #expect(document.text == "nested draft")
        #expect(document.isModified)
        #expect(window.sheets.isEmpty)
    }
}


extension AppKitWindowTests {
    @Test(arguments: ["Target", "Work/Target", "Work/Target.md", "Work/Child/Target"])
    @MainActor func wikiLinksOpenCatalogNotesWithoutChangingTheSource(target: String) async throws {
        _ = NSApplication.shared
        let library = TestLibrary()
        let source = try await library.note("[[\(target)]]\n")
        let work = try await library.files.createNotebook(named: "Work")
        let folder = target.contains("Child")
            ? try await library.files.createNotebook(named: "Child", in: work) : work
        let targetURL = folder.appendingPathComponent("Target.md")
        try Data("# Destination\n".utf8).write(to: targetURL)
        let store = NoteStore(root: library.root)
        await store.refresh()
        let preferences = TestPreferences(); defer { preferences.remove() }
        preferences.defaults.set(false, forKey: PreviewSettings.allowsEditingKey)
        let host = NSHostingView(rootView: LibraryScreen(mode: .preview, noteID: source.id, defaults: preferences.defaults)
            .environment(store).defaultAppStorage(preferences.defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await eventually { previewView(in: host)?.string.contains(target) == true }
        let preview = try #require(previewView(in: host))
        let session = try #require(previewSession(in: host))
        try await eventually { !session.isRendering }
        let index = (preview.string as NSString).range(of: "Target").location + 2
        let link = try #require(preview.textStorage?.attribute(.link, at: index, effectiveRange: nil),
                                "A wiki link must be navigable, not just formatted")
        #expect(session.engine.textView(preview, clickedOnLink: link, at: index))
        try await eventually { previewView(in: host)?.string.contains("Destination") == true }
        #expect(store.documents[source.id]?.text == "[[\(target)]]\n")
        #expect(!store.hasUnsavedChanges)
        #expect(try String(contentsOf: source.url, encoding: .utf8) == "[[\(target)]]\n")
    }
}

extension AppKitWindowTests {
    /// A failed reload leaves the catalog usable, so it must not take over the window. A failed action
    /// the user asked for does interrupt, and offers no retry that would only reload the library.
    @Test @MainActor func failedReloadStaysInlineAndFailedActionsInterruptWithoutRetry() async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let notebook = try await LibraryFiles(root: fixture.root).createNotebook(named: "Notes")
        try Data("# A\n".utf8).write(to: notebook.appendingPathComponent("A.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: notebook.path)
        do {
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notebook.path) }
            await store.refresh()
        }
        #expect(store.reloadError != nil)
        #expect(store.errorMessage == nil)
        #expect(store.notes.count == 1, "The catalog on screen survives a failed reload")
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        #expect(window.attachedSheet == nil, "A failed reload must not block the window")
        await store.refresh()
        #expect(store.reloadError == nil, "A successful reload clears the report")

        #expect(await store.createNotebook(named: "Notes") == nil)
        try await eventually { window.attachedSheet != nil }
        let alert = try #require(window.attachedSheet?.contentView)
        #expect(buttonTitles(in: alert) == ["OK"])
    }
}

@MainActor private func buttonTitles(in view: NSView) -> [String] {
    if let button = view as? NSButton { return button.isHidden || button.title.isEmpty ? [] : [button.title] }
    return view.subviews.flatMap { buttonTitles(in: $0) }
}
