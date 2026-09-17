import Foundation
import Testing
@testable import Hanshi

private let library = URL(filePath: "/tmp/hanshi-export-tests")
private let note = library.appendingPathComponent("My Note.md")

@Test func htmlExportRendersStructureAndDropsFrontMatter() async throws {
    let source = """
    ---
    title: Hidden
    ---
    # My Note

    - [ ] Pending
    - [x] Done

    | A | B |
    |---|---|
    | 1 | 2 |

    ~~gone~~, `code` and https://example.com

    ```swift
    let x = 1
    ```
    """
    let html = try await HTMLExport.document(text: source, url: note, root: library)
    #expect(html.hasPrefix("<!DOCTYPE html>"))
    #expect(html.contains("<title>My Note</title>"))
    #expect(!html.contains("title: Hidden"))
    #expect(html.contains("<h1><a id=\"my-note\"></a>My Note</h1>"))
    #expect(html.contains("type=\"checkbox\""))
    #expect(html.contains("<table>") && html.contains("<th>A</th>"))
    #expect(html.contains("<del>gone</del>"))
    #expect(html.contains("<a href=\"https://example.com\">"))
    #expect(html.contains("<code class=\"language-swift\">"))
}

@Test func htmlExportNumbersRepeatedHeadingAnchors() async throws {
    let html = try await HTMLExport.document(text: "# Notes\n\n## Notes\n", url: note, root: library)
    #expect(html.contains("<a id=\"notes\"></a>"))
    #expect(html.contains("<a id=\"notes-1\"></a>"))
}

@Test func htmlExportEmbedsFormulasAndDiagrams() async throws {
    let source = """
    Inline $x^2$ and a block:

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
    let html = try await HTMLExport.document(text: source, url: note, root: library)
    #expect(html.components(separatedBy: "data:image/png;base64,").count == 4)
    #expect(html.contains("class=\"math\"") && html.contains("vertical-align:-"))
    #expect(html.contains("class=\"math math-display\""))
    #expect(html.contains("class=\"diagram\""))
    // Whatever an engine refuses to draw stays readable as source, as it does in the preview.
    #expect(html.contains("<code>\\unknownHanshiCommand{x}</code>"))
    #expect(html.contains("language-mermaid") && html.contains("invalid diagram"))
}

@Test func htmlExportEmbedsLocalImagesAndNeutralisesBlockedLinks() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    try fixture.png().write(to: fixture.root.appendingPathComponent("pic.png"))
    let source = """
    ![shot](pic.png) ![missing](gone.png) ![remote](https://example.com/a.png)

    [bad](javascript:alert\\(1\\)) [outside](../escape.md) [anchor](#my-note)
    """
    let html = try await HTMLExport.document(text: source, url: fixture.root.appendingPathComponent("Note.md"), root: fixture.root)
    #expect(html.contains("<img src=\"data:image/png;base64,") && html.contains("alt=\"shot\""))
    #expect(html.contains("<img src=\"gone.png\" alt=\"missing\""))
    #expect(html.contains("<img src=\"https://example.com/a.png\" alt=\"remote\""))
    #expect(!html.contains("javascript:"))
    #expect(html.contains("<a href=\"\">bad</a>") && html.contains("<a href=\"\">outside</a>"))
    #expect(html.contains("<a href=\"#my-note\">anchor</a>"))
}

@Test func htmlExportKeepsLiteralHTMLInert() async throws {
    let html = try await HTMLExport.document(text: "<script>alert(1)</script>\n\nInline <b>bold</b> stays literal.\n",
                                             url: note, root: library)
    #expect(!html.contains("<script"))
    #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(html.contains("<code>&lt;b&gt;</code>"))
    #expect(!html.contains("raw HTML omitted"))
}

@Test func htmlExportRefusesOversizedNotes() async throws {
    await #expect(throws: PreviewFailure.self) {
        try await HTMLExport.document(text: String(repeating: "x", count: 2 * 1024 * 1024 + 1), url: note, root: library)
    }
}

@Test func htmlExportColoursCodeWithTheSameHighlighterAsThePreview() async throws {
    let source = """
    ```swift
    let answer = 42 // why
    ```

    ```
    plain fence
    ```

    ```definitely-not-a-language
    untouched
    ```
    """
    let html = try await HTMLExport.document(text: source, url: note, root: library)
    #expect(html.contains("<pre><code class=\"language-swift\"><span class=\"hl-keyword\">let</span> answer"))
    #expect(html.contains("<span class=\"hl-number\">42</span>"))
    #expect(html.contains("<span class=\"hl-comment\">// why</span>"))
    // Colours travel as classes, so the reader's colour scheme picks the palette.
    #expect(html.contains(".hl-keyword { color: #d73a49; }"))
    #expect(html.contains("@media (prefers-color-scheme: dark) {\n  .hl-comment"))
    #expect(html.contains("<pre><code>plain fence"))
    #expect(html.contains("<pre><code class=\"language-definitely-not-a-language\">untouched"))
}
