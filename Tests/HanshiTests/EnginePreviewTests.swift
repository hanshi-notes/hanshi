import AppKit
import HighlightKit
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

/// The engine restyles the whole note whenever the resources' fingerprint changes, so a preview
/// update whose attachments and highlighting came out the same must keep it; a new drawing must not.
@Test @MainActor func previewResourcesKeepTheirFingerprintUntilTheirContentChanges() throws {
    func recipe(_ pixels: UInt8, code: String = "let a = 1\n") -> MarkdownRecipe {
        MarkdownRecipe(anchors: [],
                       media: [PreviewMedia(kind: .math("x", display: false),
                                            // A shared header, as encoded images have: only the last byte differs.
                                            bitmap: PreviewBitmap(data: Data(repeating: 1, count: 200) + [pixels], width: 4, height: 4, baseline: 1))],
                       code: [code: [HighlightToken(range: NSRange(location: 0, length: 3), scopes: ["keyword"])]])
    }
    // Rendered twice, as every update does: equal content, distinct values.
    #expect(EnginePreviewResources(recipe: recipe(7)).fingerprint() == EnginePreviewResources(recipe: recipe(7)).fingerprint())
    #expect(EnginePreviewResources(recipe: recipe(7)).fingerprint() != EnginePreviewResources(recipe: recipe(8)).fingerprint())
    #expect(EnginePreviewResources(recipe: recipe(7)).fingerprint() != EnginePreviewResources(recipe: recipe(7, code: "let b = 2\n")).fingerprint())
}
