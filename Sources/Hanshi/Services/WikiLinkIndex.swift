import Foundation
import MarkdownEngine

/// Names are library-wide; paths are relative to the library root, never to the current note.
nonisolated struct WikiLinkIndex: WikiLinkResolver {
    private let names: [String: [URL]]
    private let paths: [String: [URL]]
    private let labels: [URL: String]

    init(notes: [URL], root: URL) {
        let prefix = root.standardizedFileURL.pathComponents
        var names: [String: [URL]] = [:]
        var paths: [String: [URL]] = [:]
        var labels: [URL: String] = [:]
        for url in Set(notes.map(\.standardizedFileURL)) {
            let components = url.pathComponents
            guard components.count > prefix.count + 1, components.starts(with: prefix),
                  url.pathExtension.lowercased() == "md" else { continue }
            let path = components.dropFirst(prefix.count).joined(separator: "/")
            let label = String(path.dropLast(3))
            names[Self.key(url.deletingPathExtension().lastPathComponent), default: []].append(url)
            paths[Self.key(label), default: []].append(url)
            labels[url] = label
        }
        self.names = names
        self.paths = paths
        self.labels = labels
    }

    func destination(for target: String) throws -> URL {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard !target.isEmpty, !target.contains("\\"), !target.contains(":"),
              !target.contains("|"), !target.contains("["), !target.contains("]"),
              !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WikiLinkError.invalid(target)
        }
        let name = target.lowercased().hasSuffix(".md") ? String(target.dropLast(3)) : target
        let matches = (components.count > 1 ? paths : names)[Self.key(name)] ?? []
        guard let url = matches.first else { throw WikiLinkError.missing(target) }
        guard matches.count == 1 else {
            throw WikiLinkError.ambiguous(target, matches.compactMap { labels[$0] }.sorted())
        }
        return url
    }

    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        do {
            let url = try destination(for: displayName)
            return WikiLinkResolution(id: displayName, exists: true, destination: url,
                                      toolTip: "Open \(labels[url] ?? displayName)")
        } catch {
            return WikiLinkResolution(id: displayName, exists: false, toolTip: error.localizedDescription)
        }
    }

    func fingerprint() -> AnyHashable { labels }

    private static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}

nonisolated enum WikiLinkError: LocalizedError, Equatable {
    case invalid(String), missing(String), ambiguous(String, [String])

    var errorDescription: String? {
        switch self {
        case let .invalid(target): "Invalid wiki link: \(target). Use a note name or a path inside the library."
        case let .missing(target): "Note not found: \(target)."
        case let .ambiguous(target, paths): "Ambiguous wiki link: \(target). Use a notebook path: \(paths.joined(separator: ", "))."
        }
    }
}
