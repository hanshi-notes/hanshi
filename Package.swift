// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hanshi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Hanshi", targets: ["Hanshi"])],
    targets: [
        .executableTarget(name: "Hanshi", swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .testTarget(name: "HanshiTests", dependencies: ["Hanshi"])
    ],
    swiftLanguageModes: [.v6]
)
