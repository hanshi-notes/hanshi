import AppKit
import SwiftUI
import Testing
@testable import Hanshi

@Test @MainActor func barIconsKeepEachSymbolsOwnOpticalSize() throws {
    _ = NSApplication.shared
    let symbols = ["square.and.arrow.down", "highlighter", "tag.fill", "paperclip", "star", "pin.fill",
                   "trash.fill", "square.and.arrow.up", "arrow.up.forward.square", "plus",
                   "magnifyingglass", "doc.text.fill", "list.bullet.rectangle.fill"]
    var largestSides: [Double] = []
    for symbol in symbols {
        let button = BarIconView(symbol)
            .foregroundStyle(BarMetrics.iconColor)
            .frame(width: BarMetrics.buttonWidth, height: BarMetrics.controlHeight)
            .background(.white)
        let rendering = try render(button)
        let ink = try #require(rendering.ink(in: 0..<BarMetrics.buttonWidth), "\(symbol) drew nothing")
        #expect(rendering.size == CGSize(width: 34.5, height: 24))
        #expect(ink.width <= 18, "\(symbol) is \(ink.width) pt wide")
        #expect(ink.height <= 18, "\(symbol) is \(ink.height) pt tall")
        #expect(ink.height >= 10.5, "\(symbol) is \(ink.height) pt tall")
        #expect(abs(ink.midX - 34.5 / 2) <= 1, "\(symbol) is off-centre: \(ink)")
        #expect(abs(ink.midY - 24 / 2) <= 1.5, "\(symbol) is off-centre: \(ink)")
        // Black, like Notable's rgb(31, 31, 31), instead of a lighter grey.
        #expect(rendering.darkest(in: 0..<34.5) <= 8, "\(symbol) is drawn too light")
        if symbol == "plus" {
            // Notable's plus measures 10.5 × 10 pt.
            #expect(ink.width <= 12.5, "the new-note plus is \(ink.width) pt wide")
        }
        largestSides.append(max(ink.width, ink.height))
    }
    // Fitting every symbol to the same square would erase this size variation.
    let largest = try #require(largestSides.max())
    let smallest = try #require(largestSides.min())
    #expect(largest - smallest >= 2, "every symbol was drawn to the same size: \(largestSides)")
}

@Test @MainActor func barIconsAreDrawnWithASemiboldStroke() throws {
    _ = NSApplication.shared
    for symbol in ["magnifyingglass", "star", "paperclip", "plus"] {
        let regular = Image(systemName: symbol).font(.system(size: BarMetrics.iconSize))
            .foregroundStyle(BarMetrics.iconColor)
            .frame(width: BarMetrics.buttonWidth, height: BarMetrics.controlHeight)
            .background(.white)
        let bar = BarIconView(symbol)
            .foregroundStyle(BarMetrics.iconColor)
            .frame(width: BarMetrics.buttonWidth, height: BarMetrics.controlHeight)
            .background(.white)
        let heavy = try render(bar).inked(in: 0..<BarMetrics.buttonWidth)
        let light = try render(regular).inked(in: 0..<BarMetrics.buttonWidth)
        #expect(Double(heavy) >= Double(light) * 1.1,
                "\(symbol) drew \(heavy) dark pixels, the regular weight drew \(light)")
    }
}

@Test @MainActor func barButtonsKeepTheirIconAtFullStrengthWhileAFeatureIsPending() throws {
    _ = NSApplication.shared
    for action: (() -> Void)? in [nil, {}] {
        let button = BarButton(title: "Tags", icon: "tag.fill", action: action).background(.white)
        let rendering = try render(button)
        #expect(rendering.size == CGSize(width: 34.5, height: 24))
        // A disabled button would draw the icon at half opacity: black over white becomes rgb(128).
        #expect(rendering.darkest(in: 0..<34.5) <= 8,
                "the icon is dimmed when the action is \(action == nil ? "missing" : "there")")
    }
}

@Test @MainActor func barControlsShareOneHeightAndAreCentredInTheBar() throws {
    _ = NSApplication.shared
    let width = 250.0
    let bar = HStack(spacing: BarMetrics.margin) {
        Color.clear.frame(maxWidth: .infinity).barControl(cornerRadius: 5)
        BarIconView("plus").frame(width: BarMetrics.buttonWidth).barControl()
    }
    .padding(.horizontal, BarMetrics.margin)
    .frame(width: width, height: BarMetrics.height)
    .background(Color(white: 0.97))
    let rendering = try render(bar)
    #expect(rendering.size == CGSize(width: width, height: 38))
    let field = try #require(rendering.ink(in: 30..<50), "the search field drew nothing")
    let button = try #require(rendering.ink(in: (width - 25)..<(width - 15)), "the button drew nothing")
    for (name, control) in [("field", field), ("button", button)] {
        #expect(abs(control.height - 24) <= 0.25, "the \(name) is \(control.height) pt tall")
        #expect(abs(control.minY - 7) <= 0.5, "the \(name) starts at \(control.minY)")
    }
    #expect(abs(field.minY - button.minY) <= 0.5, "field and button tops differ: \(field.minY) vs \(button.minY)")
    #expect(abs(field.maxY - button.maxY) <= 0.5, "field and button bottoms differ: \(field.maxY) vs \(button.maxY)")
}

private struct Rendering {
    let size: CGSize
    private let scale = 2
    private let bitmap: NSBitmapImageRep

    @MainActor init<V: View>(_ view: V) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = CGFloat(scale)
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        bitmap = try #require(NSBitmapImageRep(data: tiff))
        size = CGSize(width: Double(bitmap.pixelsWide) / Double(scale),
                      height: Double(bitmap.pixelsHigh) / Double(scale))
    }

    /// Bounds in points of pixels differing from the slice's top-left background colour.
    func ink(in points: Range<Double>) -> CGRect? {
        let columns = Int(points.lowerBound) * scale..<min(Int(points.upperBound) * scale, bitmap.pixelsWide)
        let rows = 0..<bitmap.pixelsHigh
        guard let first = columns.first else { return nil }
        let background = luminance(first, 0)
        var box: CGRect?
        for x in columns {
            for y in rows where abs(luminance(x, y) - background) > 4 {
                let pixel = CGRect(x: Double(x) / Double(scale), y: Double(y) / Double(scale),
                                   width: 1 / Double(scale), height: 1 / Double(scale))
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }

    /// Number of pixels in a horizontal slice drawn darker than mid-grey.
    func inked(in points: Range<Double>) -> Int {
        let columns = Int(points.lowerBound) * scale..<min(Int(points.upperBound) * scale, bitmap.pixelsWide)
        return columns.flatMap { x in (0..<bitmap.pixelsHigh).map { luminance(x, $0) } }.filter { $0 < 128 }.count
    }

    /// Luminance of the darkest pixel in a horizontal slice, 0 for black and 255 for white.
    func darkest(in points: Range<Double>) -> Int {
        let columns = Int(points.lowerBound) * scale..<min(Int(points.upperBound) * scale, bitmap.pixelsWide)
        return columns.flatMap { x in (0..<bitmap.pixelsHigh).map { luminance(x, $0) } }.min() ?? 255
    }

    private func luminance(_ x: Int, _ y: Int) -> Int {
        guard let colour = bitmap.colorAt(x: x, y: y) else { return 0 }
        return Int((colour.redComponent * 0.3 + colour.greenComponent * 0.59 + colour.blueComponent * 0.11) * 255)
    }
}

@MainActor private func render<V: View>(_ view: V) throws -> Rendering { try Rendering(view) }
