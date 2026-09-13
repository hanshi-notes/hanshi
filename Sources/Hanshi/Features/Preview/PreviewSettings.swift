import Foundation

nonisolated struct PreviewSettings: Equatable, Sendable {
    static let autoClosePairsKey = "editorAutoClosePairs"
    static let allowsEditingKey = "previewAllowsEditing"
    static let showsMarkdownMarkersKey = "previewShowsMarkdownMarkersWhileEditing"
    static let bodySizeKey = "previewBodySize"
    static let marginKey = "previewMargin"
    static let verticalMarginKey = "previewVerticalMargin"
    static let fontNameKey = "previewFontName"
    static let fontFamilyKey = "previewFontFamily"
    static let lineHeightKey = "previewLineHeight"
    var autoClosePairs = true
    var allowsEditing = true
    var showsMarkdownMarkers = false
}
