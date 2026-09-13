import AppKit
import Testing
@testable import Hanshi

extension AppKitWindowTests {
    @Test(arguments: [0.0, 300.0]) @MainActor
    func sourceGutterDrawsTheScrollPreparationArea(scrollOffset: Double) throws {
        let document = PreviewTestFixtures.document((1...80).map {
            "\($0). [ ] [Most important outcome]"
        }.joined(separator: "\n"))
        let session = document.editor
        session.setGutter(true)
        session.setFont(size: 14)
        let editor = session.textView
        editor.backgroundColor = .black
        editor.textColor = .white
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.scrollView
        defer { window.contentView = nil; window.close() }
        window.layoutIfNeeded()
        let ruler = try #require(editor.gutterView)
        let manager = try #require(editor.layoutManager)
        manager.ensureLayout(for: try #require(editor.textContainer))

        session.scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollOffset))
        session.scrollView.reflectScrolledClipView(session.scrollView.contentView)

        // AppKit also requests hash marks beyond the viewport while preparing scrolling.
        let drawingRect = ruler.bounds.insetBy(dx: 0, dy: -200)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(drawingRect.width)), pixelsHigh: Int(ceil(drawingRect.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh) + drawingRect.minY)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSColor.white.setFill()
        drawingRect.fill()
        ruler.drawHashMarksAndLabels(in: drawingRect)
        NSGraphicsContext.restoreGraphicsState()

        let attributes: [NSAttributedString.Key: Any] = [.font: ruler.font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        for (index, start) in ruler.lineStarts.enumerated() {
            let frame = try #require(editor.textFrame(at: start))
            let glyph = manager.glyphIndexForCharacter(at: start)
            let y = ruler.convert(frame.origin, from: editor).y + manager.location(forGlyphAt: glyph).y
                - manager.defaultBaselineOffset(for: ruler.font) - drawingRect.minY
            let height = ("\(index + 1)" as NSString).size(withAttributes: attributes).height
            guard y >= 0, y + height < CGFloat(bitmap.pixelsHigh) else { continue }
            #expect(bitmap.colorAt(x: 2, y: Int(y))?.brightnessComponent == 0,
                "Line \(index + 1) must retain the editor background beyond the initial viewport")
            let ink = (Int(y)..<Int(y + height)).contains { row in
                (4..<(bitmap.pixelsWide - 4)).contains { column in
                    let brightness = bitmap.colorAt(x: column, y: row)!.brightnessComponent
                    return brightness > 0.05 && brightness < 0.9
                }
            }
            #expect(ink, "Line \(index + 1) must be drawn in the scroll preparation area")
        }
    }
}
