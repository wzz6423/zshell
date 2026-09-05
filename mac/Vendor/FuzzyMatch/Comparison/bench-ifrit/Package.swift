// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bench-ifrit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ukushu/Ifrit.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "bench-ifrit",
            dependencies: [
                .product(name: "Ifrit", package: "Ifrit"),
            ],
            path: "Sources"
        ),
    ]
)
