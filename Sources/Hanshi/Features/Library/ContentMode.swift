import Foundation

enum ContentMode: String, CaseIterable, Identifiable {
    case source = "Editor"
    case preview = "Preview"
    case split = "Split"

    var id: Self { self }
    var icon: String {
        switch self {
        case .source: "pencil"
        case .preview: "doc.richtext"
        case .split: "rectangle.split.2x1"
        }
    }
}
