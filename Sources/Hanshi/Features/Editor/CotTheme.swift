import AppKit

// CotEditor's JSON format; built-in assets and their provenance are listed in ThirdPartyNotices.
struct CotTheme {
    let metadata: [String: String]
    private let styles: [String: Style]
    private struct Style: Decodable {
        let color: String
        var usesSystemSetting: Bool = false
        enum CodingKeys: CodingKey { case color, usesSystemSetting }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            color = try values.decode(String.self, forKey: .color)
            usesSystemSetting = try values.decodeIfPresent(Bool.self, forKey: .usesSystemSetting) ?? false
        }
    }
    enum InvalidTheme: Error { case metadata, color, missingStyle }

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard var values = object as? [String: Any],
              let metadata = values.removeValue(forKey: "metadata") as? [String: String],
              metadata["license"] == "Same as CotEditor (Apache, ver.2)" else { throw InvalidTheme.metadata }
        self.metadata = metadata
        values.removeValue(forKey: "name")
        styles = try JSONDecoder().decode([String: Style].self, from: JSONSerialization.data(withJSONObject: values))
        guard styles["background"] != nil, styles["text"] != nil else { throw InvalidTheme.missingStyle }
        guard styles.values.allSatisfy({ Self.parseColor($0.color) != nil }) else { throw InvalidTheme.color }
    }
    func color(_ name: String, system: NSColor? = nil) -> NSColor? {
        guard let style = styles[name] else { return nil }
        if style.usesSystemSetting, let system { return system }
        return Self.parseColor(style.color)
    }
    private static func parseColor(_ string: String) -> NSColor? {
        guard string.hasPrefix("#"), [7, 9].contains(string.count),
              let value = UInt32(string.dropFirst(), radix: 16) else { return nil }
        let rgb = string.count == 9 ? value >> 8 : value
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                       green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255,
                       alpha: string.count == 9 ? Double(value & 255) / 255 : 1)
    }
}

nonisolated enum EditorResources {
    static let bundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app",
           let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("Hanshi_Hanshi.bundle")) { return bundle }
        return Bundle.module
    }()
}
