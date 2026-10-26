import Foundation

/// Saved routing: app bundle ID -> output device UID. Apps not listed use the system default output.
struct AppRoutingSettings: Codable, Equatable, Sendable {
    var routes: [String: String] = [:]
}

protocol SettingsStore {
    func load() -> AppRoutingSettings
    func save(_ settings: AppRoutingSettings)
}

/// Stores settings as JSON under one UserDefaults key. Missing or corrupt data loads as empty settings.
final class UserDefaultsSettingsStore: SettingsStore {
    static let defaultKey = "AppRoutingSettings"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = UserDefaultsSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AppRoutingSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppRoutingSettings.self, from: data)
        else { return AppRoutingSettings() }
        return settings
    }

    func save(_ settings: AppRoutingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
