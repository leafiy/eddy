// swift-tools-version: 5.10
import PackageDescription

// Vendored copy of the shared Leafiy design system. The canonical source of
// truth is the separate leafiy-ui repository (which also carries the tests);
// edit there and re-sync with its scripts/sync-into-apps.sh — never in place.

var products: [Product] = [
    .library(name: "LeafiyUICore", targets: ["LeafiyUICore"])
]
var targets: [Target] = [
    .target(name: "LeafiyUICore")
]

// The SwiftUI design system needs AppKit/SwiftUI and only builds on macOS.
#if os(macOS)
products.append(.library(name: "LeafiyUI", targets: ["LeafiyUI"]))
targets.append(.target(name: "LeafiyUI", dependencies: ["LeafiyUICore"]))
#endif

let package = Package(
    name: "LeafiyUI",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
