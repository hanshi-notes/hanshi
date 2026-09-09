import AppKit
import HighlightKit

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
    var codeSize: Double
    var inset: NSSize
    /// PostScript name of the reading font; empty means the system font.
    var fontName: String
    /// Family of the same font. Some faces do not come back from `NSFont(name:)` even
    /// though the panel offered them, so the family is the second chance before the
    /// system font. The editor stores both for the same reason.
    var fontFamily: String
    /// Multiple of the font's natural line height, like the editor's own control.
    var lineHeight: Double

    /// Code size still follows the body size: one control for both keeps code and prose in
    /// proportion, and nobody has asked to set it apart. The defaults reproduce the
    /// hand-tuned 17/14, 38/14 and the leading that was hard-coded before.
    init(bodySize: Double = defaultBodySize,
         margin: Double = defaultMargin,
         verticalMargin: Double = defaultVerticalMargin,
         fontName: String = "",
         fontFamily: String = "",
         lineHeight: Double = defaultLineHeight) {
        let body = Self.clampedBodySize(bodySize)
        self.bodySize = body
        self.codeSize = (body * 0.82).rounded()
        self.inset = NSSize(width: Self.clampedMargin(margin),
                            height: Self.clampedVerticalMargin(verticalMargin))
        self.fontName = fontName
        self.fontFamily = fontFamily
        self.lineHeight = Self.clampedLineHeight(lineHeight)
    }

    static func clampedBodySize(_ value: Double) -> Double {
        value.isFinite ? min(max(value, bodySizeRange.lowerBound), bodySizeRange.upperBound) : defaultBodySize
    }

    static func clampedMargin(_ value: Double) -> Double {
        value.isFinite ? min(max(value, marginRange.lowerBound), marginRange.upperBound) : defaultMargin
    }

    static func clampedVerticalMargin(_ value: Double) -> Double {
        value.isFinite ? min(max(value, verticalMarginRange.lowerBound), verticalMarginRange.upperBound) : defaultVerticalMargin
    }

    static func clampedLineHeight(_ value: Double) -> Double {
        value.isFinite ? min(max(value, lineHeightRange.lowerBound), lineHeightRange.upperBound) : defaultLineHeight
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

    /// Headings in the chosen face, bolded through traits. The system font has real weights,
    /// so it keeps using them: `.bold` on SF Pro Display is not the same as `.semibold`.
    func headingFont(size: Double, heavy: Bool) -> NSFont {
        let font = bodyFont(size: size)
        // The system font has real weights, so it keeps using them: `.bold` traits on SF Pro
        // are not the same as asking for its bold cut.
        guard font != .systemFont(ofSize: size) else {
            return .systemFont(ofSize: size, weight: heavy ? .bold : .semibold)
        }
        let traits = font.fontDescriptor.symbolicTraits.union(.bold)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
    }

    /// Extra points between lines. AppKit's `.backgroundColor` fills the line fragment, so
    /// this must stay out of `lineHeightMultiple` or inline code sits in a slab.
    var bodyLineSpacing: Double {
        let font = bodyFont(size: bodySize)
        let natural = ceil(font.ascender - font.descender + font.leading)
        return max(0, ((lineHeight - 1) * natural).rounded())
    }
}

extension NSAttributedString.Key {
    nonisolated static let previewAlternative = NSAttributedString.Key("HanshiPreviewAlternative")
}

struct MarkdownComposition {
    let text: NSAttributedString
    let anchors: [MarkdownAnchor]
    let attachments: [PreviewAttachment]
    var attachmentRanges: [NSRange] = []
    var composedOnMainThread = true
    var fontBuildCount = 0
    var longestBatch: Duration = .zero
}

