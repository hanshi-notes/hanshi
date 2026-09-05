import Foundation
import Observation

@Observable
final class NoteStore {
    private(set) var notebooks: [Notebook] = []
    private(set) var isBusy = false
    var errorMessage: String?
    let files: LibraryFiles

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
        defer { isBusy = false }
        do { notebooks = try await files.load() }
        catch { errorMessage = error.localizedDescription }
    }

    func createNotebook(named name: String) async -> String? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let url = try await files.createNotebook(named: name)
            notebooks = try await files.load()
            return notebooks.first { $0.url == url }?.id
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
            let url = try await files.createNote(in: folder)
            notebooks = try await files.load()
            return notes.first { $0.url == url }?.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
