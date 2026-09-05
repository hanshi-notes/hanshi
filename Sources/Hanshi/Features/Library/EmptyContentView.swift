import SwiftUI

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

struct EmptyContentView: View {
    let mode: ContentMode

    var body: some View {
        if mode == .split {
            HSplitView {
                panel("Editor").frame(minWidth: 200)
                panel("Preview").frame(minWidth: 200)
            }
        } else {
            panel(mode.rawValue)
        }
    }

    private func panel(_ name: String) -> some View {
        Color(nsColor: .textBackgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("\(name) panel")
    }
}

#Preview { EmptyContentView(mode: .split).frame(width: 600, height: 400) }
