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
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store)
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
        // Leaving the note saved it; the draft is kept in the sense that matters, text and undo.
        try await zenEventually { (try? String(contentsOf: document.url, encoding: .utf8)) == draft }
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
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(mode: mode, noteID: note.id, defaults: preferences.defaults)
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
            if control.sidebarVisible != expectedSidebar {
                // Click the visible sidebar button, including when the notebook column is hidden.
                let column = split.arrangedSubviews[control.sidebarVisible == true ? 1 : 0]
                let inset = control.sidebarVisible == true ? 0 : BarMetrics.windowControlsInset
                let point = NSPoint(x: BarMetrics.margin + inset + BarMetrics.buttonWidth / 2,
                                    y: column.isFlipped ? BarMetrics.height / 2 : column.bounds.height - BarMetrics.height / 2)
                let location = column.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
            }
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

    @Test @MainActor func windowButtonsSitCentredInTheBarClearOfTheSidebarButton() async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let control = ZenTestControl()
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(defaults: preferences.defaults).environment(store)
            .overlay { ZenBindingProbe(control: control).frame(width: 0, height: 0) })
        let (window, lifecycle) = appWindow(host)
        defer { window.contentView = nil; window.close(); withExtendedLifetime(lifecycle) {} }
        try await zenEventually { control.sidebarVisible == true }
        control.toggleSidebar?()
        try await zenEventually { control.sidebarVisible == false }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try layerBitmap(host)
        func leftmostInk(rows: Range<Int>) -> Int? {
            (0..<300).first { x in
                rows.contains { y in (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1) < 0.5 }
            }
        }
        // The layer renders bottom-up, so the bar occupies the last rows. With the notebook
        // column hidden, the sidebar button is the leftmost ink in it.
        let icon = try #require(leftmostInk(rows: (bitmap.pixelsHigh - Int(BarMetrics.height))..<bitmap.pixelsHigh))
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let controls = host.convert(zoom.bounds, from: zoom)
        #expect(Double(icon) > controls.maxX, "The sidebar button starts at \(icon) pt, under window controls ending at \(controls.maxX) pt")
        #expect(abs(controls.midY - BarMetrics.height / 2) <= 1,
                "The window buttons are centred at \(controls.midY) pt instead of in the \(BarMetrics.height) pt bar")
        // The bar under the window's title area still takes clicks.
        let location = host.convert(NSPoint(x: BarMetrics.margin + BarMetrics.windowControlsInset + BarMetrics.buttonWidth / 2,
                                            y: BarMetrics.height / 2), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await zenEventually { control.sidebarVisible == true }
        // AppKit lays the title bar out again on resize, and the buttons must stay centred.
        window.setContentSize(NSSize(width: 1300, height: 720))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let resized = host.convert(zoom.bounds, from: zoom)
        #expect(abs(resized.midY - BarMetrics.height / 2) <= 1, "After resizing, the window buttons are centred at \(resized.midY) pt")
    }

    @Test(arguments: Hanshi.ContentMode.allCases) @MainActor
    func zenDocumentStartsBelowTheWindowButtons(mode: Hanshi.ContentMode) async throws {
        _ = NSApplication.shared
        let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Zen document\n\nText under the window buttons.\n".utf8).write(to: folder.appendingPathComponent("Zen.md"))
        let store = NoteStore(root: fixture.root)
        await store.refresh()
        let note = try #require(store.notes.first)
        await store.open(note)
        let document = try #require(store.documents[note.id])
        let control = ZenTestControl()
        let preferences = TestPreferences(); defer { preferences.remove() }
        let host = NSHostingView(rootView: LibraryScreen(mode: mode, noteID: note.id, defaults: preferences.defaults)
            .environment(store).overlay { ZenBindingProbe(control: control).frame(width: 0, height: 0) })
        let (window, lifecycle) = appWindow(host)
        defer { window.contentView = nil; window.close(); withExtendedLifetime(lifecycle) {} }
        try await zenEventually { control.current == false }
        control.toggle?()
        try await zenEventually { control.current == true }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let buttons = host.convert(zoom.bounds, from: zoom)
        var panels: [NSView] = []
        if mode != .preview { panels.append(document.editor.scrollView) }
        if mode != .source { panels.append(try #require(zenPreview(in: host)?.enclosingScrollView)) }
        for panel in panels {
            let top = host.convert(panel.bounds, from: panel).minY
            #expect(top >= buttons.maxY, "In \(mode), a panel starts at \(top) pt, above the window buttons ending at \(buttons.maxY) pt")
            // Where the bar ends outside Zen, so the text does not jump when Zen toggles.
            #expect(abs(top - BarMetrics.height) < 1, "In \(mode), a panel starts at \(top) pt instead of \(BarMetrics.height) pt")
        }
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

@MainActor func librarySplit(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView { return split }
    return view.subviews.lazy.compactMap { librarySplit(in: $0) }.first
}

@MainActor private func zenPreview(in view: NSView) -> NSTextView? {
    if let preview = view as? NSTextView, preview.accessibilityLabel() == "Markdown preview" { return preview }
    return view.subviews.lazy.compactMap { zenPreview(in: $0) }.first
}

@MainActor private func zenEventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(condition(), sourceLocation: sourceLocation)
}

/// A window set up like the app's: hidden title bar, with the library lifecycle attached.
@MainActor func appWindow(_ host: NSView) -> (NSWindow, LibraryLifecycle) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 650),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    let lifecycle = LibraryLifecycle()
    lifecycle.attach(to: window)
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    return (window, lifecycle)
}

/// The view's composed layers at one pixel per point. Rows run bottom-up.
@MainActor func layerBitmap(_ view: NSView) throws -> NSBitmapImageRep {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    try #require(view.layer).render(in: context.cgContext)
    return bitmap
}
