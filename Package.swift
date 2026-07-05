// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "eddy",
    platforms: [.macOS(.v13)],
    dependencies: [
        // libwebp compiled from source — WebP encoding without brew or macOS 14.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "eddy",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode"),
            ],
            path: "Sources/Eddy"
        )
    ]
)
