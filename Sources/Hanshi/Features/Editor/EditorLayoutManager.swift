//
//  LayoutManager.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by nakamuxu on 2005-01-10.
//
//  ---------------------------------------------------------------------------
//
//  © 2004-2007 nakamuxu
//  © 2014-2026 1024jp
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

nonisolated final class EditorLayoutManager: NSLayoutManager {
    var showsInvisibles = false {
        didSet { invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0)) }
    }
    var invisiblesColor = NSColor.disabledControlTextColor

    static func invisibleSymbol(for character: unichar) -> String? {
        switch character {
        case 0x20: "·"
        case 0x09: "→"
        case 0x0A, 0x0D, 0x2028, 0x2029: "¶"
        case 0xA0: "⍽"
        default: nil
        }
    }
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if showsInvisibles, let storage = textStorage {
            let text = storage.string as NSString
            for glyph in glyphsToShow.location..<glyphsToShow.upperBound {
                let character = characterIndexForGlyph(at: glyph)
                guard character < text.length,
                      let symbol = Self.invisibleSymbol(for: text.character(at: character)) else { continue }
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
                let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let location = location(forGlyphAt: glyph)
                (symbol as NSString).draw(at: NSPoint(x: origin.x + line.minX + location.x,
                    y: origin.y + line.minY + location.y - font.ascender),
                    withAttributes: [.font: font, .foregroundColor: invisiblesColor])
            }
        }
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }
}
