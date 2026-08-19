import Foundation
import WidgetKit

final class AppGroupSnapshotStore {
    private enum Key {
        static let ownCard = "yperson.v1.own_card"
        static let remoteConfiguration = "yperson.v1.remote_configuration"
        static let remoteConfigurationETag = "yperson.v1.remote_configuration_etag"
        static let analyticsConsent = "yperson.v1.analytics_consent"
        static let profileDeletionPending = "yperson.v1.profile_deletion_pending"

        enum Legacy {
            static let ownCard = "own_card"
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

    func readWidgetSnapshot() -> WidgetSnapshot {
        WidgetSnapshotStorage.read(from: defaults) ?? .empty
    }

    func writeWidgetSnapshot(_ snapshot: WidgetSnapshot) throws {
        defaults.set(
            try WidgetSnapshotStorage.encode(snapshot),
            forKey: WidgetSnapshotStorage.currentKey
        )
        WidgetCenter.shared.reloadAllTimelines()
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
            WidgetSnapshotStorage.currentKey,
            Key.remoteConfiguration,
            Key.remoteConfigurationETag,
            Key.analyticsConsent,
            Key.Legacy.ownCard,
            WidgetSnapshotStorage.legacyKey,
            Key.Legacy.remoteConfiguration,
            Key.Legacy.remoteConfigurationETag,
            Key.Legacy.analyticsConsent
        ]
        removableKeys.forEach(defaults.removeObject(forKey:))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func migrateLegacyValues() {
        migrateCodable(
            PersonCard.self,
            from: Key.Legacy.ownCard,
            to: Key.ownCard
        )
        migrateWidgetSnapshot()
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

    private func migrateWidgetSnapshot() {
        guard defaults.object(forKey: WidgetSnapshotStorage.currentKey) == nil,
              let data = defaults.data(forKey: WidgetSnapshotStorage.legacyKey),
              let snapshot = WidgetSnapshotStorage.decode(data),
              let encoded = try? WidgetSnapshotStorage.encode(snapshot) else {
            return
        }
        defaults.set(encoded, forKey: WidgetSnapshotStorage.currentKey)
        defaults.removeObject(forKey: WidgetSnapshotStorage.legacyKey)
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
