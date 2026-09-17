import AppKit
import Testing
import ImageIO
@testable import Hanshi

nonisolated struct PreviewResourceFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hanshi-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func png(width: Int = 20, height: Int = 10) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@Test func previewResourcesCanonicalizeBothSidesAndDecode() throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    let data = try fixture.png()
    let image = fixture.root.appendingPathComponent("my image.png")
    try data.write(to: image)
    let base = fixture.root.appendingPathComponent("Note.md")
    #expect(try PreviewResources.image("my%20image.png", base: base, root: fixture.root).width == 20)
    let alias = fixture.root.appendingPathComponent("alias.png")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: image)
    #expect(try PreviewResources.read(alias, root: fixture.root) == data)
    let rootAlias = fixture.root.appendingPathComponent("root-alias")
    try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixture.root)
    #expect(try PreviewResources.image("my%20image.png", base: rootAlias.appendingPathComponent("Note.md"), root: rootAlias).height == 10)
    let bitmap = try PreviewResources.decode(fixture.png(width: 3000, height: 100))
    #expect(bitmap.width <= 2048 && bitmap.height > 0)
}

@Test(arguments: ["javascript:alert(1)", "data:image/png;base64,AAAA", "ftp://example.com/file", "file://server/file.png", "//server/file.png", "../../outside.png", "file:///etc/passwd", "bad%00path"])
func previewResourcesBlockUnsafeDestinations(target: String) throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    #expect(throws: PreviewFailure.self) { try PreviewResources.destination(target, base: fixture.root.appendingPathComponent("Note.md"), root: fixture.root) }
}

@Test func previewResourcesRejectEscapingSymlinksSimilarPrefixesAndSpecialFiles() throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    let sibling = URL(filePath: fixture.root.path + "-sibling")
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sibling) }
    let secret = sibling.appendingPathComponent("secret.png")
    try fixture.png().write(to: secret)
    let link = fixture.root.appendingPathComponent("escape.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
    #expect(throws: PreviewFailure.self) { try PreviewResources.read(link, root: fixture.root) }
    #expect(throws: PreviewFailure.self) { try PreviewResources.read(secret, root: fixture.root) }
    let folder = fixture.root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: PreviewFailure.self) { try PreviewResources.read(folder, root: fixture.root) }
    let fifo = fixture.root.appendingPathComponent("pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: PreviewFailure.self) { try PreviewResources.read(fifo, root: fixture.root) }
    #expect(throws: PreviewFailure.self) { try PreviewResources.decode(Data("corrupt image".utf8)) }
    #expect(throws: PreviewFailure.self) { try PreviewResources.decode(Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/>".utf8)) }
    let large = fixture.root.appendingPathComponent("large.png")
    FileManager.default.createFile(atPath: large.path, contents: nil)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(PreviewResources.byteLimit + 1)); try handle.close()
    #expect(throws: PreviewFailure.self) { try PreviewResources.read(large, root: fixture.root) }
}

@Test @MainActor func previewImageFallbackKeepsAltTextAndLaterAnchors() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    let source = "![local][logo]\n\n![remote](https://example.com/image.png)\n\n# After\n\n[logo]: missing.png"
    let session = MarkdownPreviewSession(debounce: .zero)
    session.show(PreviewTestFixtures.snapshot(source, root: fixture.root)); await session.waitForRendering()
    defer { session.hide() }
    #expect(session.recipe?.diagnostics.count == 2)
    #expect(previewImages(in: session.textView).isEmpty)
    #expect(session.textView.string.contains("https://example.com/image.png"))
    #expect(session.message?.contains("Remote images are not downloaded") == true)
    let heading = try #require(session.composition?.anchors.first { $0.heading == "after" })
    #expect((session.textView.string as NSString).substring(with: heading.rendered).contains("After"))
}

@Test @MainActor func previewBoundsTotalAttachmentWork() async throws {
    let fixture = try PreviewResourceFixture(); defer { fixture.remove() }
    try fixture.png().write(to: fixture.root.appendingPathComponent("image.png"))
    let source = String(repeating: "![small](image.png)\n\n", count: 260)
    let recipe = try await MarkdownRenderer.render(PreviewTestFixtures.snapshot(source, root: fixture.root))
    #expect(recipe.media.compactMap(\.bitmap).count <= 256)
    #expect(!recipe.diagnostics.isEmpty)
}
