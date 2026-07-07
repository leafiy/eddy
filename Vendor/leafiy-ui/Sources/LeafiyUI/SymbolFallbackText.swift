import AppKit
import SwiftUI

/// Fonts for user-provided text that may contain private-use-area glyphs
/// (Nerd Font icons in terminal prompts, powerline segments, …).
///
/// PUA codepoints belong to no script, so Core Text's automatic fallback
/// never reaches user-installed fonts for them and draws the LastResort
/// font instead — boxes that read as question marks. These fonts keep the
/// system text style but append an installed Nerd Font to the cascade so
/// such glyphs render when the user has one.
@MainActor
public enum LeafiySymbolText {
    private static var cache: [NSFont.TextStyle: Font] = [:]

    /// Installed Nerd Font family to fall back to, resolved once. Prefers
    /// the dedicated symbols-only families; otherwise any patched family.
    private static let fallbackFamily: String? = {
        let families = NSFontManager.shared.availableFontFamilies
        let preferred = ["Symbols Nerd Font Mono", "Symbols Nerd Font"]
        if let exact = preferred.first(where: families.contains) {
            return exact
        }
        return families.first { $0.contains("Nerd Font") }
    }()

    /// The system font for `style`, with a Nerd Font appended to its
    /// fallback cascade when one is installed.
    public static func font(_ style: NSFont.TextStyle) -> Font {
        if let cached = cache[style] {
            return cached
        }
        let base = NSFont.preferredFont(forTextStyle: style, options: [:])
        let resolved: NSFont
        if let fallbackFamily {
            let fallback = NSFontDescriptor(fontAttributes: [.family: fallbackFamily])
            let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
            resolved = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        } else {
            resolved = base
        }
        let font = Font(resolved as CTFont)
        cache[style] = font
        return font
    }
}
