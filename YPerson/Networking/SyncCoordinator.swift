import Foundation

@MainActor
final class SyncCoordinator {
    enum CoordinatorError: LocalizedError {
        case noProfile
        case ownCardNotPublished
        case deletionInProgress
        case expiredExchange
        case noAudio
        case localStorageUnavailable

        var errorDescription: String? {
            switch self {
            case .noProfile: return "Сначала сохраните свою визитку."
            case .ownCardNotPublished: return "Не удалось опубликовать вашу визитку для взаимного обмена."
            case .deletionInProgress: return "Дождитесь завершения удаления профиля."
            case .expiredExchange: return "Код обмена уже истёк. Карточка сохранена только на iPhone."
            case .noAudio: return "У этой визитки нет доступного аудиоприветствия."
            case .localStorageUnavailable: return "Защищённое локальное хранилище недоступно."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let snapshotStore: AppGroupSnapshotStore?
    private let credentialStore: any InstallationCredentialStoring
    private let mediaTransfer: MediaTransferClient
    private var apiClient: APIClient?
    private var bootstrapped = false
    private var profileOperationEpoch = ProfileOperationEpoch()
    private var profileLifecycle: ProfileLifecycle
    private var deletionRecord: ProfileDeletionRecord?
    private var deletionRequestInFlight = false

    var installationID: String? { apiClient?.installationID }
    var isProfileActive: Bool { profileLifecycle.state == .active }
    var onPeopleChanged: (() -> Void)?
    var onOwnCardChanged: ((PersonCard) -> Void)?
    var onProfileDeleted: (() -> Void)?
    var onAudioInvalidated: (() -> Void)?

    init(
        baseURL: URL,
        session: URLSession,
        snapshotStore: AppGroupSnapshotStore?,
        credentialStore: any InstallationCredentialStoring,
        mediaTransfer: MediaTransferClient
    ) throws {
        self.baseURL = baseURL
        self.session = session
        self.snapshotStore = snapshotStore
        self.credentialStore = credentialStore
        self.mediaTransfer = mediaTransfer
        let credential = try credentialStore.existingCredential()
        var recoveredDeletion = snapshotStore?.profileDeletionRecord
        if recoveredDeletion == nil, snapshotStore?.profileDeletionPending == true {
            let legacyOperationID = snapshotStore?.pendingOperations.first {
                $0.request.operation == .deleteProfile
            }?.id
            recoveredDeletion = ProfileDeletionRecord(
                operationID: legacyOperationID ?? UUID().uuidString.lowercased()
            )
            snapshotStore?.profileDeletionRecord = recoveredDeletion
        }
        self.deletionRecord = recoveredDeletion
        self.profileLifecycle = ProfileLifecycle(
            deletionRecord: recoveredDeletion,
            legacyDeletionPending: snapshotStore?.profileDeletionPending == true,
            terminallyDeleted: snapshotStore?.profileTerminallyDeleted == true
        )
        for operation in snapshotStore?.pendingOperations ?? []
            where operation.request.operation == .deleteProfile {
            snapshotStore?.removePendingOperation(id: operation.id)
        }
        if let credential {
            apiClient = APIClient(
                baseURL: baseURL,
                session: session,
                snapshotStore: snapshotStore,
                credential: credential
            )
        }
    }

    func fetchConfiguration() async throws -> RemoteConfiguration? {
        try await APIClient.fetchPublicConfiguration(
            baseURL: baseURL,
            session: session,
            snapshotStore: snapshotStore
        )
    }

    func captureProfileOperationContext() -> ProfileOperationContext? {
        guard !syncSuppressed else { return nil }
        return profileOperationEpoch.capture()
    }

    func isCurrentProfileOperationContext(_ context: ProfileOperationContext) -> Bool {
        !syncSuppressed && profileOperationEpoch.isCurrent(context)
    }

    func bootstrap(context: ProfileOperationContext?) async {
        if profileLifecycle.state == .deleting {
            await resumeDeletionIfNeeded()
            return
        }
        guard let context,
              isCurrentProfileOperationContext(context),
              let apiClient else { return }
        snapshotStore?.purgeNonDurablePendingOperations()
        do {
            let response = try await apiClient.sync(
                SyncRequest(operation: .refresh, cursor: snapshotStore?.syncCursor)
            )
            try requireCurrentProfileOperation(context)
            try apply(response)
            bootstrapped = true
            await retryPendingOperations(context: context)
            guard isCurrentProfileOperationContext(context) else { return }
            await retryPushToken(context: context)
            guard isCurrentProfileOperationContext(context) else { return }
        } catch {
            // Durable local state remains visible; only non-sensitive work stays queued.
        }
    }

    func publish(
        _ card: PersonCard,
        greeting: RecordedGreeting? = nil,
        context: ProfileOperationContext
    ) async -> SyncResponse? {
        guard isCurrentProfileOperationContext(context) else { return nil }
        do {
            let client = try explicitProfileClient()
            var cloudCard = card.exchangeCopy
            var audioAssetID: String?
            if let greeting {
                if !bootstrapped {
                    let bootstrap = try await client.sync(SyncRequest(operation: .refresh))
                    try requireCurrentProfileOperation(context)
                    try apply(bootstrap)
                    bootstrapped = true
                }
                let prepared = try await client.sync(SyncRequest(
                    operation: .prepareAudioUpload,
                    audioSizeBytes: greeting.sizeBytes,
                    audioDurationMS: min(10_000, Int((greeting.duration * 1_000).rounded()))
                ))
                try requireCurrentProfileOperation(context)
                guard let upload = prepared.audioUpload else {
                    throw APIClient.ClientError.invalidResponse
                }
                try await mediaTransfer.upload(greeting, to: upload.uploadURL)
                try requireCurrentProfileOperation(context)
                audioAssetID = upload.assetID
                cloudCard.hasAudioGreeting = true
            }
            let request = SyncRequest(
                operation: .publishCard,
                card: cloudCard,
                audioAssetID: audioAssetID
            )
            snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
            let response = try await client.sync(request)
            try requireCurrentProfileOperation(context)
            snapshotStore?.removePendingOperation(id: request.operationID)
            bootstrapped = true
            if let version = response.ownCardVersion {
                var published = card
                published.version = version
                try snapshotStore?.writeOwnCard(published)
                onOwnCardChanged?(published)
            }
            await retryPushToken(context: context)
            try requireCurrentProfileOperation(context)
            return response
        } catch {
            return nil
        }
    }

    func prepareExchange(
        card: PersonCard,
        method: String,
        privateFields: PrivateCardFields?,
        greeting: RecordedGreeting? = nil,
        context: ProfileOperationContext
    ) async throws -> PreparedExchange {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
        if let greeting {
            let publication = await publish(card, greeting: greeting, context: context)
            try requireCurrentProfileOperation(context)
            guard publication != nil else { throw CoordinatorError.ownCardNotPublished }
        }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let response = try await apiClient.sync(
            SyncRequest(
                operation: .prepareExchange,
                card: card.exchangeCopy,
                privateFields: privateFields,
                exchangeMethod: method
            )
        )
        try requireCurrentProfileOperation(context)
        do {
            return try PreparedExchange.resolve(
                method: method,
                exchangeToken: response.exchangeToken,
                exchangeCode: response.exchangeCode,
                expiresAt: response.exchangeExpiresAt
            )
        } catch {
            throw APIClient.ClientError.invalidResponse
        }
    }

    func prepareExchange(
        card: PersonCard,
        method: String,
        greeting: RecordedGreeting? = nil,
        context: ProfileOperationContext
    ) async throws -> String {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
        let prepared = try await prepareExchange(
            card: card,
            method: method,
            privateFields: nil,
            greeting: greeting,
            context: context
        )
        try requireCurrentProfileOperation(context)
        guard let token = prepared.credential.exchangeToken else {
            throw APIClient.ClientError.invalidResponse
        }
        return token
    }

    func cancelExchange(
        credential: ExchangeCredential,
        context: ProfileOperationContext
    ) async {
        guard isCurrentProfileOperationContext(context), let apiClient else { return }
        let request = SyncRequest(
            operation: .cancelExchange,
            exchangeToken: credential.exchangeToken,
            exchangeCode: credential.exchangeCode
        )
        do {
            _ = try await apiClient.sync(request)
        } catch APIClient.ClientError.status(let status, _) where status == 409 {
            // Claim already won the serializable race; cancellation is terminal, not retryable.
        } catch {
            // Raw exchange credentials are never persisted; expiry is the cleanup backstop.
        }
    }

    func cancelExchange(token: String, context: ProfileOperationContext) async {
        guard isCurrentProfileOperationContext(context) else { return }
        await cancelExchange(credential: .token(token), context: context)
    }

    func claimExchange(
        credential: ExchangeCredential,
        expiresAt: Date?,
        localCardID: String?,
        ownCard: PersonCard,
        greeting: RecordedGreeting?,
        context: ProfileOperationContext
    ) async throws -> SyncResponse {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
        let publication = await publish(ownCard, greeting: greeting, context: context)
        try requireCurrentProfileOperation(context)
        guard publication != nil else {
            throw CoordinatorError.ownCardNotPublished
        }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let request = SyncRequest(
            operation: .claimExchange,
            exchangeToken: credential.exchangeToken,
            exchangeCode: credential.exchangeCode
        )
        let pending = PendingSyncOperation(
            request: request,
            expiresAt: expiresAt,
            localCardID: localCardID
        )
        if let expiresAt, expiresAt <= Date() {
            try markExpired(pending)
            throw CoordinatorError.expiredExchange
        }
        do {
            let response = try await apiClient.sync(request)
            try requireCurrentProfileOperation(context)
            try apply(response)
            return response
        } catch APIClient.ClientError.status(let status, _) where status == 409 {
            try requireCurrentProfileOperation(context)
            try markExpired(pending)
            throw CoordinatorError.expiredExchange
        }
    }

    func claimExchange(
        token: String,
        expiresAt: Date?,
        localCardID: String?,
        ownCard: PersonCard,
        greeting: RecordedGreeting?,
        context: ProfileOperationContext
    ) async throws -> SyncResponse {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
        let response = try await claimExchange(
            credential: .token(token),
            expiresAt: expiresAt,
            localCardID: localCardID,
            ownCard: ownCard,
            greeting: greeting,
            context: context
        )
        try requireCurrentProfileOperation(context)
        return response
    }

    func submitModeration(
        operation: SyncOperation,
        peerInstallationID: String,
        category: String?,
        context: ProfileOperationContext
    ) async throws {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let request = SyncRequest(
            operation: operation,
            moderationCategory: category,
            subjectInstallationID: peerInstallationID
        )
        snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
        _ = try await apiClient.sync(request)
        try requireCurrentProfileOperation(context)
        snapshotStore?.removePendingOperation(id: request.operationID)
    }

    func audioAsset(
        for peerInstallationID: String,
        context: ProfileOperationContext
    ) async throws -> AudioAsset {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let response = try await apiClient.sync(
            SyncRequest(operation: .refresh, cursor: snapshotStore?.syncCursor)
        )
        try requireCurrentProfileOperation(context)
        try apply(response)
        guard let audio = response.people.first(where: {
            $0.installationID == peerInstallationID
        })?.audio else { throw CoordinatorError.noAudio }
        return audio
    }

    func updatePushToken(_ token: String?, context: ProfileOperationContext) async {
        guard isCurrentProfileOperationContext(context) else { return }
        if snapshotStore?.pendingAPNSToken != token
            || snapshotStore?.pendingAPNSRemoval != (token == nil) {
            snapshotStore?.clearPendingOperationID(for: "apns-token")
        }
        snapshotStore?.pendingAPNSToken = token
        snapshotStore?.pendingAPNSRemoval = token == nil
        await retryPushToken(context: context)
        guard isCurrentProfileOperationContext(context) else { return }
    }

    func deleteProfile(context: ProfileOperationContext) async -> Bool {
        guard isCurrentProfileOperationContext(context) else { return false }
        let record = ProfileDeletionRecord(operationID: UUID().uuidString.lowercased())
        persistDeletionRecord(record)
        do {
            try profileLifecycle.beginDeletion()
        } catch {
            return false
        }
        deletionRequestInFlight = true
        defer { deletionRequestInFlight = false }
        profileOperationEpoch.invalidate()
        snapshotStore?.clearUserData()
        snapshotStore?.profileDeletionPending = true
        onProfileDeleted?()
        let deletionEpoch = profileOperationEpoch.capture()
        await mediaTransfer.cancelAllProfileTransfersAndWait()
        guard isCurrentDeletion(record, epoch: deletionEpoch) else { return false }
        guard let apiClient else { return finishLocalOnlyDeletion(record) }
        let request = SyncRequest(operation: .deleteProfile, operationID: record.operationID)
        do {
            _ = try await apiClient.sync(request)
            guard isCurrentDeletion(record, epoch: deletionEpoch) else { return false }
            try markDeletionServerAcknowledged(operationID: record.operationID)
            guard let acknowledged = deletionRecord else { return false }
            try finishDeletion(record: acknowledged, allowLocalOnly: false)
            return true
        } catch {
            return false
        }
    }

    func reactivateAndStoreUserCreatedCard(_ card: PersonCard) throws {
        guard let snapshotStore else { throw CoordinatorError.localStorageUnavailable }
        guard profileLifecycle.state != .deleting else {
            throw CoordinatorError.deletionInProgress
        }
        guard profileLifecycle.state == .terminal else {
            try snapshotStore.writeOwnCard(card)
            return
        }

        let previousLifecycle = profileLifecycle
        var reactivatedLifecycle = profileLifecycle
        try reactivatedLifecycle.reactivateForUserCreation()
        profileLifecycle = reactivatedLifecycle
        profileOperationEpoch.invalidate()
        snapshotStore.profileDeletionRecord = nil
        snapshotStore.profileDeletionPending = false
        snapshotStore.profileTerminallyDeleted = false
        do {
            try snapshotStore.writeOwnCard(card)
        } catch {
            profileLifecycle = previousLifecycle
            snapshotStore.profileTerminallyDeleted = true
            throw error
        }
    }

    private func explicitProfileClient() throws -> APIClient {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        if let apiClient { return apiClient }
        let credential = try credentialStore.createCredential()
        let client = APIClient(
            baseURL: baseURL,
            session: session,
            snapshotStore: snapshotStore,
            credential: credential
        )
        apiClient = client
        return client
    }

    private func requireCurrentProfileOperation(
        _ context: ProfileOperationContext
    ) throws {
        guard isCurrentProfileOperationContext(context) else {
            throw CoordinatorError.deletionInProgress
        }
    }

    private var syncSuppressed: Bool {
        profileLifecycle.suppressesSync
    }

    private func retryPendingOperations(context: ProfileOperationContext) async {
        guard isCurrentProfileOperationContext(context), let apiClient else { return }
        let pending = snapshotStore?.pendingOperations ?? []
        for operation in pending {
            guard isCurrentProfileOperationContext(context) else { return }
            guard PendingSyncOperationPersistencePolicy.allowsDurablePersistence(
                operation.request.operation
            ) else {
                snapshotStore?.removePendingOperation(id: operation.id)
                continue
            }
            if operation.request.operation == .deleteProfile {
                snapshotStore?.removePendingOperation(id: operation.id)
                continue
            }
            if operation.request.operation == .claimExchange,
               let expiresAt = operation.expiresAt,
               expiresAt <= Date() {
                try? markExpired(operation)
                continue
            }
            do {
                let request = retrySafeRequest(operation.request)
                let response = try await apiClient.sync(request)
                guard isCurrentProfileOperationContext(context) else { return }
                try apply(response)
                if operation.request.operation == .publishCard { bootstrapped = true }
                snapshotStore?.removePendingOperation(id: operation.id)
            } catch {
                continue
            }
        }
    }

    private func retryPushToken(context: ProfileOperationContext) async {
        guard bootstrapped,
              isCurrentProfileOperationContext(context),
              let apiClient else { return }
        let removal = snapshotStore?.pendingAPNSRemoval == true
        guard removal || snapshotStore?.pendingAPNSToken != nil else { return }
        let operationID = snapshotStore?.pendingOperationID(
            for: "apns-token",
            proposed: UUID().uuidString.lowercased()
        ) ?? UUID().uuidString.lowercased()
        let request = SyncRequest(
            apnsToken: removal ? nil : snapshotStore?.pendingAPNSToken,
            operation: removal ? .removePushToken : .updatePushToken,
            operationID: operationID
        )
        do {
            _ = try await apiClient.sync(request)
            guard isCurrentProfileOperationContext(context) else { return }
            snapshotStore?.pendingAPNSToken = nil
            snapshotStore?.pendingAPNSRemoval = false
            snapshotStore?.clearPendingOperationID(for: "apns-token")
        } catch {
            // The latest token remains persisted for the next foreground retry.
        }
    }

    private func markExpired(_ operation: PendingSyncOperation) throws {
        if let cardID = operation.localCardID { try snapshotStore?.markPersonLocalOnly(id: cardID) }
        snapshotStore?.removePendingOperation(id: operation.id)
        onPeopleChanged?()
    }

    private func apply(_ response: SyncResponse) throws {
        var previousVersions: [String: Int] = [:]
        for card in snapshotStore?.readPeople() ?? [] {
            previousVersions[card.id] = max(previousVersions[card.id] ?? 0, card.version)
        }
        let people = response.people.map(\.versionedCard)
        let audioMayHaveChanged = !response.revokedCardIDs.isEmpty || people.contains {
            return previousVersions[$0.id] != $0.version
        }
        try snapshotStore?.replacePeople(people)
        for id in response.revokedCardIDs { try snapshotStore?.removePerson(id: id) }
        snapshotStore?.syncCursor = response.nextCursor ?? snapshotStore?.syncCursor
        if !people.isEmpty || !response.revokedCardIDs.isEmpty { onPeopleChanged?() }
        if audioMayHaveChanged { onAudioInvalidated?() }
    }

    private func retrySafeRequest(_ request: SyncRequest) -> SyncRequest {
        guard request.operation == .publishCard,
              request.audioAssetID == nil,
              var card = request.card,
              card.hasAudioGreeting else { return request }
        card.hasAudioGreeting = false
        return SyncRequest(
            operation: .publishCard,
            operationID: request.operationID,
            card: card
        )
    }

    private func persistDeletionRecord(_ record: ProfileDeletionRecord) {
        deletionRecord = record
        snapshotStore?.profileDeletionRecord = record
        snapshotStore?.profileDeletionPending = true
    }

    private func markDeletionServerAcknowledged(operationID: String) throws {
        guard var record = deletionRecord, record.operationID == operationID else {
            throw CoordinatorError.deletionInProgress
        }
        record.markServerAcknowledged()
        persistDeletionRecord(record)
    }

    private func isCurrentDeletion(
        _ record: ProfileDeletionRecord,
        epoch: ProfileOperationEpoch.Snapshot
    ) -> Bool {
        profileLifecycle.state == .deleting
            && deletionRecord?.operationID == record.operationID
            && profileOperationEpoch.isCurrent(epoch)
    }

    private func finishLocalOnlyDeletion(_ record: ProfileDeletionRecord) -> Bool {
        do {
            try finishDeletion(record: record, allowLocalOnly: true)
            return true
        } catch {
            return false
        }
    }

    private func resumeDeletionIfNeeded() async {
        guard !deletionRequestInFlight else { return }
        guard let record = deletionRecord else { return }
        deletionRequestInFlight = true
        defer { deletionRequestInFlight = false }
        profileOperationEpoch.invalidate()
        let deletionEpoch = profileOperationEpoch.capture()
        snapshotStore?.clearUserData()
        snapshotStore?.profileDeletionPending = true
        onProfileDeleted?()
        await mediaTransfer.cancelAllProfileTransfersAndWait()
        guard isCurrentDeletion(record, epoch: deletionEpoch) else { return }
        if record.serverAcknowledged {
            try? finishDeletion(record: record, allowLocalOnly: false)
            return
        }
        guard let apiClient else {
            _ = finishLocalOnlyDeletion(record)
            return
        }
        let request = SyncRequest(operation: .deleteProfile, operationID: record.operationID)
        do {
            _ = try await apiClient.sync(request)
            guard isCurrentDeletion(record, epoch: deletionEpoch) else { return }
            try markDeletionServerAcknowledged(operationID: record.operationID)
            guard let acknowledged = deletionRecord else { return }
            try finishDeletion(record: acknowledged, allowLocalOnly: false)
        } catch {
            // The dedicated record remains durable for the next foreground retry.
        }
    }

    private func finishDeletion(
        record: ProfileDeletionRecord,
        allowLocalOnly: Bool
    ) throws {
        var lifecycle = profileLifecycle
        try lifecycle.finishDeletion(record: record, allowLocalOnly: allowLocalOnly)
        snapshotStore?.clearUserData()
        try credentialStore.deleteCredential()
        snapshotStore?.profileDeletionPending = false
        snapshotStore?.profileTerminallyDeleted = true
        snapshotStore?.profileDeletionRecord = nil
        deletionRecord = nil
        profileLifecycle = lifecycle
        apiClient = nil
        bootstrapped = false
    }
}
