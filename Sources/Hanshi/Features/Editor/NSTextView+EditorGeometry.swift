//
//  NSTextView+CurrentLineHighlighting.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2018-08-18.
//
//  ---------------------------------------------------------------------------
//
//  © 2018-2025 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

// Modified for Hanshi: reduced to horizontal TextKit 1 editing; no CotEditor modules.

import AppKit

extension NSTextView {
    func textFrame(at offset: Int, length: Int = 1) -> NSRect? {
        guard let manager = layoutManager, let container = textContainer,
              let storage = textStorage, offset >= 0, offset <= storage.length else { return nil }
        if offset == storage.length {
            manager.ensureLayout(for: container)
            if manager.extraLineFragmentTextContainer != nil {
                return manager.extraLineFragmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            }
        }
        guard storage.length > 0 else { return nil }
        let start = min(offset, storage.length - 1)
        let range = NSRange(location: start, length: min(max(1, length), storage.length - start))
        manager.ensureLayout(forCharacterRange: range)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func currentLineRect() -> NSRect? {
        guard let manager = layoutManager, let storage = textStorage else { return nil }
        let range = (storage.string as NSString).lineRange(for: selectedRange())
        guard let first = textFrame(at: range.location) else { return nil }
        let last = textFrame(at: max(range.location, range.upperBound - 1)) ?? first
        var rect = first.union(last)
        rect.origin.x = textContainerOrigin.x
        rect.size.width = max(0, bounds.width - textContainerOrigin.x * 2)
        if rect.height == 0 { rect.size.height = manager.defaultLineHeight(for: font ?? .systemFont(ofSize: 14)) }
        return rect
    }

    func firstVisibleCharacter() -> Int? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let point = NSPoint(x: container.lineFragmentPadding,
                            y: max(0, visibleRect.minY - textContainerOrigin.y + 1))
        return manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
    }
}
