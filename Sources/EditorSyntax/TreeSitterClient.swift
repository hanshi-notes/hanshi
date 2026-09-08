// Copyright (c) 2023 Marcin Krzyzanowski. MIT License.
// Adapted from STTextView-Plugin-TreeSitter; see ThirdPartyNotices/Editor-Sources.md.
import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer

public final class TreeSitterClient {
    private let languageConfiguration: LanguageConfiguration
    private let layerTree: LanguageLayer

    public struct TokenChange: Sendable, Hashable {
        public let name: String
        public let nameComponents: [String]
        public let range: NSRange

        public init(name: String, nameComponents: [String], range: NSRange) {
            self.name = name
            self.nameComponents = nameComponents
            self.range = range
        }
    }

    public init(
        languageConfiguration: LanguageConfiguration,
        languageProvider: @escaping (String) -> LanguageConfiguration?
    ) throws {
        self.languageConfiguration = languageConfiguration
        self.layerTree = try LanguageLayer(
            languageConfig: languageConfiguration,
            configuration: .init(languageProvider: languageProvider)
        )
    }

    @discardableResult
    public func resetDocument(content source: String) throws -> [TokenChange] {
        let points = TreeSitterLineIndex(source)
        let change = layerTree.replaceContent(with: source) { offset in
            points.point(at: offset)
        }
        return try tokenChanges(in: change, source: source)
    }

    public func didChangeDocument(
        content source: String,
        edit: PendingTextEdit
    ) throws -> (tokens: [TokenChange], changedRanges: [NSRange]) {
        let newEndOffset = edit.oldRange.location + edit.replacementLength
        guard edit.oldRange.location >= 0,
              edit.oldRange.upperBound >= edit.oldRange.location,
              newEndOffset >= edit.oldRange.location,
              newEndOffset <= source.utf16.count else {
            let tokens = try resetDocument(content: source)
            return (tokens, [NSRange(location: 0, length: source.utf16.count)])
        }

        let points = TreeSitterLineIndex(source)
        let inputEdit = InputEdit(
            range: edit.oldRange,
            delta: edit.replacementLength - edit.oldRange.length,
            oldEndPoint: edit.oldEndPoint,
            transformer: { points.point(at: $0) }
        )

        let content = LanguageLayer.Content(string: source)
        let change = layerTree.didChangeContent(content, using: inputEdit, resolveSublayers: true)
        let changedRanges = highlightInvalidationRanges(for: change, edit: edit, source: source)
        let querySet = querySet(for: changedRanges)
        let tokenChanges = try tokenChanges(in: querySet, source: source)
        return (tokenChanges, changedRanges)
    }

    private func highlightInvalidationRanges(
        for change: IndexSet,
        edit: PendingTextEdit,
        source: String
    ) -> [NSRange] {
        let changedRanges = change.rangeView.map { NSRange($0) }
        let editRange = NSRange(location: edit.oldRange.location, length: max(edit.replacementLength, 1))
        let lineRanges = changedRanges + [editRange]
        return normalizedRanges(lineRanges.map { lineRange(for: $0, in: source) }, maxLength: source.utf16.count)
    }

    private func querySet(for ranges: [NSRange]) -> IndexSet {
        var set = IndexSet()
        for range in ranges where range.length > 0 {
            set.insert(integersIn: range.location..<NSMaxRange(range))
        }
        return set
    }

    private func tokenChanges(in change: IndexSet, source: String) throws -> [TokenChange] {
        let content = LanguageLayer.Content(string: source)
        let tokens = try layerTree.highlights(in: change, provider: content.textProvider)
        return tokens.map { token in
            TokenChange(name: token.name, nameComponents: token.nameComponents, range: token.range)
        }
    }
}
