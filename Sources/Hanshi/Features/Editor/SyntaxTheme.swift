import AppKit

// Syntax colors for the editor. A theme is one palette of roles; the token table below maps every
// tree-sitter capture the highlight queries produce onto a role, so adding a theme is one palette.
enum SyntaxTheme: String, CaseIterable, Identifiable {
    case system, github, solarized, lowKey

    static let key = "editorSyntaxTheme"
    static var saved: SyntaxTheme { SyntaxTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .github: "GitHub (Light)"
        case .solarized: "Solarized (Light)"
        case .lowKey: "Low Key"
        }
    }

    /// Every capture name the packaged queries produce, mapped onto a role. Names are dotted paths,
    /// so `color(for:)` resolves anything more specific through its parent.
    var colors: [String: NSColor] {
        let palette = palette
        return [
            "plain": palette.plain, "variable": palette.plain, "text": palette.plain,
            "embedded": palette.plain,
            "text.title": palette.title, "punctuation.special": palette.title,
            "text.literal": palette.literal, "text.quote": palette.comment,
            "text.uri": palette.uri, "text.reference": palette.uri,
            "text.emphasis": palette.emphasis, "text.strong": palette.emphasis,
            "keyword": palette.keyword, "include": palette.keyword, "boolean": palette.keyword,
            "operator": palette.keyword, "conditional": palette.keyword, "repeat": palette.keyword,
            "exception": palette.keyword, "label": palette.keyword, "tag": palette.keyword,
            "constant.builtin": palette.keyword,
            "string": palette.string, "string.escape": palette.escape,
            "string.special": palette.escape, "escape": palette.escape, "character": palette.string,
            "comment": palette.comment, "punctuation": palette.comment,
            "number": palette.number, "float": palette.number, "constant": palette.number,
            "type": palette.type, "constructor": palette.type, "variable.builtin": palette.type,
            "namespace": palette.type, "property": palette.type, "symbol": palette.type,
            "function": palette.call, "method": palette.call,
            "parameter": palette.parameter, "attribute": palette.parameter, "field": palette.parameter,
            "annotation": palette.parameter
        ]
    }

    /// The color for a capture name, falling back to its parent: "function.method" takes the
    /// "function" color, "text.title.1" the "text.title" one.
    static func color(for token: String, in colors: [String: NSColor]) -> NSColor? {
        var name = Substring(token)
        while true {
            if let color = colors[String(name)] { return color }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }

    /// The editor's page color, when the theme asks for one of its own.
    var background: NSColor? { palette.background }

    /// The colors Settings shows next to the theme's name, darkest role first.
    var swatch: [NSColor] {
        let palette = palette
        return [palette.title, palette.keyword, palette.string, palette.number,
                palette.type, palette.call, palette.literal, palette.comment]
    }

    private var palette: Palette {
        switch self {
        case .system:
            // The colors the editor has always used: they follow the system appearance.
            Palette(background: nil,
                    plain: .textColor, title: .systemBlue, literal: .systemBrown, uri: .systemBlue,
                    emphasis: .systemPurple, keyword: .systemPurple, string: .systemRed,
                    escape: .systemOrange, comment: .secondaryLabelColor, number: .systemOrange,
                    type: .systemTeal, call: .systemBlue, parameter: .systemBrown)
        case .github:
            Palette(background: .hex(0xFFFFFF),
                    plain: .hex(0x1F2328), title: .hex(0x0550AE), literal: .hex(0x0A3069),
                    uri: .hex(0x0969DA), emphasis: .hex(0x8250DF), keyword: .hex(0xCF222E),
                    string: .hex(0x0A3069), escape: .hex(0x953800), comment: .hex(0x6E7781),
                    number: .hex(0x0550AE), type: .hex(0x953800), call: .hex(0x8250DF),
                    parameter: .hex(0x953800))
        case .solarized:
            Palette(background: .hex(0xFDF6E3),
                    plain: .hex(0x657B83), title: .hex(0x268BD2), literal: .hex(0x2AA198),
                    uri: .hex(0x268BD2), emphasis: .hex(0x6C71C4), keyword: .hex(0x859900),
                    string: .hex(0x2AA198), escape: .hex(0xCB4B16), comment: .hex(0x93A1A1),
                    number: .hex(0xD33682), type: .hex(0xB58900), call: .hex(0x268BD2),
                    parameter: .hex(0xCB4B16))
        case .lowKey:
            Palette(background: .hex(0xF6F6F4),
                    plain: .textColor, title: .hex(0x2F4858), literal: .hex(0x5A6B72),
                    uri: .hex(0x4B6A88), emphasis: .hex(0x53565A), keyword: .hex(0x6B7280),
                    string: .hex(0x5E6E5E), escape: .hex(0x7A6A5A), comment: .tertiaryLabelColor,
                    number: .hex(0x6B7280), type: .hex(0x55606B), call: .hex(0x55606B),
                    parameter: .hex(0x6B7280))
        }
    }
}

private struct Palette {
    let background: NSColor?
    let plain, title, literal, uri, emphasis, keyword, string, escape, comment, number, type, call,
        parameter: NSColor
}

private extension NSColor {
    static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255, alpha: 1)
    }
}
