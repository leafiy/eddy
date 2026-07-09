import Foundation
import LeafiyUICore

/// App strings resolved against this target's zh-Hans table.
@inline(__always)
func L(_ key: String) -> String {
    LeafiyLocalization.string(key, bundle: eddyResourceBundle)
}

private let eddyResourceBundle: Bundle = {
    let bundleName = "eddy_eddy.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
        Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true)
    ].compactMap { $0 }

    for url in candidates {
        if let bundle = Bundle(url: url) {
            return bundle
        }
    }
    return Bundle.main
}()
