// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "yieldd",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "yieldd", targets: ["Yieldd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "Yieldd",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "YielddTests",
            dependencies: ["Yieldd"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
