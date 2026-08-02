import AppKit
import CoreGraphics
import Foundation
import LeafiyUICore
import SwiftUI

struct ImageItem: Identifiable {
    enum Status: Equatable {
        case pending
        case processing
        case done              // replaced with a smaller file
        case unchanged         // already optimal; original kept
        case failed(String)
    }

    let id = UUID()
    var url: URL
    var thumbnail: CGImage?
    var originalBytes: Int
    var finalBytes: Int?
    var status: Status = .pending
    /// "4032×3024 → 1080×810" once processed; proof of the resize setting.
    var dimensions: String?
    /// Quick Share upload in progress for this row.
    var isSharing = false

    var filename: String { url.lastPathComponent }

    var isInFlight: Bool { status == .pending || status == .processing }

    var isShareable: Bool { status == .done || status == .unchanged }

    var savedFraction: Double? {
        guard let finalBytes, originalBytes > 0 else { return nil }
        return 1 - Double(finalBytes) / Double(originalBytes)
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var items: [ImageItem] = []
    @Published var toast: String?
    /// Quick Share was invoked without a configured storage account;
    /// ContentView presents the setup prompt.
    @Published var needsQuickShareSetup = false

    private var toastTask: Task<Void, Never>?
    private var hadPendingWork = false

    func clearFinished() {
        items.removeAll { !$0.isInFlight }
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        updateDockBadge()
    }

    func showToast(_ message: String, seconds: Double = 2.8) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: - Quick Share

    /// Uploads the item's (compressed, in-place) file to the configured
    /// object storage and copies the public link. Without a configured
    /// account, raises the setup prompt instead.
    func quickShare(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isSharing else { return }
        let settings = SettingsStore.shared.settings.quickShare
        guard settings.isConfigured else {
            needsQuickShareSetup = true
            return
        }
        update(id) { $0.isSharing = true }
        let fileURL = item.url
        Task { [weak self] in
            do {
                let link = try await QuickShareService.share(fileURL: fileURL, settings: settings)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(link, forType: .string)
                self?.showToast(L("Public link copied to clipboard."), seconds: 4)
            } catch {
                NSLog("Eddy quick share failed: %@", String(describing: error))
                self?.showToast(error.localizedDescription, seconds: 5)
            }
            self?.update(id) { $0.isSharing = false }
        }
    }

    // MARK: - Clipboard

    /// Handles Cmd+V: copied files are queued directly; raw image data
    /// (screenshots, images copied from apps or browsers) is saved as a PNG
    /// in Downloads and compressed there.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        let options = SettingsStore.shared.processingOptions
        let quality = options.quality
        let maxWidth = options.maxWidth
        let format = options.format

        if let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL], !urls.isEmpty {
            add(urls: urls, quality: quality, maxWidth: maxWidth, format: format)
            return
        }

        if let pngData = Self.imageData(from: pasteboard) {
            do {
                let url = try Self.savePastedImage(pngData)
                showToast(String(format: L("Pasted image saved to %@"), (url.path as NSString).abbreviatingWithTildeInPath), seconds: 5)
                add(urls: [url], quality: quality, maxWidth: maxWidth, format: format)
            } catch {
                showToast(L("Could not save the pasted image"))
            }
            return
        }

