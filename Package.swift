// swift-tools-version: 6.3
import PackageDescription
import Foundation

let package = Package(
    name: "Hanshi",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Hanshi", targets: ["Hanshi"])],
    dependencies: [
        .package(path: "Vendor/swift-markdown-engine"),
        .package(url: "https://github.com/swiftlang/swift-cmark", revision: "7898f1b3e4befeecee56cb4a3bc8eebd2cb63219"),
        .package(url: "https://github.com/PhraseHQ/HighlightKit", revision: "524c185b0553756498c1b6a1765e8d119c4623a6"),
        .package(url: "https://github.com/PhraseHQ/SwaTex", revision: "2b38d0b9b9b9466ac1302ab93b37f3b90b8c74fc"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages", revision: "15cf3a9ec3ab95e0d058b7df9f35619123c9e02d")
    ],
    targets: [
        .target(name: "EditorSyntax", dependencies: [
            .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            .product(name: "SwiftTreeSitterLayer", package: "SwiftTreeSitter")
        ] + [
            "TreeSitterBash", "TreeSitterCSS", "TreeSitterHTML", "TreeSitterJSDoc",
            "TreeSitterJSON", "TreeSitterJavaScript", "TreeSitterMarkdown", "TreeSitterMarkdownInline",
            "TreeSitterPython", "TreeSitterRegex", "TreeSitterSwift", "TreeSitterTypeScript",
            "TreeSitterYAML",
        ].map {
            .product(name: $0, package: "TreeSitterLanguages")
        }),
        .systemLibrary(name: "CMermaid"),
        .target(name: "CMarkdown", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark")
        ]),
        .executableTarget(name: "Hanshi", dependencies: [
            "CMarkdown", "CMermaid",
            .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            .product(name: "HighlightKit", package: "HighlightKit"),
            .product(name: "SwaTex", package: "SwaTex"),
            .product(name: "SwaTexRender", package: "SwaTex"),
            "EditorSyntax"
        ], exclude: ["Resources/Assets.xcassets"], resources: [.copy("Resources/ThirdPartyNotices"), .copy("Resources/Themes"), .copy("Resources/Syntax")], swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ], linkerSettings: [
            .unsafeFlags(["-L" + URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/mermaid/release").path]),
            .linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("c++")
        ]),
        .testTarget(name: "HanshiTests", dependencies: ["Hanshi"])
    ],
    swiftLanguageModes: [.v6]
)
