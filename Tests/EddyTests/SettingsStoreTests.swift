import Foundation
import XCTest
import LeafiyUICore
@testable import eddy

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testSettingsStoreRoundTripPersistsAppSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: fileURL)
        let settings = AppSettings(
            compressionQuality: 65,
            resizeMaxWidth: 1200,
            defaultSaveFormat: .jpeg,
            appLanguage: "zh-Hans",
            launchAtLogin: true,
            applicationIconMode: .dock,
            quickShare: QuickShareSettings(
                provider: .s3,
                endpointURL: "https://account-id.r2.cloudflarestorage.com",
                region: "auto",
                bucket: "public-images",
                keyPrefix: "eddy/shared",
                accessKeyID: "AKIAEDDY",
                secretAccessKey: "plain-secret"
            )
        )

        try store.save(settings)

        let data = try Data(contentsOf: fileURL)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["compressionQuality"] as? Double, 65)
        XCTAssertEqual(payload["resizeMaxWidth"] as? Int, 1200)
        XCTAssertEqual(payload["defaultSaveFormat"] as? String, "jpeg")
        XCTAssertEqual(payload["appLanguage"] as? String, "zh-Hans")
        XCTAssertEqual(payload["launchAtLogin"] as? Bool, true)
        XCTAssertEqual(payload["applicationIconMode"] as? String, "dock")
        let quickShare = try XCTUnwrap(payload["quickShare"] as? [String: Any])
        XCTAssertEqual(quickShare["provider"] as? String, "s3")
        XCTAssertEqual(quickShare["endpointURL"] as? String, "https://account-id.r2.cloudflarestorage.com")
        XCTAssertEqual(quickShare["region"] as? String, "auto")
        XCTAssertEqual(quickShare["bucket"] as? String, "public-images")
        XCTAssertEqual(quickShare["keyPrefix"] as? String, "eddy/shared")
        XCTAssertEqual(quickShare["accessKeyID"] as? String, "AKIAEDDY")
        XCTAssertEqual(quickShare["secretAccessKey"] as? String, "plain-secret")

        let loaded = SettingsStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded, settings)
    }

    func testAppSettingsDecodingDefaultsMissingOptionalSettingsAndPreservesValues() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(missing.launchAtLogin)
        XCTAssertEqual(missing.applicationIconMode, .menuBar)

        let configured = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"launchAtLogin":true,"applicationIconMode":"dock"}"#.utf8)
        )
        XCTAssertTrue(configured.launchAtLogin)
        XCTAssertEqual(configured.applicationIconMode, .dock)

        let roundTripped = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(configured)
        )
        XCTAssertTrue(roundTripped.launchAtLogin)
        XCTAssertEqual(roundTripped.applicationIconMode, .dock)

        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"showDockIcon":true}"#.utf8)
        )
        XCTAssertEqual(legacy.applicationIconMode, .menuBar)
    }

    func testMigrationAdoptsLegacyUserDefaultsValues() throws {
        let suiteName = "eddy-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(65.0, forKey: "compressionQuality")
        defaults.set(1200, forKey: "resizeMaxWidth")
        defaults.set("jpeg", forKey: "defaultSaveFormat")
        defaults.set("zh-Hans", forKey: "appLanguage")

        let migrated = AppSettings.migratedFromLegacyDefaults(defaults)
        XCTAssertEqual(migrated.compressionQuality, 65)
        XCTAssertEqual(migrated.resizeMaxWidth, 1200)
        XCTAssertEqual(migrated.defaultSaveFormat, .jpeg)
        XCTAssertEqual(migrated.appLanguage, "zh-Hans")
    }

    func testMigrationWithoutLegacyValuesYieldsDefaults() throws {
        let suiteName = "eddy-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppSettings.migratedFromLegacyDefaults(defaults), AppSettings.defaults)
    }
}
