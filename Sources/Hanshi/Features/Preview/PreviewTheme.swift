import AppKit

nonisolated struct PreviewTheme: Equatable, Sendable {
    static let defaultBodySize = 17.0
    static let bodySizeRange = 11.0...28.0
    static let defaultMargin = 38.0
    static let marginRange = 8.0...160.0
    static let defaultVerticalMargin = 14.0
    static let verticalMarginRange = 0.0...120.0
    static let defaultLineHeight = 1.25
    static let lineHeightRange = 1.0...2.5

    var bodySize: Double
    var codeSize: Double { bodySize }
    var inset: NSSize
    /// PostScript name of the reading font; empty means the system font.
    var fontName: String
    /// Family of the same font. Some faces do not come back from `NSFont(name:)` even
    /// though the panel offered them, so the family is the second chance before the
    /// system font. The editor stores both for the same reason.
    var fontFamily: String
    /// Multiple of the font's natural line height, like the editor's own control.
    var lineHeight: Double

    /// Code and prose share one text-size setting.
    init(bodySize: Double = defaultBodySize,
         margin: Double = defaultMargin,
         verticalMargin: Double = defaultVerticalMargin,
         fontName: String = "",
         fontFamily: String = "",
         lineHeight: Double = defaultLineHeight) {
        let body = Self.clampedBodySize(bodySize)
        self.bodySize = body
        self.inset = NSSize(width: Self.clampedMargin(margin),
                            height: Self.clampedVerticalMargin(verticalMargin))
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.lineHeight = Self.clampedLineHeight(lineHeight)
    }

    static func clampedBodySize(_ value: Double) -> Double {
        value[clampedTo: bodySizeRange, fallback: defaultBodySize]
    }

    static func clampedMargin(_ value: Double) -> Double {
        value[clampedTo: marginRange, fallback: defaultMargin]
    }

    static func clampedVerticalMargin(_ value: Double) -> Double {
        value[clampedTo: verticalMarginRange, fallback: defaultVerticalMargin]
    }

    static func clampedLineHeight(_ value: Double) -> Double {
        value[clampedTo: lineHeightRange, fallback: defaultLineHeight]
    }

    /// The reading font at `size`, falling back to the system font when the stored name
    /// names something this Mac no longer has.
    func bodyFont(size: Double) -> NSFont {
        if !fontName.isEmpty, let font = NSFont(name: fontName, size: size) { return font }
        if !fontFamily.isEmpty,
           let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size)
    }

    /// Extra points between lines. AppKit's `.backgroundColor` fills the line fragment, so
    /// this must stay out of `lineHeightMultiple` or inline code sits in a slab.
    var bodyLineSpacing: Double {
        let font = bodyFont(size: bodySize)
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(0, ((lineHeight - 1) * natural).rounded())
    }
}

struct MarkdownComposition {
    let text: NSAttributedString
    let anchors: [MarkdownAnchor]
}
