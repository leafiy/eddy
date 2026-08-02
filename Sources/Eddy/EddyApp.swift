import AppKit
import LeafiyUICore
import SwiftUI
import LeafiyUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SoftwareUpdateController.shared.startAutomaticCheck()
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
        let options = SettingsStore.shared.processingOptions
        Store.shared.add(urls: urls, quality: options.quality, maxWidth: options.maxWidth, format: options.format)
    }
}

@main
struct EddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsStore = SettingsStore.shared

    init() {
        LeafiyLocalization.language = SettingsStore.persistedAppLanguage()
        if CommandLine.arguments.contains("--leafiy-doctor") {
            let appBundle = LeafiyLocalization.moduleBundle(package: "eddy", target: "eddy")
            let leafiyUIBundle = LeafiyLocalization.moduleBundle(package: "LeafiyUI", target: "LeafiyUI")
            print(LeafiyDiagnostics.doctorReport(
                store: LeafiySettingsStore<AppSettings>.standard(directoryName: "Eddy"),
                probes: [
                    (label: "app", bundle: appBundle, key: "Paste Images"),
                    (label: "leafiy-ui", bundle: leafiyUIBundle, key: "About")
                ]
            ))
            exit(0)
        }
    }

    private var appLanguage: AppLanguage {
        settingsStore.appLanguage
    }

    private var quickShareBinding: Binding<QuickShareSettings> {
        Binding(
            get: { settingsStore.settings.quickShare },
            set: { newValue in settingsStore.update { $0.quickShare = newValue } }
        )
    }

    var body: some Scene {
        WindowGroup("eddy", id: "main") {
            ContentView(settingsStore: settingsStore)
                .id(appLanguage)
        }
        .defaultSize(width: 640, height: 420)
        .windowResizability(.contentMinSize)
        .commands {
            // Menu commands instead of onPasteCommand: they work regardless
            // of which view has focus. The full pasteboard group is replaced,
            // so Cut/Copy/Select All must be restored by hand — dropping them
            // silently killed ⌘C in every text field (e.g. Settings → Share).
            // Paste is smart: with a text editor focused it pastes text,
            // otherwise it pastes images into the queue.
            CommandGroup(replacing: .pasteboard) {
                Button(L("Cut")) {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                Button(L("Copy")) {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button(L("Paste")) {
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    } else {
                        Store.shared.pasteFromClipboard()
                    }
                }
                .keyboardShortcut("v", modifiers: .command)
                Button(L("Select All")) {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
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
                EddyGeneralSettingsPane(settingsStore: settingsStore)
                QuickShareSettingsPane(settings: quickShareBinding)
                AboutPane(
                    tagline: L("Drag-and-drop image compression — files are optimized in place."),
                    copyright: L("© 2026 Leafiy")
                )
            }
            .id(appLanguage)
        }
    }
}

private struct EddyMenuBarIcon: View {
    @ObservedObject private var store = Store.shared

    private static let baseIcon: NSImage = {
        let base = LeafiyMenuBarIconRenderer.baseIcon(
            NSImage.eddyIcon(),
            symbolFallback: "photo.on.rectangle.angled",
            accessibilityDescription: "Eddy"
        )
        base.accessibilityDescription = "Eddy"
        return base
    }()

    var body: some View {
        Image(nsImage: LeafiyMenuBarIconRenderer.image(base: Self.baseIcon, status: status))
            .accessibilityLabel(Text(verbatim: "Eddy"))
    }

    private var status: LeafiyMenuBarStatus {
        if store.items.contains(where: { $0.isInFlight || $0.isSharing }) {
            return .busy
        }
        if store.items.contains(where: {
            if case .failed = $0.status { return true }
            return false
        }) {
            return .failure
        }
        return .idle
    }
}

private extension NSImage {
    static func eddyIcon() -> NSImage? {
        let resourceBundle = LeafiyLocalization.moduleBundle(package: "eddy", target: "eddy")
        for bundle in [resourceBundle, Bundle.main] {
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
        LeafiyMenuTail()
    }
}

private struct EddyGeneralSettingsPane: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        LeafiyGeneralPane(language: languageBinding, tail: {
            LabeledContent(L("Default quality")) {
                HStack(spacing: LeafiyDesign.Spacing.s) {
                    Slider(value: qualityBinding, in: 10...100, step: 5)
                    Text("\(Int(settingsStore.settings.compressionQuality))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Picker(L("Save format"), selection: saveFormatBinding) {
                ForEach(SaveFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            Picker(L("Max width"), selection: resizeMaxWidthBinding) {
                ForEach(ResizeMaxWidthOption.all) { option in
                    Text(option.title).tag(option.width)
                }
            }
            Text(L("Images are optimized in place — choosing PNG or JPEG converts other formats and replaces the original file. These defaults are used for new drops."))
                .font(.caption)
                .foregroundStyle(.secondary)
        })
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsStore.appLanguage },
            set: { settingsStore.appLanguage = $0 }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { settingsStore.settings.compressionQuality },
            set: { newValue in settingsStore.update { $0.compressionQuality = newValue } }
        )
    }

    private var saveFormatBinding: Binding<SaveFormat> {
        Binding(
            get: { settingsStore.settings.defaultSaveFormat },
            set: { newValue in settingsStore.update { $0.defaultSaveFormat = newValue } }
        )
    }

    private var resizeMaxWidthBinding: Binding<Int> {
        Binding(
            get: { settingsStore.settings.resizeMaxWidth },
            set: { newValue in settingsStore.update { $0.resizeMaxWidth = newValue } }
        )
    }
}
