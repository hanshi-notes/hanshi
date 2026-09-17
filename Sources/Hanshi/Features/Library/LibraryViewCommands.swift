import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var contentMode: Binding<ContentMode>?
    @Entry var zenMode: Binding<Bool>?
    @Entry var notebookSidebarVisible: Binding<Bool>?
    @Entry var noteDocument: NoteDocument?
    @Entry var libraryRoot: URL?
}

struct LibraryViewCommands: Commands {
    @FocusedBinding(\.contentMode) private var mode
    @FocusedBinding(\.zenMode) private var isZen
    @FocusedBinding(\.notebookSidebarVisible) private var sidebarVisible
    @FocusedValue(\.noteDocument) private var document
    @FocusedValue(\.libraryRoot) private var libraryRoot

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if let document { Task { await document.save() } }
            }
            .keyboardShortcut("s")
            .disabled(document?.isModified != true || document?.isSaving == true)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export as HTML…", action: exportHTML)
                .disabled(document == nil || libraryRoot == nil)
            Button("Copy as HTML", action: copyHTML)
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(document == nil || libraryRoot == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisible == true ? "Hide Notebook Sidebar" : "Show Notebook Sidebar") {
                sidebarVisible?.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(sidebarVisible == nil || isZen == true)
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Editor") { mode = .source }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(mode == nil)
            Button("Preview") { mode = .preview }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(mode == nil)
            Button("Split View") { mode = .split }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(mode == nil)
            Divider()
            Button(isZen == true ? "Exit Zen Mode" : "Zen Mode") {
                isZen?.toggle()
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(isZen == nil)
        }
    }

    private func exportHTML() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + ".html"
        panel.allowedContentTypes = [.html]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                guard let html = await render(document) else { return }
                do { try await HTMLExport.write(html, to: url) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }

    private func copyHTML() {
        guard let document else { return }
        Task {
            guard let html = await render(document) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(html, forType: .string)
        }
    }

    private func render(_ document: NoteDocument) async -> String? {
        guard let libraryRoot else { return nil }
        do { return try await HTMLExport.document(text: document.text, url: document.url, root: libraryRoot) }
        catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}
