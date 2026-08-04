import Foundation
import XCTest
@testable import eddy

final class OriginalsTests: XCTestCase {
    private var workDirectory: URL!
    private var originals: Originals!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        originals = Originals(directory: workDirectory.appendingPathComponent("originals", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Backup & restore

    func testRestorePutsIntakeOriginalBytesBack() throws {
        let file = try writeFile("photo.jpg", "intake original bytes")
        let backup = try originals.createBackup(of: file)
        XCTAssertTrue(backup.hasSuffix(".jpg"), "backup keeps the original extension")

        // Simulate the compression replace, then the one-step restore.
        try Data("compressed".utf8).write(to: file)
        try originals.restore(backupFilename: backup, originalPath: file.path, outputPath: file.path)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "intake original bytes")
    }

    func testRestoreRecreatesOriginalAndRemovesConversionArtifact() throws {
        let png = try writeFile("art.png", "png bytes")
        let backup = try originals.createBackup(of: png)

        // Simulate a PNG → JPEG conversion: the original is gone,
        // the artifact lives next to it under a new extension.
        try FileManager.default.removeItem(at: png)
        let jpg = try writeFile("art.jpg", "jpeg bytes")

        try originals.restore(backupFilename: backup, originalPath: png.path, outputPath: jpg.path)

        XCTAssertEqual(try String(contentsOf: png, encoding: .utf8), "png bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpg.path), "conversion artifact is deleted")
    }

    func testRestoreThrowsWhenBackupIsMissing() throws {
        let file = try writeFile("photo.jpg", "bytes")
        XCTAssertThrowsError(
            try originals.restore(backupFilename: "missing.jpg", originalPath: file.path, outputPath: file.path)
        ) { error in
            XCTAssertTrue(error is RestoreError)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "bytes", "a failed restore never touches the file")
    }

    func testCleanupOrphansOnlyDeletesUnreferencedBackups() throws {
        let first = try originals.createBackup(of: writeFile("a.png", "a"))
        let second = try originals.createBackup(of: writeFile("b.png", "b"))

        originals.cleanupOrphans(keeping: [first])

        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.backupURL(filename: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.backupURL(filename: second).path))
    }

    // MARK: - Backup lifecycle follows history entries

    @MainActor
    func testRemovingAndClearingEntriesDeletesTheirBackups() throws {
        let store = HistoryStore(
            fileURL: workDirectory.appendingPathComponent("history.json"),
            originals: originals
        )
        let firstBackup = try originals.createBackup(of: writeFile("one.png", "1"))
        let secondBackup = try originals.createBackup(of: writeFile("two.png", "2"))
        let first = HistoryEntry(
            path: "/tmp/one.png", originalBytes: 10, finalBytes: 5, backupFilename: firstBackup)
        let second = HistoryEntry(
            path: "/tmp/two.png", originalBytes: 10, finalBytes: 5, backupFilename: secondBackup)
        store.record(first)
        store.record(second)

        store.remove(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.backupURL(filename: firstBackup).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originals.backupURL(filename: secondBackup).path))

        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.backupURL(filename: secondBackup).path))
    }

    @MainActor
    func testEvictionAtCapDeletesTheEvictedEntrysBackup() throws {
        let store = HistoryStore(
            fileURL: workDirectory.appendingPathComponent("history.json"),
            originals: originals
        )
        let oldestBackup = try originals.createBackup(of: writeFile("oldest.png", "old"))
        store.record(HistoryEntry(
            path: "/tmp/oldest.png", originalBytes: 10, finalBytes: 5, backupFilename: oldestBackup))
        for index in 0..<HistoryDocument.maxEntries {
            store.record(HistoryEntry(path: "/tmp/f\(index).png", originalBytes: 10, finalBytes: 5))
        }

        XCTAssertEqual(store.entries.count, HistoryDocument.maxEntries)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originals.backupURL(filename: oldestBackup).path),
            "evicted entry's backup is deleted with it"
        )
    }

    @MainActor
    func testReferencedBackupFilenamesListsLiveEntriesOnly() throws {
        let store = HistoryStore(
            fileURL: workDirectory.appendingPathComponent("history.json"),
            originals: originals
        )
        store.record(HistoryEntry(path: "/tmp/a.png", originalBytes: 10, finalBytes: 5, backupFilename: "a.png"))
        store.record(HistoryEntry(path: "/tmp/b.png", originalBytes: 10, finalBytes: 5))

        XCTAssertEqual(store.referencedBackupFilenames, ["a.png"])
    }
}
