import AppKit
import SwiftUI
import LeafiyUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Files dropped on the Dock icon or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        let percent = UserDefaults.standard.object(forKey: "compressionQuality") as? Double ?? 80
        let maxWidth = UserDefaults.standard.integer(forKey: "resizeMaxWidth")
        Task { @MainActor in
            Store.shared.add(urls: urls, quality: percent / 100, maxWidth: maxWidth)
        }
    }
}

@main
struct EddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("eddy") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Menu command instead of onPasteCommand: works regardless of
            // which view has focus.
            CommandGroup(replacing: .pasteboard) {
                Button("Paste Images") {
                    Store.shared.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }

        Settings {
            SettingsScaffold {
                EddyGeneralSettingsPane()
                AboutPane(
                    tagline: "Drag-and-drop image compression — files are optimized in place.",
                    copyright: "© 2026 Leafiy"
                )
            }
        }
    }
}

private struct EddyGeneralSettingsPane: View {
    @AppStorage("compressionQuality") private var qualityPercent = 80.0
    @AppStorage("resizeMaxWidth") private var resizeMaxWidth = 0

    var body: some View {
        SettingsPane("General", systemImage: "gearshape") {
            Section("Compression") {
                LabeledContent("Default quality") {
                    HStack(spacing: LeafiyDesign.Spacing.s) {
                        Slider(value: $qualityPercent, in: 10...100, step: 5)
                        Text("\(Int(qualityPercent))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Resize") {
                Picker("Max width", selection: $resizeMaxWidth) {
                    ForEach(ResizeMaxWidthOption.all) { option in
                        Text(option.title).tag(option.width)
                    }
                }

                Text("Images are optimized in place. These defaults are used for new drops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
