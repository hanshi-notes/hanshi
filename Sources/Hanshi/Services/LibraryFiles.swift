import Foundation

nonisolated struct LibraryFiles: Sendable {
    let root: URL

    @concurrent func load() async throws -> [Notebook] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try children(of: root).compactMap { folder in
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let notes = try children(of: folder).compactMap { url -> Note? in
                guard url.pathExtension.lowercased() == "md" else { return nil }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return Note(id: try fileID(url), url: url)
            }
            return Notebook(id: try fileID(folder), url: folder, notes: notes)
        }
    }

    @concurrent func createNotebook(named name: String) async throws -> URL {
        let name = try validatedName(name)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @concurrent func createNote(in folder: URL, text: String = "") async throws -> URL {
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw LibraryError.invalidNotebook
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LibraryError.invalidNotebook
        }
        // ponytail: tries "Note", "Note (1)", … in order; O(notes in the notebook) per creation.
        var number = 0
        while number < Int.max {
            let name = number == 0 ? NoteTitle.defaultName : "\(NoteTitle.defaultName) (\(number))"
            let url = folder.appendingPathComponent(name + ".md")
            do {
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
        throw LibraryError.numberLimit
    }

    @concurrent func readNote(at url: URL) async throws -> NoteContents {
        var coordinationError: NSError?
        var result: Result<NoteContents, any Error> = .failure(LibraryError.invalidNote)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result {
                try validateNote(coordinatedURL)
                return try contents(at: coordinatedURL)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    @concurrent func saveCopy(text: String, to url: URL) async throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    @concurrent func saveNote(at url: URL, text: String, expected: Data) async throws -> NoteContents {
        var coordinationError: NSError?
        var result: Result<NoteContents, any Error> = .failure(LibraryError.invalidNote)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
                try validateNote(coordinatedURL)
                guard try Data(contentsOf: coordinatedURL) == expected else { throw LibraryError.noteConflict }
                let data = Data(text.utf8)
                try data.write(to: coordinatedURL, options: .atomic)
                return NoteContents(data: data, text: text, fileID: try fileID(coordinatedURL))
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // Keep these local metadata operations synchronous so a document cannot start saving mid-move.
    func renameNote(at url: URL, to name: String) throws -> URL {
        let name = try validatedName(name)
        let filename = name.lowercased().hasSuffix(".md") ? name : name + ".md"
        let destination = url.deletingLastPathComponent().appendingPathComponent(filename)
        return try moveItem(at: url, to: destination, validate: validateNote)
    }

    func renameNotebook(at url: URL, to name: String) throws -> URL {
        let destination = root.appendingPathComponent(try validatedName(name), isDirectory: true)
        return try moveItem(at: url, to: destination, validate: validateNotebook)
    }

    func moveNote(at url: URL, to notebook: URL) throws -> URL {
        try moveItem(at: url, to: notebook.appendingPathComponent(url.lastPathComponent)) { source in
            try validateNotebook(notebook)
            try validateNote(source)
        }
    }

    private func moveItem(at url: URL, to destination: URL, validate: (URL) throws -> Void) throws -> URL {
        var coordinationError: NSError?
        var result: Result<URL, any Error> = .failure(LibraryError.invalidNote)
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { source, target in
            result = Result {
                try validate(source)
                guard source != target else { return target }
                coordinator.item(at: source, willMoveTo: target)
                try FileManager.default.moveItem(at: source, to: target)
                coordinator.item(at: source, didMoveTo: target)
                return target
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    @discardableResult func trashNote(at url: URL) throws -> URL? {
        try trashItem(at: url, validate: validateNote)
    }

    @discardableResult func trashNotebook(at url: URL) throws -> URL? {
        try trashItem(at: url, validate: validateNotebook)
    }

    private func trashItem(at url: URL, validate: (URL) throws -> Void) throws -> URL? {
        var coordinationError: NSError?
        var result: Result<URL?, any Error> = .failure(LibraryError.invalidNote)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { source in
            result = Result {
                try validate(source)
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &trashedURL)
                return trashedURL as URL?
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalidName
        }
        return name
    }

    private func validateNote(_ url: URL) throws {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              url.pathExtension.lowercased() == "md" else { throw LibraryError.invalidNote }
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.invalidNote }
    }

    private func validateNotebook(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw LibraryError.invalidNotebook
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibraryError.invalidNotebook }
    }

    private func contents(at url: URL) throws -> NoteContents {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw LibraryError.invalidEncoding }
        return NoteContents(data: data, text: text, fileID: try fileID(url))
    }

    private func children(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // The store preserves open-document identity across atomic replacements.
    private func fileID(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw LibraryError.invalidNotebook
        }
        return "\(device):\(inode)"
    }
}

nonisolated enum LibraryError: LocalizedError {
    case invalidName, invalidNotebook, numberLimit, invalidNote, invalidEncoding, noteConflict

    var errorDescription: String? {
        switch self {
        case .invalidName: "Use a name without slashes, colons, control characters, or a leading dot."
        case .invalidNotebook: "The notebook is no longer available. Refresh the library and choose a folder inside it."
        case .numberLimit: "This notebook cannot hold another new note."
        case .invalidNote: "Choose a Markdown file inside a notebook in this library. Symbolic links are not supported."
        case .invalidEncoding: "This note is not valid UTF-8. Its contents have not been changed."
        case .noteConflict: "This note changed on disk. Your edits are still open. Save a copy to keep both versions, or reload from disk to discard your edits."
        }
    }
}

nonisolated struct NoteContents: Sendable {
    let data: Data
    let text: String
    let fileID: String
}
