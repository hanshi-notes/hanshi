import Foundation

nonisolated struct Notebook: Identifiable, Sendable {
    static let selectionKey = "selectedNotebookID"

    let id: String
    let url: URL
    let notes: [Note]
    var name: String { url.lastPathComponent }

    func contains(_ descendant: URL) -> Bool {
        descendant.standardizedFileURL.path.hasPrefix(url.standardizedFileURL.path + "/")
    }

    func path(in root: URL) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
    }
}
