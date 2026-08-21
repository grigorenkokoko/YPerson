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
        static let profileDeletionRecord = "yperson.v3.profile_deletion_record"
        static let cardPublicationJournal = "yperson.v4.card_publication_journal"
        static let pendingPushTokenSyncRecord = "yperson.v4.pending_push_token_sync_record"
        static let pendingAudioCardCommitRecord = "yperson.v5.pending_audio_card_commit_record"

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

    @discardableResult
    func writeOwnCardAndStagePublication(
        _ card: PersonCard,
        audioCommitIntent: AudioCardCommitIntent? = nil
    ) throws -> PendingSyncOperation {
        let operation = PendingSyncOperation(
            request: SyncRequest(operation: .publishCard, card: card.exchangeCopy),
            expiresAt: nil,
            localCardID: nil
        )
        let journal = CardPublicationJournal(
            card: card,
            operation: operation,
            audioCommitIntent: audioCommitIntent
        )
        defaults.set(try encoder.encode(journal), forKey: Key.cardPublicationJournal)
        try recoverPendingCardPublication()
        return operation
    }

    var pendingCardPublicationJournal: CardPublicationJournal? {
        get {
            guard let data = defaults.data(forKey: Key.cardPublicationJournal) else { return nil }
            return try? decoder.decode(CardPublicationJournal.self, from: data)
        }
        set {
            if let newValue {
                defaults.set(try? encoder.encode(newValue), forKey: Key.cardPublicationJournal)
            } else {
                defaults.removeObject(forKey: Key.cardPublicationJournal)
            }
        }
    }

    func recoverPendingCardPublication() throws {
        guard let journal = pendingCardPublicationJournal else { return }
        try writeOwnCard(journal.card)
        enqueue(journal.operation)
        if let intent = journal.audioCommitIntent {
            pendingAudioCardCommitRecord = PendingAudioCardCommitRecord(
                intent: intent,
                publicationOperationID: journal.operation.id,
                cardID: journal.card.id
            )
        } else {
            pendingAudioCardCommitRecord = nil
        }
        pendingCardPublicationJournal = nil
    }

    var pendingAudioCardCommitRecord: PendingAudioCardCommitRecord? {
        get {
            guard let data = defaults.data(forKey: Key.pendingAudioCardCommitRecord) else {
                return nil
            }
            return try? decoder.decode(PendingAudioCardCommitRecord.self, from: data)
        }
        set {
            if let newValue {
                defaults.set(
                    try? encoder.encode(newValue),
                    forKey: Key.pendingAudioCardCommitRecord
                )
            } else {
                defaults.removeObject(forKey: Key.pendingAudioCardCommitRecord)
            }
        }
    }

    @discardableResult
    func clearPendingAudioCardCommitRecord(
        ifCurrent record: PendingAudioCardCommitRecord
    ) -> Bool {
        guard pendingAudioCardCommitRecord == record else { return false }
        pendingAudioCardCommitRecord = nil
        return true
    }

    @discardableResult
    func writePublishedOwnCard(
        _ card: PersonCard,
        ifCurrent ownership: PublicationCardOwnership
    ) throws -> Bool {
        guard ownership.matches(readOwnCard()) else { return false }
        try writeOwnCard(card)
        return true
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
        set {
            let durable = PendingSyncOperationPersistencePolicy.durableOperations(from: newValue)
            defaults.set(try? encoder.encode(durable), forKey: Key.pendingOperations)
        }
    }

    func enqueue(_ operation: PendingSyncOperation) {
        guard PendingSyncOperationPersistencePolicy.allowsDurablePersistence(
            operation.request.operation
        ) else { return }
        var operations = pendingOperations
        if operation.request.operation == .publishCard {
            operations.removeAll {
                $0.request.operation == .publishCard && $0.id != operation.id
            }
        }
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

    func containsPendingOperation(id: String) -> Bool {
        pendingOperations.contains { $0.id == id }
    }

    @discardableResult
    func revalidatePendingPublication(_ operation: PendingSyncOperation) -> Bool {
        guard operation.request.operation == .publishCard,
              containsPendingOperation(id: operation.id),
              let queuedCard = operation.request.card,
              let currentCard = readOwnCard() else { return false }
        let ownership = PublicationCardOwnership(card: queuedCard.exchangeCopy)
        guard ownership.matches(currentCard.exchangeCopy) else {
            enqueue(PendingSyncOperation(
                request: SyncRequest(
                    operation: .publishCard,
                    card: currentCard.exchangeCopy
                ),
                expiresAt: nil,
                localCardID: nil
            ))
            return false
        }
        return true
    }

    func purgeNonDurablePendingOperations() {
        let operations = pendingOperations
        let durable = PendingSyncOperationPersistencePolicy.durableOperations(from: operations)
        guard operations != durable else { return }
        pendingOperations = durable
    }

    var pendingPushTokenSyncRecord: PendingPushTokenSyncRecord? {
        get {
            guard let data = defaults.data(forKey: Key.pendingPushTokenSyncRecord) else {
                return nil
            }
            return try? decoder.decode(PendingPushTokenSyncRecord.self, from: data)
        }
        set {
            if let newValue {
                defaults.set(try? encoder.encode(newValue), forKey: Key.pendingPushTokenSyncRecord)
            } else {
                defaults.removeObject(forKey: Key.pendingPushTokenSyncRecord)
            }
        }
    }

    @discardableResult
    func clearPendingPushTokenSyncRecord(
        ifCurrent record: PendingPushTokenSyncRecord
    ) -> Bool {
        guard pendingPushTokenSyncRecord == record else { return false }
        pendingPushTokenSyncRecord = nil
        return true
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

    func existingPendingOperationID(for key: String) -> String? {
        let operations = defaults.dictionary(forKey: Key.pendingOperationIDs) as? [String: String]
        return operations?[key]
    }

    private let defaults: any SnapshotKeyValueStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?(appGroupIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        self.defaults = defaults
        migrateLegacyValues()
        migrateLegacyPendingPushToken()
        try? recoverPendingCardPublication()
        purgeNonDurablePendingOperations()
    }

#if DEBUG
    private init(defaults: any SnapshotKeyValueStore) {
        self.defaults = defaults
    }

    static func inMemory() -> AppGroupSnapshotStore {
        AppGroupSnapshotStore(defaults: InMemorySnapshotKeyValueStore())
    }
#endif

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

    var profileDeletionRecord: ProfileDeletionRecord? {
        get {
            guard let data = defaults.data(forKey: Key.profileDeletionRecord) else { return nil }
            return try? decoder.decode(ProfileDeletionRecord.self, from: data)
        }
        set {
            if let newValue {
                defaults.set(try? encoder.encode(newValue), forKey: Key.profileDeletionRecord)
            } else {
                defaults.removeObject(forKey: Key.profileDeletionRecord)
            }
        }
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
            Key.cardPublicationJournal,
            Key.pendingPushTokenSyncRecord,
            Key.pendingAudioCardCommitRecord,
            Key.Legacy.ownCard,
            Key.Legacy.obsoleteWidgetSnapshot,
            Key.Legacy.remoteConfiguration,
            Key.Legacy.remoteConfigurationETag,
            Key.Legacy.analyticsConsent
        ]
        removableKeys.forEach(defaults.removeObject(forKey:))
    }

    private func migrateLegacyPendingPushToken() {
        guard pendingPushTokenSyncRecord == nil else {
            defaults.removeObject(forKey: Key.pendingAPNSToken)
            defaults.removeObject(forKey: Key.pendingAPNSRemoval)
            clearPendingOperationID(for: "apns-token")
            return
        }
        let removal = defaults.bool(forKey: Key.pendingAPNSRemoval)
        let token = defaults.string(forKey: Key.pendingAPNSToken)
        guard removal || token != nil else { return }
        let operationID = existingPendingOperationID(for: "apns-token")
            ?? UUID().uuidString.lowercased()
        if removal {
            pendingPushTokenSyncRecord = .removal(operationID: operationID)
        } else if let token {
            pendingPushTokenSyncRecord = .update(token: token, operationID: operationID)
        }
        defaults.removeObject(forKey: Key.pendingAPNSToken)
        defaults.removeObject(forKey: Key.pendingAPNSRemoval)
        clearPendingOperationID(for: "apns-token")
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

private protocol SnapshotKeyValueStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func string(forKey defaultName: String) -> String?
    func bool(forKey defaultName: String) -> Bool
    func dictionary(forKey defaultName: String) -> [String: Any]?
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: SnapshotKeyValueStore {}

#if DEBUG
private final class InMemorySnapshotKeyValueStore: SnapshotKeyValueStore {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? {
        value(forKey: defaultName) as? Data
    }

    func string(forKey defaultName: String) -> String? {
        value(forKey: defaultName) as? String
    }

    func bool(forKey defaultName: String) -> Bool {
        if let value = value(forKey: defaultName) as? Bool { return value }
        return (value(forKey: defaultName) as? NSNumber)?.boolValue ?? false
    }

    func dictionary(forKey defaultName: String) -> [String: Any]? {
        value(forKey: defaultName) as? [String: Any]
    }

    func object(forKey defaultName: String) -> Any? {
        value(forKey: defaultName)
    }

    func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: defaultName)
    }

    private func value(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName]
    }
}
#endif
