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

    var savedFraction: Double? {
        guard let finalBytes, originalBytes > 0 else { return nil }
        return 1 - Double(finalBytes) / Double(originalBytes)
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var items: [ImageItem] = []

    func clearFinished() {
        items.removeAll { $0.status != .pending && $0.status != .processing }
    }

    func add(urls: [URL], quality: Double) {
        let files = Self.expand(urls)
        guard !files.isEmpty else { return }
        let newItems = files.map { url in
            ImageItem(url: url, thumbnail: nil, originalBytes: Self.fileSize(url))
        }
        items.append(contentsOf: newItems)
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
    }

    // MARK: - File discovery

    private static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey]
                ) else { continue }
                for case let child as URL in enumerator where isSupported(child) {
                    result.append(child)
                }
            } else if isSupported(url) {
                result.append(url)
            }
        }
        return result
    }

    private static func isSupported(_ url: URL) -> Bool {
        Compressor.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
