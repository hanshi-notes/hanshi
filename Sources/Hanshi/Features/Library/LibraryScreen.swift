import SwiftUI

struct LibraryScreen: View {
    @Environment(NoteStore.self) private var store
    @State private var notebookID = "all"
    @State private var noteID: String?
    @State private var query = ""
    @State private var mode = ContentMode.source
    @State private var isZen = false
    @State private var showingNotebookSheet = false
    @State private var showingDestinationSheet = false
    @State private var notebookName = ""
    @State private var openingNoteID: String?
    @State private var renamingNote: Note?
    @State private var noteName = ""
    @State private var trashingNote: Note?
    @FocusState private var searchFocused: Bool

    private var notebook: Notebook? { store.notebooks.first { $0.id == notebookID } }
    private var selectedNote: Note? { store.notes.first { $0.id == noteID } }
    private var document: NoteDocument? { noteID.flatMap { store.documents[$0] } }
    private var visibleNotes: [Note] {
        (notebook?.notes ?? store.notes).filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
    }

    private var libraryLayout: some View {
        GeometryReader { geometry in
            if isZen {
                documentContent
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 140, idealWidth: geometry.size.width * 0.212, maxWidth: 440)
                        .ignoresSafeArea(.container, edges: .top)
                    noteList
                        .frame(minWidth: 180, idealWidth: geometry.size.width * 0.272, maxWidth: 560)
                        .ignoresSafeArea(.container, edges: .top)
                    content
                        .frame(minWidth: 450, idealWidth: geometry.size.width * 0.516)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
        .background(.white)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        .focusedSceneValue(\.contentMode, $mode)
        .focusedSceneValue(\.zenMode, $isZen)
        .focusedSceneValue(\.noteDocument, document)
    }

    var body: some View {
        libraryLayout
        .task(id: noteID) { await openSelectedNote() }
        .onChange(of: store.notebooks.map(\.id)) { _, ids in
            if notebookID != "all", !ids.contains(notebookID) { notebookID = "all" }
        }
        .onChange(of: store.notes.map(\.id)) { _, ids in
            if let noteID, !ids.contains(noteID), store.documents[noteID] == nil { self.noteID = nil }
        }
        .sheet(isPresented: $showingNotebookSheet) { newNotebookSheet }
        .sheet(isPresented: $showingDestinationSheet) { destinationSheet }
        .sheet(item: $renamingNote) { note in renameNoteSheet(note) }
        .confirmationDialog("Move this note to the Trash?", isPresented: Binding(
            get: { trashingNote != nil },
            set: { if !$0 { trashingNote = nil } }
        ), presenting: trashingNote) { note in
            Button("Move to Trash", role: .destructive) { Task { await store.trash(note) } }
        } message: { note in
            Text("\(note.name) will be moved to the Trash. Any unsaved changes will be saved first.")
        }
        .alert("Library Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("Retry") { Task { await store.refresh() } }
            Button("OK", role: .cancel) { }
        } message: { Text(store.errorMessage ?? "") }
        .background {
            Button("Find Notes") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 38)
            ScrollView {
                LazyVStack(spacing: 0) {
                    Button {
                        notebookID = "all"
                        query = ""
                        selectNote(store.notes.first?.id)
                    } label: {
                        sidebarRow("All Notes", icon: "doc.text.fill", count: store.notes.count,
                                   selected: notebookID == "all")
                    }
                    Button { showingNotebookSheet = true } label: {
                        sidebarRow("Notebooks", icon: "list.bullet.rectangle.fill", count: store.notes.count)
                    }
                    .help("New Notebook (⌘⇧N)")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.isBusy)

                    ForEach(store.notebooks) { notebook in
                        Button {
                            notebookID = notebook.id
                            query = ""
                            selectNote(notebook.notes.first?.id)
                        } label: {
                            sidebarRow(notebook.name, count: notebook.notes.count,
                                       selected: notebookID == notebook.id)
                        }
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: notebook.url.path)
                            }
                        }
                    }
                    sidebarRow("Tags", icon: "tag.fill", count: 0)
                        .accessibilityHint("Tag organization is not available yet")
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(red: 0.12, green: 0.16, blue: 0.18))
        .foregroundStyle(.white)
        .contextMenu {
            Button("New Notebook…") { showingNotebookSheet = true }
                .disabled(store.isBusy)
            Button("Show Library in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.files.root.path)
            }
            Button("Refresh Library") { Task { await store.refresh() } }
                .disabled(store.isBusy)
        }
        .background {
            Button("Refresh Library") { Task { await store.refresh() } }
                .keyboardShortcut("r")
                .disabled(store.isBusy)
                .hidden()
        }
    }

    private func sidebarRow(_ name: String, icon: String? = nil, count: Int,
                            selected: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .frame(width: 18, height: 18)
            }
            Text(name)
                .font(.system(size: 13.5, weight: .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(count, format: .number)
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
        }
        .padding(.leading, icon == nil ? 35 : 12)
        .padding(.trailing, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? Color.white.opacity(0.08) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    TextField("Search…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .padding(.horizontal, 5)
                        .focused($searchFocused)
                        .accessibilityLabel("Search notes by filename")
                    Image(systemName: "magnifyingglass")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .frame(width: 18, height: 18)
                        .frame(width: 29)
                }
                .frame(height: 24.5)
                .background(.white, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.14)))
                Button(action: newNote) {
                    Image(systemName: "plus")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .frame(width: 18, height: 18)
                        .frame(width: 34.5, height: 24)
                }
                .buttonStyle(.plain)
                .background(.white, in: RoundedRectangle(cornerRadius: 4.5))
                .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(.black.opacity(0.14)))
                .help("New Note (⌘N)")
                .accessibilityLabel("New Note")
                .keyboardShortcut("n")
                .disabled(store.isBusy)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(white: 0.97))
            .overlay(alignment: .bottom) { Divider() }
            HStack {
                Text("Name")
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 12))
                    .frame(width: 18, height: 18)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .overlay(alignment: .bottom) { Divider() }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleNotes) { note in
                            Button { selectNote(note.id) } label: {
                                NoteRowView(note: note, selected: noteID == note.id)
                            }
                            .buttonStyle(.plain)
                            .id(note.id)
                            .help("\(note.notebookName) / \(note.name)")
                            .contextMenu {
                                Button("Rename…") {
                                    noteName = note.url.deletingPathExtension().lastPathComponent
                                    renamingNote = note
                                }
                                .disabled(store.isBusy)
                                Button("Move to Trash", role: .destructive) { trashingNote = note }
                                    .disabled(store.isBusy)
                                Divider()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                            }
                        }
                    }
                }
                .onChange(of: noteID) { _, id in
                    if let id { scroll.scrollTo(id) }
                }
                .overlay {
                    if visibleNotes.isEmpty {
                        VStack(spacing: 12) {
                            Text(query.isEmpty ? "No notes yet" : "No matching notes")
                                .foregroundStyle(.secondary)
                            if query.isEmpty {
                                Button(store.notebooks.isEmpty ? "New Notebook" : "New Note", action: newNote)
                                    .disabled(store.isBusy)
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

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                toolbarGroup {
                    toolbarButton("Save (⌘S)", icon: document?.isModified == true ? "square.and.arrow.down.fill" : "square.and.arrow.down",
                                  action: document.map { document in { Task { await document.save() } } })
                    .disabled(document?.isModified != true || document?.isSaving == true)
                    toolbarDivider
                    toolbarButton("Edit", icon: "pencil", active: mode != .preview) {
                        mode = mode == .preview ? .source : .preview
                    }
                    .contextMenu {
                        ForEach(ContentMode.allCases) { option in
                            Button(option.rawValue) { mode = option }
                        }
                    }
                    toolbarDivider
                    toolbarButton("Tags", icon: "tag.fill")
                    toolbarDivider
                    toolbarButton("Attachments", icon: "paperclip")
                }
                toolbarGroup {
                    toolbarButton("Favorite", icon: "star")
                    toolbarDivider
                    toolbarButton("Pin", icon: "pin.fill")
                }
                toolbarGroup {
                    toolbarButton("Move to Trash", icon: "trash.fill")
                }
                Spacer(minLength: 0)
                toolbarGroup {
                    toolbarButton("Share", icon: "square.and.arrow.up")
                    toolbarDivider
                    toolbarButton("Show Note in Finder", icon: "arrow.up.forward.square",
                                  action: selectedNote.map { note in
                        { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
                    })
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(white: 0.97))
            .overlay(alignment: .bottom) { Divider() }
            documentContent
        }
    }

    @ViewBuilder private var documentContent: some View {
        if let document {
            NoteEditorContentView(document: document, files: store.files, mode: mode)
        } else if noteID != nil {
            VStack(spacing: 12) {
                if openingNoteID == noteID { ProgressView("Opening note…") }
                else {
                    Text("Unable to open this note.").foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await openSelectedNote() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a note to start writing")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbarDivider: some View { Divider().frame(height: 24) }

    private func toolbarGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .background(.white, in: RoundedRectangle(cornerRadius: 4.5))
            .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(.black.opacity(0.14)))
    }

    private func toolbarButton(_ title: String, icon: String, active: Bool = false,
                               action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 18, height: 18)
                .foregroundStyle(active ? .orange : Color(white: 0.13))
                .frame(width: 34.5, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(title)
        .help(action == nil ? "\(title) — not available yet" : title)
    }

    private var newNotebookSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Notebook").font(.title2.bold())
            Text("Create a folder in your Hanshi library.").foregroundStyle(.secondary)
            TextField("Notebook name", text: $notebookName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createNotebook)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingNotebookSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: createNotebook)
                    .keyboardShortcut(.defaultAction)
                    .disabled(notebookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var destinationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Notebook").font(.title2.bold())
            Text("The new note will be created in this folder.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.notebooks) { notebook in
                        Button {
                            showingDestinationSheet = false
                            notebookID = notebook.id
                            noteID = nil
                            createNote(in: notebook.url)
                        } label: {
                            Label(notebook.name, systemImage: "book.closed")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showingDestinationSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func renameNoteSheet(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Note").font(.title2.bold())
            TextField("Name", text: $noteName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { renameNote(note) }
            Text("The .md extension is kept automatically.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renamingNote = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { renameNote(note) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(noteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func renameNote(_ note: Note) {
        guard !store.isBusy else { return }
        let name = noteName
        renamingNote = nil
        Task {
            if await store.rename(note, to: name), noteID == note.id { document?.editor.requestFocus() }
        }
    }

    private func newNote() {
        if let notebook { createNote(in: notebook.url) }
        else if store.notebooks.isEmpty { showingNotebookSheet = true }
        else { showingDestinationSheet = true }
    }

    private func selectNote(_ id: String?) {
        searchFocused = false
        noteID = id
        if id != nil {
            if mode == .preview { mode = .source }
            document?.editor.requestFocus()
        }
    }

    private func openSelectedNote() async {
        guard let selectedNote else { return }
        openingNoteID = selectedNote.id
        await store.open(selectedNote)
        guard !Task.isCancelled, noteID == selectedNote.id else { return }
        openingNoteID = nil
        document?.editor.requestFocus()
    }

    private func createNotebook() {
        guard !notebookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let name = notebookName
        showingNotebookSheet = false
        Task {
            if let id = await store.createNotebook(named: name) {
                notebookID = id
                noteID = nil
                notebookName = ""
                query = ""
            }
        }
    }

    private func createNote(in folder: URL) {
        query = ""
        let destinationID = notebookID
        Task {
            let createdID = await store.createNote(in: folder)
            if notebookID == destinationID { selectNote(createdID) }
        }
    }
}

#Preview {
    LibraryScreen().environment(NoteStore(root: URL(filePath: "/tmp/HanshiPreview")))
}
