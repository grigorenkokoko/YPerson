import Foundation

@MainActor
final class SyncCoordinator {
    enum CoordinatorError: LocalizedError {
        case noProfile
        case ownCardNotPublished
        case deletionInProgress
        case expiredExchange
        case noAudio

        var errorDescription: String? {
            switch self {
            case .noProfile: return "Сначала сохраните свою визитку."
            case .ownCardNotPublished: return "Не удалось опубликовать вашу визитку для взаимного обмена."
            case .deletionInProgress: return "Дождитесь завершения удаления профиля."
            case .expiredExchange: return "Код обмена уже истёк. Карточка сохранена только на iPhone."
            case .noAudio: return "У этой визитки нет доступного аудиоприветствия."
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

    var installationID: String? { apiClient?.installationID }
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
        if let credential = try credentialStore.existingCredential() {
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

    func bootstrap() async {
        snapshotStore?.purgeNonDurablePendingOperations()
        guard snapshotStore?.profileTerminallyDeleted != true else { return }
        if snapshotStore?.profileDeletionPending == true {
            let hasPendingDeletion = snapshotStore?.pendingOperations.contains {
                $0.request.operation == .deleteProfile
            } == true
            if apiClient == nil || !hasPendingDeletion {
                do {
                    try finishDeletion(operationID: nil)
                } catch {
                    // Keep the pending state; foreground retry remains fail-closed.
                }
            } else {
                await retryPendingOperations()
            }
            return
        }
        guard !syncSuppressed, let apiClient else { return }
        let operationEpoch = profileOperationEpoch.capture()
        do {
            let response = try await apiClient.sync(
                SyncRequest(operation: .refresh, cursor: snapshotStore?.syncCursor)
            )
            try requireCurrentProfileOperation(operationEpoch)
            try apply(response)
            bootstrapped = true
            await retryPendingOperations()
            guard isCurrentProfileOperation(operationEpoch) else { return }
            await retryPushToken()
            guard isCurrentProfileOperation(operationEpoch) else { return }
        } catch {
            // Durable local state remains visible; only non-sensitive work stays queued.
        }
    }

    func publish(_ card: PersonCard, greeting: RecordedGreeting? = nil) async -> SyncResponse? {
        guard !syncSuppressed else { return nil }
        let operationEpoch = profileOperationEpoch.capture()
        do {
            let client = try explicitProfileClient()
            var cloudCard = card.exchangeCopy
            var audioAssetID: String?
            if let greeting {
                if !bootstrapped {
                    let bootstrap = try await client.sync(SyncRequest(operation: .refresh))
                    try requireCurrentProfileOperation(operationEpoch)
                    try apply(bootstrap)
                    bootstrapped = true
                }
                let prepared = try await client.sync(SyncRequest(
                    operation: .prepareAudioUpload,
                    audioSizeBytes: greeting.sizeBytes,
                    audioDurationMS: min(10_000, Int((greeting.duration * 1_000).rounded()))
                ))
                try requireCurrentProfileOperation(operationEpoch)
                guard let upload = prepared.audioUpload else {
                    throw APIClient.ClientError.invalidResponse
                }
                try await mediaTransfer.upload(greeting, to: upload.uploadURL)
                try requireCurrentProfileOperation(operationEpoch)
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
            try requireCurrentProfileOperation(operationEpoch)
            snapshotStore?.removePendingOperation(id: request.operationID)
            bootstrapped = true
            if let version = response.ownCardVersion {
                var published = card
                published.version = version
                try snapshotStore?.writeOwnCard(published)
                onOwnCardChanged?(published)
            }
            await retryPushToken()
            try requireCurrentProfileOperation(operationEpoch)
            return response
        } catch {
            return nil
        }
    }

    func prepareExchange(
        card: PersonCard,
        method: String,
        privateFields: PrivateCardFields?,
        greeting: RecordedGreeting? = nil
    ) async throws -> PreparedExchange {
        guard !syncSuppressed else {
            throw CoordinatorError.deletionInProgress
        }
        let operationEpoch = profileOperationEpoch.capture()
        if let greeting {
            let publication = await publish(card, greeting: greeting)
            try requireCurrentProfileOperation(operationEpoch)
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
        try requireCurrentProfileOperation(operationEpoch)
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
        greeting: RecordedGreeting? = nil
    ) async throws -> String {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        let operationEpoch = profileOperationEpoch.capture()
        let prepared = try await prepareExchange(
            card: card,
            method: method,
            privateFields: nil,
            greeting: greeting
        )
        try requireCurrentProfileOperation(operationEpoch)
        guard let token = prepared.credential.exchangeToken else {
            throw APIClient.ClientError.invalidResponse
        }
        return token
    }

    func cancelExchange(credential: ExchangeCredential) async {
        guard !syncSuppressed, let apiClient else { return }
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

    func cancelExchange(token: String) async {
        await cancelExchange(credential: .token(token))
    }

    func claimExchange(
        credential: ExchangeCredential,
        expiresAt: Date?,
        localCardID: String?,
        ownCard: PersonCard,
        greeting: RecordedGreeting?
    ) async throws -> SyncResponse {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        let operationEpoch = profileOperationEpoch.capture()
        let publication = await publish(ownCard, greeting: greeting)
        try requireCurrentProfileOperation(operationEpoch)
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
            try requireCurrentProfileOperation(operationEpoch)
            try apply(response)
            return response
        } catch APIClient.ClientError.status(let status, _) where status == 409 {
            try requireCurrentProfileOperation(operationEpoch)
            try markExpired(pending)
            throw CoordinatorError.expiredExchange
        }
    }

    func claimExchange(
        token: String,
        expiresAt: Date?,
        localCardID: String?,
        ownCard: PersonCard,
        greeting: RecordedGreeting?
    ) async throws -> SyncResponse {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        let operationEpoch = profileOperationEpoch.capture()
        let response = try await claimExchange(
            credential: .token(token),
            expiresAt: expiresAt,
            localCardID: localCardID,
            ownCard: ownCard,
            greeting: greeting
        )
        try requireCurrentProfileOperation(operationEpoch)
        return response
    }

    func submitModeration(
        operation: SyncOperation,
        peerInstallationID: String,
        category: String?
    ) async throws {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        let operationEpoch = profileOperationEpoch.capture()
        guard let apiClient else { throw CoordinatorError.noProfile }
        let request = SyncRequest(
            operation: operation,
            moderationCategory: category,
            subjectInstallationID: peerInstallationID
        )
        snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
        _ = try await apiClient.sync(request)
        try requireCurrentProfileOperation(operationEpoch)
        snapshotStore?.removePendingOperation(id: request.operationID)
    }

    func audioAsset(for peerInstallationID: String) async throws -> AudioAsset {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        let operationEpoch = profileOperationEpoch.capture()
        guard let apiClient else { throw CoordinatorError.noProfile }
        let response = try await apiClient.sync(
            SyncRequest(operation: .refresh, cursor: snapshotStore?.syncCursor)
        )
        try requireCurrentProfileOperation(operationEpoch)
        try apply(response)
        guard let audio = response.people.first(where: {
            $0.installationID == peerInstallationID
        })?.audio else { throw CoordinatorError.noAudio }
        return audio
    }

    func updatePushToken(_ token: String?) async {
        guard !syncSuppressed else { return }
        let operationEpoch = profileOperationEpoch.capture()
        if snapshotStore?.pendingAPNSToken != token
            || snapshotStore?.pendingAPNSRemoval != (token == nil) {
            snapshotStore?.clearPendingOperationID(for: "apns-token")
        }
        snapshotStore?.pendingAPNSToken = token
        snapshotStore?.pendingAPNSRemoval = token == nil
        await retryPushToken()
        guard isCurrentProfileOperation(operationEpoch) else { return }
    }

    func deleteProfile() async -> Bool {
        guard !syncSuppressed else { return false }
        profileOperationEpoch.invalidate()
        snapshotStore?.clearUserData()
        snapshotStore?.profileDeletionPending = true
        onProfileDeleted?()
        guard let apiClient else {
            do {
                try finishDeletion(operationID: nil)
                return true
            } catch {
                return false
            }
        }
        let deletionEpoch = profileOperationEpoch.capture()
        let request = SyncRequest(operation: .deleteProfile)
        snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
        do {
            _ = try await apiClient.sync(request)
            guard profileOperationEpoch.isCurrent(deletionEpoch) else { return false }
            try finishDeletion(operationID: request.operationID)
            return true
        } catch {
            return false
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
        snapshotStore?.profileTerminallyDeleted = false
        return client
    }

    private func isCurrentProfileOperation(_ epoch: ProfileOperationEpoch.Snapshot) -> Bool {
        !syncSuppressed && profileOperationEpoch.isCurrent(epoch)
    }

    private func requireCurrentProfileOperation(
        _ epoch: ProfileOperationEpoch.Snapshot
    ) throws {
        guard isCurrentProfileOperation(epoch) else {
            throw CoordinatorError.deletionInProgress
        }
    }

    private var syncSuppressed: Bool {
        snapshotStore?.profileDeletionPending == true
            || snapshotStore?.profileTerminallyDeleted == true
    }

    private func retryPendingOperations() async {
        guard let apiClient, snapshotStore?.profileTerminallyDeleted != true else { return }
        let retryEpoch = profileOperationEpoch.capture()
        let pending = snapshotStore?.pendingOperations ?? []
        for operation in pending {
            guard profileOperationEpoch.isCurrent(retryEpoch) else { return }
            guard PendingSyncOperationPersistencePolicy.allowsDurablePersistence(
                operation.request.operation
            ) else {
                snapshotStore?.removePendingOperation(id: operation.id)
                continue
            }
            if snapshotStore?.profileDeletionPending == true,
               operation.request.operation != .deleteProfile { continue }
            if operation.request.operation == .claimExchange,
               let expiresAt = operation.expiresAt,
               expiresAt <= Date() {
                try? markExpired(operation)
                continue
            }
            do {
                let request = retrySafeRequest(operation.request)
                let response = try await apiClient.sync(request)
                guard profileOperationEpoch.isCurrent(retryEpoch) else { return }
                if operation.request.operation == .deleteProfile {
                    try finishDeletion(operationID: operation.id)
                    return
                }
                guard !syncSuppressed else { return }
                try apply(response)
                if operation.request.operation == .publishCard { bootstrapped = true }
                snapshotStore?.removePendingOperation(id: operation.id)
            } catch {
                continue
            }
        }
    }

    private func retryPushToken() async {
        guard bootstrapped,
              snapshotStore?.profileDeletionPending != true,
              snapshotStore?.profileTerminallyDeleted != true,
              let apiClient else { return }
        let operationEpoch = profileOperationEpoch.capture()
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
            guard isCurrentProfileOperation(operationEpoch) else { return }
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

    private func finishDeletion(operationID: String?) throws {
        if let operationID { snapshotStore?.removePendingOperation(id: operationID) }
        snapshotStore?.clearUserData()
        try credentialStore.deleteCredential()
        snapshotStore?.profileDeletionPending = false
        snapshotStore?.profileTerminallyDeleted = true
        apiClient = nil
        bootstrapped = false
    }
}
