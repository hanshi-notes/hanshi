import AppKit
import Testing
@testable import Hanshi

@MainActor enum PreviewTestFixtures {
    static func snapshot(_ text: String, root: URL = URL(filePath: "/tmp/preview-tests")) -> PreviewSnapshot {
        PreviewSnapshot(library: UUID(), documentID: "test", text: text, url: root.appendingPathComponent("Note.md"), root: root)
    }
    static func document(_ text: String, id: String = UUID().uuidString, root: URL = URL(filePath: "/tmp/preview-tests")) -> NoteDocument {
        NoteDocument(note: Note(id: id, url: root.appendingPathComponent("\(id).md")),
                     contents: NoteContents(data: Data(text.utf8), text: text, fileID: id)) { _, _, _ in throw CocoaError(.fileWriteUnknown) }
    }
    static func composition(_ text: String) async throws -> MarkdownComposition {
        try await MarkdownRenderer.compose(try MarkdownRenderer.parse(text), theme: PreviewTheme())
    }
}

@Test @MainActor func previewRendersNestedTraitsWithoutLosingText() async throws {
    let result = try await PreviewTestFixtures.composition("# Heading **bold**\n\nPlain **bold and *italic*** with [**link**](https://example.com) and ~~gone~~.\n\n- **item**\n")
    #expect(result.text.string.contains("Plain bold and italic with link and gone."))
    for word in ["bold", "italic", "link", "item"] {
        let range = (result.text.string as NSString).range(of: word, options: .backwards)
        let font = try #require(result.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        if word == "italic" { #expect(NSFontManager.shared.traits(of: font).contains(.italicFontMask)) }
    }
    let gone = (result.text.string as NSString).range(of: "gone")
    #expect(result.text.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) as? Int == 1)
    #expect(result.anchors.contains { $0.heading == "heading-bold" })
}

@Test @MainActor func previewTasksListsTablesAndLiteralHTML() async throws {
    let result = try await PreviewTestFixtures.composition("""
    3. Three
    4. Four

    - [ ] Pending
    - [x] Done
      - [X] Nested

    Text [x] is not a task.

    | Name | Amount |
    | :--- | ---: |
    | **Tea** | 2 |
    | | 3 |

    <script>alert('literal')</script>
    """)
    #expect(result.text.string.contains("3. Three"))
    #expect(result.text.string.contains("4. Four"))
    #expect(result.text.string.contains("\u{fffc} Pending"))
    #expect(result.text.string.contains("\u{fffc} Done"))
    #expect(result.text.string.contains("\u{fffc} Nested"))
    #expect(result.text.string.contains("Text [x] is not a task."))
    #expect(result.text.string.contains("<script>alert('literal')</script>"))
    let tea = (result.text.string as NSString).range(of: "Tea")
    let style = try #require(result.text.attribute(.paragraphStyle, at: tea.location, effectiveRange: nil) as? NSParagraphStyle)
    let cell = try #require(style.textBlocks.first as? NSTextTableBlock)
    #expect(cell.table.numberOfColumns == 2)
    #expect(cell.startingRow == 1 && cell.startingColumn == 0)
    let amount = (result.text.string as NSString).range(of: "2")
    let amountStyle = try #require(result.text.attribute(.paragraphStyle, at: amount.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(amountStyle.alignment == .right)
}

@Test(arguments: [
    ("swift", "let value = \"😀\"", "keyword"), ("js", "const x = true;", "keyword"),
    ("typescript", "const x: number = 1;", "keyword"), ("python", "def hello():\n    return 1", "keyword"),
    ("bash", "echo \"hello\"", "string"), ("json", "{\"hello\": true}", "attr"),
    ("yaml", "hello: true", "attr"), ("sql", "SELECT * FROM notes;", "keyword"),
    ("html", "<div class=\"x\">Hello</div>", "name"), ("css", "p { color: red; }", "attribute")
]) func previewHighlightsWholeCodeBlocks(language: String, code: String, expected: String) throws {
    let recipe = try MarkdownRenderer.parse("Before\n\n```\(language)\n\(code)\n```\n")
    let run = try #require(recipe.runs.first { !$0.tokens.isEmpty })
    #expect(run.text == code + "\n")
    #expect(run.tokens.contains { $0.scope.contains(expected) })
    #expect(run.tokens.allSatisfy { $0.range.location >= 0 && $0.range.upperBound <= run.text.utf16.count })
}

@Test(arguments: ["", "not-a-language"]) func previewUnknownCodePreservesOriginal(language: String) throws {
    let code = "\"quotes\" `ticks` </script> 😀 漢字"
    let recipe = try MarkdownRenderer.parse("```\(language)\n\(code)\n```")
    #expect(recipe.text == code + "\n")
    #expect(recipe.runs.allSatisfy { $0.tokens.isEmpty })
}

@Test func previewSourceMapPreservesUnicodeAndCRLF() throws {
    let text = "---\r\ntitle: 😀\r\n---\r\n# 漢字\r\n\r\n\tcode 😀\r\n\r\n| a | b |\r\n|---|---|\r\n| 😀 | 値 |\r\n"
    let lines = MarkdownLineIndex(text)
    #expect(lines.offsets[1] == 5)
    #expect((text as NSString).substring(with: lines.range(start: 2, end: 2)) == "title: 😀\r\n")
    let recipe = try MarkdownRenderer.parse(text)
    #expect(recipe.text.hasPrefix("---\r\ntitle: 😀\r\n---\r\n"))
    let heading = try #require(recipe.anchors.first { $0.heading == "漢字" })
    #expect(heading.source == lines.range(start: 4, end: 4))
    #expect(recipe.anchors.allSatisfy { $0.source.upperBound <= text.utf16.count && $0.rendered.upperBound <= recipe.text.utf16.count })
    let row = recipe.anchors.filter { $0.source == lines.range(start: 10, end: 10) }
    #expect(row.count >= 2)
    #expect(Set(row.map(\.rendered.location)).count >= 2)
}

