import Foundation

nonisolated struct Note: Identifiable, Sendable {
    static let selectionKey = "selectedNoteID"
    let id: String
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var notebookName: String { url.deletingLastPathComponent().lastPathComponent }
}

// Option B in Settings: a new note starts with a heading, and its file follows that heading.
nonisolated enum NoteTitle {
    static let templateKey = "newNoteTitleTemplate"
    static let defaultName = "Note"
    static let template = "# \(defaultName)\n"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: templateKey) as? Bool ?? true }

    /// Names the app gave the note itself: "Note", "Note (1)", … Nobody has claimed them yet, so
    /// they still follow the heading.
    static func isDefault(_ name: String) -> Bool {
        name == defaultName
            || (name.hasPrefix("\(defaultName) (") && name.hasSuffix(")")
                && Int(name.dropFirst(defaultName.count + 2).dropLast()) != nil)
    }

    /// The file name a note's first-line `# heading` asks for, once it is safe to put on disk.
    static func filename(for text: String) -> String? {
        guard let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              line.hasPrefix("# ") else { return nil }
        let unusable = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let scalars = line.dropFirst(2).unicodeScalars.map { unusable.contains($0) ? "-" : $0 }
        // Leading dots hide the file; trailing dots and spaces would land in the ".md" suffix.
        let name = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return name.isEmpty ? nil : String(name.prefix(100))
    }
}
