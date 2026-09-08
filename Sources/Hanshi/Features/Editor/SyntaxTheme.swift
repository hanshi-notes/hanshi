import AppKit

// Syntax colors for the editor. A theme is one palette of roles; the token table below maps every
// tree-sitter capture the highlight queries produce onto a role, so adding a theme is one palette.
enum SyntaxTheme: String, CaseIterable, Identifiable {
    case system, github, solarized, lowKey
    case anura, anuraDark, classic, dendrobates, dendrobatesDark, kawazu, lakritz, mono, note
    case printen, pulse, resinifictrix, resinifictrixDark

    static let key = "editorSyntaxTheme"
    static var saved: SyntaxTheme { SyntaxTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .github: "GitHub (Light)"
        case .solarized: "Solarized (Light)"
        case .lowKey: "Low Key"
        case .anura: "Anura"
        case .anuraDark: "Anura (Dark)"
        case .classic: "Classic"
        case .dendrobates: "Dendrobates"
        case .dendrobatesDark: "Dendrobates (Dark)"
        case .kawazu: "Kawazu"
        case .lakritz: "Lakritz"
        case .mono: "Mono"
        case .note: "Note"
        case .printen: "Printen"
        case .pulse: "Pulse"
        case .resinifictrix: "Resinifictrix"
        case .resinifictrixDark: "Resinifictrix (Dark)"
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
            "annotation": palette.parameter,
            "H1": palette.title, "H2": palette.title, "H3": palette.title,
            "H4": palette.title, "H5": palette.title, "H6": palette.title,
            "EMPH": palette.emphasis, "STRONG": palette.emphasis, "HRULE": palette.comment,
            "LIST_BULLET": palette.title, "LIST_ENUMERATOR": palette.title,
            "LINK": palette.uri, "AUTO_LINK_URL": palette.uri, "AUTO_LINK_EMAIL": palette.uri,
            "REFERENCE": palette.uri, "IMAGE": palette.uri, "CODE": palette.literal,
            "VERBATIM": palette.literal, "HTML_ENTITY": palette.escape, "COMMENT": palette.comment,
            "BLOCKQUOTE": palette.comment
        ]
    }

    private static let markdownRoles = ["text.title.1": "H1", "text.title.2": "H2", "text.title.3": "H3",
                     "text.title.4": "H4", "text.title.5": "H5", "text.title.6": "H6",
                     "text.emphasis": "EMPH", "text.strong": "STRONG", "text.uri": "LINK",
                     "text.reference": "REFERENCE", "text.literal": "CODE", "text.quote": "BLOCKQUOTE",
                     "text.uri.autolink": "AUTO_LINK_URL", "text.uri.email": "AUTO_LINK_EMAIL",
                     "text.image": "IMAGE", "text.literal.verbatim": "VERBATIM",
                     "text.list.bullet": "LIST_BULLET", "text.list.number": "LIST_ENUMERATOR", "text.hrule": "HRULE"]

    /// The color for a capture name, falling back to its parent: "function.method" takes the
    /// "function" color, "text.title.1" the "text.title" one.
    static func color(for token: String, in colors: [String: NSColor]) -> NSColor? {
        if let role = markdownRoles[token], let color = colors[role] { return color }
        var name = Substring(token)
        while true {
            if let color = colors[String(name)] { return color }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }

    /// The editor's page color, when the theme asks for one of its own.
    var background: NSColor? { palette.background }
    var plain: NSColor { palette.plain }
    var appearance: NSAppearance? {
        guard let color = background?.usingColorSpace(.deviceRGB) else { return nil }
        let brightness = color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
        return NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
    }
    var invisibles: NSColor { cotTheme?.color("invisibles") ?? .disabledControlTextColor }
    var lineHighlight: NSColor { cotTheme?.color("lineHighlight") ?? .quaternaryLabelColor }
    var selection: NSColor { cotTheme?.color("selection", system: .selectedTextBackgroundColor) ?? .selectedTextBackgroundColor }
    var insertionPoint: NSColor { cotTheme?.color("insertionPoint", system: .textColor) ?? plain }
    var highlight: NSColor { cotTheme?.color("highlight", system: .findHighlightColor) ?? .findHighlightColor }
    var cotTheme: CotTheme? { Self.cotThemes[name] }
    private static let cotThemes: [String: CotTheme] = Dictionary(uniqueKeysWithValues: allCases.compactMap { theme in
        guard let url = EditorResources.bundle.url(forResource: theme.name, withExtension: "cottheme", subdirectory: "Themes"),
              let data = try? Data(contentsOf: url), let value = try? CotTheme(data: data) else { return nil }
        return (theme.name, value)
    })

    /// The colors Settings shows next to the theme's name, darkest role first.
    var swatch: [NSColor] {
        let palette = palette
        return [palette.title, palette.keyword, palette.string, palette.number,
                palette.type, palette.call, palette.literal, palette.comment]
    }

    private var palette: Palette {
        if let theme = cotTheme {
            let plain = theme.color("text") ?? .textColor
            let keyword = theme.color("keywords") ?? plain
            let string = theme.color("strings") ?? plain
            let type = theme.color("types") ?? plain
            return Palette(background: theme.color("background"), plain: plain, title: keyword,
                literal: string, uri: theme.color("commands") ?? keyword, emphasis: type,
                keyword: keyword, string: string, escape: theme.color("characters") ?? string,
                comment: theme.color("comments") ?? plain, number: theme.color("numbers") ?? plain,
                type: type, call: theme.color("commands") ?? plain, parameter: theme.color("attributes") ?? plain)
        }
        return switch self {
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
        default: SyntaxTheme.system.palette
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
