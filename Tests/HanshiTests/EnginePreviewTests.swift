import AppKit
import MarkdownEngine
import Testing
@testable import Hanshi

@Test @MainActor func enginePreviewRendersLocalImagesFormulasAndDiagramsWithoutChangingDraft() async throws {
    let fixture = try PreviewResourceFixture()
    defer { fixture.remove() }
    try fixture.png().write(to: fixture.root.appendingPathComponent("image.png"))
    let document = PreviewTestFixtures.document("Saved", root: fixture.root)
    document.edit("# Draft\n\n![image](image.png)\n\n$x^2$\n\n```mermaid\ngraph TD\nA --> B\n```\n")
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    session.show(PreviewTestFixtures.snapshot(document.text, root: fixture.root))
    await session.waitForRendering()
    #expect(session.textView.textLayoutManager != nil)
    #expect(!session.textView.isEditable)
    #expect(previewImages(in: session.textView).count == 3)
    #expect(session.message == nil)
    #expect(document.saved.text == "Saved")
    #expect(document.isModified)
    #expect(session.textView.string == document.text)
}

@Test @MainActor func enginePreviewKeepsFailedMediaReadableAndMapsHeadingsAfterWikiLinks() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    let source = "[[Note|opaque-id]] 👩🏽‍💻\n\n# Heading\n\n![missing](missing.png)\n\n```mermaid\ninvalid diagram\n```"
    session.show(PreviewTestFixtures.snapshot(source))
    await session.waitForRendering()
    #expect(session.message != nil)
    #expect(session.textView.string.contains("missing.png"))
    #expect(session.textView.string.contains("invalid diagram"))
    let heading = try #require(session.composition?.anchors.first { $0.heading == "heading" })
    #expect(heading.source.location == (source as NSString).range(of: "# Heading").location)
    #expect(heading.rendered.location == (session.textView.string as NSString).range(of: "# Heading").location)
    #expect(session.composition?.anchors.allSatisfy { NSMaxRange($0.rendered) <= session.textView.string.utf16.count } == true)
}
