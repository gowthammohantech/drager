// swift-tools-version: 6.2
// Test-only conformance CLI (`sb-swift`). Never shipped in an app.
// See docs/API/CONFORMANCE.md §5 for the command contract.
import PackageDescription

let package = Package(
    name: "SwiftHarness",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "sb-swift", targets: ["sb-swift"]),
    ],
    dependencies: [
        .package(name: "SpatialBridgeKit", path: "../../Packages/SpatialBridgeKit"),
    ],
    targets: [
        .executableTarget(
            name: "sb-swift",
            dependencies: [
                .product(name: "BridgeModels", package: "SpatialBridgeKit"),
                .product(name: "BridgeCore", package: "SpatialBridgeKit"),
                .product(name: "BridgeSecurity", package: "SpatialBridgeKit"),
                .product(name: "BridgeNetworking", package: "SpatialBridgeKit"),
                .product(name: "BridgeTransfer", package: "SpatialBridgeKit"),
                .product(name: "BridgePersistence", package: "SpatialBridgeKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
