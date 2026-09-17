import Foundation
import cmark_gfm
import cmark_gfm_extensions
import CMarkdown
import HighlightKit

nonisolated struct PreviewSnapshot: Equatable, Sendable {
    let library: UUID
    let documentID: String
    var text: String
    let url: URL
    let root: URL
    var theme = PreviewTheme()
    var settings = PreviewSettings()
    var resources = 0
    var scale = 2.0
    var noteURLs: [URL] = []
}

nonisolated struct MarkdownLineIndex: Sendable {
    let offsets: [Int]
    let length: Int
    init(_ text: String) {
        let units = Array(text.utf16)
        var starts = [0]
        var index = 0
        while index < units.count {
            if units[index] == 13 {
                if index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                starts.append(index + 1)
            } else if units[index] == 10 { starts.append(index + 1) }
            index += 1
        }
        offsets = starts
        length = units.count
    }
    func range(start: Int, end: Int) -> NSRange {
        let first = offsets[min(max(0, start - 1), offsets.count - 1)]
        let last = end < offsets.count ? offsets[max(0, end)] : length
        return NSRange(location: first, length: max(0, last - first))
    }
}

nonisolated struct MarkdownAnchor: Sendable, Equatable {
    let source: NSRange
    var rendered: NSRange
    var heading: String? = nil
}

nonisolated struct PreviewMedia: Sendable {
    nonisolated enum Kind: Sendable {
        case image(String)
        case math(String, display: Bool)
        case mermaid(String)
    }
    let kind: Kind
    var bitmap: PreviewBitmap?
}

/// What the engine cannot work out on the main thread by itself: where each block sits in the source,
/// the attachments to draw ahead of time, and the highlighting for fenced code.
/// Makes repeated headings unique the way GitHub does: the first free `-1`, `-2`, … suffix.
nonisolated struct HeadingSlugs {
    private var taken: Set<String> = []
    /// Per base, the lowest suffix that may be free. Slugs are never released, so all below it stay taken,
    /// and a run of identical headings no longer retries every suffix from 1.
    private var nextSuffix: [String: Int] = [:]

    mutating func claim(_ base: String) -> String {
        var slug = base
        if taken.contains(base) {
            var suffix = nextSuffix[base, default: 1]
            repeat { slug = "\(base)-\(suffix)"; suffix += 1 } while taken.contains(slug)
            nextSuffix[base] = suffix
        }
        taken.insert(slug)
        return slug
    }
}

nonisolated struct MarkdownRecipe: Sendable {
    var anchors: [MarkdownAnchor]
    var media: [PreviewMedia] = []
    /// HighlightKit tokens for each fenced block with a language, keyed by its code.
    var code: [String: [HighlightToken]] = [:]
    var diagnostics: [String] = []
}

