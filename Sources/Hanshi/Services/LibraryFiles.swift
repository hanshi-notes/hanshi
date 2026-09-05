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
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalidName
        }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @concurrent func createNote(in folder: URL) async throws -> URL {
        guard folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw LibraryError.invalidNotebook
        }
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LibraryError.invalidNotebook
        }
        let numbers = try children(of: folder).compactMap { url -> Int? in
            let stem = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension.lowercased() == "md", !stem.isEmpty,
                  stem.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            guard let number = Int(stem) else { throw LibraryError.numberLimit }
            return number
        }
        var number = numbers.max() ?? 0
        while number < Int.max {
            number += 1
            let filename = (number < 10 ? "0" : "") + String(number) + ".md"
            let url = folder.appendingPathComponent(filename)
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw LibraryError.numberLimit
    }

    private func children(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // Filesystem identity survives external renames; document identity will be added with editing.
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
    case invalidName, invalidNotebook, numberLimit

    var errorDescription: String? {
        switch self {
        case .invalidName: "Use a notebook name without slashes, colons, control characters, or a leading dot."
        case .invalidNotebook: "The notebook is no longer available. Refresh the library and choose a folder inside it."
        case .numberLimit: "This notebook has reached the supported numeric filename limit."
        }
    }
}
