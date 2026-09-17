import SwiftUI

struct NoteListView: View {
    enum Event {
        case toggleSidebar
        case newNote
        case select(String)
        case move(noteID: String, to: Notebook)
        case rename(Note)
        case trash(Note)
    }

    let notes: [Note]
    let selection: String?
    let notebooks: [Notebook]
    let root: URL
    let sessionID: UUID
    let sidebarVisible: Bool
    let isBusy: Bool
    @Binding var query: String
    let searchFocused: FocusState<Bool>.Binding
    let onEvent: (Event) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: BarMetrics.margin) {
                BarButton(title: sidebarVisible ? "Hide Notebook Sidebar" : "Show Notebook Sidebar", icon: "sidebar.left") {
                    onEvent(.toggleSidebar)
                }
                .barControl()
                .help(sidebarVisible ? "Hide Notebook Sidebar (⌃⌘S)" : "Show Notebook Sidebar (⌃⌘S)")
                HStack(spacing: 0) {
                    TextField("Search…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .padding(.horizontal, 5)
                        .focused(searchFocused)
                        .accessibilityLabel("Search notes by filename")
                    BarIconView("magnifyingglass")
                        .foregroundStyle(BarMetrics.iconColor)
                        .frame(width: 29)
                }
                .barControl(cornerRadius: 5)
                Button { onEvent(.newNote) } label: {
                    BarIconView("plus")
                        .foregroundStyle(BarMetrics.iconColor)
                        .frame(width: BarMetrics.buttonWidth, height: BarMetrics.controlHeight)
                }
                .buttonStyle(.plain)
                .barControl()
                .help("New Note (⌘N)")
                .accessibilityLabel("New Note")
                .keyboardShortcut("n")
                .disabled(isBusy)
            }
            .barGlassContainer()
            // Without the notebook column, this bar is the one under the window's buttons.
            .padding(.leading, sidebarVisible ? 0 : BarMetrics.windowControlsInset)
            .padding(.horizontal, BarMetrics.margin)
            .frame(height: BarMetrics.height)
            .background(Color(white: 0.97))
            .overlay(alignment: .bottom) { Divider() }
            HStack {
                Text("Name")
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 12))
                    .frame(width: BarMetrics.iconBox, height: BarMetrics.iconBox)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .overlay(alignment: .bottom) { Divider() }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(notes) { note in
                            Button { onEvent(.select(note.id)) } label: {
                                NoteRowView(note: note, selected: selection == note.id)
                                    .onDrag { NoteDrag.provider(noteID: note.id, sessionID: sessionID) }
                            }
                            .buttonStyle(.plain)
                            .id(note.id)
                            .help("\(note.notebookName) / \(note.name)")
                            .contextMenu {
                                Menu("Move to Notebook") {
                                    ForEach(notebooks.filter { $0.url != note.url.deletingLastPathComponent() }) { notebook in
                                        Button(notebook.path(in: root)) { onEvent(.move(noteID: note.id, to: notebook)) }
                                    }
                                }
                                .disabled(isBusy || notebooks.count < 2)
                                Button("Rename…") { onEvent(.rename(note)) }
                                    .disabled(isBusy)
                                Button("Move to Trash", role: .destructive) { onEvent(.trash(note)) }
                                    .disabled(isBusy)
                                Divider()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                            }
                        }
                    }
                }
                .onChange(of: selection) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
                .overlay {
                    if notes.isEmpty {
                        VStack(spacing: 12) {
                            Text(query.isEmpty ? "No notes yet" : "No matching notes")
                                .foregroundStyle(.secondary)
                            if query.isEmpty {
                                Button(notebooks.isEmpty ? "New Notebook" : "New Note") { onEvent(.newNote) }
                                    .disabled(isBusy)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .foregroundStyle(Color(white: 0.12))
        .background(.white)
    }
}

#Preview {
    @Previewable @FocusState var searchFocused: Bool
    let notebook = URL(filePath: "/library/Writing")
    NoteListView(
        notes: [Note(id: "draft", url: notebook.appendingPathComponent("Draft.md"))],
        selection: "draft", notebooks: [], root: URL(filePath: "/library"), sessionID: UUID(),
        sidebarVisible: true, isBusy: false,
        query: .constant(""), searchFocused: $searchFocused) { _ in }
        .frame(width: 320, height: 400)
}
