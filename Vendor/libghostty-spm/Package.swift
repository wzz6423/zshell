// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "ShellCraftKit", targets: ["ShellCraftKit"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "ShellCraftKit",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/ShellCraftKit"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/egoist-labs/libghostty-spm/releases/download/storage.1.3.7/GhosttyKit.xcframework.zip",
            checksum: "81a9d2757fc0b7e966509738f05f3e350c9d64c2eafd385c4c788bcd2d57a4aa"
        ),
        .testTarget(
            name: "GhosttyKitTest",
            dependencies: ["GhosttyKit", "GhosttyTerminal", "GhosttyTheme", "ShellCraftKit"]
        ),
    ]
)
