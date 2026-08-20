import Foundation

@MainActor
final class SyncCoordinator {
    enum CoordinatorError: LocalizedError {
        case noProfile
        case deletionInProgress
        case expiredExchange

        var errorDescription: String? {
            switch self {
            case .noProfile: return "Сначала сохраните свою визитку."
            case .deletionInProgress: return "Дождитесь завершения удаления профиля."
            case .expiredExchange: return "Код обмена уже истёк. Карточка сохранена только на iPhone."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let snapshotStore: AppGroupSnapshotStore?
    private let credentialStore: any InstallationCredentialStoring
    private var apiClient: APIClient?
    private var bootstrapped = false

    var installationID: String? { apiClient?.installationID }
    var onPeopleChanged: (() -> Void)?
    var onOwnCardChanged: ((PersonCard) -> Void)?
    var onProfileDeleted: (() -> Void)?

    init(
        baseURL: URL,
        session: URLSession,
        snapshotStore: AppGroupSnapshotStore?,
        credentialStore: any InstallationCredentialStoring
    ) throws {
        self.baseURL = baseURL
        self.session = session
        self.snapshotStore = snapshotStore
        self.credentialStore = credentialStore
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
        guard snapshotStore?.profileTerminallyDeleted != true else { return }
        if snapshotStore?.profileDeletionPending == true {
            if apiClient == nil {
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
        guard let apiClient else { return }
        do {
            let response = try await apiClient.sync(
                SyncRequest(operation: .refresh, cursor: snapshotStore?.syncCursor)
            )
            try apply(response)
            bootstrapped = true
            await retryPendingOperations()
            await retryPushToken()
        } catch {
            // Durable local state remains visible and all pending work remains queued.
        }
    }

    func publish(_ card: PersonCard) async -> SyncResponse? {
        do {
            let client = try explicitProfileClient()
            let request = SyncRequest(operation: .publishCard, card: card.exchangeCopy)
            snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
            let response = try await client.sync(request)
            snapshotStore?.removePendingOperation(id: request.operationID)
            bootstrapped = true
            if let version = response.ownCardVersion {
                var published = card
                published.version = version
                try snapshotStore?.writeOwnCard(published)
                onOwnCardChanged?(published)
            }
            await retryPushToken()
            return response
        } catch {
            return nil
        }
    }

    func prepareExchange(card: PersonCard, method: String) async throws -> String {
        guard !syncSuppressed else {
            throw CoordinatorError.deletionInProgress
        }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let response = try await apiClient.sync(
            SyncRequest(operation: .prepareExchange, card: card.exchangeCopy, exchangeMethod: method)
        )
        guard let token = response.exchangeToken, !token.isEmpty else {
            throw APIClient.ClientError.invalidResponse
        }
        return token
    }

    func cancelExchange(token: String) async {
        guard !syncSuppressed, let apiClient else { return }
        let request = SyncRequest(operation: .cancelExchange, exchangeToken: token)
        snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
        do {
            _ = try await apiClient.sync(request)
            snapshotStore?.removePendingOperation(id: request.operationID)
        } catch APIClient.ClientError.status(let status, _) where status == 409 {
            // Claim already won the serializable race; cancellation is terminal, not retryable.
            snapshotStore?.removePendingOperation(id: request.operationID)
        } catch {
            // The exact request and stable operation ID stay durable for foreground retry.
        }
    }

    func claimExchange(
        token: String,
        expiresAt: Date?,
        localCardID: String?
    ) async throws -> SyncResponse {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let request = SyncRequest(operation: .claimExchange, exchangeToken: token)
        let pending = PendingSyncOperation(
            request: request,
            expiresAt: expiresAt,
            localCardID: localCardID
        )
        snapshotStore?.enqueue(pending)
        if let expiresAt, expiresAt <= Date() {
            try markExpired(pending)
            throw CoordinatorError.expiredExchange
        }
        do {
            let response = try await apiClient.sync(request)
            try apply(response)
            snapshotStore?.removePendingOperation(id: request.operationID)
            return response
        } catch APIClient.ClientError.status(let status, _) where status == 409 {
            try markExpired(pending)
            throw CoordinatorError.expiredExchange
        }
    }

    func submitModeration(
        operation: SyncOperation,
        peerInstallationID: String,
        category: String?
    ) async throws {
        guard !syncSuppressed else { throw CoordinatorError.deletionInProgress }
        guard let apiClient else { throw CoordinatorError.noProfile }
        let request = SyncRequest(
            operation: operation,
            moderationCategory: category,
            subjectInstallationID: peerInstallationID
        )
        snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
        _ = try await apiClient.sync(request)
        snapshotStore?.removePendingOperation(id: request.operationID)
    }

    func updatePushToken(_ token: String?) async {
        guard !syncSuppressed else { return }
        if snapshotStore?.pendingAPNSToken != token
            || snapshotStore?.pendingAPNSRemoval != (token == nil) {
            snapshotStore?.clearPendingOperationID(for: "apns-token")
        }
        snapshotStore?.pendingAPNSToken = token
        snapshotStore?.pendingAPNSRemoval = token == nil
        await retryPushToken()
    }

    func deleteProfile() async -> Bool {
        guard snapshotStore?.profileDeletionPending != true else { return false }
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
        let request = SyncRequest(operation: .deleteProfile)
        snapshotStore?.enqueue(PendingSyncOperation(request: request, expiresAt: nil, localCardID: nil))
        do {
            _ = try await apiClient.sync(request)
            try finishDeletion(operationID: request.operationID)
            return true
        } catch {
            return false
        }
    }

    private func explicitProfileClient() throws -> APIClient {
        if snapshotStore?.profileDeletionPending == true { throw CoordinatorError.deletionInProgress }
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

    private var syncSuppressed: Bool {
        snapshotStore?.profileDeletionPending == true
            || snapshotStore?.profileTerminallyDeleted == true
    }

    private func retryPendingOperations() async {
        guard let apiClient, snapshotStore?.profileTerminallyDeleted != true else { return }
        let pending = snapshotStore?.pendingOperations ?? []
        for operation in pending {
            if snapshotStore?.profileDeletionPending == true,
               operation.request.operation != .deleteProfile { continue }
            if operation.request.operation == .claimExchange,
               let expiresAt = operation.expiresAt,
               expiresAt <= Date() {
                try? markExpired(operation)
                continue
            }
            do {
                let response = try await apiClient.sync(operation.request)
                try apply(response)
                if operation.request.operation == .publishCard { bootstrapped = true }
                if operation.request.operation == .deleteProfile {
                    try finishDeletion(operationID: operation.id)
                    return
                }
                snapshotStore?.removePendingOperation(id: operation.id)
            } catch APIClient.ClientError.status(let status, _)
                where operation.request.operation == .claimExchange && status == 409 {
                try? markExpired(operation)
            } catch APIClient.ClientError.status(let status, _)
                where operation.request.operation == .cancelExchange && status == 409 {
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
        let people = response.people.map(\.versionedCard)
        try snapshotStore?.replacePeople(people)
        for id in response.revokedCardIDs { try snapshotStore?.removePerson(id: id) }
        snapshotStore?.syncCursor = response.nextCursor ?? snapshotStore?.syncCursor
        if !people.isEmpty || !response.revokedCardIDs.isEmpty { onPeopleChanged?() }
    }

    private func finishDeletion(operationID: String?) throws {
        try credentialStore.deleteCredential()
        if let operationID { snapshotStore?.removePendingOperation(id: operationID) }
        snapshotStore?.profileDeletionPending = false
        snapshotStore?.profileTerminallyDeleted = true
        apiClient = nil
        bootstrapped = false
    }
}
