import Foundation
import Testing
import EditorSyntax
import SwiftTreeSitter
@testable import Hanshi

@Test func syntaxLineIndexPreservesUTF16ByteColumnsAcrossUnicodeAndCRLF() {
    let source = "😀e\u{301}\r\n漢字\n\nEnd"
    let index = TreeSitterLineIndex(source)
    for offset in (0...source.utf16.count).filter({ $0 != 1 }) {
        #expect(index.point(at: offset) == TreeSitterTextPoint.point(in: source, utf16Offset: offset))
    }
    #expect(index.point(at: 6) == Point(row: 1, column: 0))
    #expect(index.point(at: 8) == Point(row: 1, column: 4))
    #expect(TreeSitterLineIndex("").point(at: 0) == .zero)
}

@Test func syntaxReadsThroughASurrogatePairAtTheParserChunkBoundary() throws {
    let source = String(repeating: "a", count: 1023) + "😀\n\n# Last heading\n"
    let configuration = try #require(SyntaxResources.configuration(for: .markdown))
    let client = try TreeSitterClient(languageConfiguration: configuration,
                                    languageProvider: SyntaxResources.languageProvider(named:))
    let tokens = try client.resetDocument(content: source)
    let last = (source as NSString).range(of: "Last heading")
    #expect(tokens.contains { $0.name.hasPrefix("text.title") && NSIntersectionRange($0.range, last).length == last.length })
}

@Test func everyPackagedGrammarLoadsAndMarkdownQueriesExposeItsPaletteRoles() throws {
    for language in TreeSitterLanguage.allCases {
        #expect(SyntaxResources.configuration(for: language) != nil, "Queries for \(language.name)")
    }
    #expect(TreeSitterLanguage.injectedLanguage(named: "unknown-language") == nil)
    let client = try TreeSitterClient(languageConfiguration: #require(SyntaxResources.configuration(for: .markdown)),
                                    languageProvider: SyntaxResources.languageProvider(named:))
    let source = "# One\n\n## Two\n\n- Bullet\n\n1. Numbered\n\n> Quote\n\n---\n\n<https://example.com>\n\n<test@example.com>\n\n![Alt](image.png)\n"
    let names = Set(try client.resetDocument(content: source).map(\.name))
    for name in ["text.title.1", "text.title.2", "text.list.bullet", "text.list.number", "text.quote", "text.hrule", "text.uri.autolink", "text.uri.email", "text.image"] {
        #expect(names.contains(name), "Capture for \(name)")
    }
}
