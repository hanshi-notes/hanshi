import AppKit
import HighlightKit

nonisolated struct PreviewTheme: Equatable, Sendable {
    var bodySize = 17.0
    var codeSize = 14.0
    var inset = NSSize(width: 36, height: 12)
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
        setWidth(12, type: .absoluteValueType, for: .padding)
        setWidth(8, type: .absoluteValueType, for: .margin, edge: .minY)
        setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
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
                    base = .systemFont(ofSize: theme.bodySize * [1.9, 1.55, 1.3, 1.15, 1, 0.95][min(5, heading - 1)], weight: .semibold)
                } else {
                    base = code ? .monospacedSystemFont(ofSize: theme.codeSize, weight: .regular) : .systemFont(ofSize: theme.bodySize)
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
                    style.lineHeightMultiple = 1.2
                    style.lineSpacing = 2
                    style.paragraphSpacing = descriptor.compact ? 4 : 12
                    style.paragraphSpacingBefore = descriptor.heading > 0 ? 20 : 0
                    style.headIndent = Double(descriptor.indent) * 20 + Double(descriptor.quote) * 16
                    style.firstLineHeadIndent = style.headIndent
                    style.lineBreakMode = .byWordWrapping
                    if descriptor.heading > 0 { style.lineHeightMultiple = 1.05 }
                    if descriptor.code { style.paragraphSpacing = 0; style.lineHeightMultiple = 1.1 }
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
