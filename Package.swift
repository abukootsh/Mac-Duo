// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDuo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Reads the hinge angle from the built-in HID sensor.
        .target(
            name: "LidSensorKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure logic: trigger policy, smoothing, projection. No AppKit.
        .target(
            name: "DuoCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacDuo",
            dependencies: ["LidSensorKit", "DuoCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lidprobe",
            dependencies: ["LidSensorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DuoCoreTests",
            dependencies: ["DuoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
