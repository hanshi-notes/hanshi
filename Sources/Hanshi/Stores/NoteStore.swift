import Foundation
import Observation

@Observable
final class NoteStore {
    private(set) var notebooks: [Notebook] = []
    private(set) var isBusy = false
    var errorMessage: String?
    let files: LibraryFiles
    let sessionID = UUID()
    private(set) var resourceGeneration = 0
    // ponytail: keep opened sessions for this library; evict clean sessions if memory becomes a constraint.
    private(set) var documents: [String: NoteDocument] = [:]

    // The Settings toggle, unless a caller pins it.
    var usesTitleTemplate: Bool {
        get { pinnedTitleTemplate ?? NoteTitle.isEnabled }
        set { pinnedTitleTemplate = newValue }
    }
    @ObservationIgnored private var pinnedTitleTemplate: Bool?

    var hasUnsavedChanges: Bool { documents.values.contains { $0.isModified || $0.isSaving } }

    init(root: URL = URL.documentsDirectory.appendingPathComponent("hanshi", isDirectory: true)) {
        files = LibraryFiles(root: root)
    }

    var notes: [Note] {
        notebooks.flatMap(\.notes).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame
                ? $0.notebookName.localizedStandardCompare($1.notebookName) == .orderedAscending
                : order == .orderedAscending
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; resourceGeneration += 1 }
        do {
            let loaded = try await files.load()
            notebooks = loaded.map { notebook in
                Notebook(id: notebook.id, url: notebook.url, notes: notebook.notes.map { note in
                    if let document = documents.values.first(where: {
                        $0.url == note.url || $0.saved.fileID == note.id
                    }) {
                        document.url = note.url
                        return Note(id: document.id, url: note.url)
                    }
                    return note
                })
            }
            for document in documents.values { await document.reload(using: files) }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func createNotebook(named name: String) async -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await files.createNotebook(named: name).resolvingSymlinksInPath()
            isBusy = false
            await refresh()
            // The loaded URLs come from FileManager, so compare them resolved: a library reached
            // through a symbolic link spells the same folder two ways.
            return notebooks.first { $0.url.resolvingSymlinksInPath() == url }?.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func createNote(in folder: URL) async -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await files.createNote(in: folder,
                                                 text: usesTitleTemplate ? NoteTitle.template : "")
                .resolvingSymlinksInPath()
            isBusy = false
            await refresh()
            return notes.first { $0.url.resolvingSymlinksInPath() == url }?.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func open(_ note: Note) async {
        guard documents[note.id] == nil else { return }
        let wasListed = notes.contains { $0.id == note.id }
        do {
            let contents = try await files.readNote(at: note.url)
            guard documents[note.id] == nil else { return }
            // A notebook may have moved or been trashed while the read was in flight.
            let currentNote = notes.first { $0.id == note.id }
            guard currentNote != nil || !wasListed else { return }
            let files = files
            let document = NoteDocument(note: currentNote ?? note, contents: contents) { url, text, expected in
                try await files.saveNote(at: url, text: text, expected: expected)
            }
            document.didSave = { [weak self] document, previousText in
                await self?.renameToMatchHeading(document, previousText: previousText)
            }
            documents[note.id] = document
        } catch {
            if !wasListed || notes.contains(where: { $0.id == note.id }) { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult func rename(_ note: Note, to name: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let document = documents[note.id]
        if document?.isSaving == true, await document?.save() != true {
            errorMessage = document?.errorMessage
            return false
        }
        do {
            let url = try files.renameNote(at: document?.url ?? note.url, to: name)
            document?.url = url
            isBusy = false
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Keeps the file named after the note's heading, until someone renames the file by hand.
    private func renameToMatchHeading(_ document: NoteDocument, previousText: String) async {
        guard usesTitleTemplate, !isBusy,
              let note = notes.first(where: { $0.id == document.id }),
              NoteTitle.filename(for: previousText) == note.name || NoteTitle.isDefault(note.name),
              let heading = NoteTitle.filename(for: document.text), heading != note.name else { return }
        await rename(note, to: availableName(heading, like: note))
    }

    /// `name`, or the first "name (n)" free in the note's notebook, so a shared heading cannot
    /// fail the save with a name clash.
    private func availableName(_ name: String, like note: Note) -> String {
        let taken = Set(notes.filter { $0.notebookName == note.notebookName && $0.id != note.id }.map(\.name))
        guard taken.contains(name) else { return name }
        return (1...).lazy.map { "\(name) (\($0))" }.first { !taken.contains($0) } ?? name
    }

    @discardableResult func trash(_ note: Note) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let document = documents[note.id]
        if let document, !(await document.save()) {
            errorMessage = document.errorMessage
            return false
        }
        do {
            try files.trashNote(at: document?.url ?? note.url)
            documents.removeValue(forKey: note.id)
            isBusy = false
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult func saveAll() async -> Bool {
        for document in documents.values where document.isModified || document.isSaving {
            guard await document.save() else { return false }
        }
        return !hasUnsavedChanges
    }

    @discardableResult func rename(_ notebook: Notebook, to name: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        while let document = documents(in: notebook).first(where: \.isSaving) {
            guard await document.save() else { errorMessage = document.errorMessage; return false }
        }
        do {
            let url = try files.renameNotebook(at: notebook.url, to: name)
            for document in documents(in: notebook) {
                document.url = url.appendingPathComponent(document.url.lastPathComponent)
            }
            if let index = notebooks.firstIndex(where: { $0.id == notebook.id }) {
                notebooks[index] = Notebook(id: notebook.id, url: url, notes: notebooks[index].notes.map {
                    Note(id: $0.id, url: url.appendingPathComponent($0.url.lastPathComponent))
                })
            }
            isBusy = false
            await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult func trash(_ notebook: Notebook) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        // Recheck all sessions after each await: another note may have been edited while saving.
        while let document = documents(in: notebook).first(where: { $0.isModified || $0.isSaving }) {
            guard await document.save() else { errorMessage = document.errorMessage; return false }
        }
        do {
            try files.trashNotebook(at: notebook.url)
            for document in documents(in: notebook) { documents.removeValue(forKey: document.id) }
            notebooks.removeAll { $0.id == notebook.id }
            isBusy = false
            await refresh()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func documents(in notebook: Notebook) -> [NoteDocument] {
        documents.values.filter { $0.url.deletingLastPathComponent().standardizedFileURL.path == notebook.url.standardizedFileURL.path }
    }

    enum CloseAction { case save, discard, cancel }

    func finishEditing(_ action: CloseAction) async -> Bool {
        switch action {
        case .save: return await saveAll()
        case .cancel: return false
        case .discard:
            guard !documents.values.contains(where: \.isSaving) else { return false }
            for document in documents.values { document.edit(document.saved.text) }
            return true
        }
    }
}
