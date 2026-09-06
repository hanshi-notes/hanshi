import SwiftUI

enum BarMetrics {
    static let height = 38.0
    static let margin = 10.0
    static let controlHeight = 24.0
    static let buttonWidth = 34.5
    static let cornerRadius = 4.5
    static let iconSize = 14.0
    static let iconBox = 18.0
    static let iconColor = Color.black
}

// Font sizing preserves each symbol's optical size and stroke weight.
struct BarIconView: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name).font(.system(size: BarMetrics.iconSize))
    }
}

// Buttons for features that do not exist yet keep their icon at full strength: a disabled
// button would draw it at half opacity and leave the bar looking washed out.
struct BarButton: View {
    let title: String
    let icon: String
    var active = false
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            BarIconView(icon)
                .foregroundStyle(active ? .orange : BarMetrics.iconColor)
                .frame(width: BarMetrics.buttonWidth, height: BarMetrics.controlHeight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(action == nil ? "Not available yet" : "")
        .help(action == nil ? "\(title) — not available yet" : title)
    }
}

extension View {
    func barControl(cornerRadius: Double = BarMetrics.cornerRadius) -> some View {
        frame(height: BarMetrics.controlHeight)
            .background(.white, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.14)))
    }
}
