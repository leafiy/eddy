import SwiftUI

/// The one settings-window layout used by every Leafiy app.
///
/// Host it in the SwiftUI `Settings` scene — Apple's official settings
/// mechanism for macOS apps (⌘, and the app-menu "Settings…" item come for
/// free). The embedded `TabView` renders the standard System-Settings-style
/// toolbar tabs.
///
///     Settings {
///         SettingsScaffold {
///             GeneralPane()          // a SettingsPane
///             AboutPane(...)
///         }
///     }
///
/// Settings are instant-apply: panes bind controls straight to the app's
/// settings store. Never add Save/Cancel buttons.
public struct SettingsScaffold<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        TabView {
            content
        }
    }
}

/// One tab of a `SettingsScaffold`: a grouped `Form` with a fixed,
/// family-wide width. Compose content from `Section`, `LabeledContent`,
/// `Toggle`, `Picker`, `TextField`, `Stepper` — stock controls only.
public struct SettingsPane<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let height: CGFloat
    private let content: Content

    public init(
        _ title: String,
        systemImage: String,
        height: CGFloat = LeafiyDesign.Size.settingsPaneHeight,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.height = height
        self.content = content()
    }

    public var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(width: LeafiyDesign.Size.settingsPaneWidth, height: height)
        .tabItem {
            Label(title, systemImage: systemImage)
        }
    }
}
