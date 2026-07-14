// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Gloss",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GlossCore", targets: ["GlossCore"]),
        .executable(name: "Gloss", targets: ["Gloss"]),
        .executable(name: "gloss-cli", targets: ["GlossCLI"])
    ],
    targets: [
        .target(name: "GlossCore"),
        .target(name: "GlossOCR"),
        .executableTarget(
            name: "Gloss",
            dependencies: ["GlossCore", "GlossOCR"]
        ),
        .executableTarget(
            name: "GlossCLI",
            dependencies: ["GlossCore"]
        ),
        .testTarget(
            name: "GlossCoreTests",
            dependencies: ["GlossCore"]
        ),
        .testTarget(
            name: "GlossOCRTests",
            dependencies: ["GlossOCR"]
        ),
        .testTarget(
            name: "GlossAppTests",
            dependencies: ["Gloss"]
        )
    ]
)
