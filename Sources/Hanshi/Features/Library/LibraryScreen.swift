import SwiftUI

struct LibraryScreen: View {
    @Environment(NoteStore.self) private var store
    @AppStorage(Notebook.selectionKey) private var notebookID = "all"
    @AppStorage(SidebarTheme.key) private var sidebarTheme = SidebarTheme.standard
    @State private var noteID: String?
    @State private var restoredPath: String?
    @State private var query = ""
    @State private var mode = ContentMode.source
    @State private var isZen = false
    @State private var sidebarVisible = true
    @State private var notebooksExpanded = true
    @State private var collapsedNotebookIDs: Set<String> = []
    @State private var newNotebookParent: Notebook?
    @State private var layoutPreviewFocus: Bool?
    @State private var showingNotebookSheet = false
    @State private var showingDestinationSheet = false
    @State private var notebookName = ""
    @State private var previewSession = MarkdownPreviewSession()
    @State private var openingFromPreview = false
    @State private var openingNoteID: String?
    @State private var renamingNote: Note?
    @State private var noteName = ""
    @State private var trashingNote: Note?
    @State private var renamingNotebook: Notebook?
    @State private var trashingNotebook: Notebook?
    @State private var dropNotebookID: String?
    @FocusState private var searchFocused: Bool

    private let defaults: UserDefaults

    init(mode: ContentMode? = nil, noteID: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _notebookID = AppStorage(wrappedValue: "all", Notebook.selectionKey, store: defaults)
        _sidebarTheme = AppStorage(wrappedValue: .standard, SidebarTheme.key, store: defaults)
        _mode = State(initialValue: mode ?? defaults.string(forKey: ContentMode.startupKey).flatMap(ContentMode.init(rawValue:)) ?? .source)
        _noteID = State(initialValue: noteID)
        // Reopen on the note the reader left, alongside the notebook. Saving rewrites the file
        // atomically, so a note's id changes with every save and only its path still names it
        // at the next launch; the catalog arrives later, so the restore waits for it.
        _restoredPath = State(initialValue: noteID == nil ? defaults.string(forKey: Note.selectionKey) : nil)
    }

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
            // Keep the document's SwiftUI identity when hiding the library chrome.
            HSplitView {
                if !isZen && sidebarVisible {
                    NotebookSidebarView(notebooks: store.notebooks, noteCount: store.notes.count, selection: notebookID,
                                        root: store.files.root, theme: sidebarTheme, isBusy: store.isBusy,
                                        sessionID: store.sessionID, isExpanded: $notebooksExpanded,
                                        collapsedIDs: $collapsedNotebookIDs, dropTargetID: $dropNotebookID, onEvent: handle)
                        .frame(minWidth: 140, idealWidth: geometry.size.width * 0.212, maxWidth: 440)
                        .ignoresSafeArea(.container, edges: .top)
                }
                if !isZen {
                    NoteListView(notes: visibleNotes, selection: noteID, notebooks: store.notebooks, root: store.files.root,
                                 sessionID: store.sessionID, sidebarVisible: sidebarVisible, isBusy: store.isBusy,
                                 reloadError: store.reloadError, query: $query, searchFocused: $searchFocused, onEvent: handle)
                        .frame(minWidth: sidebarVisible ? 180 : 180 + BarMetrics.windowControlsInset,
                               idealWidth: geometry.size.width * 0.272, maxWidth: 560)
                        .ignoresSafeArea(.container, edges: .top)
                }
                VStack(spacing: 0) {
                    if !isZen {
                        NoteToolbarView(notebooks: store.notebooks, root: store.files.root, notebookSelection: notebookID,
                                        showsNotebookPicker: !sidebarVisible, document: document, noteURL: selectedNote?.url,
                                        mode: $mode, onSelectNotebook: selectNotebook)
                    }
                    // Zen hides the bar; the document keeps its place so it stays clear of the window's buttons.
                    NoteDocumentView(document: document, hasSelection: noteID != nil, isOpening: openingNoteID == noteID,
                                     files: store.files, mode: mode, libraryID: store.sessionID,
                                     resourceGeneration: store.resourceGeneration, noteURLs: store.notes.map(\.url),
                                     preview: previewSession, onEvent: handle)
                        .padding(.top, isZen ? BarMetrics.height : 0)
                }
                .frame(minWidth: sidebarVisible ? 450 : 610, idealWidth: geometry.size.width * 0.516)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .background(.white)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        .focusedSceneValue(\.contentMode, $mode)
        .focusedSceneValue(\.zenMode, layoutBinding($isZen))
        .focusedSceneValue(\.notebookSidebarVisible, layoutBinding($sidebarVisible))
        .focusedSceneValue(\.noteDocument, document)
        .focusedSceneValue(\.libraryRoot, store.files.root)
    }

