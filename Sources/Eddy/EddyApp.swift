import AppKit
import LeafiyUICore
import SwiftUI
import LeafiyUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: LeafiyAppDelegate {
    override func leafiyApplicationDidFinishLaunching(_ notification: Notification) {
        // Reconcile persisted launch-time preferences with process/system
        // state — like daisy/fifi, this repairs stale state after the app
        // bundle moves or settings.json is restored from a backup.
        let settings = SettingsStore.shared.settings
        LeafiyLaunchAtLogin.setEnabled(settings.launchAtLogin)
        LeafiyApplicationPresentation.shared.apply(settings.applicationIconMode)
        NSApp.activate(ignoringOtherApps: true)
        // Sweep orphan backups: crop-only backups from past sessions and
        // crash residue between a backup write and its entry's persist
        // (Backup lifecycle, ADR-0001).
        let referenced = HistoryStore.shared.referencedBackupFilenames
        Task.detached(priority: .utility) {
            Originals.standard.cleanupOrphans(keeping: referenced)
        }
    }

    /// Files dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        let options = SettingsStore.shared.processingOptions
        Store.shared.add(urls: urls, quality: options.quality, maxWidth: options.maxWidth, format: options.format)
    }
}

/// Raises the main window from secondary entry points (menu bar, history).
@MainActor
enum EddyWindows {
    static func presentMain(_ openWindow: OpenWindowAction) {
        openWindow(id: "main")
        LeafiyWindowPresenter.presentWhenAvailable {
            LeafiyWindowRegistry.window(id: "main")
        }
    }
}

@MainActor
enum EddyActions {
    static func openImages(_ openWindow: OpenWindowAction) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = L("Open")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        let options = SettingsStore.shared.processingOptions
        Store.shared.add(
            urls: panel.urls,
            quality: options.quality,
            maxWidth: options.maxWidth,
            format: options.format
        )
        EddyWindows.presentMain(openWindow)
    }

    static func toggleHistory(_ openWindow: OpenWindowAction) {
        EddyWindows.presentMain(openWindow)
        withAnimation(HistoryPanel.slideAnimation) {
            HistoryStore.shared.isPresented.toggle()
        }
    }
}

private struct EddyCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L("Open")) {
                EddyActions.openImages(openWindow)
            }
            .keyboardShortcut("o", modifiers: .command)
        }
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
        CommandGroup(after: .windowArrangement) {
            Button(L("History")) {
                EddyActions.toggleHistory(openWindow)
            }
            .keyboardShortcut("y", modifiers: .command)
        }
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
        LeafiyDiagnostics.writeLaunchReport(
            store: LeafiySettingsStore<AppSettings>.standard(directoryName: "Eddy"),
            probes: [
                (label: "app",
                 bundle: LeafiyLocalization.moduleBundle(package: "eddy", target: "eddy"),
                 key: "Paste Images"),
                (label: "leafiy-ui",
                 bundle: LeafiyLocalization.moduleBundle(package: "LeafiyUI", target: "LeafiyUI"),
                 key: "About")
            ]
        )
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
        // A single-instance Window, not a WindowGroup: reopening from the
        // menu bar must raise the existing queue, never spawn a second one
        // (canonical-app behavior, like daisy).
        Window(LeafiyAppIdentity.current.name, id: "main") {
            ContentView(settingsStore: settingsStore)
                .id(appLanguage)
                .leafiyWindow(id: "main", role: .primary)
        }
        .defaultSize(width: 640, height: 420)
        .windowResizability(.contentMinSize)
        .commands {
            EddyCommands()
        }

        LeafiyMenuBarExtra {
            LeafiyFamilyMenu(language: appLanguage) {
                EddyMenuContent()
            }
        } label: {
            EddyMenuBarIcon()
                .id(appLanguage)
        }
        Settings {
            LeafiyFamilySettings(language: appLanguage) {
                EddyGeneralSettingsPane(settingsStore: settingsStore)
                QuickShareSettingsPane(settings: quickShareBinding)
            }
        }
    }
}

private struct EddyMenuBarIcon: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        LeafiyMenuBarLabel(status: status)
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

private struct EddyMenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Open eddy")) {
            EddyWindows.presentMain(openWindow)
        }
        Button(L("Paste Images")) {
            Store.shared.pasteFromClipboard()
        }
        Button(L("History")) {
            EddyActions.toggleHistory(openWindow)
        }
    }
}

private struct EddyGeneralSettingsPane: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        LeafiyGeneralPane(
            language: languageBinding,
            launchAtLogin: launchAtLoginBinding,
            applicationIconMode: applicationIconModeBinding,
            tail: {
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
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsStore.appLanguage },
            set: { settingsStore.appLanguage = $0 }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.launchAtLogin },
            set: { newValue in settingsStore.update { $0.launchAtLogin = newValue } }
        )
    }

    private var applicationIconModeBinding: Binding<LeafiyApplicationIconMode> {
        Binding(
            get: { settingsStore.settings.applicationIconMode },
            set: { newValue in settingsStore.update { $0.applicationIconMode = newValue } }
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
