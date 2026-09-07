import Foundation
import cmark_gfm
import cmark_gfm_extensions
import CMarkdown
import HighlightKit

nonisolated struct PreviewSnapshot: Equatable, Sendable {
    let library: UUID
    let documentID: String
    let text: String
    let url: URL
    let root: URL
    var theme = PreviewTheme()
    var resources = 0
    var scale = 2.0
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

nonisolated struct PreviewParagraph: Sendable, Hashable {
    var heading = 0
    var indent = 0
    var quote = 0
    var compact = false
    var code = false
    var codeBlock: Int?
    var cell: PreviewCell?
}

nonisolated struct PreviewCell: Sendable, Hashable {
    let table: Int
    let columns: Int
    let row: Int
    let column: Int
    let alignment: UInt8
    let header: Bool
}

nonisolated struct PreviewRun: Sendable {
    var text: String
    var paragraph = PreviewParagraph()
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var link: String?
    var task: Bool?
    var tokens: [HighlightToken] = []
    var media: Media?
    var bitmap: PreviewBitmap?
    var diagnostic: String?

    nonisolated enum Media: Sendable {
        case image(String, alt: String)
        case math(String, display: Bool)
        case mermaid(String)
        var alternative: String {
            switch self {
            case let .image(target, alt): return "[Image: \(alt.isEmpty ? target : alt)]"
            case let .math(latex, display): return (display ? "$$" : "$") + latex + (display ? "$$" : "$")
            case let .mermaid(source): return "Mermaid diagram:\n" + source
            }
        }
    }
}

nonisolated struct MarkdownRecipe: Sendable {
    var runs: [PreviewRun]
    var anchors: [MarkdownAnchor]
    var diagnostics: [String] = []
    var text: String { runs.map(\.text).joined() }
}

nonisolated enum MarkdownRenderer {
    @concurrent static func render(_ snapshot: PreviewSnapshot, cached: MarkdownRecipe? = nil) async throws -> MarkdownRecipe {
        // ponytail: full parse up to 2 MB; add block caching if measured update latency exceeds the budget.
        var recipe = try cached ?? parse(snapshot.text)
        recipe.diagnostics = []
        for index in recipe.runs.indices { recipe.runs[index].bitmap = nil; recipe.runs[index].diagnostic = nil }
        var mediaCount = 0
        var pixels = 0.0
        // Parsing and all native engines run off MainActor. Only immutable values leave this operation.
        for index in recipe.runs.indices {
            try Task.checkCancellation()
            guard let media = recipe.runs[index].media else { continue }
            do {
                guard mediaCount < 256, pixels < 32_000_000 else { throw PreviewFailure.message("Preview attachment budget exceeded (256 attachments / 32 million pixels)") }
                mediaCount += 1
                recipe.runs[index].bitmap = try autoreleasepool {
                    switch media {
                    case let .image(target, _): try PreviewResources.image(target, base: snapshot.url, root: snapshot.root)
                    case let .math(latex, display): try MathRenderer.render(latex, display: display, scale: snapshot.scale)
                    case let .mermaid(source): try MermaidRenderer.render(source, scale: snapshot.scale)
                    }
                }
                if let bitmap = recipe.runs[index].bitmap {
                    let density = if case .image = media { 1.0 } else { snapshot.scale * snapshot.scale }
                    pixels += bitmap.width * bitmap.height * density
                    if pixels > 32_000_000 {
                        recipe.runs[index].bitmap = nil
                        throw PreviewFailure.message("Preview attachment budget exceeded (32 million pixels)")
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                recipe.runs[index].diagnostic = error.localizedDescription
                recipe.diagnostics.append(error.localizedDescription)
            }
        }
        return recipe
    }

    static func parse(_ text: String) throws -> MarkdownRecipe {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw PreviewFailure.message("Preview supports notes up to 2 MB. The full source remains available in Editor.") }
        let builder = Builder(text: text)
        return try builder.build()
    }

    private final class Builder {
        let text: String
        let lines: MarkdownLineIndex
        var runs: [PreviewRun] = []
        var anchors: [MarkdownAnchor] = []
        var offset = 0
        var baseLine = 0
        var tables = 0
        var slugs: Set<String> = []
        var nodeCount = 0
        var work: [() throws -> Void] = []

        init(text: String) { self.text = text; lines = MarkdownLineIndex(text) }
        func append(_ text: String, _ style: PreviewRun) {
            guard !text.isEmpty else { return }
            var run = style
            run.text = text
            runs.append(run)
            offset += text.utf16.count
        }
        func newline(_ style: PreviewRun) {
            if runs.last?.text.hasSuffix("\n") != true { append("\n", style) }
        }
        func build() throws -> MarkdownRecipe {
            var source = text
            let ns = text as NSString
            if lines.offsets.count > 2, ns.substring(with: lines.range(start: 1, end: 1)).trimmingCharacters(in: .newlines) == "---" {
                for line in 2...min(lines.offsets.count, 10000) {
                    let value = ns.substring(with: lines.range(start: line, end: line)).trimmingCharacters(in: .newlines)
                    if value == "---" || value == "..." {
                        let range = lines.range(start: 1, end: line)
                        var style = PreviewRun(text: "")
                        style.code = true; style.paragraph.code = true; style.paragraph.codeBlock = 0
                        append(ns.substring(with: range), style)
                        newline(style)
                        anchors.append(MarkdownAnchor(source: range, rendered: NSRange(location: 0, length: offset)))
                        source = ns.substring(from: range.upperBound)
                        baseLine = line
                        break
                    }
                }
            }
            guard let parser = hanshi_markdown_parser() else { throw PreviewFailure.message("Cannot create Markdown parser") }
            defer { cmark_parser_free(parser) }
            source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
            guard let root = cmark_parser_finish(parser) else { throw PreviewFailure.message("Cannot parse Markdown") }
            defer { cmark_node_free(root) }
            defer { work.removeAll() }
            try walk(root, style: PreviewRun(text: ""), depth: 0)
            while let next = work.popLast() { try Task.checkCancellation(); try next() }
            anchors.sort { $0.source.location == $1.source.location ? $0.source.length < $1.source.length : $0.source.location < $1.source.location }
            return MarkdownRecipe(runs: runs, anchors: anchors)
        }
        func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String { cmark_node_get_literal(node).map(String.init(cString:)) ?? "" }
        func children(_ node: UnsafeMutablePointer<cmark_node>, style: PreviewRun, depth: Int) throws {
            var nodes: [UnsafeMutablePointer<cmark_node>] = []
            var child = cmark_node_first_child(node)
            while let current = child { nodes.append(current); child = cmark_node_next(current) }
            // Explicit traversal stack: Swift debug frames overflow a worker stack long before 128 nested blocks.
            for current in nodes.reversed() { work.append { try self.walk(current, style: style, depth: depth + 1) } }
        }
        func sourceRange(_ node: UnsafeMutablePointer<cmark_node>) -> NSRange {
            lines.range(start: baseLine + Int(cmark_node_get_start_line(node)), end: baseLine + Int(cmark_node_get_end_line(node)))
        }
        func walk(_ node: UnsafeMutablePointer<cmark_node>, style original: PreviewRun, depth: Int) throws {
            try Task.checkCancellation()
            nodeCount += 1
            guard depth <= 128, nodeCount <= 250_000 else { throw PreviewFailure.message("Markdown nesting or complexity limit exceeded") }
            var style = original
            let kind = String(cString: cmark_node_get_type_string(node))
            let start = offset
            let firstRun = runs.count
            let isBlock = ["paragraph", "heading", "item", "tasklist", "block_quote", "code_block", "thematic_break", "html_block", "table_row", "table_header", "table_cell"].contains(kind)
            var heading: String?
            if isBlock {
                work.append { self.anchors.append(MarkdownAnchor(source: self.sourceRange(node), rendered: NSRange(location: start, length: self.offset - start), heading: heading)) }
            }
            switch kind {
            case "document": try children(node, style: style, depth: depth)
            case "text": append(literal(node), style)
            case "softbreak": append(" ", style)
            case "linebreak": append("\n", style)
            case "strong": style.bold = true; try children(node, style: style, depth: depth)
            case "emph": style.italic = true; try children(node, style: style, depth: depth)
            case "strikethrough": style.strike = true; try children(node, style: style, depth: depth)
            case "code": style.code = true; append(literal(node), style)
            case "math", "display_math":
                style.media = .math(literal(node), display: kind == "display_math")
                append("\u{fffc}", style)
            case "paragraph", "heading":
                if kind == "heading" { style.paragraph.heading = Int(cmark_node_get_heading_level(node)); style.bold = true }
                let paragraphStyle = style
                work.append {
                    if kind == "heading" {
                        let raw = self.runs[firstRun...].map(\.text).joined()
                        let base = MarkdownRenderer.slug(raw)
                        var slug = base; var suffix = 1
                        while self.slugs.contains(slug) { slug = "\(base)-\(suffix)"; suffix += 1 }
                        self.slugs.insert(slug); heading = slug
                    }
                    self.newline(paragraphStyle)
                }
                try children(node, style: style, depth: depth)
            case "block_quote":
                style.paragraph.quote += 1
                try children(node, style: style, depth: depth)
            case "list":
                style.paragraph.indent += 1
                style.paragraph.compact = cmark_node_get_list_tight(node) != 0
                var number = Int(cmark_node_get_list_start(node))
                var child = cmark_node_first_child(node)
                var items: [() throws -> Void] = []
                let itemStyle = style
                while let item = child {
                    let task = String(cString: cmark_node_get_type_string(item)) == "tasklist"
                    let marker = task ? (cmark_gfm_extensions_get_tasklist_item_checked(item) ? "☑ " : "☐ ")
                        : (cmark_node_get_list_type(node) == CMARK_ORDERED_LIST ? "\(number). " : "• ")
                    items.append {
                        let itemStart = self.offset
                        var markerStyle = itemStyle
                        if task { markerStyle.task = cmark_gfm_extensions_get_tasklist_item_checked(item) }
                        self.append(marker, markerStyle)
                        self.work.append { self.anchors.append(MarkdownAnchor(source: self.sourceRange(item), rendered: NSRange(location: itemStart, length: self.offset - itemStart))) }
                        try self.walk(item, style: itemStyle, depth: depth + 1)
                    }
                    number += 1; child = cmark_node_next(item)
                }
                work.append(contentsOf: items.reversed())
            case "item", "tasklist":
                let itemStyle = style
                work.append { self.newline(itemStyle) }
                try children(node, style: style, depth: depth)
            case "link":
                style.link = cmark_node_get_url(node).map(String.init(cString:))
                try children(node, style: style, depth: depth)
            case "image":
                var alt = ""
                let iterator = cmark_iter_new(node)!
                defer { cmark_iter_free(iterator) }
                while cmark_iter_next(iterator) != CMARK_EVENT_DONE {
                    if let current = cmark_iter_get_node(iterator), cmark_node_get_type(current) == CMARK_NODE_TEXT { alt += literal(current) }
                }
                let target = cmark_node_get_url(node).map(String.init(cString:)) ?? ""
                style.media = .image(target, alt: alt)
                append("\u{fffc}", style)
            case "code_block":
                style.code = true; style.paragraph.code = true
                let code = literal(node)
                let language = (cmark_node_get_fence_info(node).map(String.init(cString:)) ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                if language.lowercased() == "mermaid" {
                    style.media = .mermaid(code); append("\u{fffc}", style); style.media = nil; newline(style)
                } else {
                    style.paragraph.codeBlock = sourceRange(node).location + 1
                    if !language.isEmpty, code.utf8.count <= 65536 { style.tokens = Highlighter.shared.highlight(code, as: language).tokens }
                    append(code.isEmpty ? "\n" : code, style)
                    let codeLines = MarkdownLineIndex(code)
                    let sourceLine = baseLine + Int(cmark_node_get_start_line(node))
                    var fenceLength: Int32 = 0, fenceOffset: Int32 = 0
                    var fenceCharacter: CChar = 0
                    let fenced = cmark_node_get_fenced(node, &fenceLength, &fenceOffset, &fenceCharacter) != 0
                    for index in codeLines.offsets.indices {
                        let range = codeLines.range(start: index + 1, end: index + 1)
                        anchors.append(MarkdownAnchor(source: lines.range(start: sourceLine + (fenced ? 1 : 0) + index, end: sourceLine + (fenced ? 1 : 0) + index), rendered: NSRange(location: start + range.location, length: range.length)))
                    }
                    style.tokens = []; newline(style)
                }
            case "thematic_break": append("────────────────\n", style)
            case "html_inline": style.code = true; append(literal(node), style)
            case "html_block": style.code = true; append(literal(node), style); newline(style)
            case "table":
                let table = tables; tables += 1
                let columns = Int(cmark_gfm_extensions_get_table_columns(node))
                let alignments = cmark_gfm_extensions_get_table_alignments(node)
                var rowNode = cmark_node_first_child(node); var row = 0
                var rows: [() throws -> Void] = []
                let tableStyle = style
                while let currentRow = rowNode {
                    var cellNode = cmark_node_first_child(currentRow); var column = 0
                    var cells: [() throws -> Void] = []
                    while let cellNodeValue = cellNode {
                        var cellStyle = style
                        cellStyle.paragraph.cell = PreviewCell(table: table, columns: columns, row: row, column: column,
                            alignment: alignments?[column] ?? 0, header: row == 0)
                        cellStyle.bold = row == 0 || style.bold
                        let finalStyle = cellStyle
                        cells.append {
                            let cellStart = self.offset
                            self.work.append {
                                self.append("\n", finalStyle)
                                self.anchors.append(MarkdownAnchor(source: self.sourceRange(currentRow), rendered: NSRange(location: cellStart, length: self.offset - cellStart)))
                            }
                            try self.children(cellNodeValue, style: finalStyle, depth: depth + 2)
                        }
                        column += 1; cellNode = cmark_node_next(cellNodeValue)
                    }
                    let rowCells = cells
                    rows.append {
                        let rowStart = self.offset
                        self.work.append { self.anchors.append(MarkdownAnchor(source: self.sourceRange(currentRow), rendered: NSRange(location: rowStart, length: self.offset - rowStart))) }
                        self.work.append(contentsOf: rowCells.reversed())
                    }
                    row += 1; rowNode = cmark_node_next(currentRow)
                }
                work.append { self.append("\n", tableStyle) }
                work.append(contentsOf: rows.reversed())
            default:
                if cmark_node_first_child(node) != nil { try children(node, style: style, depth: depth) }
                else { append(literal(node), style) }
            }
        }
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn: "_-"))
        return title.lowercased().unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return "-" }
            return allowed.contains(scalar) ? String(scalar) : nil
        }.joined()
    }
}
