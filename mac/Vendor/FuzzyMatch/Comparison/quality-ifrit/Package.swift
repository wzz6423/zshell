// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "quality-ifrit",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ukushu/Ifrit.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "quality-ifrit",
            dependencies: [
                .product(name: "Ifrit", package: "Ifrit"),
            ],
            path: "Sources"
        ),
    ]
)
