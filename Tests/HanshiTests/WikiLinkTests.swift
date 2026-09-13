import AppKit
import Testing
import MarkdownEngine
@testable import Hanshi

private let wikiRoot = URL(fileURLWithPath: "/WikiLibrary", isDirectory: true)

@Test(arguments: ["Project", " Project ", "project.md", "Work/Project", "work/project.MD"])
func wikiLinkNamesAndLibraryPathsResolve(target: String) throws {
    let note = wikiRoot.appendingPathComponent("Work/Project.md")
    let index = WikiLinkIndex(notes: [note, note], root: wikiRoot)
    #expect(try index.destination(for: target) == note)
    #expect(index.resolve(displayName: target, range: NSRange(location: 0, length: 0))?.destination == note)
}

@Test func wikiLinkNamesAreUnicodeAwareAndNeverChooseAnAmbiguousNote() throws {
    let first = wikiRoot.appendingPathComponent("Personal/Café 日本語.md")
    let second = wikiRoot.appendingPathComponent("Work/Child/Café 日本語.md")
    let index = WikiLinkIndex(notes: [second, first], root: wikiRoot)
    #expect(throws: WikiLinkError.ambiguous("Café 日本語", ["Personal/Café 日本語", "Work/Child/Café 日本語"])) {
        try index.destination(for: "Café 日本語")
    }
    #expect(try index.destination(for: "work/child/Cafe\u{301} 日本語") == second)
    #expect(index.resolve(displayName: "Café 日本語", range: .init(location: 0, length: 0))?.exists == false)
    #expect(throws: WikiLinkError.missing("Missing")) { try index.destination(for: "Missing") }
}

@Test(arguments: ["", "/Work/Project", "../Work/Project", "Work/../Project", "./Work/Project",
                  "Work//Project", "https://example.com", "file:///WikiLibrary/Work/Project.md",
                  "Work\\Project", "Project|alias", "[Project]", "Project\0", "Work/Pro\nject"])
func wikiLinksRejectPathsAndSchemesOutsideTheirGrammar(target: String) {
    let index = WikiLinkIndex(notes: [wikiRoot.appendingPathComponent("Work/Project.md")], root: wikiRoot)
    #expect(throws: (any Error).self) { try index.destination(for: target) }
}

@Test func wikiLinksOnlyResolveCatalogMarkdownNotesInsideTheLibrary() {
    let urls = [URL(fileURLWithPath: "/WikiLibrary-other/Work/Outside.md"),
                wikiRoot.appendingPathComponent("Root.md"), wikiRoot.appendingPathComponent("Work/Image.png")]
    let index = WikiLinkIndex(notes: urls, root: wikiRoot)
    for name in ["Outside", "Root", "Image"] {
        #expect(throws: WikiLinkError.missing(name)) { try index.destination(for: name) }
    }
}

@Test @MainActor func wikiLinkPreviewExplainsUnresolvedLinksAndRefreshesCatalogChanges() async throws {
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    var snapshot = PreviewTestFixtures.snapshot("[[Project]] [[Missing]]\n")
    let first = snapshot.root.appendingPathComponent("Work/Project.md")
    let second = snapshot.root.appendingPathComponent("Personal/Project.md")
    snapshot.noteURLs = [first, second]
    session.show(snapshot)
    await session.waitForRendering()
    let view = session.textView
    func attribute(_ key: NSAttributedString.Key, on name: String) -> Any? {
        let range = (view.string as NSString).range(of: name)
        return view.textStorage?.attribute(key, at: range.location, effectiveRange: nil)
    }
    #expect(attribute(.link, on: "Project") == nil)
    #expect((attribute(.toolTip, on: "Project") as? String)?.contains("Ambiguous") == true)
    #expect((attribute(.toolTip, on: "Project") as? String)?.contains("Work/Project") == true)
    #expect(attribute(.link, on: "Missing") == nil)
    #expect((attribute(.toolTip, on: "Missing") as? String)?.contains("Note not found") == true)
    snapshot.noteURLs = [first]
    session.show(snapshot)
    await session.waitForRendering()
    #expect(attribute(.link, on: "Project") as? URL == first.standardizedFileURL)
    #expect(attribute(.toolTip, on: "Project") as? String == "Open Work/Project")
    snapshot.noteURLs = []
    session.show(snapshot)
    await session.waitForRendering()
    #expect(attribute(.link, on: "Project") == nil)
    #expect((attribute(.toolTip, on: "Project") as? String)?.contains("Note not found") == true)
    #expect(view.string == snapshot.text)
}

@Test @MainActor func wikiLinkPreviewEditsKeepPlainMarkdownAndIgnoreCodeAndEscapes() async throws {
    let source = "[[Project]]\n\n`[[Project]]`\n\n```\n[[Project]]\n```\n\n\\[[Project]]\n"
    let document = PreviewTestFixtures.document(source)
    let session = MarkdownPreviewSession(debounce: .zero)
    defer { session.hide() }
    var snapshot = PreviewTestFixtures.snapshot(source)
    snapshot = PreviewSnapshot(library: snapshot.library, documentID: document.id, text: source,
                               url: document.url, root: document.url.deletingLastPathComponent())
    snapshot.noteURLs = [snapshot.root.appendingPathComponent("Work/Project.md")]
    session.show(snapshot, document: document)
    await session.waitForRendering()
    let view = session.textView
    let storage = try #require(view.textStorage)
    var links = 0
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if value != nil { links += 1 }
    }
    #expect(links == 1, "Code and escaped brackets must remain literal")
    #expect(storage.attribute(.wikiLinkID, at: 3, effectiveRange: nil) == nil)
    view.insertText("More text", replacementRange: NSRange(location: storage.length, length: 0))
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    await session.waitForRendering()
    #expect(document.text == source + "More text")
    #expect(!document.text.contains("|"), "Navigating and editing must not insert engine identifiers")
}
