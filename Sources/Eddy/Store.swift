import AppKit
import CoreGraphics
import Foundation
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
    let url: URL
    var thumbnail: CGImage?
    var originalBytes: Int
    var finalBytes: Int?
    var status: Status = .pending

    var filename: String { url.lastPathComponent }

    var isInFlight: Bool { status == .pending || status == .processing }

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

    private var toastTask: Task<Void, Never>?
    private var hadPendingWork = false

    func clearFinished() {
        items.removeAll { !$0.isInFlight }
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
        updateDockBadge()
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func add(urls: [URL], quality: Double) {
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
            let plural = skipped == 1 ? "" : "s"
            showToast(files.isEmpty
                ? "No supported images — skipped \(skipped) file\(plural)"
                : "Skipped \(skipped) unsupported file\(plural)")
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
        process(batch: newItems, quality: quality)
    }

    // MARK: - Processing

    private func process(batch: [ImageItem], quality: Double) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
                var next = 0
                while next < min(width, batch.count) {
                    let item = batch[next]
                    next += 1
                    group.addTask { await self.processOne(item, quality: quality) }
                }
                for await _ in group where next < batch.count {
                    let item = batch[next]
                    next += 1
                    group.addTask { await self.processOne(item, quality: quality) }
                }
            }
        }
    }

    nonisolated private func processOne(_ item: ImageItem, quality: Double) async {
        let thumbnail = Compressor.thumbnail(for: item.url)
        await MainActor.run {
            self.update(item.id) {
                $0.thumbnail = thumbnail
                $0.status = .processing
            }
        }
        do {
            let outcome = try Compressor.optimize(fileURL: item.url, quality: quality)
            await MainActor.run {
                self.update(item.id) {
                    $0.originalBytes = outcome.originalBytes
                    $0.finalBytes = outcome.finalBytes
                    $0.status = outcome.replaced ? .done : .unchanged
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
            ? "Done — saved \(Formatters.bytes(saved))"
            : "Done — files were already optimal")
    }

    // MARK: - File helpers

    private static func isSupported(_ url: URL) -> Bool {
        Compressor.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
