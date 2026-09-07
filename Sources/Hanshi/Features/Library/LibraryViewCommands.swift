import SwiftUI

extension FocusedValues {
    @Entry var contentMode: Binding<ContentMode>?
    @Entry var zenMode: Binding<Bool>?
    @Entry var notebookSidebarVisible: Binding<Bool>?
    @Entry var noteDocument: NoteDocument?
}

struct LibraryViewCommands: Commands {
    @FocusedBinding(\.contentMode) private var mode
    @FocusedBinding(\.zenMode) private var isZen
    @FocusedBinding(\.notebookSidebarVisible) private var sidebarVisible
    @FocusedValue(\.noteDocument) private var document

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if let document { Task { await document.save() } }
            }
            .keyboardShortcut("s")
            .disabled(document?.isModified != true || document?.isSaving == true)
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
}
