// Copyright (c) 2023 Marcin Krzyzanowski. MIT License.
// Adapted from STTextView-Plugin-TreeSitter; see ThirdPartyNotices/Editor-Sources.md.
import Foundation

public actor SyntaxHighlightService {
    public typealias TokenHandler = @Sendable (HighlightUpdate) async -> Void

    private let treeSitterClient: TreeSitterClient
    private let tokenHandler: TokenHandler?
    private var cachedTokens: [SyntaxToken] = []
    private var generation = 0

    public init(treeSitterClient: TreeSitterClient, tokenHandler: TokenHandler? = nil) {
        self.treeSitterClient = treeSitterClient
        self.tokenHandler = tokenHandler
    }

    public func requestInitialHighlighting(_ content: String) async {
        do {
            try await performReset(content: content)
        } catch {
            await tokenHandler?(HighlightUpdate(
                generation: nextGeneration(),
                invalidatedRanges: [NSRange(location: 0, length: content.utf16.count)],
                tokens: []
            ))
        }
    }

    public func requestHighlighting(content: String, edit: PendingTextEdit) async {
        cachedTokens = adjustedTokenRanges(
            cachedTokens,
            editRange: edit.oldRange,
            replacementLength: edit.replacementLength
        )

        do {
            try await performHighlighting(content: content, edit: edit)
        } catch {
            try? await performReset(content: content)
        }
    }

    private func performReset(content: String) async throws {
        try Task.checkCancellation()
        let generation = nextGeneration()
        let tokens = try treeSitterClient.resetDocument(content: content).map(SyntaxToken.init)
        try Task.checkCancellation()
        cachedTokens = tokens
        await tokenHandler?(HighlightUpdate(
            generation: generation,
            invalidatedRanges: [NSRange(location: 0, length: content.utf16.count)],
            tokens: tokens
        ))
    }

    private func performHighlighting(content: String, edit: PendingTextEdit) async throws {
        let generation = nextGeneration()
        let oldTokens = cachedTokens
        let result = try treeSitterClient.didChangeDocument(content: content, edit: edit)
        let fallbackLength = max(edit.replacementLength, 1)
        let changedRanges = result.changedRanges.isEmpty
            ? [NSRange(location: edit.oldRange.location, length: fallbackLength)]
            : result.changedRanges
        let newTokens = result.tokens.map(SyntaxToken.init)

        cachedTokens.removeAll { token in
            changedRanges.contains { rangesOverlap($0, token.range) }
        }
        cachedTokens.append(contentsOf: newTokens)

        let invalidated = styleInvalidationRanges(
            changedRanges: changedRanges,
            oldTokens: oldTokens,
            newTokens: cachedTokens,
            contentLength: content.utf16.count
        )
        await tokenHandler?(HighlightUpdate(
            generation: generation,
            invalidatedRanges: invalidated,
            tokens: cachedTokens
        ))
    }

    private func adjustedTokenRanges(
        _ tokens: [SyntaxToken],
        editRange: NSRange,
        replacementLength: Int
    ) -> [SyntaxToken] {
        let delta = replacementLength - editRange.length
        let editEnd = NSMaxRange(editRange)

        return tokens.compactMap { token in
            let tokenEnd = NSMaxRange(token.range)

            if tokenEnd <= editRange.location {
                return token
            }

            if token.range.location >= editEnd {
                return SyntaxToken(
                    range: NSRange(location: token.range.location + delta, length: token.range.length),
                    name: token.name,
                    nameComponents: token.nameComponents
                )
            }

            if token.range.location <= editRange.location, tokenEnd >= editEnd {
                let newLength = token.range.length + delta
                guard newLength > 0 else { return nil }
                return SyntaxToken(
                    range: NSRange(location: token.range.location, length: newLength),
                    name: token.name,
                    nameComponents: token.nameComponents
                )
            }

            return nil
        }
    }

    private func styleInvalidationRanges(
        changedRanges: [NSRange],
        oldTokens: [SyntaxToken],
        newTokens: [SyntaxToken],
        contentLength: Int
    ) -> [NSRange] {
        let impactedOld = oldTokens.map(\.range).filter { oldRange in
            changedRanges.contains { rangesOverlap($0, oldRange) }
        }
        let impactedNew = newTokens.map(\.range).filter { newRange in
            changedRanges.contains { rangesOverlap($0, newRange) }
        }
        return normalizedRanges(changedRanges + impactedOld + impactedNew, maxLength: contentLength)
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }
}

private extension SyntaxToken {
    init(_ token: TreeSitterClient.TokenChange) {
        self.init(range: token.range, name: token.name, nameComponents: token.nameComponents)
    }
}
