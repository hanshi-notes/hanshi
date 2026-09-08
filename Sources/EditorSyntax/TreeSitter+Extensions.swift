// Copyright (c) 2023 Marcin Krzyzanowski. MIT License.
// Adapted from STTextView-Plugin-TreeSitter; see ThirdPartyNotices/Editor-Sources.md.
import Foundation
import SwiftTreeSitter

extension InputEdit {
    init(range: NSRange, delta: Int, oldEndPoint: Point, transformer: (Int) -> Point?) {
        let startLocation = range.location
        let newEndLocation = range.upperBound + delta

        precondition(startLocation >= 0, "Invalid edit start")
        precondition(newEndLocation >= 0, "Invalid edit end")

        self.init(
            startByte: UInt32(range.location * 2),
            oldEndByte: UInt32(range.upperBound * 2),
            newEndByte: UInt32(newEndLocation * 2),
            startPoint: transformer(startLocation) ?? .zero,
            oldEndPoint: oldEndPoint,
            newEndPoint: transformer(newEndLocation) ?? .zero
        )
    }
}
