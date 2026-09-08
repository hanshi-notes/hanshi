import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test @MainActor func hiddenSidebarNotebookPickerSelectsNotesAndKeepsDrafts() async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let control = ZenTestControl()
        let host = NSHostingView(rootView: LibraryScreen().environment(store)
            .overlay { ZenBindingProbe(control: control).frame(width: 0, height: 0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await zenEventually { control.sidebarVisible == true }
        #expect(notebookPicker(in: host) == nil)
        control.toggleSidebar?()
        try await zenEventually { notebookPicker(in: host) != nil }
        let picker = try #require(notebookPicker(in: host))
        host.layoutSubtreeIfNeeded()
        #expect(picker.bounds.width >= 175)
        let titleFont = picker.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(try #require(titleFont).pointSize >= 14)
        #expect(picker.bounds.height >= 24)
        #expect(picker.itemTitles == ["All Notes"])
        #expect(picker.titleOfSelectedItem == "All Notes")

        _ = await store.createNotebook(named: "Empty")
        let folder = try await store.files.createNotebook(named: "Writing")
        try Data("# Draft\n".utf8).write(to: folder.appendingPathComponent("First.md"))
        await store.refresh()
        try await zenEventually { picker.itemTitles == ["All Notes", "Empty", "Writing"] }
        func choose(_ title: String) throws {
            let index = picker.indexOfItem(withTitle: title)
            try #require(index >= 0)
            try #require(picker.menu).performActionForItem(at: index)
        }
        try choose("Writing")
        let note = try #require(store.notes.first)
        try await zenEventually { store.documents[note.id]?.editor.textView === window.firstResponder }
        let notebookFont = picker.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(try #require(notebookFont).pointSize >= 14)
        let document = try #require(store.documents[note.id])
        document.editor.textView.undoManager?.groupsByEvent = false
        document.editor.textView.undoManager?.beginUndoGrouping()
        document.editor.textView.insertText("Unsaved ", replacementRange: NSRange(location: 2, length: 0))
        document.editor.textView.undoManager?.endUndoGrouping()
        let draft = document.text
        try choose("Empty")
        try await zenEventually { document.editor.textView.window == nil }
        #expect(picker.titleOfSelectedItem == "Empty")
        try choose("All Notes")
        try await zenEventually { window.firstResponder === document.editor.textView }
        #expect(document.text == draft)
        #expect(document.isModified)
        #expect(document.editor.textView.undoManager?.canUndo == true)
        try choose("Writing")
        let notebook = try #require(store.notebooks.first { $0.name == "Writing" })
        #expect(await store.rename(notebook, to: "Renamed"))
        try await zenEventually { picker.titleOfSelectedItem == "Renamed" }
        control.toggleSidebar?()
        try await zenEventually { notebookPicker(in: host) == nil }
        control.toggleSidebar?()
        try await zenEventually { notebookPicker(in: host)?.titleOfSelectedItem == "Renamed" }
        #expect(document.text == draft)
        document.editor.textView.undoManager?.undo()
        #expect(document.text == "# Draft\n")
    }

    @Test(arguments: [(Hanshi.ContentMode.source, false), (.split, false), (.split, true), (.preview, true)], [false, true]) @MainActor
    func libraryVisibilityKeepsTheSelectedDocumentVisible(panel: (Hanshi.ContentMode, Bool), sidebarCycle: Bool) async throws {
        let (mode, focusPreview) = panel
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = "# Zen document\n\nText that must stay visible.\n"
        try Data(original.utf8).write(to: folder.appendingPathComponent("Zen.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let note = try #require(store.notes.first)
        await store.open(note)
        let document = try #require(store.documents[note.id])
        let editor = document.editor
        let control = ZenTestControl()
        let host = NSHostingView(rootView: LibraryScreen(mode: mode, noteID: note.id)
            .environment(store).overlay { ZenBindingProbe(control: control).frame(width: 0, height: 0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await zenEventually { control.current != nil && control.sidebarVisible != nil }
        let split = try #require(librarySplit(in: host))
        #expect(split.arrangedSubviews.count == 3)
        editor.textView.undoManager?.groupsByEvent = false
        editor.textView.undoManager?.beginUndoGrouping()
        editor.textView.insertText("Draft ", replacementRange: NSRange(location: 2, length: 0))
        editor.textView.undoManager?.endUndoGrouping()
        let draft = document.text
        let selection = editor.textView.selectedRange()
        let focusedView: NSView
        if focusPreview {
            try await zenEventually { zenPreview(in: host)?.string.contains("Draft Zen document") == true }
            focusedView = try #require(zenPreview(in: host))
        } else { focusedView = editor.textView }
        #expect(window.makeFirstResponder(focusedView))
        // A hidden sidebar stays hidden after entering and leaving Zen.
        let steps = sidebarCycle
            ? [(false, false), (true, false), (false, false), (false, true)]
            : [(true, true), (false, true), (true, true), (false, true)]
        for (expectedZen, expectedSidebar) in steps {
            if control.sidebarVisible != expectedSidebar { control.toggleSidebar?() }
            if control.current != expectedZen { control.toggle?() }
            try await zenEventually { control.current == expectedZen && control.sidebarVisible == expectedSidebar }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            #expect(split.arrangedSubviews.count == (expectedZen ? 1 : expectedSidebar ? 3 : 2))
            #expect((notebookPicker(in: host) != nil) == (!expectedZen && !expectedSidebar))
            if mode != .preview {
                #expect(editor.textView.isDescendant(of: host))
                #expect(editor.textView.window === window)
                #expect(editor.scrollView.visibleRect.width > 100)
                #expect(editor.scrollView.visibleRect.height > 100)
                #expect(editor.textView.selectedRange() == selection)
            }
            if mode != .source {
                let preview = try #require(zenPreview(in: host))
                try await zenEventually { preview.string.contains("Draft Zen document") }
                #expect(preview.visibleRect.width > 100 && preview.visibleRect.height > 100)
            }
            #expect(document.text == draft)
            #expect(window.firstResponder === focusedView)
            if expectedZen, mode == .source {
                #expect(abs(editor.scrollView.frame.width - host.bounds.width) < 2)
            }
        }
        let undo = try #require(editor.textView.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(document.text == original)
    }
}

@MainActor private func notebookPicker(in view: NSView) -> NSPopUpButton? {
    if let picker = view as? NSPopUpButton { return picker }
    return view.subviews.lazy.compactMap { notebookPicker(in: $0) }.first
}

@MainActor private final class ZenTestControl {
    var current: Bool?
    var toggle: (() -> Void)?
    var sidebarVisible: Bool?
    var toggleSidebar: (() -> Void)?
}

private struct ZenBindingProbe: View {
    @FocusedBinding(\.zenMode) private var isZen
    @FocusedBinding(\.notebookSidebarVisible) private var sidebarVisible
    let control: ZenTestControl
    var body: some View {
        Color.clear.onChange(of: isZen, initial: true) { _, value in
            control.current = value
            control.toggle = { isZen?.toggle() }
        }
        .onChange(of: sidebarVisible, initial: true) { _, value in
            control.sidebarVisible = value
            control.toggleSidebar = { sidebarVisible?.toggle() }
        }
    }
}

@MainActor private func librarySplit(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView { return split }
    return view.subviews.lazy.compactMap { librarySplit(in: $0) }.first
}

@MainActor private func zenPreview(in view: NSView) -> PreviewTextView? {
    if let preview = view as? PreviewTextView { return preview }
    return view.subviews.lazy.compactMap { zenPreview(in: $0) }.first
}

@MainActor private func zenEventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition(), sourceLocation: sourceLocation)
}
