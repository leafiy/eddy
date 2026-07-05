// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "eddy",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "eddy",
            path: "Sources/Eddy"
        )
    ]
)
