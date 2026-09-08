import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test @MainActor func previewEditsUpdateTheDraftSourceUndoRedoAndSavedFile() async throws {
        let fixture = try PreviewResourceFixture()
        defer { fixture.remove() }
        let files = LibraryFiles(root: fixture.root)
        let notebook = try await files.createNotebook(named: "Notes")
        let url = notebook.appendingPathComponent("Note.md")
        let source = "**Bold** and café 👩🏽‍💻"
        try Data(source.utf8).write(to: url)
        let contents = try await files.readNote(at: url)
        let document = NoteDocument(note: Note(id: "editing", url: url), contents: contents) { url, text, expected in
            try await files.saveNote(at: url, text: text, expected: expected)
        }
        let session = MarkdownPreviewSession(debounce: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { session.hide(); window.contentView = nil; window.close() }
        session.show(PreviewSnapshot(library: UUID(), documentID: document.id, text: source, url: url, root: fixture.root), document: document)
        await session.waitForRendering()
        let view = session.textView
        #expect(window.makeFirstResponder(view))
        #expect(view.isEditable, "Preview editing defaults to enabled")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(previewMarkerIsHidden(view))
        let undo = try #require(view.undoManager)
        undo.beginUndoGrouping()
        view.insertText("X", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        await drainPreviewEdits(session)
        #expect(document.text == "**BXold** and café 👩🏽‍💻")
        #expect(document.editor.displayedText == document.text)
        #expect(document.isModified)
        #expect(view.selectedRange().location == 4)
        #expect(previewMarkerIsHidden(view))
        #expect(undo.canUndo)
        undo.undo()
        await drainPreviewEdits(session)
        #expect(document.text == source)
        #expect(undo.canRedo)
        undo.redo()
        await drainPreviewEdits(session)
        #expect(document.text == "**BXold** and café 👩🏽‍💻")
        #expect(await document.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == document.text)
        #expect(!document.isModified)
    }

    @Test(arguments: ["Second", "**F日本語irst**"]) @MainActor
    func previewCompositionAndPendingEditsStayWithTheirNote(_ incoming: String) async throws {
        let first = PreviewTestFixtures.document("**First**")
        let second = PreviewTestFixtures.document(incoming)
        let session = MarkdownPreviewSession(debounce: .zero)
        defer { session.hide() }
        let library = UUID()
        func snapshot(_ document: NoteDocument) -> PreviewSnapshot {
            PreviewSnapshot(library: library, documentID: document.id, text: document.text,
                url: document.url, root: document.url.deletingLastPathComponent())
        }
        session.show(snapshot(first), document: first)
        await session.waitForRendering()
        let view = session.textView
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var settingsChange = snapshot(first)
        settingsChange.settings.showsMarkdownMarkers = true
        session.show(settingsChange, document: first)
        await session.waitForRendering()
        #expect(view.hasMarkedText())
        #expect(first.text == "**First**")
        view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        // Switch before the engine publishes its asynchronous binding callback.
        session.show(snapshot(second), document: second)
        #expect(!view.isEditable, "The outgoing view cannot edit the incoming note while it loads")
        await drainPreviewEdits(session)
        #expect(first.text == "**F日本語irst**")
        #expect(second.text == incoming)
        #expect(view.string == incoming)
        view.insertText("!", replacementRange: NSRange(location: incoming.utf16.count, length: 0))
        await drainPreviewEdits(session)
        #expect(second.text == incoming + "!")
        #expect(first.text == "**F日本語irst**")
        // This fixture rejects writes: failed saving must retain the preview draft.
        #expect(await second.save() == false)
        #expect(second.isModified)
        #expect(second.text == incoming + "!")
        session.show(snapshot(first), document: first)
        await session.waitForRendering()
        #expect(view.string == first.text)
    }

    @Test @MainActor func previewSettingsPersistAndReconfigureAMountedPreview() async throws {
        let suite = "HanshiTests.Preview.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = PreviewTestFixtures.document("**Bold**")
        let session = MarkdownPreviewSession(debounce: .zero)
        let snapshot = PreviewSnapshot(library: UUID(), documentID: document.id, text: document.text, url: document.url, root: document.url.deletingLastPathComponent())
        let host = NSHostingView(rootView: MarkdownPreviewView(session: session, snapshot: snapshot, document: document).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { session.hide(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await session.waitForRendering()
        #expect(session.textView.isEditable)
        session.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(previewMarkerIsHidden(session.textView))
        defaults.set(true, forKey: PreviewSettings.showsMarkdownMarkersKey)
        try await previewEventually { !previewMarkerIsHidden(session.textView) }
        #expect(session.textView.isEditable)
        defaults.set(false, forKey: PreviewSettings.allowsEditingKey)
        try await previewEventually { !session.textView.isEditable && previewMarkerIsHidden(session.textView) }
        session.textView.insertText("blocked", replacementRange: NSRange(location: 3, length: 0))
        await drainPreviewEdits(session)
        #expect(document.text == "**Bold**")
        defaults.set(true, forKey: PreviewSettings.allowsEditingKey)
        try await previewEventually { session.textView.isEditable && !previewMarkerIsHidden(session.textView) }
        #expect(defaults.bool(forKey: PreviewSettings.showsMarkdownMarkersKey))
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        #expect(reopenedDefaults.bool(forKey: PreviewSettings.allowsEditingKey))
        #expect(reopenedDefaults.bool(forKey: PreviewSettings.showsMarkdownMarkersKey))
        #expect(!document.isModified)
    }

    @Test @MainActor func settingsSwitchesWriteThePreviewPreferences() async throws {
        let suite = "HanshiTests.PreviewControls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: TextEditingSettingsView().defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        func switches(in view: NSView) -> [NSSwitch] {
            if let control = view as? NSSwitch { return [control] }
            return view.subviews.flatMap { switches(in: $0) }
        }
        // SwiftUI exposes labels through virtual accessibility elements, not NSSwitch.
        // Identify each native control by the preference its action actually changes.
        var controls: [String: NSSwitch] = [:]
        for control in switches(in: host) {
            let before = defaults.dictionaryRepresentation()
            control.performClick(nil)
            for key in [PreviewSettings.allowsEditingKey, PreviewSettings.showsMarkdownMarkersKey] {
                if (before[key] as? Bool) != (defaults.object(forKey: key) as? Bool) { controls[key] = control }
            }
            control.performClick(nil)
        }
        let editing = try #require(controls[PreviewSettings.allowsEditingKey])
        let markers = try #require(controls[PreviewSettings.showsMarkdownMarkersKey])
        #expect(editing.state == .on)
        #expect(markers.state == .off)
        markers.performClick(nil)
        try await previewEventually { defaults.bool(forKey: PreviewSettings.showsMarkdownMarkersKey) }
        editing.performClick(nil)
        try await previewEventually { defaults.object(forKey: PreviewSettings.allowsEditingKey) as? Bool == false }
        try await previewEventually { !markers.isEnabled }
        #expect(markers.state == .on)
    }
}

@MainActor private func previewMarkerIsHidden(_ view: NSTextView) -> Bool {
    guard let storage = view.textStorage, storage.length > 0 else { return false }
    let color = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    return color?.alphaComponent == 0 || (font?.pointSize ?? 16) < 1
}

@MainActor private func drainPreviewEdits(_ session: MarkdownPreviewSession) async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    await session.waitForRendering()
}

@MainActor private func previewEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition())
}
