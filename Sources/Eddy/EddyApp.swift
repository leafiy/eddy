import AppKit
import LeafiyUICore
import SwiftUI
import LeafiyUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running after the last window closes — like fifi, the menu-bar
    /// item stays available (reopen via the icon, the Dock, or ⌘O drops).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Files dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        let percent = UserDefaults.standard.object(forKey: "compressionQuality") as? Double ?? 80
        let maxWidth = UserDefaults.standard.integer(forKey: "resizeMaxWidth")
        let format = SaveFormat(rawValue: UserDefaults.standard.string(forKey: "defaultSaveFormat") ?? "") ?? .keep
        Task { @MainActor in
            Store.shared.add(urls: urls, quality: percent / 100, maxWidth: maxWidth, format: format)
        }
    }
}

@main
struct EddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue

    init() {
        LeafiyLocalization.language = Self.language(from: UserDefaults.standard.string(forKey: "appLanguage"))
    }

    private var appLanguage: AppLanguage {
        Self.language(from: languageRaw)
    }

    private static func language(from rawValue: String?) -> AppLanguage {
        AppLanguage(rawValue: rawValue ?? AppLanguage.system.rawValue) ?? .system
    }

    private func applyLanguage(_ rawValue: String) {
        LeafiyLocalization.language = Self.language(from: rawValue)
    }


    var body: some Scene {
        WindowGroup("eddy", id: "main") {
            ContentView()
                .id(appLanguage)
                .onChange(of: languageRaw) { _, newValue in
                    applyLanguage(newValue)
                }
        }
        .defaultSize(width: 640, height: 420)
        .windowResizability(.contentMinSize)
        .commands {
            // Menu command instead of onPasteCommand: works regardless of
            // which view has focus.
            CommandGroup(replacing: .pasteboard) {
                Button(L("Paste Images")) {
                    Store.shared.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }

        MenuBarExtra {
            EddyMenuContent()
                .id(appLanguage)
        } label: {
            EddyMenuBarIcon()
                .id(appLanguage)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsScaffold {
                EddyGeneralSettingsPane()
                AboutPane(
                    tagline: L("Drag-and-drop image compression — files are optimized in place."),
                    copyright: L("© 2026 Leafiy")
                )
            }
            .id(appLanguage)
            .onChange(of: languageRaw) { _, newValue in
                applyLanguage(newValue)
            }
        }
    }
}

private struct EddyMenuBarIcon: View {
    private static let icon = NSImage.eddyIcon()?.leafiyMenuBarSized()

    var body: some View {
        Group {
            if let icon = Self.icon {
                Image(nsImage: icon)
                    .frame(width: LeafiyDesign.Size.menuBarIcon, height: LeafiyDesign.Size.menuBarIcon)
            }
        }
        .frame(width: LeafiyDesign.Size.menuBarIcon, height: LeafiyDesign.Size.menuBarIcon)
        .accessibilityLabel("Eddy")
    }
}

private extension NSImage {
    static func eddyIcon() -> NSImage? {
        for bundle in [Bundle.module, Bundle.main] {
            guard let url = bundle.url(forResource: "eddy", withExtension: "png"),
                  let image = NSImage(contentsOf: url) else {
                continue
            }
            image.accessibilityDescription = "Eddy"
            return image
        }
        return nil
    }
}

private struct EddyMenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Open eddy")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(L("Paste Images")) {
            Store.shared.pasteFromClipboard()
        }
        Divider()
        Button(L("Settings…")) {
            openSettingsWindow()
        }
        Button(L("Quit eddy")) {
            NSApp.terminate(nil)
        }
    }
}

/// Opens the SwiftUI Settings scene from the menu-bar menu by performing the
/// app-menu "Settings…" item SwiftUI maintains (equivalent to ⌘,); falls back
/// to the legacy responder-chain selector. Same approach as fifi — a plain
/// `SettingsLink` doesn't activate the app from a menu-bar click, so the
/// window opened behind whatever app was frontmost.
@MainActor
private func openSettingsWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let appMenu = NSApp.mainMenu?.items.first?.submenu,
       let index = appMenu.items.firstIndex(where: {
           $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
       }) {
        appMenu.performActionForItem(at: index)
        return
    }
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

private struct EddyGeneralSettingsPane: View {
    @AppStorage("compressionQuality") private var qualityPercent = 80.0
    @AppStorage("resizeMaxWidth") private var resizeMaxWidth = 0
    @AppStorage("defaultSaveFormat") private var saveFormatRaw = SaveFormat.keep.rawValue
    @AppStorage("appLanguage") private var languageRaw = AppLanguage.system.rawValue

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            AppLanguage(rawValue: languageRaw) ?? .system
        } set: { newLanguage in
            languageRaw = newLanguage.rawValue
            LeafiyLocalization.language = newLanguage
        }
    }


    var body: some View {
        SettingsPane(L("General"), systemImage: "gearshape", height: 390) {
            Section(L("General")) {
                LanguagePicker(selection: languageBinding)
            }

            Section(L("Compression")) {
                LabeledContent(L("Default quality")) {
                    HStack(spacing: LeafiyDesign.Spacing.s) {
                        Slider(value: $qualityPercent, in: 10...100, step: 5)
                        Text("\(Int(qualityPercent))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Picker(L("Save format"), selection: $saveFormatRaw) {
                    ForEach(SaveFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
            }

            Section(L("Resize")) {
                Picker(L("Max width"), selection: $resizeMaxWidth) {
                    ForEach(ResizeMaxWidthOption.all) { option in
                        Text(option.title).tag(option.width)
                    }
                }

                Text(L("Images are optimized in place — choosing PNG or JPEG converts other formats and replaces the original file. These defaults are used for new drops."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
