import Foundation
import Observation

nonisolated enum Autosave {
    static let enabledKey = "autosaveEnabled"
    static let secondsKey = "autosaveSeconds"
    static let defaultSeconds = 60
    static let secondsRange = 5...600

    static func clampedSeconds(_ seconds: Int) -> Int { seconds[clampedTo: secondsRange] }

    /// How long a note may carry unsaved edits, or nil when the user turned autosave off.
    static func interval(in defaults: UserDefaults = .standard) -> Duration? {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return nil }
        return .seconds(clampedSeconds(defaults.object(forKey: secondsKey) as? Int ?? defaultSeconds))
    }
}

@Observable
final class NoteDocument: Identifiable {
    let id: String
    var url: URL
    private(set) var text: String
    private(set) var saved: NoteContents
    private(set) var isSaving = false
    var errorMessage: String?
    @ObservationIgnored private var saveTask: Task<Bool, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// Read when the timer is armed, so a changed setting applies from the next edit on.
    @ObservationIgnored private let autosave: () -> Duration?
    @ObservationIgnored private let write: @Sendable (URL, String, Data) async throws -> NoteContents
    @ObservationIgnored lazy var editor = MarkdownEditorSession(document: self)
    // The store renames the file to match a changed heading; the text it had before this save says
    // whether the file was still following that heading.
    @ObservationIgnored var didSave: ((NoteDocument, _ previousText: String) async -> Void)?

    init(note: Note, contents: NoteContents,
         autosave: @escaping () -> Duration? = { Autosave.interval() },
         write: @escaping @Sendable (URL, String, Data) async throws -> NoteContents) {
        id = note.id
        url = note.url
        text = contents.text
        saved = contents
        self.autosave = autosave
        self.write = write
    }

    var isModified: Bool { text != saved.text }

    func edit(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        scheduleAutosave()
    }

    /// A ceiling on what a crash can cost, not a pause detector: the first edit after a save arms
    /// the timer and later keystrokes do not push it back, so writing without ever stopping still
    /// saves on schedule.
    private func scheduleAutosave() {
        guard autosaveTask == nil, isModified, let interval = autosave() else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self else { return }
            // Cleared before the write, so edits made while it runs arm the next interval.
            autosaveTask = nil
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    // One write at a time; edits made during a save are written before it completes.
    @discardableResult func save() async -> Bool {
        if let saveTask { return await saveTask.value }
        guard isModified else { return true }
        let previousText = saved.text
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
        if success { await didSave?(self, previousText) }
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
