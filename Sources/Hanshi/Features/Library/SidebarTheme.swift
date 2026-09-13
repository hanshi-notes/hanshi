import SwiftUI

enum SidebarTheme: String, CaseIterable, Identifiable {
    case standard = "Default"
    case dark = "Dark"
    case light = "Light"

    static let key = "sidebarTheme"
    var id: Self { self }

    var background: Color {
        switch self {
        case .standard: Color(red: 0.12, green: 0.16, blue: 0.18)
        case .dark: Color(red: 49 / 255, green: 54 / 255, blue: 64 / 255)
        case .light: Color(red: 236 / 255, green: 236 / 255, blue: 236 / 255)
        }
    }

    var foreground: Color { self == .light ? Color(white: 0.12) : .white }
}
