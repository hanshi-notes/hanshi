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
    /// Leading room for the close, minimize and zoom buttons over the hidden title bar.
    // ponytail: fixed inset clears macOS 15's centred buttons, which end at 66 pt; read
    // standardWindowButton(.zoomButton) if a macOS release moves them further right.
    static let windowControlsInset = 68.0
}

// Font sizing preserves each symbol's optical size; semibold matches Notable's stroke weight.
struct BarIconView: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name).font(.system(size: BarMetrics.iconSize, weight: .semibold))
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
                .contentShape(Rectangle())
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
            .modifier(BarControlBackground(cornerRadius: cornerRadius))
    }

    @ViewBuilder func barGlassContainer() -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: BarMetrics.margin) { self }
        } else {
            self
        }
    }
}

private struct BarControlBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: Double

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.white, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.black.opacity(0.14)))
        }
    }
}
