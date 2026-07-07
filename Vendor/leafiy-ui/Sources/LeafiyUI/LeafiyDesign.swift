import SwiftUI

/// Design tokens shared by the Leafiy app family (daisy, eddy, fifi).
///
/// Every visual constant that appears in more than one view lives here so
/// the apps stay strictly aligned. Rules:
/// - Colors: semantic system styles only (`.primary`, `.secondary`,
///   `.tertiary`, `.quaternary`, `.separator`, materials, `Color.accentColor`;
///   `.red` for error/failure text and icons). Never fixed RGB values.
/// - Typography: system text styles only (`.title2`, `.body`, `.callout`,
///   `.caption`, …). Never fixed point sizes for text.
public enum LeafiyDesign {
    /// Spacing scale, in points.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 28
    }

    /// Corner radii.
    public enum Radius {
        public static let control: CGFloat = 6
        public static let card: CGFloat = 10
        public static let panel: CGFloat = 12
    }

    /// Fixed dimensions shared across the apps.
    public enum Size {
        /// Content width of every settings pane.
        public static let settingsPaneWidth: CGFloat = 620
        /// Default content height of a settings pane.
        public static let settingsPaneHeight: CGFloat = 440
        /// Content height of the standardized About pane.
        public static let aboutPaneHeight: CGFloat = 400
        /// Point size of a menu-bar (`MenuBarExtra`) icon.
        public static let menuBarIcon: CGFloat = 18
        /// Square edge of list-row thumbnails and icons.
        public static let rowIcon: CGFloat = 40
        /// Minimum content size of document-style main windows.
        public static let mainWindowMinWidth: CGFloat = 520
        public static let mainWindowMinHeight: CGFloat = 440
        /// Icon edge in the About pane.
        public static let aboutIcon: CGFloat = 96
        /// Width of the single-character key field in `ShortcutField`.
        public static let shortcutKeyField: CGFloat = 48
    }
}
