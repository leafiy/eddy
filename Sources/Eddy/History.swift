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
    /// Where the Intake Original lived when it was handed in — differs from
    /// `path` only when a format conversion changed the extension. nil on
    /// entries recorded before restore existed.
    var originalPath: String?
    /// Filename of the Intake Original inside the originals directory;
    /// nil means this entry cannot be restored.
    var backupFilename: String?

    init(
        id: UUID = UUID(),
        path: String,
        originalBytes: Int,
        finalBytes: Int,
        dimensions: String? = nil,
        date: Date = Date(),
        originalPath: String? = nil,
        backupFilename: String? = nil
    ) {
        self.id = id
        self.path = path
        self.originalBytes = originalBytes
        self.finalBytes = finalBytes
        self.dimensions = dimensions
        self.date = date
        self.originalPath = originalPath
        self.backupFilename = backupFilename
    }

    var url: URL { URL(fileURLWithPath: path) }

    var filename: String { url.lastPathComponent }

    var isRestorable: Bool { backupFilename != nil }

    var savedFraction: Double {
        guard originalBytes > 0 else { return 0 }
        return 1 - Double(finalBytes) / Double(originalBytes)
    }
}

/// The persisted history document — one plain JSON file next to settings.json,
/// read and written through the Base Library Settings Store so it shares the
/// same atomic-write and corrupt-file-falls-back-to-defaults behavior.
struct HistoryDocument: Codable, Equatable, LeafiyAppSettings {
    /// Local storage cap; the newest entries win.
    static let maxEntries = 500

    var entries: [HistoryEntry] = []

    static var defaults: HistoryDocument { HistoryDocument() }

    func normalized() -> HistoryDocument {
        var normalized = self
        if normalized.entries.count > Self.maxEntries {
            normalized.entries = Array(normalized.entries.prefix(Self.maxEntries))
        }
        return normalized
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry]
    /// Whether the main window's history panel is showing. Runtime-only
    /// presentation state (daisy keeps the same flag on its history object).
    @Published var isPresented = false

    private let store: LeafiySettingsStore<HistoryDocument>
    /// Backup storage whose files live and die with these entries.
    private let originals: Originals

    /// `~/Library/Application Support/Eddy/history.json`.
    nonisolated static func standardFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Eddy", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    init(fileURL: URL? = nil, originals: Originals = .standard) {
        store = LeafiySettingsStore(fileURL: fileURL ?? Self.standardFileURL())
        self.originals = originals
        entries = store.load().entries
    }

    var totalSavedBytes: Int {
        entries.reduce(0) { $0 + ($1.originalBytes - $1.finalBytes) }
    }

    func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > HistoryDocument.maxEntries {
            let evicted = entries.suffix(entries.count - HistoryDocument.maxEntries)
            for old in evicted {
                originals.deleteBackup(old.backupFilename)
            }
            entries.removeLast(evicted.count)
        }
        persist()
    }

    func remove(_ id: HistoryEntry.ID) {
        if let entry = entries.first(where: { $0.id == id }) {
            originals.deleteBackup(entry.backupFilename)
        }
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Image editing can introduce alpha and move an opaque source to a PNG.
    /// Keep the existing compression record pointed at the live output so its
    /// reveal, re-compress and restore actions continue to work.
    func updateOutputPath(_ id: HistoryEntry.ID, path: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].path = path
        persist()
    }

    func clear() {
        for entry in entries {
            originals.deleteBackup(entry.backupFilename)
        }
        entries.removeAll()
        persist()
    }

    /// Backup filenames still referenced by live entries — everything else
    /// in the originals directory is an orphan (launch-time sweep).
    var referencedBackupFilenames: Set<String> {
        Set(entries.compactMap(\.backupFilename))
    }

    private func persist() {
        do {
            try store.save(HistoryDocument(entries: entries))
        } catch {
            NSLog("Eddy: failed to save history: %@", String(describing: error))
        }
    }
}
