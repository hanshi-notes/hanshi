import AppKit
import SwiftUI
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test(arguments: [true, false]) @MainActor func editorLayoutSettlesWhenResizingAndSwitchingPanels(blank: Bool) async throws {
        _ = NSApplication.shared
        let source = blank ? "" : String(repeating: "A long Markdown line with Unicode 😀 and **bold text**. ", count: 20) + "\n"
        let document = NoteDocument(note: Note(id: "layout", url: URL(filePath: "/unused.md")),
                                    contents: NoteContents(data: Data(source.utf8), text: source, fileID: "layout")) {
            _, _, _ in throw CocoaError(.fileWriteUnknown)
        }
        let lifecycle = LibraryLifecycle()
        let host = LayoutHostingView(rootView: layoutContent(document: document, lifecycle: lifecycle, mode: .source))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "Hanshi layout regression test"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        for (width, mode) in [(1440.0, Hanshi.ContentMode.source), (1020, .source), (1600, .split), (1100, .split), (1020, .preview), (1020, .source)] {
            let before = host.constraintUpdates
            host.rootView = layoutContent(document: document, lifecycle: lifecycle, mode: mode)
            window.setContentSize(NSSize(width: width, height: 500))
            window.contentView?.layoutSubtreeIfNeeded()
            if let split = findSplitView(in: host) {
                split.setPosition(140, ofDividerAt: 0)
                split.setPosition(321, ofDividerAt: 1)
            }
            // Allow AppKit's display cycle to run: synchronous layout alone hides the feedback loop.
            try await Task.sleep(for: .seconds(1))
            #expect(host.constraintUpdates - before < 30, "Layout must settle for \(mode) at width \(width)")
            if mode != .preview {
                #expect(document.editor.scrollView.bounds.width > 100)
                #expect(document.editor.scrollView.bounds.width <= width)
                #expect(document.editor.scrollView.bounds.height > 100)
                #expect(document.editor.scrollView.bounds.height <= window.frame.height)
            }
        }
        #expect(document.text == source)
    }
}

@MainActor private func layoutContent(document: NoteDocument, lifecycle: LibraryLifecycle, mode: Hanshi.ContentMode) -> some View {
    GeometryReader { geometry in
        HSplitView {
            Color.gray.frame(minWidth: 140, idealWidth: geometry.size.width * 0.212, maxWidth: 440).ignoresSafeArea(.container, edges: .top)
            Color.white.frame(minWidth: 180, idealWidth: geometry.size.width * 0.272, maxWidth: 560).ignoresSafeArea(.container, edges: .top)
            VStack(spacing: 0) {
                Color.gray.frame(height: 38)
                NoteEditorContentView(document: document, files: LibraryFiles(root: URL(filePath: "/unused")), mode: mode)
            }
            .frame(minWidth: 450, idealWidth: geometry.size.width * 0.516)
            .ignoresSafeArea(.container, edges: .top)
        }
    }
    .ignoresSafeArea(.container, edges: .top)
    .background(LibraryWindowAttachment(lifecycle: lifecycle, isEdited: document.isModified))
    .frame(minWidth: 1020, minHeight: 580)
}

@MainActor private final class LayoutHostingView<Content: View>: NSHostingView<Content> {
    var constraintUpdates = 0

    override func updateConstraints() {
        constraintUpdates += 1
        super.updateConstraints()
    }
}

@MainActor private func findSplitView(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView { return split }
    return view.subviews.lazy.compactMap { findSplitView(in: $0) }.first
}
