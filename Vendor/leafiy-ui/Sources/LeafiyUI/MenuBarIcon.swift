import AppKit

extension NSImage {
    /// Copy sized for a `MenuBarExtra` label. The status bar renders an
    /// NSImage-backed `Image` at the NSImage's own point size — SwiftUI
    /// `.frame()`/`.resizable()` on the label do not reliably constrain it —
    /// so the size must be set on the image itself.
    ///
    /// Cache the result (e.g. in a `static let`); label views re-render often.
    public func leafiyMenuBarSized() -> NSImage {
        // A shallow NSImage copy shares the underlying representations.
        let sized = self.copy() as! NSImage
        sized.size = NSSize(
            width: LeafiyDesign.Size.menuBarIcon,
            height: LeafiyDesign.Size.menuBarIcon
        )
        return sized
    }
}
