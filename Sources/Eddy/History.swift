import Foundation
import LeafiyUICore

/// One successful compression (the file was replaced with a smaller or
/// converted result). Unchanged and failed runs are not history.
struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// Absolute path; a plain string so entries survive files that later move
    /// or disappear.
    var path: String
    var originalBytes: Int
    var finalBytes: Int
    /// "4032×3024 → 1080×810" as shown in the main window row.
    var dimensions: String?
    var date: Date

    init(
        id: UUID = UUID(),
        path: String,
        originalBytes: Int,
        finalBytes: Int,
        dimensions: String? = nil,
        date: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.originalBytes = originalBytes
        self.finalBytes = finalBytes
        self.dimensions = dimensions
        self.date = date
    }

    var url: URL { URL(fileURLWithPath: path) }

    var filename: String { url.lastPathComponent }

    var savedFraction: Double {
        guard originalBytes > 0 else { return 0 }
        return 1 - Double(finalBytes) / Double(originalBytes)
    }
}

/// The persisted history document — one plain JSON file next to settings.json,
/// read and written through the Base Library Settings Store so it shares the
/// same atomic-write and corrupt-file-falls-back-to-defaults behavior.
struct HistoryDocument: Codable, Equatable, LeafiyAppSettings {
    var entries: [HistoryEntry] = []

    static var defaults: HistoryDocument { HistoryDocument() }

    func normalized() -> HistoryDocument {
        var normalized = self
        if normalized.entries.count > HistoryStore.maxEntries {
            normalized.entries = Array(normalized.entries.prefix(HistoryStore.maxEntries))
        }
        return normalized
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Local storage cap; the newest entries win.
    static let maxEntries = 500

    @Published private(set) var entries: [HistoryEntry]

    private let store: LeafiySettingsStore<HistoryDocument>

    /// `~/Library/Application Support/Eddy/history.json`.
    nonisolated static func standardFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Eddy", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    init(fileURL: URL? = nil) {
        store = LeafiySettingsStore(fileURL: fileURL ?? Self.standardFileURL())
        entries = store.load().entries
    }

    var totalSavedBytes: Int {
        entries.reduce(0) { $0 + ($1.originalBytes - $1.finalBytes) }
    }

    func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        persist()
    }

    func remove(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        do {
            try store.save(HistoryDocument(entries: entries))
        } catch {
            NSLog("Eddy: failed to save history: %@", String(describing: error))
        }
    }
}