    private func layoutBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue }, set: { value in
            // Capture the active panel before NSSplitView rearranges its children.
            layoutPreviewFocus = mode == .preview || previewSession.textView.window?.firstResponder === previewSession.textView
            binding.wrappedValue = value
        })
    }

    var body: some View {
        @Bindable var store = store
        libraryLayout
        .task(id: noteID) { await openSelectedNote() }
        // Leaving a note is a checkpoint: it stays open, but its edits should not wait for the
        // autosave interval. Watching the selection covers every route that changes it.
        .onChange(of: noteID) { previous, _ in
            guard let previous, let document = store.documents[previous] else { return }
            Task { await document.save() }
        }
        .onChange(of: mode) { focusSelectedNote() }
        .onChange(of: notebookID) {
            guard let notebook else { return }
            for ancestor in store.notebooks where ancestor.contains(notebook.url) {
                collapsedNotebookIDs.remove(ancestor.id)
            }
        }
        .task(id: [isZen, sidebarVisible]) {
            guard let layoutPreviewFocus, let document else { return }
            self.layoutPreviewFocus = nil
            if layoutPreviewFocus {
                previewSession.focusDocumentID = document.id
                previewSession.focusIfNeeded()
            } else {
                document.editor.requestFocus()
            }
        }
        .onChange(of: store.resourceGeneration, initial: true) {
            // An empty catalog before the first successful load is not a deleted notebook.
            guard store.hasLoaded else { return }
            if notebookID != "all", !store.notebooks.contains(where: { $0.id == notebookID }) { notebookID = "all" }
        }
        .onChange(of: store.notes.map(\.id), initial: true) { _, ids in
            // An empty catalog before the first load is not a deleted note, and dropping the
            // restored selection there would defeat reopening where the reader left off.
            guard store.hasLoaded else { return }
            var selection = noteID
            if let restoredPath {
                self.restoredPath = nil
                selection = store.notes.first { $0.url.path == restoredPath }?.id
                noteID = selection
            }
            guard let selection else { return }
            if !ids.contains(selection), store.documents[selection] == nil { noteID = nil; return }
            // A restored selection names a note that did not exist when the screen mounted,
            // so `.task(id: noteID)` already ran and found nothing. Open it now that it does.
            if ids.contains(selection), store.documents[selection] == nil {
                Task { await openSelectedNote() }
            }
        }
        .onChange(of: selectedNote?.url ?? document?.url, initial: true) { _, url in
            rememberSelectedNote(url)
        }
        .sheet(isPresented: $showingNotebookSheet) { notebookNameForm(renaming: nil) }
        .sheet(item: $renamingNotebook) { notebook in notebookNameForm(renaming: notebook) }
        .sheet(isPresented: $showingDestinationSheet) {
            NotebookPickerView(notebooks: store.notebooks, root: store.files.root, onEvent: handle)
        }
        .sheet(item: $renamingNote) { note in
            NameFormView(title: "Rename Note", placeholder: "Name", footnote: "The .md extension is kept automatically.",
                         confirmTitle: "Rename", name: $noteName, isBusy: store.isBusy) { event in
                switch event {
                case .confirm: renameNote(note)
                case .cancel: renamingNote = nil
                }
            }
        }
        .confirmationDialog("Move this note to the Trash?", isPresented: $trashingNote.isPresented, presenting: trashingNote) { note in
            Button("Move to Trash", role: .destructive) { Task { await store.trash(note) } }
        } message: { note in
            Text("\(note.name) will be moved to the Trash. Any unsaved changes will be saved first.")
        }
        .confirmationDialog("Move this notebook to the Trash?", isPresented: $trashingNotebook.isPresented, presenting: trashingNotebook) { notebook in
            Button("Move to Trash", role: .destructive) { Task { await store.trash(notebook) } }
        } message: { notebook in
            Text("The folder \(notebook.name) and all its contents will be moved to the Trash. Unsaved notes will be saved first.")
        }
        .alert("Library Error", isPresented: $store.errorMessage.isPresented) {
            Button("OK", role: .cancel) { }
        } message: { Text(store.errorMessage ?? "") }
        .background {
            Button("Find Notes") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        }
    }

    private func handle(_ event: NotebookSidebarView.Event) {
        switch event {
        case let .select(id): selectNotebook(id)
        case let .newNotebook(parent): showNewNotebook(in: parent)
        case let .rename(notebook):
            notebookName = notebook.name
            renamingNotebook = notebook
        case let .trash(notebook): trashingNotebook = notebook
        case let .move(noteID, notebook): moveNote(noteID, to: notebook)
        case .refresh: Task { await store.refresh() }
        }
    }

    private func handle(_ event: NoteListView.Event) {
        switch event {
        case .toggleSidebar: layoutBinding($sidebarVisible).wrappedValue.toggle()
        case .newNote: newNote()
        case let .select(id): selectNote(id)
        case let .move(noteID, notebook): moveNote(noteID, to: notebook)
        case let .rename(note):
            noteName = note.name
            renamingNote = note
        case let .trash(note): trashingNote = note
        case .retryReload: Task { await store.refresh() }
        }
    }

    private func handle(_ event: NoteDocumentView.Event) {
        switch event {
        case .editorAppeared: previewSession.openNote = openPreviewNote
        case .retryOpen: Task { await openSelectedNote() }
        }
    }

    private func handle(_ event: NotebookPickerView.Event) {
        switch event {
        case let .choose(notebook):
            showingDestinationSheet = false
            notebookID = notebook.id
            noteID = nil
            createNote(in: notebook.url)
        case .cancel: showingDestinationSheet = false
        }
    }

    private func notebookNameForm(renaming notebook: Notebook?) -> NameFormView {
        NameFormView(
            title: notebook == nil ? "New Notebook" : "Rename Notebook",
            message: notebook == nil
                ? "Create a folder in \(newNotebookParent?.path(in: store.files.root) ?? "your Hanshi library")."
                : "Rename this notebook and keep all its contents.",
            placeholder: "Notebook name", confirmTitle: notebook == nil ? "Create" : "Rename",
            name: $notebookName, isBusy: store.isBusy) { event in
            switch event {
            case .confirm: saveNotebook(notebook)
            case .cancel: showingNotebookSheet = false; renamingNotebook = nil
            }
        }
    }

    private func moveNote(_ id: String, to notebook: Notebook) {
        Task {
            if await store.move(noteID: id, to: notebook.id), noteID == id, notebookID != "all" {
                notebookID = notebook.id
            }
        }
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
        else if store.notebooks.isEmpty { showNewNotebook(in: nil) }
        else { showingDestinationSheet = true }
    }

    private func selectNotebook(_ id: String) {
        notebookID = id
        query = ""
        selectNote((notebook?.notes ?? store.notes).first?.id)
    }

    private func selectNote(_ id: String?) {
        openingFromPreview = false
        previewSession.pendingHeading = nil
        previewSession.focusDocumentID = nil
        searchFocused = false
        noteID = id
        if id != nil { focusSelectedNote() }
    }

    /// The reader's place in the library, so the next launch opens where they left off. Renaming
    /// a note moves its file, so this follows the path the selection has now.
    private func rememberSelectedNote(_ url: URL?) {
        if let url { defaults.set(url.path, forKey: Note.selectionKey) }
        else if noteID == nil, restoredPath == nil { defaults.removeObject(forKey: Note.selectionKey) }
    }

    private func openSelectedNote() async {
        guard let selectedNote else { return }
        openingNoteID = selectedNote.id
        await store.open(selectedNote)
        guard !Task.isCancelled, noteID == selectedNote.id else { return }
        openingNoteID = nil
        if !openingFromPreview { focusSelectedNote() }
    }

    private func focusSelectedNote() {
        if mode == .preview {
            previewSession.focusDocumentID = noteID
            previewSession.focusIfNeeded()
        } else {
            document?.editor.requestFocus()
        }
    }

    private func openPreviewNote(_ url: URL, fragment: String?) -> Bool {
        guard let note = store.notes.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else { return false }
        openingFromPreview = true
        previewSession.pendingHeading = fragment
        previewSession.focusDocumentID = note.id
        searchFocused = false
        if noteID == note.id {
            if let fragment { previewSession.navigateHeading(fragment) }
            previewSession.focusIfNeeded()
        } else { noteID = note.id }
        return true
    }

    private func showNewNotebook(in parent: Notebook?) {
        newNotebookParent = parent
        renamingNotebook = nil
        notebookName = ""
        showingNotebookSheet = true
    }

    private func saveNotebook(_ target: Notebook?) {
        guard !store.isBusy, !notebookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let name = notebookName
        let parent = newNotebookParent
        showingNotebookSheet = false
        renamingNotebook = nil
        Task {
            if let target {
                if await store.rename(target, to: name), notebookID == target.id { document?.editor.requestFocus() }
            } else if let id = await store.createNotebook(named: name, in: parent?.url) {
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

struct SaveNoteButton: View {
    let document: NoteDocument?

    var body: some View {
        BarButton(title: "Save (⌘S)",
                  icon: document?.isModified == true ? "square.and.arrow.down.fill" : "square.and.arrow.down") {
            if let document { Task { await document.save() } }
        }
        .disabled(document?.isModified != true || document?.isSaving == true)
    }
}
