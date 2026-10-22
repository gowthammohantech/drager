// swift-tools-version: 6.2
// Spatial Bridge shared packages. Platform-neutral: no UIKit/AppKit imports allowed here.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "SpatialBridgeKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BridgeModels", targets: ["BridgeModels"]),
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "BridgeDiagnostics", targets: ["BridgeDiagnostics"]),
        .library(name: "BridgeSecurity", targets: ["BridgeSecurity"]),
        .library(name: "BridgeNetworking", targets: ["BridgeNetworking"]),
        .library(name: "BridgeTransfer", targets: ["BridgeTransfer"]),
        .library(name: "BridgeGesture", targets: ["BridgeGesture"]),
        .library(name: "BridgeCalibration", targets: ["BridgeCalibration"]),
        .library(name: "BridgePersistence", targets: ["BridgePersistence"]),
        .library(name: "BridgeServices", targets: ["BridgeServices"]),
        .library(name: "BridgeTestSupport", targets: ["BridgeTestSupport"]),
    ],
    targets: [
        // MARK: Sources
        .target(name: "BridgeModels", swiftSettings: swiftSettings),
        .target(name: "BridgeCore", dependencies: ["BridgeModels", "BridgeDiagnostics"], swiftSettings: swiftSettings),
        .target(name: "BridgeDiagnostics", dependencies: ["BridgeModels"], swiftSettings: swiftSettings),
        .target(
            name: "BridgeSecurity",
            dependencies: ["BridgeModels", "BridgeCore", "BridgeDiagnostics"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BridgeNetworking",
            dependencies: ["BridgeModels", "BridgeCore", "BridgeSecurity", "BridgeDiagnostics"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BridgeTransfer",
            dependencies: ["BridgeModels", "BridgeCore", "BridgeDiagnostics"],
            swiftSettings: swiftSettings
        ),
        .target(name: "BridgeGesture", dependencies: ["BridgeModels"], swiftSettings: swiftSettings),
        .target(name: "BridgeCalibration", dependencies: ["BridgeModels"], swiftSettings: swiftSettings),
        .target(
            name: "BridgePersistence",
            dependencies: ["BridgeModels", "BridgeCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BridgeServices",
            dependencies: [
                "BridgeModels", "BridgeCore", "BridgeDiagnostics", "BridgeSecurity",
                "BridgeNetworking", "BridgeTransfer", "BridgePersistence",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BridgeTestSupport",
            dependencies: ["BridgeModels", "BridgeCore", "BridgeSecurity", "BridgeNetworking", "BridgeTransfer"],
            swiftSettings: swiftSettings
        ),

        // MARK: Unit tests
        .testTarget(name: "BridgeModelsTests", dependencies: ["BridgeModels"], path: "Tests/Unit/BridgeModelsTests"),
        .testTarget(
            name: "BridgeSecurityTests",
            dependencies: ["BridgeSecurity", "BridgeTestSupport"],
            path: "Tests/Unit/BridgeSecurityTests"
        ),
        .testTarget(
            name: "BridgeNetworkingTests",
            dependencies: ["BridgeNetworking", "BridgeTestSupport"],
            path: "Tests/Unit/BridgeNetworkingTests"
        ),
        .testTarget(
            name: "BridgeTransferTests",
            dependencies: ["BridgeTransfer", "BridgeTestSupport"],
            path: "Tests/Unit/BridgeTransferTests"
        ),
        .testTarget(
            name: "BridgeGestureTests",
            dependencies: ["BridgeGesture", "BridgeTestSupport"],
            path: "Tests/Unit/BridgeGestureTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BridgeCalibrationTests",
            dependencies: ["BridgeCalibration"],
            path: "Tests/Unit/BridgeCalibrationTests"
        ),
        .testTarget(
            name: "BridgePersistenceTests",
            dependencies: ["BridgePersistence", "BridgeTestSupport"],
            path: "Tests/Unit/BridgePersistenceTests"
        ),
        .testTarget(
            name: "BridgeDiagnosticsTests",
            dependencies: ["BridgeDiagnostics"],
            path: "Tests/Unit/BridgeDiagnosticsTests"
        ),

        // MARK: Integration tests (real Network.framework loopback)
        .testTarget(
            name: "BridgeIntegrationTests",
            dependencies: [
                "BridgeNetworking", "BridgeTransfer", "BridgeSecurity", "BridgeTestSupport",
                "BridgeServices", "BridgePersistence",
            ],
            path: "Tests/Integration/BridgeIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
