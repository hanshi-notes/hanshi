import Foundation

nonisolated struct PreviewSettings: Equatable, Sendable {
    static let allowsEditingKey = "previewAllowsEditing"
    static let showsMarkdownMarkersKey = "previewShowsMarkdownMarkersWhileEditing"
    var allowsEditing = true
    var showsMarkdownMarkers = false
}
