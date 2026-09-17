import AppKit
import Observation
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test(arguments: [false, true]) @MainActor
    func saveControlsObserveEditsWithoutReevaluatingTheirParent(initiallyModified: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Draft.md")
        try Data("Original".utf8).write(to: url)
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let note = try #require(store.notes.first)
        await store.open(note)
        let document = try #require(store.documents[note.id])
        if initiallyModified { document.edit("Unsaved before mounting") }
        let evaluations = ViewEvaluationCount()
        let host = NSHostingView(rootView: SaveControlsTestView(store: store, document: document,
            lifecycle: LibraryLifecycle(), evaluations: evaluations).frame(width: 100, height: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let initialEvaluations = evaluations.count
        #expect(window.isDocumentEdited == initiallyModified)

        for text in ["First edit", "Second edit"] {
            document.edit(text)
            host.layoutSubtreeIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !window.isDocumentEdited, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(window.isDocumentEdited)
            #expect(evaluations.count == initialEvaluations)
        }
        let location = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while document.isModified || window.isDocumentEdited, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "Second edit")
        #expect(!document.isModified)
        #expect(!window.isDocumentEdited)
        #expect(evaluations.count == initialEvaluations)
    }

    @Test @MainActor func replacingTheInjectedPreviewReplacesTheMountedSession() async throws {
        _ = NSApplication.shared
        let document = PreviewTestFixtures.document("# Preview\n\nDraft")
        let files = LibraryFiles(root: document.url.deletingLastPathComponent())
        let first = MarkdownPreviewSession(debounce: .zero)
        let second = MarkdownPreviewSession(debounce: .zero)
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: NoteEditorContentView(document: document,
            files: files, mode: .preview, preview: first).defaultAppStorage(preferences.defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { first.hide(); second.hide(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await first.waitForRendering()
        #expect(first.textView.window === window)

        for session in [second, first] {
            host.rootView = NoteEditorContentView(document: document,
                files: files, mode: .preview, preview: session).defaultAppStorage(preferences.defaults)
            host.layoutSubtreeIfNeeded()
            await session.waitForRendering()
            #expect(session.textView.window === window, "A replacement input must reach the mounted preview")
            #expect(session.textView.string.contains("Draft"))
        }
        #expect(document.text == "# Preview\n\nDraft")
    }
}

/// The app reloads the catalog every time it becomes active. Reassigning an identical catalog must
/// not wake every view that reads it; a real change still must.
@Test @MainActor func reloadingAnUnchangedLibraryDoesNotNotifyCatalogObservers() async throws {
    let library = TestLibrary()
    let note = try await library.note("keep")
    let store = NoteStore(root: library.root)
    await store.refresh()
    let changes = ChangeCount()
    withObservationTracking { _ = store.notebooks } onChange: { changes.count += 1 }
    await store.refresh()
    #expect(changes.count == 0, "An identical catalog must not notify")
    try Data("other".utf8).write(to: note.url.deletingLastPathComponent().appendingPathComponent("Other.md"))
    await store.refresh()
    #expect(changes.count == 1, "A changed catalog must notify")
}

private final class ChangeCount: @unchecked Sendable {
    var count = 0
}

@MainActor private final class ViewEvaluationCount {
    var count = 0
}

private struct SaveControlsTestView: View {
    let store: NoteStore
    let document: NoteDocument
    let lifecycle: LibraryLifecycle
    let evaluations: ViewEvaluationCount

    var body: some View {
        evaluations.count += 1
        return SaveNoteButton(document: document)
            .background(LibraryWindowStatusView(lifecycle: lifecycle, store: store))
    }
}

@MainActor @Observable private final class ProjectionValues {
    var number = 0.0
    var width = 0
    var item: String?
}

@Test(arguments: [Double.nan, .infinity, -.infinity, -10, 10, 14, 144, 200]) @MainActor
func numericBindingsClampReadsAndWrites(value: Double) {
    @Bindable var values = ProjectionValues()
    let binding = $values.number[clampedTo: EditorFont.sizeRange, fallback: EditorFont.defaultSize]
    let expected = value.isFinite ? min(max(value, 10), 144) : 14
    values.number = value
    #expect(binding.wrappedValue == expected)
    binding.wrappedValue = value
    #expect(values.number == expected)
    #expect(EditorFont.clampedSize(value) == expected)
}

@Test(arguments: [-1, 1, 4, 8, 99]) @MainActor
func tabWidthBindingsClampReadsAndWrites(value: Int) {
    @Bindable var values = ProjectionValues()
    let binding = $values.width[clampedTo: EditorFont.tabWidthRange]
    let expected = min(max(value, 1), 8)
    values.width = value
    #expect(binding.wrappedValue == expected)
    binding.wrappedValue = value
    #expect(values.width == expected)
}

@Test @MainActor func presentationBindingDismissesTheCurrentItemWithoutInventingOne() {
    @Bindable var values = ProjectionValues()
    let binding = $values.item.isPresented
    #expect(!binding.wrappedValue)
    binding.wrappedValue = true
    #expect(values.item == nil)
    values.item = "First"
    #expect(binding.wrappedValue)
    binding.wrappedValue = true
    #expect(values.item == "First")
    values.item = "Replacement"
    binding.wrappedValue = false
    #expect(values.item == nil)
    #expect(!binding.wrappedValue)
}
