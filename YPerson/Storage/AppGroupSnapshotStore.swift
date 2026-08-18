import Foundation
import WidgetKit

final class AppGroupSnapshotStore {
    private enum Key {
        static let widgetSnapshot = "widget_snapshot"
        static let remoteConfiguration = "remote_configuration"
        static let remoteConfigurationETag = "remote_configuration_etag"
        static let analyticsConsent = "analytics_consent"
        static let profileDeletionPending = "profile_deletion_pending"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?(appGroupIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        self.defaults = defaults
    }

    func readWidgetSnapshot() -> WidgetSnapshot {
        guard let data = defaults.data(forKey: Key.widgetSnapshot),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    func writeWidgetSnapshot(_ snapshot: WidgetSnapshot) throws {
        defaults.set(try encoder.encode(snapshot), forKey: Key.widgetSnapshot)
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
        defaults.removeObject(forKey: Key.widgetSnapshot)
        defaults.removeObject(forKey: Key.remoteConfiguration)
        defaults.removeObject(forKey: Key.remoteConfigurationETag)
        defaults.removeObject(forKey: Key.analyticsConsent)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