nonisolated enum MarkdownRenderer {
    @concurrent static func render(_ snapshot: PreviewSnapshot, cached: MarkdownRecipe? = nil) async throws -> MarkdownRecipe {
        // ponytail: full parse up to 2 MB; add block caching if measured update latency exceeds the budget.
        var recipe = try cached ?? parse(snapshot.text)
        recipe.diagnostics = []
        for index in recipe.media.indices { recipe.media[index].bitmap = nil }
        var pixels = 0.0
        // Parsing and all native engines run off MainActor. Only immutable values leave this operation.
        for index in recipe.media.indices {
            try Task.checkCancellation()
            let kind = recipe.media[index].kind
            do {
                guard index < 256, pixels < 32_000_000 else { throw PreviewFailure.message("Preview attachment budget exceeded (256 attachments / 32 million pixels)") }
                recipe.media[index].bitmap = try autoreleasepool {
                    switch kind {
                    case let .image(target): try PreviewResources.image(target, base: snapshot.url, root: snapshot.root)
                    case let .math(latex, display): try MathRenderer.render(latex, display: display, scale: snapshot.scale)
                    case let .mermaid(source): try MermaidRenderer.render(source, scale: snapshot.scale)
                    }
                }
                if let bitmap = recipe.media[index].bitmap {
                    let density = if case .image = kind { 1.0 } else { snapshot.scale * snapshot.scale }
                    pixels += bitmap.width * bitmap.height * density
                    if pixels > 32_000_000 {
                        recipe.media[index].bitmap = nil
                        throw PreviewFailure.message("Preview attachment budget exceeded (32 million pixels)")
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { recipe.diagnostics.append(error.localizedDescription) }
        }
        return recipe
    }

    static func parse(_ text: String) throws -> MarkdownRecipe {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw PreviewFailure.message("Preview supports notes up to 2 MB. The full source remains available in Editor.") }
        let lines = MarkdownLineIndex(text)
        var recipe = MarkdownRecipe(anchors: [])
        var source = text
        var baseLine = 0
        if let matter = frontmatter(text, lines: lines) {
            recipe.anchors.append(MarkdownAnchor(source: matter.range, rendered: matter.range))
            source = (text as NSString).substring(from: matter.range.upperBound)
            baseLine = matter.endLine
        }
        guard let parser = hanshi_markdown_parser() else { throw PreviewFailure.message("Cannot create Markdown parser") }
        defer { cmark_parser_free(parser) }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let root = cmark_parser_finish(parser) else { throw PreviewFailure.message("Cannot parse Markdown") }
        defer { cmark_node_free(root) }
        guard let iterator = cmark_iter_new(root) else { throw PreviewFailure.message("Cannot read the document") }
        defer { cmark_iter_free(iterator) }

        func anchor(_ node: UnsafeMutablePointer<cmark_node>, heading: String? = nil) {
            let range = lines.range(start: baseLine + Int(cmark_node_get_start_line(node)), end: baseLine + Int(cmark_node_get_end_line(node)))
            recipe.anchors.append(MarkdownAnchor(source: range, rendered: range, heading: heading))
        }
        func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String { cmark_node_get_literal(node).map(String.init(cString:)) ?? "" }
        var heading: String?
        var slugs = HeadingSlugs()
        var image: UnsafeMutablePointer<cmark_node>?

        func visit(_ node: UnsafeMutablePointer<cmark_node>, kind: String, hasChildren: Bool) {
            switch kind {
            case "text", "code", "html_inline": heading? += literal(node)
            case "softbreak", "linebreak": heading? += " "
            case "heading": heading = ""
            case "paragraph", "item", "tasklist", "block_quote", "thematic_break", "html_block", "table_row", "table_header": anchor(node)
            case "math", "display_math": recipe.media.append(PreviewMedia(kind: .math(literal(node), display: kind == "display_math")))
            case "image":
                if hasChildren { image = node }
                recipe.media.append(PreviewMedia(kind: .image(cmark_node_get_url(node).map(String.init(cString:)) ?? "")))
            case "code_block":
                anchor(node)
                let code = literal(node)
                let language = (cmark_node_get_fence_info(node).map(String.init(cString:)) ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                if language.lowercased() == "mermaid" {
                    recipe.media.append(PreviewMedia(kind: .mermaid(code)))
                    return
                }
                if !language.isEmpty, code.utf8.count <= 65536 {
                    let tokens = Highlighter.shared.highlight(code, as: language).tokens
                    if !tokens.isEmpty { recipe.code[code] = tokens }
                }
                // One anchor per code line, so a long block still scrolls in step with the editor.
                var fenceLength: Int32 = 0, fenceOffset: Int32 = 0
                var fenceCharacter: CChar = 0
                let fenced = cmark_node_get_fenced(node, &fenceLength, &fenceOffset, &fenceCharacter) != 0
                let first = baseLine + Int(cmark_node_get_start_line(node)) + (fenced ? 1 : 0)
                for index in MarkdownLineIndex(code).offsets.indices {
                    let range = lines.range(start: first + index, end: first + index)
                    recipe.anchors.append(MarkdownAnchor(source: range, rendered: range))
                }
            default: break
            }
        }

        // Iterating instead of recursing: Swift debug frames overflow a worker stack long before 128 nested blocks.
        var depth = 0, nodeCount = 0
        while case let event = cmark_iter_next(iterator), event != CMARK_EVENT_DONE {
            guard let node = cmark_iter_get_node(iterator) else { continue }
            let hasChildren = cmark_node_first_child(node) != nil
            let kind = String(cString: cmark_node_get_type_string(node))
            if event == CMARK_EVENT_ENTER {
                try Task.checkCancellation()
                nodeCount += 1
                guard depth <= 128, nodeCount <= 250_000 else { throw PreviewFailure.message("Markdown nesting or complexity limit exceeded") }
                // An image's alt text is neither content nor a heading's title.
                if image == nil { visit(node, kind: kind, hasChildren: hasChildren) }
                if hasChildren { depth += 1 }
            }
            if event == CMARK_EVENT_EXIT {
                if hasChildren { depth -= 1 }
                if node == image { image = nil }
                if kind == "heading", let title = heading {
                    anchor(node, heading: slugs.claim(slug(title)))
                    heading = nil
                }
            }
        }
        return recipe
    }

    /// The YAML front matter block a note opens with, as a source range and the line it closes on.
    static func frontmatter(_ text: String, lines: MarkdownLineIndex) -> (range: NSRange, endLine: Int)? {
        let ns = text as NSString
        guard lines.offsets.count > 2,
              ns.substring(with: lines.range(start: 1, end: 1)).trimmingCharacters(in: .newlines) == "---" else { return nil }
        for line in 2...min(lines.offsets.count, 10000) {
            let value = ns.substring(with: lines.range(start: line, end: line)).trimmingCharacters(in: .newlines)
            if value == "---" || value == "..." { return (lines.range(start: 1, end: line), line) }
        }
        return nil
    }

    private static let slugCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_-"))

    static func slug(_ title: String) -> String {
        var slug = String.UnicodeScalarView()
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { slug.append("-") }
            else if slugCharacters.contains(scalar) { slug.append(scalar) }
        }
        return String(slug)
    }
}
