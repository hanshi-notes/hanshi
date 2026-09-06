// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hanshi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hanshi", targets: ["Hanshi"])],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/STTextView", exact: "2.4.0"),
        .package(url: "https://github.com/krzyzanowskim/STTextView-Plugin-TreeSitter",
                 revision: "346bbce977ce6a485ff9ad5696bebbe8790241e9")
    ],
    targets: [
        .executableTarget(name: "Hanshi", dependencies: [
            .product(name: "STTextView", package: "STTextView"),
            .product(name: "STTextView-Plugin-TreeSitter", package: "STTextView-Plugin-TreeSitter")
        ], swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .testTarget(name: "HanshiTests", dependencies: ["Hanshi"])
    ],
    swiftLanguageModes: [.v6]
)
