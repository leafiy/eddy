import Foundation
import LeafiyUICore

private let appBundle = LeafiyLocalization.moduleBundle(package: "eddy", target: "eddy")

@inline(__always)
func L(_ key: String) -> String {
    LeafiyLocalization.string(key, bundle: appBundle)
}