nonisolated final class PreviewAttachment: NSTextAttachment {
    let originalSize: NSSize
    let baseline: Double
    let inline: Bool
    let alternative: String
    let bitmap: NSImage

    @MainActor init(bitmap: PreviewBitmap, alternative: String, inline: Bool) {
        originalSize = NSSize(width: bitmap.width, height: bitmap.height)
        baseline = bitmap.baseline
        self.inline = inline
        self.alternative = alternative
        self.bitmap = NSImage(data: bitmap.data) ?? NSImage(size: originalSize)
        super.init(data: nil, ofType: nil)
        let cell = PreviewAttachmentCell(imageCell: self.bitmap)
        cell.setAccessibilityLabel(alternative)
        attachmentCell = cell
        resize(width: 700)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @MainActor func resize(width: Double) {
        let factor = min(1, max(40, width) / max(1, originalSize.width))
        bitmap.size = NSSize(width: originalSize.width * factor, height: originalSize.height * factor)
        (attachmentCell as? PreviewAttachmentCell)?.descent = inline ? -(originalSize.height - baseline) * factor : 0
    }
}

nonisolated private final class PreviewAttachmentCell: NSTextAttachmentCell {
    var descent = 0.0
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: descent) }
}

// One native text block spans all the paragraphs in a fence, including wrapped lines.
nonisolated final class PreviewCodeBlock: NSTextTableBlock {
    init() {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setValue(100, type: .percentageValueType, for: .width)
        super.init(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        setWidth(16, type: .absoluteValueType, for: .padding)
        setWidth(12, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        backgroundColor = NSColor(white: 0.95, alpha: 1)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        backgroundColor?.setFill()
        // TextKit includes the outer margins in this frame; keep them as page space.
        let top = width(for: .margin, edge: .minY), bottom = width(for: .margin, edge: .maxY)
        let background = NSRect(x: frameRect.minX, y: frameRect.minY + top,
            width: frameRect.width, height: max(0, frameRect.height - top - bottom))
        NSBezierPath(roundedRect: background, xRadius: 8, yRadius: 8).fill()
    }
}

// Owned by one composition task, then transferred once to MainActor with `sending`.
nonisolated struct PreparedPreviewText {
    nonisolated enum Attachment {
        case task(Bool)
        case media(PreviewBitmap, PreviewRun.Media)
    }
    let text: NSMutableAttributedString
    let anchors: [MarkdownAnchor]
    let attachments: [(range: NSRange, content: Attachment)]
    let composedOnMainThread: Bool
    let fontBuildCount: Int
}

extension MarkdownRenderer {
    @MainActor static func compose(_ recipe: MarkdownRecipe, theme: PreviewTheme) async throws -> MarkdownComposition {
        let prepared = try await composeText(recipe, theme: theme)
        try Task.checkCancellation()
        var attachments: [PreviewAttachment] = []
        var ranges: [NSRange] = []
        var taskSymbols: [Bool: NSTextAttachment] = [:]
        let clock = ContinuousClock()
        var batchStart = clock.now
        var longestBatch = Duration.zero
        for item in prepared.attachments {
            try Task.checkCancellation()
            let attachment: NSTextAttachment
            switch item.content {
            case let .task(checked):
                if let cached = taskSymbols[checked] { attachment = cached }
                else {
                    let symbol = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: nil)!
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: theme.bodySize - 1, weight: .regular)
                            .applying(.init(paletteColors: checked ? [.white, .systemBlue] : [.secondaryLabelColor])))!
                    let value = NSTextAttachment()
                    let cell = PreviewAttachmentCell(imageCell: symbol)
                    cell.descent = NSFont.systemFont(ofSize: theme.bodySize).descender
                    cell.setAccessibilityLabel(checked ? "Completed task" : "Incomplete task")
                    value.attachmentCell = cell
                    taskSymbols[checked] = value
                    attachment = value
                }
            case let .media(bitmap, media):
                let inline: Bool = if case .math(_, false) = media { true } else { false }
                let value = PreviewAttachment(bitmap: bitmap, alternative: media.alternative, inline: inline)
                attachments.append(value)
                ranges.append(item.range)
                attachment = value
            }
            prepared.text.addAttribute(.attachment, value: attachment, range: item.range)
            // Media are capped at 256, but task lists can contain many more markers.
            if batchStart.duration(to: clock.now) >= .milliseconds(4) {
                longestBatch = max(longestBatch, batchStart.duration(to: clock.now))
                await Task.yield()
                batchStart = clock.now
            }
        }
        longestBatch = max(longestBatch, batchStart.duration(to: clock.now))
        return MarkdownComposition(text: prepared.text, anchors: prepared.anchors, attachments: attachments,
            attachmentRanges: ranges, composedOnMainThread: prepared.composedOnMainThread,
            fontBuildCount: prepared.fontBuildCount, longestBatch: longestBatch)
    }

    @concurrent static func composeText(_ recipe: MarkdownRecipe, theme: PreviewTheme) async throws -> sending PreparedPreviewText {
        try autoreleasepool {
            let text = NSMutableAttributedString(string: "")
            var tables: [Int: NSTextTable] = [:]
            var cells: [PreviewCell: NSTextTableBlock] = [:]
            var paragraphs: [PreviewParagraph: NSParagraphStyle] = [:]
            var attachments: [(range: NSRange, content: PreparedPreviewText.Attachment)] = []
            var anchors = recipe.anchors
            var originalOffset = 0
            var boundaries: [(old: Int, new: Int)] = [(0, 0)]
            struct FontKey: Hashable {
                let heading: Int
                let code: Bool
                let bold: Bool
                let italic: Bool
            }
            var fonts: [FontKey: NSFont] = [:]
            func font(heading: Int, code: Bool, bold: Bool, italic: Bool) -> NSFont {
                let key = FontKey(heading: heading, code: code, bold: bold, italic: italic)
                if let cached = fonts[key] { return cached }
                let base: NSFont
                if heading > 0 {
                    base = theme.headingFont(size: theme.bodySize * [2.0, 1.6, 1.3, 1.15, 1, 0.95][min(5, heading - 1)],
                                             heavy: heading == 1)
                } else {
                    base = code ? .monospacedSystemFont(ofSize: theme.codeSize, weight: .regular)
                                : theme.bodyFont(size: theme.bodySize)
                }
                var traits = base.fontDescriptor.symbolicTraits
                if bold { traits.insert(.bold) }
                if italic { traits.insert(.italic) }
                let value = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
                fonts[key] = value
                return value
            }
            var codeTheme = HighlightTheme.githubLight
            codeTheme.font.size = theme.codeSize
            for (index, run) in recipe.runs.enumerated() {
                if index.isMultiple(of: 200) {
                    try Task.checkCancellation()
                }
                let descriptor = run.paragraph
                let paragraph: NSParagraphStyle
                if let cached = paragraphs[descriptor] { paragraph = cached }
                else {
                    let style = NSMutableParagraphStyle()
                    // Leading goes in lineSpacing, not lineHeightMultiple: a multiple grows
                    // the line fragment and `.backgroundColor` fills all of it, so inline code
                    // would sit in a slab tall enough to touch the line above.
                    style.lineSpacing = theme.bodyLineSpacing
                    style.paragraphSpacing = descriptor.compact ? 5 : 14
                    style.paragraphSpacingBefore = descriptor.heading > 0 ? 28 : 0
                    style.headIndent = Double(descriptor.indent) * 20 + Double(descriptor.quote) * 16
                    style.firstLineHeadIndent = style.headIndent
                    style.lineBreakMode = .byWordWrapping
                    if descriptor.heading > 0 { style.lineSpacing = 2; style.paragraphSpacing = 14 }
                    if descriptor.code { style.paragraphSpacing = 0; style.lineSpacing = 4 }
                    if descriptor.codeBlock != nil { style.textBlocks = [PreviewCodeBlock()] }
                    if let cell = descriptor.cell {
                        let table = tables[cell.table] ?? {
                            let value = NSTextTable()
                            value.numberOfColumns = max(1, cell.columns)
                            value.layoutAlgorithm = .fixedLayoutAlgorithm
                            value.collapsesBorders = true
                            value.hidesEmptyCells = false
                            value.setValue(100, type: .percentageValueType, for: .width)
                            tables[cell.table] = value
                            return value
                        }()
                        let block = cells[cell] ?? {
                            let value = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: 1, startingColumn: cell.column, columnSpan: 1)
                            value.setValue(100 / Double(max(1, cell.columns)), type: .percentageValueType, for: .width)
                            value.setWidth(7, type: .absoluteValueType, for: .padding)
                            value.setWidth(0.5, type: .absoluteValueType, for: .border)
                            value.setBorderColor(.separatorColor)
                            value.backgroundColor = cell.header ? NSColor(white: 0.95, alpha: 1) : .white
                            cells[cell] = value
                            return value
                        }()
                        style.textBlocks = [block]
                        style.paragraphSpacing = 0
                        style.alignment = cell.alignment == 114 ? .right : (cell.alignment == 99 ? .center : .left)
                    }
                    paragraph = style
                    paragraphs[descriptor] = style
                }
                let runFont = font(heading: descriptor.heading, code: run.code || descriptor.code, bold: run.bold, italic: run.italic)
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: descriptor.quote > 0 ? NSColor.secondaryLabelColor : NSColor.labelColor, .paragraphStyle: paragraph]
                // Display-size text tracks loose at its default spacing; tighten the two largest levels.
                if descriptor.heading == 1 || descriptor.heading == 2 {
                    attributes[.kern] = runFont.pointSize * -0.02
                }
                if (run.code || descriptor.code) && descriptor.codeBlock == nil && run.media == nil { attributes[.backgroundColor] = NSColor(white: 0.96, alpha: 1) }
                if run.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor }
                var visible = run.text
                if let media = run.media, run.bitmap == nil {
                    visible = media.alternative + " [" + (run.diagnostic ?? "Unavailable") + "]"
                    if case let .image(target, _) = media { visible += " (" + target + ")" }
                }
                let part = NSMutableAttributedString(string: visible, attributes: attributes)
                if let checked = run.task {
                    part.replaceCharacters(in: NSRange(location: 0, length: 1), with: "\u{fffc}")
                    part.addAttribute(.previewAlternative, value: checked ? "[x]" : "[ ]", range: NSRange(location: 0, length: 1))
                    attachments.append((NSRange(location: text.length, length: 1), .task(checked)))
                }
                if let media = run.media, let bitmap = run.bitmap {
                    part.addAttribute(.previewAlternative, value: media.alternative, range: NSRange(location: 0, length: part.length))
                    attachments.append((NSRange(location: text.length, length: part.length), .media(bitmap, media)))
                }
                for (tokenIndex, token) in run.tokens.enumerated() where token.range.location >= 0 && token.range.upperBound <= part.length {
                    if tokenIndex.isMultiple(of: 200) { try Task.checkCancellation() }
                    guard let scope = codeTheme.style(for: token) else { continue }
                    if let color = scope.color { part.addAttribute(.foregroundColor, value: color, range: token.range) }
                    let tokenFont = font(heading: descriptor.heading, code: run.code || descriptor.code,
                        bold: run.bold || scope.bold, italic: run.italic || scope.italic)
                    part.addAttribute(.font, value: tokenFont, range: token.range)
                }
                text.append(part)
                originalOffset += run.text.utf16.count
                boundaries.append((originalOffset, text.length))
            }
            func translate(_ offset: Int) -> Int {
                var low = 0, high = boundaries.count
                while low < high {
                    let middle = (low + high) / 2
                    if boundaries[middle].old <= offset { low = middle + 1 } else { high = middle }
                }
                let boundary = boundaries[max(0, low - 1)]
                return min(text.length, boundary.new + offset - boundary.old)
            }
            for index in anchors.indices {
                let range = anchors[index].rendered
                let start = translate(range.location), end = translate(range.upperBound)
                anchors[index].rendered = NSRange(location: start, length: max(0, end - start))
            }
            try Task.checkCancellation()
            return PreparedPreviewText(text: text, anchors: anchors, attachments: attachments,
                composedOnMainThread: Thread.isMainThread, fontBuildCount: fonts.count)
        }
    }
}