        showToast(L("No image in the clipboard"))
    }

    private static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private static func savePastedImage(_ data: Data) throws -> URL {
        let fm = FileManager.default
        let directory = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "eddy-\(formatter.string(from: Date()))"
        var url = directory.appendingPathComponent("\(base).png")
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(counter).png")
            counter += 1
        }
        try data.write(to: url)
        return url
    }

    func add(urls: [URL], quality: Double, maxWidth: Int = 0, format: SaveFormat) {
        var files: [URL] = []
        var skipped = 0
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                skipped += 1
                continue
            }
            if isDirectory.boolValue {
                // Inside a folder, quietly take what we support.
                guard let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey]
                ) else { continue }
                for case let child as URL in enumerator where Self.isSupported(child) {
                    files.append(child)
                }
            } else if Self.isSupported(url) {
                files.append(url)
            } else {
                // A directly dropped unsupported file deserves feedback.
                skipped += 1
            }
        }

        if skipped > 0 {
            let message: String
            if files.isEmpty {
                message = skipped == 1
                    ? String(format: L("No supported images — skipped %d file"), skipped)
                    : String(format: L("No supported images — skipped %d files"), skipped)
            } else {
                message = skipped == 1
                    ? String(format: L("Skipped %d unsupported file"), skipped)
                    : String(format: L("Skipped %d unsupported files"), skipped)
            }
            showToast(message)
        }
        guard !files.isEmpty else { return }

        // Re-dropping a file replaces its finished row instead of duplicating.
        let incoming = Set(files.map(\.path))
        items.removeAll { incoming.contains($0.url.path) && !$0.isInFlight }

        let newItems = files.map { url in
            ImageItem(url: url, thumbnail: nil, originalBytes: Self.fileSize(url))
        }
        items.append(contentsOf: newItems)
        updateDockBadge()
        process(batch: newItems, quality: quality, maxWidth: maxWidth, format: format)
    }

    // MARK: - Processing

    private func process(batch: [ImageItem], quality: Double, maxWidth: Int, format: SaveFormat) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
                var next = 0
                while next < min(width, batch.count) {
                    let item = batch[next]
                    next += 1
                    group.addTask { await self.processOne(item, quality: quality, maxWidth: maxWidth, format: format) }
                }
                for await _ in group where next < batch.count {
                    let item = batch[next]
                    next += 1
                    group.addTask { await self.processOne(item, quality: quality, maxWidth: maxWidth, format: format) }
                }
            }
        }
    }

    nonisolated private func processOne(_ item: ImageItem, quality: Double, maxWidth: Int, format: SaveFormat) async {
        let thumbnail = Compressor.thumbnail(for: item.url)
        let before = Compressor.pixelDimensions(of: item.url)
        await MainActor.run {
            self.update(item.id) {
                $0.thumbnail = thumbnail
                $0.dimensions = before.map { "\($0.width)×\($0.height)" }
                $0.status = .processing
            }
        }
        do {
            let outcome = try Compressor.optimize(fileURL: item.url, quality: quality, maxWidth: maxWidth, format: format)
            let after = Compressor.pixelDimensions(of: outcome.outputURL)
            await MainActor.run {
                var dimensionsText: String?
                if let before, let after {
                    dimensionsText = before == after
                        ? "\(after.width)×\(after.height)"
                        : "\(before.width)×\(before.height) → \(after.width)×\(after.height)"
                }
                self.update(item.id) {
                    $0.url = outcome.outputURL
                    $0.originalBytes = outcome.originalBytes
                    $0.finalBytes = outcome.finalBytes
                    $0.status = outcome.replaced ? .done : .unchanged
                    if dimensionsText != nil {
                        $0.dimensions = dimensionsText
                    }
                }
                if outcome.replaced {
                    HistoryStore.shared.record(HistoryEntry(
                        path: outcome.outputURL.path,
                        originalBytes: outcome.originalBytes,
                        finalBytes: outcome.finalBytes,
                        dimensions: dimensionsText
                    ))
                }
            }
        } catch {
            await MainActor.run {
                self.update(item.id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout ImageItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
        updateDockBadge()
    }

    // MARK: - Dock badge & batch summary

    private func updateDockBadge() {
        let pending = items.filter(\.isInFlight).count
        NSApp.dockTile.badgeLabel = pending > 0 ? String(pending) : nil
        if pending > 0 {
            hadPendingWork = true
        } else if hadPendingWork {
            hadPendingWork = false
            showBatchSummary()
        }
    }

    private func showBatchSummary() {
        let finished = items.filter { $0.finalBytes != nil }
        let saved = finished.reduce(0) { $0 + ($1.originalBytes - ($1.finalBytes ?? $1.originalBytes)) }
        showToast(saved > 0
            ? String(format: L("Done — saved %@"), Formatters.bytes(saved))
            : L("Done — files were already optimal"))
    }

    // MARK: - File helpers

    private static func isSupported(_ url: URL) -> Bool {
        Compressor.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
