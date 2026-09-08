// Copyright (c) 2023 Marcin Krzyzanowski. MIT License.
// Adapted from STTextView-Plugin-TreeSitter; see ThirdPartyNotices/Editor-Sources.md.
import Foundation
import SwiftTreeSitter

public struct SyntaxToken: Sendable, Hashable {
    public let range: NSRange
    public let name: String
    public let nameComponents: [String]

    public init(range: NSRange, name: String, nameComponents: [String]) {
        self.range = range
        self.name = name
        self.nameComponents = nameComponents
    }
}

public struct PendingTextEdit: Sendable {
    public let oldText: String
    public let oldRange: NSRange
    public let replacementLength: Int
    public let newLength: Int
    public let oldEndPoint: Point

    public init(oldText: String, oldRange: NSRange, replacementText: String) {
        self.oldText = oldText
        self.oldRange = oldRange
        self.replacementLength = replacementText.utf16.count
        self.newLength = oldText.utf16.count - oldRange.length + replacementLength
        self.oldEndPoint = TreeSitterTextPoint.point(in: oldText, utf16Offset: oldRange.upperBound)
    }
}

public struct HighlightUpdate: Sendable {
    public let generation: Int
    public let invalidatedRanges: [NSRange]
    public let tokens: [SyntaxToken]

    public init(generation: Int, invalidatedRanges: [NSRange], tokens: [SyntaxToken]) {
        self.generation = generation
        self.invalidatedRanges = invalidatedRanges
        self.tokens = tokens
    }
}

public enum TreeSitterTextPoint {
    public static func point(in text: String, utf16Offset targetOffset: Int) -> Point {
        var row = 0
        var columnBytes = 0
        var offset = 0

        for scalar in text.unicodeScalars {
            if offset >= targetOffset { break }
            let length = scalar.utf16.count
            if scalar == "\n" {
                row += 1
                columnBytes = 0
            } else {
                columnBytes += length * 2
            }
            offset += length
        }

        return Point(row: UInt32(row), column: UInt32(columnBytes))
    }
}

public func rangesOverlap(_ a: NSRange, _ b: NSRange) -> Bool {
    NSIntersectionRange(a, b).length > 0
}

public func normalizedRanges(_ ranges: [NSRange], maxLength: Int) -> [NSRange] {
    let bounds = NSRange(location: 0, length: maxLength)
    var set = IndexSet()

    for range in ranges {
        let clipped = NSIntersectionRange(range, bounds)
        if clipped.length > 0 {
            set.insert(integersIn: clipped.location..<NSMaxRange(clipped))
        }
    }

    return set.rangeView.map(NSRange.init)
}

public func lineRange(for range: NSRange, in source: String) -> NSRange {
    let sourceLength = source.utf16.count
    guard sourceLength > 0 else { return NSRange(location: 0, length: 0) }

    let start = max(0, min(range.location, sourceLength))
    let end = max(start, min(NSMaxRange(range), sourceLength))
    guard let stringRange = Range(NSRange(location: start, length: end - start), in: source) else {
        return NSRange(location: start, length: 0)
    }

    return NSRange(source.lineRange(for: stringRange), in: source)
}

/// UTF-16 line starts shared by every position conversion in one parse operation.
public struct TreeSitterLineIndex: Sendable {
    private let starts: [Int]
    public init(_ text: String) {
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
        self.starts = starts
    }
    public func point(at offset: Int) -> Point {
        var lower = 0, upper = starts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if starts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        let row = max(0, lower - 1)
        return Point(row: UInt32(row), column: UInt32(max(0, offset - starts[row]) * 2))
    }
}
