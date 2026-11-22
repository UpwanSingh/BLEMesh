// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeshCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MeshCore", targets: ["MeshCore"]),
        .library(name: "MeshSimulator", targets: ["MeshSimulator"]),
        .executable(name: "mesh-demo", targets: ["MeshDemo"]),
    ],
    targets: [
        .target(name: "MeshCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MeshSimulator", dependencies: ["MeshCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MeshDemo", dependencies: ["MeshCore", "MeshSimulator"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "MeshCoreSDKTests",
            dependencies: ["MeshCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeshCoreTests",
            dependencies: ["MeshCore", "MeshSimulator"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
