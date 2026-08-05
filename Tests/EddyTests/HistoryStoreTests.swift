import Foundation
import XCTest
@testable import eddy

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private func entry(_ name: String, original: Int = 1000, final: Int = 400) -> HistoryEntry {
        HistoryEntry(path: "/tmp/\(name).png", originalBytes: original, finalBytes: final)
    }

    func testRecordInsertsNewestFirstAndPersistsAcrossLoads() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = HistoryStore(fileURL: fileURL)
        store.record(entry("first"))
        store.record(entry("second"))

        XCTAssertEqual(store.entries.map(\.filename), ["second.png", "first.png"])

        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    func testSavedFractionAndTotalSavedBytes() {
        let saved = entry("saved", original: 1000, final: 400)
        XCTAssertEqual(saved.savedFraction, 0.6, accuracy: 0.0001)

        // Format conversion can grow a file; the fraction goes negative.
        let grew = entry("grew", original: 400, final: 500)
        XCTAssertEqual(grew.savedFraction, -0.25, accuracy: 0.0001)

        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: fileURL)
        store.record(saved)
        store.record(grew)
        XCTAssertEqual(store.totalSavedBytes, 600 - 100)
    }

    func testHistoryIsCappedAtMaxEntriesKeepingNewest() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = HistoryStore(fileURL: fileURL)
        for index in 0...(HistoryDocument.maxEntries + 4) {
            store.record(entry("file-\(index)"))
        }

        XCTAssertEqual(store.entries.count, HistoryDocument.maxEntries)
        XCTAssertEqual(store.entries.first?.filename, "file-\(HistoryDocument.maxEntries + 4).png")
        // The oldest overflowed entries are gone.
        XCTAssertFalse(store.entries.contains { $0.filename == "file-0.png" })

        let reloaded = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.entries.count, HistoryDocument.maxEntries)
    }

    func testLoadTrimsOversizedPersistedDocument() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let oversized = HistoryDocument(
            entries: (0...(HistoryDocument.maxEntries + 9)).map { entry("file-\($0)") }
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(oversized).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL)
        XCTAssertEqual(store.entries.count, HistoryDocument.maxEntries)
        // normalized() keeps the head of the list — the newest entries.
        XCTAssertEqual(store.entries.first?.filename, "file-0.png")
    }

    func testUnreadableFileFallsBackToEmptyHistory() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertTrue(HistoryStore(fileURL: fileURL).entries.isEmpty)
    }

    func testRemoveAndClearPersist() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = HistoryStore(fileURL: fileURL)
        let kept = entry("kept")
        let removed = entry("removed")
        store.record(kept)
        store.record(removed)

        store.remove(removed.id)
        XCTAssertEqual(store.entries, [kept])
        XCTAssertEqual(HistoryStore(fileURL: fileURL).entries, [kept])

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(HistoryStore(fileURL: fileURL).entries.isEmpty)
    }

    func testUpdatingOutputPathPersistsAfterAlphaConversion() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = HistoryStore(fileURL: fileURL)
        let original = entry("subject")
        store.record(original)
        store.updateOutputPath(original.id, path: "/tmp/subject-background.png")

        XCTAssertEqual(store.entries.first?.path, "/tmp/subject-background.png")
        XCTAssertEqual(
            HistoryStore(fileURL: fileURL).entries.first?.path,
            "/tmp/subject-background.png"
        )
    }
}
