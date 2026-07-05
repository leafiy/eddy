// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PicShrink",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PicShrink",
            path: "Sources/PicShrink"
        )
    ]
)
