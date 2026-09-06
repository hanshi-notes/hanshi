import Foundation
import Observation

@Observable
final class NoteDocument: Identifiable {
    let id: String
    var url: URL
    private(set) var text: String
    private(set) var saved: NoteContents
    private(set) var isSaving = false
    var errorMessage: String?
    @ObservationIgnored private var saveTask: Task<Bool, Never>?
    @ObservationIgnored private let write: @Sendable (URL, String, Data) async throws -> NoteContents
    @ObservationIgnored lazy var editor = MarkdownEditorSession(document: self)

    init(note: Note, contents: NoteContents,
         write: @escaping @Sendable (URL, String, Data) async throws -> NoteContents) {
        id = note.id
        url = note.url
        text = contents.text
        saved = contents
        self.write = write
    }

    var isModified: Bool { text != saved.text }

    func edit(_ text: String) {
        if self.text != text { self.text = text }
    }

    // One write at a time; edits made during a save are written before it completes.
    @discardableResult func save() async -> Bool {
        if let saveTask { return await saveTask.value }
        guard isModified else { return true }
        isSaving = true
        errorMessage = nil
        let task = Task {
            do {
                while isModified {
                    saved = try await write(url, text, saved.data)
                }
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        saveTask = task
        let success = await task.value
        saveTask = nil
        isSaving = false
        return success
    }

    func reload(using files: LibraryFiles, discardChanges: Bool = false) async {
        guard !isSaving, discardChanges || !isModified else { return }
        let previousText = text
        do {
            let contents = try await files.readNote(at: url)
            guard !isSaving, text == previousText else { return }
            saved = contents
            text = contents.text
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
