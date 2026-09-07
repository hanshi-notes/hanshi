import Foundation
import CMermaid
import ImageIO

nonisolated enum MermaidRenderer {
    static func render(_ source: String, scale: Double) throws -> PreviewBitmap {
        let bytes = Array(source.utf8)
        guard !bytes.isEmpty else { throw PreviewFailure.message("Empty Mermaid diagram") }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = bytes.withUnsafeBufferPointer {
            hanshi_mermaid_render($0.baseAddress, $0.count, Float(scale), &output, &length)
        }
        defer { if let output { hanshi_mermaid_free(output, length) } }
        guard let output else { throw PreviewFailure.message("Mermaid renderer returned no output") }
        let data = Data(bytes: output, count: length)
        guard status == 0 else { throw PreviewFailure.message(String(decoding: data, as: UTF8.self)) }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else {
            throw PreviewFailure.message("Mermaid produced an invalid image")
        }
        return PreviewBitmap(data: data, width: width / scale, height: height / scale, baseline: 0)
    }
}
