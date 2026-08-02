import Combine
import Foundation
import LeafiyUICore

struct AppSettings: Codable, Equatable, LeafiyAppSettings {
    var compressionQuality: Double
    var resizeMaxWidth: Int
    var defaultSaveFormat: SaveFormat
    var appLanguage: String
    var quickShare: QuickShareSettings

    static var defaults: AppSettings { AppSettings() }
    private static let defaultQuickShare = QuickShareSettings(keyPrefix: "eddy")

    init(
        compressionQuality: Double = 80,
        resizeMaxWidth: Int = 0,
        defaultSaveFormat: SaveFormat = .keep,
        appLanguage: String = AppLanguage.system.rawValue,
        quickShare: QuickShareSettings = AppSettings.defaultQuickShare
    ) {
        self.compressionQuality = compressionQuality
        self.resizeMaxWidth = resizeMaxWidth
        self.defaultSaveFormat = defaultSaveFormat
        self.appLanguage = appLanguage
        self.quickShare = quickShare
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.defaults
        compressionQuality = try container.decodeIfPresent(Double.self, forKey: .compressionQuality) ?? defaults.compressionQuality
        resizeMaxWidth = try container.decodeIfPresent(Int.self, forKey: .resizeMaxWidth) ?? defaults.resizeMaxWidth
        defaultSaveFormat = try container.decodeIfPresent(SaveFormat.self, forKey: .defaultSaveFormat) ?? defaults.defaultSaveFormat
        appLanguage = try container.decodeIfPresent(String.self, forKey: .appLanguage) ?? defaults.appLanguage
        quickShare = try container.decodeIfPresent(QuickShareSettings.self, forKey: .quickShare) ?? defaults.quickShare
    }

    func normalized() -> AppSettings {
        var normalized = self
        if !normalized.compressionQuality.isFinite {
            normalized.compressionQuality = AppSettings.defaults.compressionQuality
        }
        normalized.compressionQuality = min(max(normalized.compressionQuality, 10), 100)
        if !ResizeMaxWidthOption.all.contains(where: { $0.width == normalized.resizeMaxWidth }) {
            normalized.resizeMaxWidth = AppSettings.defaults.resizeMaxWidth
        }
        if AppLanguage(rawValue: normalized.appLanguage) == nil {
            normalized.appLanguage = AppLanguage.system.rawValue
        }
        return normalized
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings

    private let store: LeafiySettingsStore<AppSettings>

    nonisolated static func persistedAppLanguage(
        store: LeafiySettingsStore<AppSettings> = .standard(directoryName: "Eddy")
    ) -> AppLanguage {
        AppLanguage(rawValue: store.load().appLanguage) ?? .system
    }

    init(fileURL: URL? = nil) {
        let backingStore: LeafiySettingsStore<AppSettings>
        if let fileURL {
            backingStore = LeafiySettingsStore(fileURL: fileURL)
        } else {
            backingStore = .standard(directoryName: "Eddy")
        }
        self.store = backingStore
        settings = backingStore.load()
        applyLocalization()
    }

    var processingOptions: (quality: Double, maxWidth: Int, format: SaveFormat) {
        (settings.compressionQuality / 100, settings.resizeMaxWidth, settings.defaultSaveFormat)
    }

    @discardableResult
    func load() -> AppSettings {
        settings = store.load()
        applyLocalization()
        return settings
    }

    func save() {
        settings = settings.normalized()
        do {
            try store.save(settings)
            applyLocalization()
        } catch {
            NSLog("Eddy: failed to save settings: %@", String(describing: error))
        }
    }

    func save(_ settings: AppSettings) throws {
        self.settings = settings.normalized()
        try store.save(self.settings)
        applyLocalization()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        save()
    }

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: settings.appLanguage) ?? .system }
        set { update { $0.appLanguage = newValue.rawValue } }
    }

    private func applyLocalization() {
        LeafiyLocalization.language = appLanguage
    }
}
