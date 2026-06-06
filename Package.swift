// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Cocker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cocker", targets: ["CockerCLI"]),
        .executable(name: "cockerd", targets: ["CockerDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // swift-log 1.13+ exige swift-tools-version 6.2 (Xcode 26), pas dispo
        // sur macos-15 runner (Xcode 16.4 max = Swift 6.1). Cap à < 1.13.
        .package(url: "https://github.com/apple/swift-log", "1.5.0"..<"2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "4.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "CockerCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/CockerCore",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "CockerCLI",
            dependencies: [
                "CockerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CockerCLI"
        ),
        .executableTarget(
            name: "CockerDaemon",
            dependencies: [
                "CockerCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/CockerDaemon",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("vmnet", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "CockerTests",
            dependencies: ["CockerCore"],
            path: "Tests/CockerTests"
        ),
    ]
)
