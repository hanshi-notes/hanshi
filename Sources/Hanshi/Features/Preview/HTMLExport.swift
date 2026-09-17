import AppKit
import Foundation
import HighlightKit
import cmark_gfm
import cmark_gfm_extensions
import CMarkdown

/// Renders a note as a standalone HTML document. Images, formulas and diagrams travel inside the
/// file as data URLs, so the export keeps working once it leaves the library.
nonisolated enum HTMLExport {
    static let attachmentLimit = 256
    static let pixelLimit = 32_000_000.0

    @concurrent static func document(text: String, url: URL, root: URL, scale: Double = 2) async throws -> String {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw PreviewFailure.message("Export supports notes up to 2 MB.") }
        let lines = MarkdownLineIndex(text)
        // Front matter is metadata, not content: the preview shows it, the exported document drops it.
        let source = MarkdownRenderer.frontmatter(text, lines: lines)
            .map { (text as NSString).substring(from: $0.range.upperBound) } ?? text
        guard let parser = hanshi_markdown_parser() else { throw PreviewFailure.message("Cannot create Markdown parser") }
        defer { cmark_parser_free(parser) }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let tree = cmark_parser_finish(parser) else { throw PreviewFailure.message("Cannot parse Markdown") }
        defer { cmark_node_free(tree) }
        var palette = Palette()
        try rewrite(tree, base: url, root: root, scale: scale, palette: &palette)
        // Every raw HTML node is gone by now, so CMARK_OPT_UNSAFE only emits the attachments written here.
        guard let rendered = cmark_render_html(tree, CMARK_OPT_UNSAFE, cmark_parser_get_syntax_extensions(parser)) else {
            throw PreviewFailure.message("Cannot render HTML")
        }
        defer { free(rendered) }
        return page(title: url.deletingPathExtension().lastPathComponent, body: String(cString: rendered),
                    highlighting: palette.stylesheet)
    }

    @concurrent static func write(_ html: String, to url: URL) async throws {
        try Data(html.utf8).write(to: url, options: .atomic)
    }

    /// Resolves attachments, neutralises links the preview would refuse to open, and turns literal
    /// HTML into code, so the export shows exactly what the preview shows.
    private static func rewrite(_ tree: UnsafeMutablePointer<cmark_node>, base: URL, root: URL, scale: Double,
                                palette: inout Palette) throws {
        guard let iterator = cmark_iter_new(tree) else { throw PreviewFailure.message("Cannot read the document") }
        var nodes: [UnsafeMutablePointer<cmark_node>] = []
        while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
            if cmark_iter_get_event_type(iterator) == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) {
                nodes.append(node)
            }
        }
        cmark_iter_free(iterator)
        var budget = Budget()
        var slugs: Set<String> = []
        for node in nodes {
            try Task.checkCancellation()
            let kind = String(cString: cmark_node_get_type_string(node))
            let literal = cmark_node_get_literal(node).map(String.init(cString:)) ?? ""
            switch kind {
            case "image":
                let target = cmark_node_get_url(node).map(String.init(cString:)) ?? ""
                if let bitmap = try? PreviewResources.image(target, base: base, root: root) {
                    try budget.take(bitmap, density: 1)
                    cmark_node_set_url(node, dataURL(bitmap))
                } else if (try? PreviewResources.destination(target, base: base, root: root)) == nil {
                    cmark_node_set_url(node, "")
                }
            case "link":
                let target = cmark_node_get_url(node).map(String.init(cString:)) ?? ""
                if (try? PreviewResources.destination(target, base: base, root: root)) == nil {
                    cmark_node_set_url(node, "")
                }
            case "math", "display_math":
                let display = kind == "display_math"
                // A formula that fails to render stays a code span, which is how the preview shows it too.
                guard let bitmap = try? MathRenderer.render(literal, display: display, scale: scale) else { break }
                try budget.take(bitmap, density: scale * scale)
                let alignment = display ? "" : String(format: ";vertical-align:-%.2fpx", max(0, bitmap.height - bitmap.baseline))
                let fence = display ? "$$" : "$"
                replace(node, with: CMARK_NODE_HTML_INLINE, literal: """
                <img class="math\(display ? " math-display" : "")" alt="\(escape(fence + literal + fence))" \
                src="\(dataURL(bitmap))" style="\(size(bitmap))\(alignment)">
                """)
            case "code_block":
                let language = (cmark_node_get_fence_info(node).map(String.init(cString:)) ?? "")
                    .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                if language.lowercased() == "mermaid" {
                    guard let bitmap = try? MermaidRenderer.render(literal, scale: scale) else { break }
                    try budget.take(bitmap, density: scale * scale)
                    replace(node, with: CMARK_NODE_HTML_BLOCK, literal: """
                    <p class="diagram"><img alt="Mermaid diagram" src="\(dataURL(bitmap))" style="\(size(bitmap))"></p>\n
                    """)
                    break
                }
                // Same highlighter and the same size limit as the preview, so both colour alike.
                guard !language.isEmpty, literal.utf8.count <= 65536 else { break }
                let tokens = Highlighter.shared.highlight(literal, as: language).tokens
                guard !tokens.isEmpty else { break }
                replace(node, with: CMARK_NODE_HTML_BLOCK, literal: """
                <pre><code class="language-\(escape(language))">\(highlight(literal, tokens: tokens, palette: &palette))</code></pre>\n
                """)
            case "html_inline": replace(node, with: CMARK_NODE_CODE, literal: literal)
            case "html_block": replace(node, with: CMARK_NODE_CODE_BLOCK, literal: literal)
            case "heading":
                guard let plain = cmark_render_plaintext(node, CMARK_OPT_DEFAULT, 0) else { break }
                defer { free(plain) }
                let base = MarkdownRenderer.slug(String(cString: plain).trimmingCharacters(in: .whitespacesAndNewlines))
                var slug = base
                var suffix = 1
                while slugs.contains(slug) { slug = "\(base)-\(suffix)"; suffix += 1 }
                slugs.insert(slug)
                guard let anchor = cmark_node_new(CMARK_NODE_HTML_INLINE) else { break }
                cmark_node_set_literal(anchor, "<a id=\"\(escape(slug))\"></a>")
                if cmark_node_prepend_child(node, anchor) == 0 { cmark_node_free(anchor) }
            default: break
            }
        }
    }

    private static func replace(_ node: UnsafeMutablePointer<cmark_node>, with type: cmark_node_type, literal: String) {
        guard let replacement = cmark_node_new(type) else { return }
        cmark_node_set_literal(replacement, literal)
        guard cmark_node_replace(node, replacement) != 0 else { return cmark_node_free(replacement) }
        cmark_node_free(node)
    }

    private static func highlight(_ code: String, tokens: [HighlightToken], palette: inout Palette) -> String {
        let ns = code as NSString
        var markup = ""
        var cursor = 0
        for token in tokens where token.range.location >= cursor && token.range.upperBound <= ns.length {
            markup += escape(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            let code = escape(ns.substring(with: token.range))
            markup += palette.name(for: token).map { "<span class=\"\($0)\">\(code)</span>" } ?? code
            cursor = token.range.upperBound
        }
        return markup + escape(ns.substring(from: cursor))
    }

    /// The scope classes a document actually used, written out as a stylesheet instead of inline
    /// styles so the code follows the reader's colour scheme.
    private struct Palette {
        private var light: [String: String] = [:]
        private var dark: [String: String] = [:]

        mutating func name(for token: HighlightToken) -> String? {
            guard let style = HighlightTheme.githubLight.style(for: token) else { return nil }
            let name = "hl-" + token.scope.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            guard light[name] == nil else { return name }
            light[name] = declarations(style)
            if let night = HighlightTheme.githubDark.style(for: token) { dark[name] = declarations(night) }
            return name
        }

        var stylesheet: String {
            var rules = light.keys.sorted().map { ".\($0) { \(light[$0]!) }" }
            let night = dark.keys.sorted().filter { dark[$0] != light[$0] }
            if !night.isEmpty {
                rules.append("@media (prefers-color-scheme: dark) {")
                rules += night.map { "  .\($0) { \(dark[$0]!) }" }
                rules.append("}")
            }
            return rules.joined(separator: "\n")
        }

        private func declarations(_ style: ScopeStyle) -> String {
            var declarations = style.color.flatMap(hex).map { "color: \($0);" } ?? ""
            if style.bold { declarations += " font-weight: 600;" }
            if style.italic { declarations += " font-style: italic;" }
            return declarations.trimmingCharacters(in: .whitespaces)
        }

        private func hex(_ color: NSColor) -> String? {
            guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
            return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255 + 0.5),
                          Int(rgb.greenComponent * 255 + 0.5), Int(rgb.blueComponent * 255 + 0.5))
        }
    }

    private static func dataURL(_ bitmap: PreviewBitmap) -> String {
        "data:image/png;base64," + bitmap.data.base64EncodedString()
    }

    private static func size(_ bitmap: PreviewBitmap) -> String {
        String(format: "width:%.2fpx;height:%.2fpx", bitmap.width, bitmap.height)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    private struct Budget {
        var count = 0
        var pixels = 0.0
        mutating func take(_ bitmap: PreviewBitmap, density: Double) throws {
            count += 1
            pixels += bitmap.width * bitmap.height * density
            guard count <= attachmentLimit, pixels <= pixelLimit else {
                throw PreviewFailure.message("Export attachment budget exceeded (\(attachmentLimit) attachments / 32 million pixels)")
            }
        }
    }

    private static func page(title: String, body: String, highlighting: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --text: #1c1c1e; --page: #ffffff; --link: #0a6cff; --rule: rgba(127,127,127,0.35); --fill: rgba(127,127,127,0.14); }
        @media (prefers-color-scheme: dark) { :root { --text: #e8e8ea; --page: #1c1c1e; --link: #6aa9ff; } }
        body { font: 16px/1.65 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; color: var(--text); background: var(--page); max-width: 46em; margin: 3rem auto; padding: 0 1.25rem; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.8em 0 0.6em; }
        h1 { font-size: 1.9em } h2 { font-size: 1.5em } h3 { font-size: 1.25em }
        a { color: var(--link); }
        code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9em; }
        :not(pre) > code { background: var(--fill); padding: 0.15em 0.35em; border-radius: 4px; }
        pre { background: var(--fill); padding: 0.9em 1em; border-radius: 8px; overflow-x: auto; }
        blockquote { margin: 1.2em 0; padding-left: 1em; border-left: 3px solid var(--rule); opacity: 0.85; }
        table { border-collapse: collapse; margin: 1.4em 0; }
        th, td { border: 1px solid var(--rule); padding: 0.4em 0.7em; text-align: left; }
        hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
        img { max-width: 100%; }
        li input[type="checkbox"] { margin-right: 0.35em; }
        .math-display { display: block; margin: 1.2em auto; }
        .diagram { text-align: center; }
        \(highlighting)
        </style>
        </head>
        <body>
        \(body)</body>
        </html>
        """
    }
}
