import Foundation

enum RestoreError: LocalizedError {
    case backupMissing

    var errorDescription: String? {
        switch self {
        case .backupMissing: return L("Backup file is missing — cannot restore")
        }
    }
}

/// Storage for Intake Originals — the exact bytes of a file before Eddy's
/// first destructive operation on it (see CONTEXT.md and ADR-0001).
///
/// One flat directory of `<UUID>.<original extension>` files. A backup
/// created by compression lives exactly as long as its history entry
/// (HistoryStore deletes it alongside the entry); a backup created by a
/// crop alone has no entry and is swept as an orphan on the next launch.
struct Originals {
    /// `~/Library/Application Support/Eddy/originals/`, next to history.json.
    static let standard = Originals(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Eddy/originals", isDirectory: true)
    )

    let directory: URL

    func backupURL(filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Copies the file's current bytes into the originals directory and
    /// returns the backup's filename. Called immediately before the first
    /// destructive operation, while the intake bytes still exist.
    func createBackup(of fileURL: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = fileURL.pathExtension
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        try fm.copyItem(at: fileURL, to: backupURL(filename: filename))
        return filename
    }

    /// Restores the Intake Original: atomically puts the backup's bytes back
    /// at `originalPath` (the path the user handed in) and, when a format
    /// conversion moved the result elsewhere, deletes the conversion
    /// artifact at `outputPath`. The backup file itself is kept — deleting
    /// it (and the history entry) is the caller's bookkeeping.
    func restore(backupFilename: String, originalPath: String, outputPath: String) throws {
        let fm = FileManager.default
        let backup = backupURL(filename: backupFilename)
        guard fm.fileExists(atPath: backup.path) else { throw RestoreError.backupMissing }

        let originalURL = URL(fileURLWithPath: originalPath)
        // Stage next to the destination so the swap is atomic on the same
        // volume — the same pattern Compressor.optimize uses.
        let staging = originalURL
            .deletingLastPathComponent()
            .appendingPathComponent(".eddy-\(UUID().uuidString).tmp")
        try fm.copyItem(at: backup, to: staging)
        do {
            if fm.fileExists(atPath: originalPath) {
                _ = try fm.replaceItemAt(originalURL, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: originalURL)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        if outputPath != originalPath {
            try? fm.removeItem(at: URL(fileURLWithPath: outputPath))
        }
    }

    func deleteBackup(_ filename: String?) {
        guard let filename else { return }
        try? FileManager.default.removeItem(at: backupURL(filename: filename))
    }

    /// Launch-time sweep: every file not referenced by a history entry is
    /// an orphan — a crop-only backup from a past session, or residue from
    /// a crash between a backup write and its entry's persist.
    func cleanupOrphans(keeping referenced: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !referenced.contains(file) {
            try? fm.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
