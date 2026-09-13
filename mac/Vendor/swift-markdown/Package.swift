// swift-tools-version:6.2
/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021-2023 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import PackageDescription

let package = Package(
    name: "swift-markdown",
    products: [
        .library(
            name: "Markdown",
            targets: ["Markdown"]),
    ],
    dependencies: [
        // Vendored copy of swift-cmark beside this package; see ../DEPENDENCIES.md.
        .package(path: "../swift-cmark"),
    ],
    targets: [
        .target(
            name: "Markdown",
            dependencies: [
                "CAtomic",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            exclude: [
                "CMakeLists.txt"
            ],
            swiftSettings: [.unsafeFlags(["-Xcc", "-DCMARK_GFM_STATIC_DEFINE"], .when(platforms: [.windows]))]
        ),
        .testTarget(
            name: "MarkdownTests",
            dependencies: ["Markdown"],
            resources: [.process("Visitors/Everything.md")]),
        .target(name: "CAtomic"),
    ],
    swiftLanguageModes: [.v5]
)
