// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "eddy",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../leafiy-ui"),
        // libwebp compiled from source — in-process WebP encoding.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
        // libavif + libaom compiled from source — in-process AVIF encoding.
        .package(url: "https://github.com/SDWebImage/libavif-Xcode.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "eddy",
            dependencies: [
                .product(name: "LeafiyUI", package: "leafiy-ui"),
                .product(name: "LeafiyUICore", package: "leafiy-ui"),
                .product(name: "libwebp", package: "libwebp-Xcode"),
                .product(name: "libavif", package: "libavif-Xcode"),
            ],
            path: "Sources/Eddy",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "EddyTests",
            dependencies: [
                "eddy",
                .product(name: "LeafiyUICore", package: "leafiy-ui"),
            ]
        )
    ]
)
