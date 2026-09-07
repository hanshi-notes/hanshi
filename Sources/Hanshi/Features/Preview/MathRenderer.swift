import Foundation
import SwaTex
import SwaTexRender

nonisolated enum MathRenderer {
    static func render(_ latex: String, display: Bool, scale: Double) throws -> PreviewBitmap {
        guard latex.utf8.count <= 4096 else { throw PreviewFailure.message("Formula exceeds 4 KB") }
        var depth = 0
        for character in latex {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            guard depth <= 64 else { throw PreviewFailure.message("Formula nesting exceeds 64 levels") }
        }
        let list = try SwaTexEngine.displayList(for: latex, style: display ? .display : .text)
        let options = RenderOptions(fontSize: display ? 20 : 16, padding: 2)
        let metrics = DisplayListRenderer.metrics(for: list, options: options)
        guard metrics.width.isFinite, metrics.height.isFinite, metrics.width * scale <= 4096,
              metrics.height * scale <= 4096, metrics.width * metrics.height * scale * scale <= 8_000_000,
              let data = ImageRenderer.png(for: list, options: options, displayScale: scale) else {
            throw PreviewFailure.message("Formula is too large to display")
        }
        return PreviewBitmap(data: data, width: metrics.width, height: metrics.height, baseline: metrics.baseline)
    }
}
