import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PreviewFailure: Error, LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

nonisolated enum PreviewDestination: Equatable, Sendable {
    case heading(String)
    case external(URL)
    case local(URL, fragment: String?)
}

nonisolated enum PreviewResources {
    static let byteLimit = 20 * 1024 * 1024

    static func destination(_ target: String, base: URL, root: URL) throws -> PreviewDestination {
        if target.hasPrefix("#") { return .heading(String(target.dropFirst()).removingPercentEncoding ?? String(target.dropFirst())) }
        guard !target.isEmpty, !target.contains("\0"),
              let components = URLComponents(string: target) else { throw PreviewFailure.message("Invalid link") }
        if let scheme = components.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            guard let url = components.url, scheme == "mailto" || url.host?.isEmpty == false else {
                throw PreviewFailure.message("Invalid web link")
            }
            return .external(url)
        }
        guard components.scheme == nil || components.scheme?.lowercased() == "file",
              components.host == nil || components.host == "" else {
            throw PreviewFailure.message("This link type is not allowed")
        }
        let path = components.path
        guard !path.contains("\0"), !path.isEmpty else { throw PreviewFailure.message("Invalid file path") }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : base.deletingLastPathComponent().appendingPathComponent(path)
        let canonical = try canonicalURL(url)
        let library = try canonicalURL(root)
        let prefix = library.pathComponents
        guard canonical.pathComponents.count > prefix.count,
              Array(canonical.pathComponents.prefix(prefix.count)) == prefix else {
            throw PreviewFailure.message("The file is outside this library")
        }
        return .local(canonical, fragment: components.fragment)
    }

    // Foundation re-shortens /private/var to /var on macOS; descriptor traversal needs realpath's spelling.
    static func canonicalURL(_ url: URL) throws -> URL {
        let normalized = url.standardizedFileURL
        if let path = realpath(normalized.path, nil) {
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path))
        }
        guard normalized.path != "/" else { throw PreviewFailure.message("Cannot resolve the library") }
        return try canonicalURL(normalized.deletingLastPathComponent()).appendingPathComponent(normalized.lastPathComponent)
    }

    // Walk from / with no-follow descriptors: a swapped ancestor or final symlink fails closed.
    static func read(_ url: URL, root: URL) throws -> Data {
        guard case let .local(canonical, _) = try destination(url.absoluteString, base: url, root: root) else {
            throw PreviewFailure.message("Only local files can be loaded")
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw PreviewFailure.message("Cannot open the library") }
        defer { Darwin.close(descriptor) }
        let parts = canonical.pathComponents.dropFirst()
        for (index, component) in parts.enumerated() {
            let final = index == parts.count - 1
            let next = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (final ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw PreviewFailure.message("File unavailable or changed while opening") }
            Darwin.close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw PreviewFailure.message("The resource must be a regular file")
        }
        guard info.st_size >= 0, info.st_size <= byteLimit else { throw PreviewFailure.message("Image exceeds 20 MB") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw PreviewFailure.message("Cannot read the resource") }
            guard result.count + count <= byteLimit else { throw PreviewFailure.message("Image exceeds 20 MB") }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    static func image(_ target: String, base: URL, root: URL) throws -> PreviewBitmap {
        guard case let .local(url, _) = try destination(target, base: base, root: root) else {
            throw PreviewFailure.message("Remote images are not downloaded")
        }
        return try decode(read(url, root: root))
    }

    static func decode(_ data: Data) throws -> PreviewBitmap {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let utType = UTType(type as String), utType.conforms(to: .image), !utType.conforms(to: .svg),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 80_000_000 else {
            throw PreviewFailure.message("Unsupported, corrupt or oversized image")
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary) else { throw PreviewFailure.message("Cannot decode this image") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw PreviewFailure.message("Cannot prepare this image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PreviewFailure.message("Cannot prepare this image") }
        return PreviewBitmap(data: output as Data, width: Double(image.width), height: Double(image.height), baseline: 0)
    }
}

nonisolated struct PreviewBitmap: Sendable {
    let data: Data
    let width: Double
    let height: Double
    let baseline: Double
}
