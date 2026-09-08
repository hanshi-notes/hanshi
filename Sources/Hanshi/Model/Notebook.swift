import Foundation

nonisolated struct Notebook: Identifiable, Sendable {
    static let selectionKey = "selectedNotebookID"

    let id: String
    let url: URL
    let notes: [Note]
    var name: String { url.lastPathComponent }
}
