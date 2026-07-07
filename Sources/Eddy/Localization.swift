import Foundation
import LeafiyUICore

/// App strings resolved against this target's zh-Hans table.
@inline(__always)
func L(_ key: String) -> String {
    LeafiyLocalization.string(key, bundle: .module)
}
