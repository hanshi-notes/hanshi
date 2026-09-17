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
}

@Test @MainActor func previewRendersNestedTraitsAndHeadingAnchors() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    session.show(PreviewTestFixtures.snapshot("# Heading **bold**\n\nPlain **bold and *italic*** with [**link**](https://example.com) and ~~gone~~.\n\n- **item**\n"))
    await session.waitForRendering()
    defer { session.hide() }
    let storage = try #require(session.textView.textStorage)
    for word in ["bold", "italic", "link", "item"] {
        let range = (storage.string as NSString).range(of: word, options: .backwards)
        let font = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "\(word) must be bold")
        if word == "italic" { #expect(NSFontManager.shared.traits(of: font).contains(.italicFontMask)) }
    }
    let gone = (storage.string as NSString).range(of: "gone")
    #expect(storage.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) as? Int == 1)
    #expect(session.composition?.anchors.contains { $0.heading == "heading-bold" } == true)
}

@Test(arguments: [
    ("swift", "let value = \"😀\"", "keyword"), ("js", "const x = true;", "keyword"),
    ("typescript", "const x: number = 1;", "keyword"), ("python", "def hello():\n    return 1", "keyword"),
    ("bash", "echo \"hello\"", "string"), ("json", "{\"hello\": true}", "attr"),
    ("yaml", "hello: true", "attr"), ("sql", "SELECT * FROM notes;", "keyword"),
    ("html", "<div class=\"x\">Hello</div>", "name"), ("css", "p { color: red; }", "attribute")
]) func previewHighlightsWholeCodeBlocks(language: String, code: String, expected: String) throws {
    let recipe = try MarkdownRenderer.parse("Before\n\n```\(language)\n\(code)\n```\n")
    // Keyed by the block's code, as the engine asks for it.
    let tokens = try #require(recipe.code[code + "\n"])
    #expect(recipe.code.count == 1)
    #expect(tokens.contains { $0.scope.contains(expected) })
    #expect(tokens.allSatisfy { $0.range.location >= 0 && $0.range.upperBound <= (code + "\n").utf16.count })
}

@Test(arguments: ["", "not-a-language"]) func previewUnknownCodePreservesOriginal(language: String) throws {
    let code = "\"quotes\" `ticks` </script> 😀 漢字"
    let recipe = try MarkdownRenderer.parse("```\(language)\n\(code)\n```")
    #expect(recipe.code.isEmpty)
    #expect(recipe.media.isEmpty)
}

@Test func previewSourceMapPreservesUnicodeAndCRLF() throws {
    let text = "---\r\ntitle: 😀\r\n---\r\n# 漢字\r\n\r\n\tcode 😀\r\n\r\n| a | b |\r\n|---|---|\r\n| 😀 | 値 |\r\n"
    let lines = MarkdownLineIndex(text)
    #expect(lines.offsets[1] == 5)
    #expect((text as NSString).substring(with: lines.range(start: 2, end: 2)) == "title: 😀\r\n")
    let recipe = try MarkdownRenderer.parse(text)
    #expect(recipe.anchors.first?.source == lines.range(start: 1, end: 3), "Front matter is its own anchor")
    let heading = try #require(recipe.anchors.first { $0.heading == "漢字" })
    #expect(heading.source == lines.range(start: 4, end: 4))
    #expect(recipe.anchors.contains { $0.source == lines.range(start: 6, end: 6) }, "Indented code line")
    #expect(recipe.anchors.contains { $0.source == lines.range(start: 10, end: 10) }, "Table row")
    #expect(recipe.anchors.allSatisfy { $0.source.upperBound <= text.utf16.count && $0.rendered == $0.source })
}

@Test func previewDuplicateUnicodeHeadingsAndIncompleteFrontMatter() throws {
    let recipe = try MarkdownRenderer.parse("# Café 世界\n\n# Café 世界\n\n# Café 世界-1\n")
    #expect(recipe.anchors.compactMap(\.heading) == ["café-世界", "café-世界-1", "café-世界-1-1"])
    // Unclosed front matter is ordinary Markdown: a rule, then a paragraph.
    #expect(try MarkdownRenderer.parse("---\ntitle: unclosed").anchors.map(\.source) == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 15)])
    #expect(try MarkdownRenderer.parse("").anchors.isEmpty)
}

@Test(arguments: ["![Logo][logo]\n\n[logo]: picture.png", "![logo][]\n\n[logo]: picture.png", "![LoGo]\n\n[logo]: picture.png"])
func previewResolvesReferenceImages(source: String) throws {
    let recipe = try MarkdownRenderer.parse(source)
    let media = try #require(recipe.media.first)
    guard case let .image(target) = media.kind else { Issue.record("Expected an image"); return }
    #expect(target == "picture.png")
    #expect(try MarkdownRenderer.parse("![missing][unknown]").media.isEmpty)
}

