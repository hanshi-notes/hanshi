//
//  LineNumberView.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by nakamuxu on 2005-03-30.
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

final class LineNumberView: NSRulerView {
    var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) {
        didSet { updateThickness(); needsDisplay = true }
    }
    private(set) var lineStarts = [0]

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        // Scrolling blits the ruler over its own visible rect, and since macOS 14 that rect
        // is unclipped: without this the gutter smears line numbers over the toolbar above.
        clipsToBounds = true
        setAccessibilityLabel("Line numbers")
        invalidateLineNumbers()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    func invalidateLineNumbers() {
        guard let text = (clientView as? NSTextView)?.textStorage?.string as NSString? else { return }
        lineStarts = [0]
        var offset = 0
        // ponytail: rebuild the line index on edits; update the affected suffix if larger notes need it.
        while offset < text.length {
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            lineStarts.append(offset)
        }
        if text.length > 0, text.lineRange(for: NSRange(location: text.length, length: 0)).length > 0 {
            lineStarts.removeLast()
        }
        updateThickness()
        needsDisplay = true
    }
    private func updateThickness() {
        let width = (String(repeating: "8", count: max(3, String(lineStarts.count).count)) as NSString)
            .size(withAttributes: [.font: font]).width + 16
        if ruleThickness != width { ruleThickness = width }
    }
    func lineNumber(at offset: Int) -> Int {
        var lower = 0, upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= offset { lower = middle + 1 } else { upper = middle }
        }
        return max(1, lower)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let text = clientView as? NSTextView, let manager = text.layoutManager,
              let container = text.textContainer else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // AppKit prepares hash marks beyond the viewport for scrolling. Clip to its
        // requested drawing area; clipsToBounds keeps the displayed ruler in its column.
        rect.clip()
        text.backgroundColor.setFill()
        rect.fill()
        let top = text.convert(NSPoint(x: 0, y: rect.minY), from: self).y - text.textContainerOrigin.y
        let first = manager.characterIndex(for: NSPoint(x: container.lineFragmentPadding, y: max(0, top)),
            in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
            .foregroundColor: (text.textColor ?? .textColor).withAlphaComponent(0.6)]
        for index in (lineNumber(at: first) - 1)..<lineStarts.count {
            guard let frame = text.textFrame(at: lineStarts[index]) else { continue }
            // Match the glyph baseline, including blank lines and expanded line spacing.
            let baseline: CGFloat
            if lineStarts[index] == text.textStorage?.length {
                baseline = manager.defaultBaselineOffset(for: text.font ?? .systemFont(ofSize: 14))
            } else {
                let glyph = manager.glyphIndexForCharacter(at: lineStarts[index])
                baseline = manager.location(forGlyphAt: glyph).y
            }
            let point = convert(frame.origin, from: text)
            if point.y > rect.maxY { break }
            let label = String(index + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8,
                                   y: point.y + baseline - manager.defaultBaselineOffset(for: font)), withAttributes: attributes)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard let text = clientView as? NSTextView, let manager = text.layoutManager,
              let container = text.textContainer else { return }
        let point = text.convert(event.locationInWindow, from: nil)
        let offset = manager.characterIndex(for: NSPoint(x: container.lineFragmentPadding,
            y: max(0, point.y - text.textContainerOrigin.y)), in: container,
            fractionOfDistanceBetweenInsertionPoints: nil)
        let range = (text.string as NSString).lineRange(for: NSRange(location: min(offset, text.string.utf16.count), length: 0))
        window?.makeFirstResponder(text)
        text.setSelectedRange(range)
    }
}
