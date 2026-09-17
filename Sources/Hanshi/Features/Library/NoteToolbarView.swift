import SwiftUI

struct NoteToolbarView: View {
    let notebooks: [Notebook]
    let root: URL
    let notebookSelection: String
    let showsNotebookPicker: Bool
    let document: NoteDocument?
    let noteURL: URL?
    @Binding var mode: ContentMode
    let onSelectNotebook: (String) -> Void

    var body: some View {
        HStack(spacing: BarMetrics.margin) {
            if showsNotebookPicker {
                Picker("Notebook", selection: Binding(get: { notebookSelection }, set: onSelectNotebook)) {
                    Text("All Notes").font(.system(size: 14)).tag("all")
                    ForEach(notebooks) { notebook in
                        Text(notebook.path(in: root)).font(.system(size: 14)).tag(notebook.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 180, height: 28)
                .help(notebooks.first { $0.id == notebookSelection }?.name ?? "All Notes")
            }
            group {
                SaveNoteButton(document: document)
                divider
                BarButton(title: "Edit", icon: "highlighter", active: mode != .preview) {
                    mode = mode == .preview ? .source : .preview
                }
                .contextMenu {
                    ForEach(ContentMode.allCases) { option in
                        Button(option.rawValue) { mode = option }
                    }
                }
                divider
                BarButton(title: "Tags", icon: "tag.fill")
                divider
                BarButton(title: "Attachments", icon: "paperclip")
            }
            group {
                BarButton(title: "Favorite", icon: "star")
                divider
                BarButton(title: "Pin", icon: "pin.fill")
            }
            group {
                BarButton(title: "Move to Trash", icon: "trash.fill")
            }
            Spacer(minLength: 0)
            group {
                BarButton(title: "Share", icon: "square.and.arrow.up")
                divider
                BarButton(title: "Show Note in Finder", icon: "arrow.up.forward.square",
                          action: noteURL.map { url in { NSWorkspace.shared.activateFileViewerSelecting([url]) } })
            }
        }
        .barGlassContainer()
        .padding(.horizontal, BarMetrics.margin)
        .frame(height: BarMetrics.height)
        .background(Color(white: 0.97))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var divider: some View { Divider().frame(height: BarMetrics.controlHeight) }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0, content: content).barControl()
    }
}

#Preview {
    NoteToolbarView(notebooks: [], root: URL(filePath: "/library"), notebookSelection: "all",
                    showsNotebookPicker: true, document: nil, noteURL: nil, mode: .constant(.source)) { _ in }
        .frame(width: 900)
}
