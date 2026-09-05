// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Examples",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "fuzzygrep",
            dependencies: [
                .product(name: "FuzzyMatch", package: "FuzzyMatch"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            path: "fuzzygrep/Sources"
        )
    ]
)
