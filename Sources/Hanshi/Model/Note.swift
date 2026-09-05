import Foundation

nonisolated struct Note: Identifiable, Sendable {
    let id: String
    let url: URL
    var name: String { url.lastPathComponent }
    var notebookName: String { url.deletingLastPathComponent().lastPathComponent }
}
