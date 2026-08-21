import Foundation

final class AppGroupSnapshotStore {
    private enum Key {
        static let ownCard = "yperson.v1.own_card"
        static let obsoleteWidgetSnapshot = "yperson.v1.widget_snapshot"
        static let remoteConfiguration = "yperson.v1.remote_configuration"
        static let remoteConfigurationETag = "yperson.v1.remote_configuration_etag"
        static let analyticsConsent = "yperson.v1.analytics_consent"
        static let profileDeletionPending = "yperson.v1.profile_deletion_pending"
        static let people = "yperson.v2.people"
        static let syncCursor = "yperson.v2.sync_cursor"
        static let pendingOperationIDs = "yperson.v2.pending_operation_ids"
        static let pendingOperations = "yperson.v2.pending_operations"
        static let pendingAPNSToken = "yperson.v2.pending_apns_token"
        static let pendingAPNSRemoval = "yperson.v2.pending_apns_removal"
        static let profileTerminallyDeleted = "yperson.v2.profile_terminally_deleted"
        static let publicLinkToken = "yperson.v2.public_link_token"
        static let publicLinkActive = "yperson.v2.public_link_active"

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

    func readPeople() -> [PersonCard] {
        guard let data = defaults.data(forKey: Key.people),
              let people = try? decoder.decode([PersonCard].self, from: data) else {
            return []
        }
        return people
    }

    func upsertPerson(_ card: PersonCard) throws {
        var people = readPeople()
        if let index = people.firstIndex(where: { $0.id == card.id }) {
            guard card.version >= people[index].version else { return }
            var merged = card
            merged.meetingPlace = people[index].meetingPlace ?? card.meetingPlace
            people[index] = merged
        } else {
            people.append(card)
        }
        try storePeople(people)
    }

    func replacePeople(_ cards: [PersonCard]) throws {
        var mergedByID: [String: PersonCard] = [:]
        for local in readPeople() {
            if let existing = mergedByID[local.id], existing.version > local.version { continue }
            mergedByID[local.id] = local
        }
        for card in cards {
            guard let local = mergedByID[card.id] else {
                mergedByID[card.id] = card
                continue
            }
            guard card.syncState == .synced || card.version >= local.version else { continue }
            var merged = card
            merged.meetingPlace = local.meetingPlace ?? card.meetingPlace
            mergedByID[card.id] = merged
        }
        try storePeople(Array(mergedByID.values))
    }

    func removePerson(id: String) throws {
        try storePeople(readPeople().filter { $0.id != id })
    }

    func markPersonLocalOnly(id: String) throws {
        guard var card = readPeople().first(where: { $0.id == id }) else { return }
        card.syncState = .localOnly
        try upsertPerson(card)
    }

    var pendingOperations: [PendingSyncOperation] {
        get {
            guard let data = defaults.data(forKey: Key.pendingOperations) else { return [] }
            return (try? decoder.decode([PendingSyncOperation].self, from: data)) ?? []
        }
        set { defaults.set(try? encoder.encode(newValue), forKey: Key.pendingOperations) }
    }

    func enqueue(_ operation: PendingSyncOperation) {
        var operations = pendingOperations
        if let index = operations.firstIndex(where: { $0.id == operation.id }) {
            operations[index] = operation
        } else {
            operations.append(operation)
        }
        pendingOperations = operations
    }

    func removePendingOperation(id: String) {
        pendingOperations = pendingOperations.filter { $0.id != id }
    }

    var pendingAPNSToken: String? {
        get { defaults.string(forKey: Key.pendingAPNSToken) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.pendingAPNSToken) }
            else { defaults.removeObject(forKey: Key.pendingAPNSToken) }
        }
    }

    var pendingAPNSRemoval: Bool {
        get { defaults.bool(forKey: Key.pendingAPNSRemoval) }
        set { defaults.set(newValue, forKey: Key.pendingAPNSRemoval) }
    }

    var syncCursor: String? {
        get { defaults.string(forKey: Key.syncCursor) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.syncCursor)
            } else {
                defaults.removeObject(forKey: Key.syncCursor)
            }
        }
    }

    func pendingOperationID(for key: String, proposed: String) -> String {
        var operations = defaults.dictionary(forKey: Key.pendingOperationIDs) as? [String: String] ?? [:]
        if let existing = operations[key] { return existing }
        operations[key] = proposed
        defaults.set(operations, forKey: Key.pendingOperationIDs)
        return proposed
    }

    func clearPendingOperationID(for key: String) {
        var operations = defaults.dictionary(forKey: Key.pendingOperationIDs) as? [String: String] ?? [:]
        operations.removeValue(forKey: key)
        defaults.set(operations, forKey: Key.pendingOperationIDs)
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

    var profileTerminallyDeleted: Bool {
        get { defaults.bool(forKey: Key.profileTerminallyDeleted) }
        set { defaults.set(newValue, forKey: Key.profileTerminallyDeleted) }
    }

    var publicLinkToken: String? {
        get { defaults.string(forKey: Key.publicLinkToken) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.publicLinkToken) }
            else { defaults.removeObject(forKey: Key.publicLinkToken) }
        }
    }

    var publicLinkActive: Bool {
        get { defaults.bool(forKey: Key.publicLinkActive) }
        set { defaults.set(newValue, forKey: Key.publicLinkActive) }
    }

    func clearUserData() {
        let removableKeys = [
            Key.ownCard,
            Key.obsoleteWidgetSnapshot,
            Key.remoteConfiguration,
            Key.remoteConfigurationETag,
            Key.analyticsConsent,
            Key.people,
            Key.syncCursor,
            Key.pendingOperationIDs,
            Key.pendingOperations,
            Key.pendingAPNSToken,
            Key.pendingAPNSRemoval,
            Key.publicLinkToken,
            Key.publicLinkActive,
            Key.Legacy.ownCard,
            Key.Legacy.obsoleteWidgetSnapshot,
            Key.Legacy.remoteConfiguration,
            Key.Legacy.remoteConfigurationETag,
            Key.Legacy.analyticsConsent
        ]
        removableKeys.forEach(defaults.removeObject(forKey:))
    }

    private func storePeople(_ people: [PersonCard]) throws {
        let ordered = people.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        defaults.set(try encoder.encode(ordered), forKey: Key.people)
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
