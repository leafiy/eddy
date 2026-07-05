import AppKit
import SwiftUI

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
    }
}