@Test func mathSyntaxRespectsCodeEscapesCurrencyAndLinks() throws {
    let recipe = try MarkdownRenderer.parse(#"Inline $x_1 + \frac{a}{b}$ and \$escaped, $5 and $10. `$code$` [link](https://example.com/$path$). $$\begin{matrix}a&b\\c&d\end{matrix}$$"#)
    #expect(formulas(in: recipe) == [#"x_1 + \frac{a}{b}"#, #"\begin{matrix}a&b\\c&d\end{matrix}"#])
    #expect(try MarkdownRenderer.parse("```latex\n$x$\n```\n\n<span title='$no$'>\n").media.isEmpty)
    #expect(try MarkdownRenderer.parse("Unclosed $x and $$y").media.isEmpty)
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
    let session = MarkdownPreviewSession(debounce: .zero)
    session.show(PreviewTestFixtures.snapshot(source)); await session.waitForRendering()
    defer { session.hide() }
    let recipe = try #require(session.recipe)
    #expect(recipe.media.compactMap(\.bitmap).count == 3)
    #expect(recipe.media.compactMap(\.bitmap).allSatisfy { $0.width > 1 && $0.height > 1 && !$0.data.isEmpty })
    #expect(recipe.diagnostics.count == 2)
    #expect(previewImages(in: session.textView).count == 3)
    #expect(session.textView.string.contains("invalid diagram"))
    #expect(session.textView.string.contains("unknownHanshiCommand"))
    #expect(session.message?.components(separatedBy: " · ").count == 2)
    let length = session.textView.textStorage?.length ?? 0
    #expect(session.composition?.anchors.allSatisfy { $0.rendered.upperBound <= length } == true)
}

@Test func mathCannotConsumeALinkAfterCurrency() throws {
    let source = "$5 and $10 [link](https://example.com/$path$) then $x$"
    #expect(formulas(in: try MarkdownRenderer.parse(source)) == ["x"])
}

@Test func mathLeavesLinkDestinationsIntactInExports() async throws {
    let source = "$5 and $10 [link](https://example.com/$path$) then $x$"
    let html = try await HTMLExport.document(text: source, url: URL(filePath: "/tmp/hanshi-math/Note.md"), root: URL(filePath: "/tmp/hanshi-math"))
    #expect(html.contains("href=\"https://example.com/$path$\""))
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
    for (line, visible) in [(2, "> let first = 1\n"), (3, "> let second = 2\n")] {
        let anchor = recipe.anchors.first { $0.source == lines.range(start: line, end: line) }
        #expect(anchor.map { (source as NSString).substring(with: $0.source) } == visible)
    }
    #expect(recipe.code["let first = 1\nlet second = 2\n"] != nil)
}

private func formulas(in recipe: MarkdownRecipe) -> [String] {
    recipe.media.compactMap { if case let .math(latex, _) = $0.kind { latex } else { nil } }
}

@Test func previewAnchorsEmptyBlocksAndKeepsImageAltTextOutOfHeadings() throws {
    let source = "- \n\n#\n\n# Title ![alt $x$](a.png)\n\n![](b.png)\n"
    let recipe = try MarkdownRenderer.parse(source)
    let lines = MarkdownLineIndex(source)
    // Each block anchors once, however many children it has.
    #expect(recipe.anchors.filter { $0.source == lines.range(start: 1, end: 1) }.count == 1, "An empty list item")
    #expect(recipe.anchors.filter { $0.source == lines.range(start: 3, end: 3) }.map(\.heading) == [""], "An empty heading")
    #expect(recipe.anchors.compactMap(\.heading) == ["", "title-"])
    let targets = recipe.media.compactMap { if case let .image(target) = $0.kind { target } else { nil } }
    #expect(targets == ["a.png", "b.png"] && recipe.media.count == 2, "Each image once, nothing from its alt text")
}

/// A heading that already carries a suffix still pushes later repeats past it, in the preview and the export alike.
@Test func repeatedHeadingsTakeTheFirstFreeSuffixInPreviewAndExport() async throws {
    let source = "# A\n\n# A-2\n\n# A\n\n# A\n\n# A\n"
    let expected = ["a", "a-2", "a-1", "a-3", "a-4"]
    #expect(try MarkdownRenderer.parse(source).anchors.compactMap(\.heading) == expected)
    let html = try await HTMLExport.document(text: source, url: URL(filePath: "/tmp/hanshi-slugs/Note.md"), root: URL(filePath: "/tmp/hanshi-slugs"))
    let ids = html.components(separatedBy: "<a id=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
    #expect(ids == expected)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HANSHI_PERF"] != nil))
func repeatedHeadingSlugsScaleLinearly() throws {
    func seconds(_ headings: Int) throws -> Double {
        let text = String(repeating: "## Notes\n\n", count: headings)
        let clock = ContinuousClock()
        let elapsed = try clock.measure { _ = try MarkdownRenderer.parse(text) }.components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    let small = try seconds(2_000), large = try seconds(16_000)
    print("HEADING_SLUGS small=\(small) large=\(large) ratio=\(large / small)")
    // 8× the headings: linear reads about 8×, retrying every suffix from 1 about 64×.
    #expect(large / small < 16)
}
