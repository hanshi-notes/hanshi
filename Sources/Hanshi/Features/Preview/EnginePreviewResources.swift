import AppKit
import HighlightKit
import MarkdownEngine

/// Resources are prepared by Hanshi's bounded worker; the engine only reads them.
nonisolated struct EnginePreviewResources: EmbeddedImageProvider, LatexRenderer, SyntaxHighlighter {
    let id = UUID()
    var images: [String: NSImage] = [:]
    var diagrams: [String: NSImage] = [:]
    var formulas: [String: LatexRenderResult] = [:]
    var code: [String: [HighlightToken]] = [:]

    @MainActor init(recipe: MarkdownRecipe) {
        for run in recipe.runs {
            if let bitmap = run.bitmap, let image = NSImage(data: bitmap.data) {
                image.size = NSSize(width: bitmap.width, height: bitmap.height)
                switch run.media {
                case let .image(target, _): images[target] = image
                case let .math(source, _):
                    formulas[source.trimmingCharacters(in: .whitespacesAndNewlines)] = LatexRenderResult(
                        image: image, size: image.size, baselineOffset: bitmap.height - bitmap.baseline)
                case let .mermaid(source): diagrams[source.trimmingCharacters(in: .whitespacesAndNewlines)] = image
                default: break
                }
            }
            if !run.tokens.isEmpty { code[run.text] = run.tokens }
        }
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? { images[reference.name] }
    func fingerprint() -> AnyHashable { id }
    func image(forCodeBlock code: String, language: String?) -> NSImage? {
        guard language?.lowercased() == "mermaid" else { return nil }
        return diagrams[code.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        formulas[latex.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    func backgroundColor() -> NSColor { NSColor(white: 0.95, alpha: 1) }
    func highlight(code: String, language: String?) -> NSAttributedString? {
        guard let tokens = self.code[code] else { return nil }
        let result = NSMutableAttributedString(string: code)
        let theme = HighlightTheme.githubLight
        for token in tokens where token.range.location >= 0 && NSMaxRange(token.range) <= result.length {
            if let color = theme.style(for: token)?.color {
                result.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }
        return result
    }
    var appearanceDidChangeNotification: Notification.Name? { nil }
}

extension PreviewTheme {
    var engineConfiguration: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.textInsets = TextInsets(horizontal: inset.width, vertical: inset.height)
        configuration.overscroll = OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)
        // Two styling paths reach the same view: `MarkdownRenderer.composeText` builds the
        // attributed string, and the engine restyles it whenever the preview is editable.
        // Whatever these two disagree on, the engine wins on screen — so every value below
        // mirrors the composed one.
        configuration.headings.fontMultipliers = [2.0, 1.6, 1.3, 1.15, 1.0, 0.95]
        configuration.headings.topSpacingEm = configuration.headings.fontMultipliers.map { 28 / (bodySize * $0) }
        // The engine grows the line box itself (minimumLineHeight), so this also loosens code
        // blocks and stretches inline-code backgrounds. It is the same leading the composed
        // paragraph style uses, expressed in the unit the engine wants.
        let leading = bodyLineSpacing
        // Source newlines already separate paragraphs; extra paragraph spacing would also
        // be added after every ordinary Return, on top of the configured line height.
        configuration.paragraph = ParagraphStyle(spacingFactor: 0, lineHeightExtraSpacing: leading)
        configuration.lists.extraLineHeight = leading
        configuration.blockquote = BlockquoteStyle(extraLineHeight: leading)
        configuration.codeBlock.fontSizeScale = codeSize / bodySize
        configuration.codeBlock.paragraphSpacing = 5
        configuration.codeBlock.cornerRadius = 8
        configuration.extensions = [StrikethroughExtension()]
        configuration.spellChecking = SpellCheckingPolicy(continuousSpellChecking: false, grammarChecking: false, automaticSpellingCorrection: false)
        return configuration
    }
}
