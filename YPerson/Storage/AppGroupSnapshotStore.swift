import Foundation

final class AppGroupSnapshotStore {
    private enum Key {
        static let ownCard = "yperson.v1.own_card"
        static let obsoleteWidgetSnapshot = "yperson.v1.widget_snapshot"
        static let remoteConfiguration = "yperson.v1.remote_configuration"
        static let remoteConfigurationETag = "yperson.v1.remote_configuration_etag"
        static let analyticsConsent = "yperson.v1.analytics_consent"
        static let profileDeletionPending = "yperson.v1.profile_deletion_pending"

        enum Legacy {
            static let ownCard = "own_card"
            static let obsoleteWidgetSnapshot = "widget_snapshot"
            static let remoteConfiguration = "remote_configuration"
            static let remoteConfigurationETag = "remote_configuration_etag"
            static let analyticsConsent = "analytics_consent"
            static let profileDeletionPending = "profile_deletion_pending"
        }
    }

    func readOwnCard() -> PersonCard? {
        guard let data = defaults.data(forKey: Key.ownCard) else { return nil }
        return try? decoder.decode(PersonCard.self, from: data)
    }

    func writeOwnCard(_ card: PersonCard) throws {
        defaults.set(try encoder.encode(card), forKey: Key.ownCard)
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?(appGroupIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        self.defaults = defaults
        migrateLegacyValues()
    }

    func cachedConfiguration() -> (RemoteConfiguration, String?)? {
        guard let data = defaults.data(forKey: Key.remoteConfiguration),
              let config = try? decoder.decode(RemoteConfiguration.self, from: data) else { return nil }
        return (config, defaults.string(forKey: Key.remoteConfigurationETag))
    }

    func cacheConfiguration(_ configuration: RemoteConfiguration, etag: String?) throws {
        defaults.set(try encoder.encode(configuration), forKey: Key.remoteConfiguration)
        defaults.set(etag, forKey: Key.remoteConfigurationETag)
    }

    var analyticsConsent: Bool {
        get { defaults.bool(forKey: Key.analyticsConsent) }
        set { defaults.set(newValue, forKey: Key.analyticsConsent) }
    }

    var profileDeletionPending: Bool {
        get { defaults.bool(forKey: Key.profileDeletionPending) }
        set { defaults.set(newValue, forKey: Key.profileDeletionPending) }
    }

    func clearUserData() {
        let removableKeys = [
            Key.ownCard,
            Key.obsoleteWidgetSnapshot,
            Key.remoteConfiguration,
            Key.remoteConfigurationETag,
            Key.analyticsConsent,
            Key.Legacy.ownCard,
            Key.Legacy.obsoleteWidgetSnapshot,
            Key.Legacy.remoteConfiguration,
            Key.Legacy.remoteConfigurationETag,
            Key.Legacy.analyticsConsent
        ]
        removableKeys.forEach(defaults.removeObject(forKey:))
    }

    private func migrateLegacyValues() {
        migrateCodable(
            PersonCard.self,
            from: Key.Legacy.ownCard,
            to: Key.ownCard
        )
        migrateCodable(
            RemoteConfiguration.self,
            from: Key.Legacy.remoteConfiguration,
            to: Key.remoteConfiguration
        )
        migrateString(
            from: Key.Legacy.remoteConfigurationETag,
            to: Key.remoteConfigurationETag
        )
        migrateBool(
            from: Key.Legacy.analyticsConsent,
            to: Key.analyticsConsent
        )
        migrateBool(
            from: Key.Legacy.profileDeletionPending,
            to: Key.profileDeletionPending
        )
    }

    private func migrateCodable<Value: Decodable>(
        _ type: Value.Type,
        from legacyKey: String,
        to currentKey: String
    ) {
        guard defaults.object(forKey: currentKey) == nil,
              let data = defaults.data(forKey: legacyKey),
              (try? decoder.decode(type, from: data)) != nil else {
            return
        }
        defaults.set(data, forKey: currentKey)
        defaults.removeObject(forKey: legacyKey)
    }

    private func migrateString(from legacyKey: String, to currentKey: String) {
        guard defaults.object(forKey: currentKey) == nil,
              let value = defaults.string(forKey: legacyKey) else {
            return
        }
        defaults.set(value, forKey: currentKey)
        defaults.removeObject(forKey: legacyKey)
    }

    private func migrateBool(from legacyKey: String, to currentKey: String) {
        guard defaults.object(forKey: currentKey) == nil,
              let value = defaults.object(forKey: legacyKey) as? NSNumber else {
            return
        }
        defaults.set(value.boolValue, forKey: currentKey)
        defaults.removeObject(forKey: legacyKey)
    }
}