@Test func previewDuplicateUnicodeHeadingsAndIncompleteFrontMatter() throws {
    let recipe = try MarkdownRenderer.parse("# Café 世界\n\n# Café 世界\n\n# Café 世界-1\n")
    #expect(recipe.anchors.compactMap(\.heading) == ["café-世界", "café-世界-1", "café-世界-1-1"])
    #expect(try MarkdownRenderer.parse("---\ntitle: unclosed").text.contains("title: unclosed"))
    #expect(try MarkdownRenderer.parse("").text.isEmpty)
}

@Test(arguments: ["![Logo][logo]\n\n[logo]: picture.png", "![logo][]\n\n[logo]: picture.png", "![LoGo]\n\n[logo]: picture.png"])
func previewResolvesReferenceImages(source: String) throws {
    let recipe = try MarkdownRenderer.parse(source)
    let media = try #require(recipe.runs.compactMap(\.media).first)
    guard case let .image(target, _) = media else { Issue.record("Expected an image"); return }
    #expect(target == "picture.png")
    #expect(try MarkdownRenderer.parse("![missing][unknown]").text.contains("![missing][unknown]"))
}

@Test func mathSyntaxRespectsCodeEscapesCurrencyAndLinks() throws {
    let recipe = try MarkdownRenderer.parse(#"Inline $x_1 + \frac{a}{b}$ and \$escaped, $5 and $10. `$code$` [link](https://example.com/$path$). $$\begin{matrix}a&b\\c&d\end{matrix}$$"#)
    let formulas = recipe.runs.compactMap { run -> String? in
        if case let .math(latex, _) = run.media { return latex }; return nil
    }
    #expect(formulas == [#"x_1 + \frac{a}{b}"#, #"\begin{matrix}a&b\\c&d\end{matrix}"#])
    #expect(recipe.text.contains("$escaped, $5 and $10."))
    #expect(recipe.text.contains("$code$"))
    #expect(recipe.runs.contains { $0.link == "https://example.com/$path$" })
    #expect(try MarkdownRenderer.parse("```latex\n$x$\n```\n\n<span title='$no$'>\n").runs.allSatisfy { $0.media == nil })
    #expect(try MarkdownRenderer.parse("Unclosed $x and $$y").text.contains("$x"))
}

@Test @MainActor func specializedEnginesProduceImagesAndVisibleErrors() async throws {
    let source = """
    $\\frac{1}{2} + \\sqrt{x} + x_i^2$

    $$\\int_0^1 x dx$$

    ```mermaid
    flowchart TD
    A[Start] --> B[Done]
    ```

    ```mermaid
    invalid diagram
    ```

    $\\unknownHanshiCommand{x}$
    """
    let recipe = try await MarkdownRenderer.render(PreviewTestFixtures.snapshot(source))
    #expect(recipe.runs.compactMap(\.bitmap).count == 3)
    #expect(recipe.runs.compactMap(\.bitmap).allSatisfy { $0.width > 1 && $0.height > 1 && !$0.data.isEmpty })
    let result = try await MarkdownRenderer.compose(recipe, theme: PreviewTheme())
    #expect(result.attachments.count == 3)
    #expect(result.attachments.first?.baseline ?? 0 > 0)
    #expect(result.text.string.contains("invalid diagram"))
    #expect(result.text.string.contains("unknownHanshiCommand"))
    #expect(recipe.diagnostics.count == 2)
    #expect(result.anchors.allSatisfy { $0.rendered.upperBound <= result.text.length })
}

@Test func mathCannotConsumeALinkAfterCurrency() throws {
    let source = "$5 and $10 [link](https://example.com/$path$) then $x$"
    let recipe = try MarkdownRenderer.parse(source)
    #expect(recipe.text.contains("$5 and $10 link"))
    #expect(recipe.runs.contains { $0.link == "https://example.com/$path$" })
    #expect(recipe.runs.compactMap(\.media).count == 1)
}

@Test func previewLimitsPathologicalInputsWithoutLosingTheDocument() throws {
    #expect(throws: PreviewFailure.self) { try MarkdownRenderer.parse(String(repeating: "x", count: 2 * 1024 * 1024 + 1)) }
    #expect(throws: PreviewFailure.self) { try MarkdownRenderer.parse(String(repeating: "> ", count: 150) + "deep") }
    #expect(throws: PreviewFailure.self) { try MathRenderer.render(String(repeating: "{", count: 65) + "x", display: false, scale: 2) }
    #expect(throws: PreviewFailure.self) { try MermaidRenderer.render(String(repeating: "x", count: 32769), scale: 2) }
}

@Test func fencedCodeInsideQuotesKeepsEachOriginalSourceLine() throws {
    let source = "> ```swift\n> let first = 1\n> let second = 2\n> ```\n"
    let recipe = try MarkdownRenderer.parse(source)
    let lines = MarkdownLineIndex(source)
    for (line, visible) in [(2, "let first = 1\n"), (3, "let second = 2\n")] {
        #expect(recipe.anchors.contains {
            $0.source == lines.range(start: line, end: line)
                && (recipe.text as NSString).substring(with: $0.rendered) == visible
        })
    }
}
