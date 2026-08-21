import Foundation

struct PrivateCardFields: Codable, Equatable {
    let phone: String

    init?(card: PersonCard) {
        let value = card.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return nil }
        phone = value
    }
}

struct PrivatePhoneShareConsent: Equatable {
    private(set) var isAuthorized = false

    mutating func authorize() {
        isAuthorized = true
    }

    mutating func revoke() {
        isAuthorized = false
    }

    mutating func consume(
        forPreparationMethod method: String,
        card: PersonCard
    ) -> PrivateCardFields? {
        guard method == "manual", isAuthorized else { return nil }
        isAuthorized = false
        return PrivateCardFields(card: card)
    }
}

enum PendingSyncOperationPersistencePolicy {
    static func allowsDurablePersistence(_ operation: SyncOperation) -> Bool {
        switch operation {
        case .claimExchange, .cancelExchange:
            return false
        default:
            return true
        }
    }

    static func durableOperations(
        from operations: [PendingSyncOperation]
    ) -> [PendingSyncOperation] {
        operations.filter { allowsDurablePersistence($0.request.operation) }
    }
}

struct ProfileOperationEpoch {
    struct Snapshot: Equatable {
        fileprivate let value: UInt64
    }

    private var value: UInt64 = 0

    func capture() -> Snapshot {
        Snapshot(value: value)
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        snapshot.value == value
    }

    mutating func invalidate() {
        value &+= 1
    }
}

typealias ProfileOperationContext = ProfileOperationEpoch.Snapshot

struct ProfileBootstrapTaskOwnership {
    enum Kind: Sendable {
        case active
        case deletionRecovery
    }

    struct Ticket: Equatable, Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let kind: Kind
    }

    struct ActiveStart: Equatable, Sendable {
        let ticket: Ticket
        let replaced: Ticket?
    }

    private var active: Ticket?
    private var deletionRecovery: Ticket?

    mutating func beginActive() -> ActiveStart {
        let replaced = active
        let ticket = Ticket(id: UUID(), kind: .active)
        active = ticket
        return ActiveStart(ticket: ticket, replaced: replaced)
    }

    mutating func beginDeletionRecovery() -> Ticket? {
        guard deletionRecovery == nil else { return nil }
        let ticket = Ticket(id: UUID(), kind: .deletionRecovery)
        deletionRecovery = ticket
        return ticket
    }

    mutating func invalidateActive() -> Ticket? {
        defer { active = nil }
        return active
    }

    mutating func finish(_ ticket: Ticket) {
        switch ticket.kind {
        case .active:
            if active == ticket { active = nil }
        case .deletionRecovery:
            if deletionRecovery == ticket { deletionRecovery = nil }
        }
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        switch ticket.kind {
        case .active: return active == ticket
        case .deletionRecovery: return deletionRecovery == ticket
        }
    }
}

final class AsyncFIFOOperationGate: @unchecked Sendable {
    struct Lease: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private let lock = NSLock()
    private var holderID: UUID?
    private var waiters: [Waiter] = []

    func acquire() async throws -> Lease {
        let id = UUID()
        let lease: Lease? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Lease?, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else if holderID == nil {
                    holderID = id
                    lock.unlock()
                    continuation.resume(returning: Lease(id: id))
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWaiter(id: id)
        }
        guard let lease else { throw CancellationError() }
        guard !Task.isCancelled else {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    func release(_ lease: Lease) {
        var next: Waiter?
        lock.lock()
        guard holderID == lease.id else {
            lock.unlock()
            return
        }
        if waiters.isEmpty {
            holderID = nil
        } else {
            next = waiters.removeFirst()
            holderID = next?.id
        }
        lock.unlock()
        if let next {
            next.continuation.resume(returning: Lease(id: next.id))
        }
    }

    private func cancelWaiter(id: UUID) {
        var cancelled: Waiter?
        lock.lock()
        if holderID != id,
           let index = waiters.firstIndex(where: { $0.id == id }) {
            cancelled = waiters.remove(at: index)
        }
        lock.unlock()
        cancelled?.continuation.resume(returning: nil)
    }
}

struct PublicationCardOwnership: Equatable {
    private let id: String
    private let name: String
    private let role: String
    private let company: String
    private let phone: String
    private let email: String
    private let tagline: String
    private let hasAudioGreeting: Bool
    private let meetingPlace: String?
    private let isBlocked: Bool
    private let templateID: String
    private let sourceInstallationID: String?

    init(card: PersonCard) {
        id = card.id
        name = card.name
        role = card.role
        company = card.company
        phone = card.phone
        email = card.email
        tagline = card.tagline
        hasAudioGreeting = card.hasAudioGreeting
        meetingPlace = card.meetingPlace
        isBlocked = card.isBlocked
        templateID = card.templateID
        sourceInstallationID = card.sourceInstallationID
    }

    func matches(_ card: PersonCard?) -> Bool {
        guard let card else { return false }
        return id == card.id
            && name == card.name
            && role == card.role
            && company == card.company
            && phone == card.phone
            && email == card.email
            && tagline == card.tagline
            && hasAudioGreeting == card.hasAudioGreeting
            && meetingPlace == card.meetingPlace
            && isBlocked == card.isBlocked
            && templateID == card.templateID
            && sourceInstallationID == card.sourceInstallationID
    }
}

struct CardPublicationJournal: Codable, Equatable {
    let card: PersonCard
    let operation: PendingSyncOperation
}

enum ProfileBootstrapCredentialPolicy {
    static func requiresNewCredential(
        apiClientExists: Bool,
        pendingOperations: [PendingSyncOperation]
    ) -> Bool {
        !apiClientExists && pendingOperations.contains {
            $0.request.operation == .publishCard
        }
    }
}

enum PublicGreetingCommitPolicy {
    enum RestoreAction: Equatable {
        case none
        case useCommitted
        case requireExplicitResave
    }

    enum PlaybackSource: Equatable {
        case none
        case draft
        case committedPublic
    }

    static func restoreAction(
        expectedPublic: Bool,
        committedExists: Bool,
        legacyExists: Bool
    ) -> RestoreAction {
        guard expectedPublic else { return .none }
        if committedExists { return .useCommitted }
        return legacyExists ? .requireExplicitResave : .none
    }

    static func shouldPromoteDraft(
        explicitPublicChoice: Bool,
        cardSaveSucceeded: Bool,
        draftIsValid: Bool
    ) -> Bool {
        explicitPublicChoice && cardSaveSucceeded && draftIsValid
    }

    static func playbackSource(
        hasUncommittedDraft: Bool,
        committedPublicEnabled: Bool
    ) -> PlaybackSource {
        if hasUncommittedDraft { return .draft }
        return committedPublicEnabled ? .committedPublic : .none
    }
}

enum PendingPublicationAudioRecoveryPolicy {
    enum Action: Equatable {
        case send
        case uploadSavedGreeting
        case waitForSavedGreeting
    }

    static func action(
        for operation: PendingSyncOperation,
        savedGreetingAvailable: Bool
    ) -> Action {
        let request = operation.request
        guard request.operation == .publishCard,
              request.card?.hasAudioGreeting == true else { return .send }
        if request.audioAssetID != nil { return .send }
        return savedGreetingAvailable ? .uploadSavedGreeting : .waitForSavedGreeting
    }

    static func uploadedGreetingRequest(
        for operation: PendingSyncOperation,
        audioAssetID: String
    ) -> SyncRequest? {
        guard operation.request.operation == .publishCard,
              let card = operation.request.card,
              card.hasAudioGreeting == true,
              !audioAssetID.isEmpty else { return nil }
        return SyncRequest(
            operation: .publishCard,
            operationID: operation.id,
            card: card.exchangeCopy,
            audioAssetID: audioAssetID
        )
    }
}

struct PendingPushTokenSyncRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case update
        case removal
    }

    let kind: Kind
    let token: String?
    let operationID: String

    static func update(token: String, operationID: String) -> Self {
        Self(kind: .update, token: token, operationID: operationID)
    }

    static func removal(operationID: String) -> Self {
        Self(kind: .removal, token: nil, operationID: operationID)
    }

    private init(kind: Kind, token: String?, operationID: String) {
        self.kind = kind
        self.token = token
        self.operationID = operationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let token = try container.decodeIfPresent(String.self, forKey: .token)
        let operationID = try container.decode(String.self, forKey: .operationID)
        guard !operationID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .operationID,
                in: container,
                debugDescription: "Pending APNs operation ID is empty"
            )
        }
        switch kind {
        case .update:
            guard token != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .token,
                    in: container,
                    debugDescription: "Pending APNs update is missing its token"
                )
            }
        case .removal:
            guard token == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .token,
                    in: container,
                    debugDescription: "Pending APNs removal unexpectedly contains a token"
                )
            }
        }
        self.init(kind: kind, token: token, operationID: operationID)
    }
}

struct ProfileDeletionAttemptOwnership {
    struct Attempt: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private var current: Attempt?

    mutating func begin() -> Attempt {
        let attempt = Attempt(id: UUID())
        current = attempt
        return attempt
    }

    func acceptsOutcome(for attempt: Attempt, profileIsActive: Bool) -> Bool {
        !profileIsActive && current == attempt
    }

    @discardableResult
    mutating func finish(_ attempt: Attempt) -> Bool {
        guard current == attempt else { return false }
        current = nil
        return true
    }

    mutating func invalidateForProfileRecreation() {
        current = nil
    }
}

struct ContactReconciliationProfileLifecycle: Equatable {
    private(set) var isActive = true

    mutating func beginDeletion() {
        isActive = false
    }

    mutating func reactivateForUserCreation() {
        isActive = true
    }
}

final class ContactReconciliationCommitBarrier: @unchecked Sendable {
    struct Session: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let completion: CommitCompletion

        static func == (lhs: Session, rhs: Session) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct Invalidation: Sendable {
        fileprivate let completions: [CommitCompletion]

        func waitForInFlightCommits() async {
            for completion in completions {
                await completion.wait()
            }
        }
    }

    enum FenceError: Error {
        case invalidated
    }

    fileprivate final class CommitCompletion: @unchecked Sendable {
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var commitCount = 0

        func enter() {
            lock.lock()
            commitCount += 1
            lock.unlock()
            group.enter()
        }

        func leave() {
            lock.lock()
            commitCount -= 1
            lock.unlock()
            group.leave()
        }

        var isIdle: Bool {
            lock.lock()
            defer { lock.unlock() }
            return commitCount == 0
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                group.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume()
                }
            }
        }
    }

    private let lock = NSLock()
    private var acceptsSessions = true
    private var activeSessionIDs: Set<UUID> = []
    private var sessionCompletions: [UUID: CommitCompletion] = [:]

    func beginSession() -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsSessions else { return nil }
        let session = Session(id: UUID(), completion: CommitCompletion())
        activeSessionIDs.insert(session.id)
        sessionCompletions[session.id] = session.completion
        return session
    }

    func isCurrent(_ session: Session) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsSessions && activeSessionIDs.contains(session.id)
    }

    func invalidateSession(_ session: Session) {
        lock.lock()
        activeSessionIDs.remove(session.id)
        if session.completion.isIdle {
            sessionCompletions.removeValue(forKey: session.id)
        }
        lock.unlock()
    }

    func beginDeletion() -> Invalidation {
        lock.lock()
        acceptsSessions = false
        let completions = Array(sessionCompletions.values)
        activeSessionIDs.removeAll()
        sessionCompletions.removeAll()
        lock.unlock()
        return Invalidation(completions: completions)
    }

    func reactivateForUserCreation() {
        lock.lock()
        acceptsSessions = true
        lock.unlock()
    }

    func performCommit<T>(
        for session: Session,
        _ operation: () throws -> T
    ) throws -> T {
        lock.lock()
        guard acceptsSessions,
              activeSessionIDs.contains(session.id),
              sessionCompletions[session.id] === session.completion else {
            lock.unlock()
            throw FenceError.invalidated
        }
        session.completion.enter()
        lock.unlock()
        defer {
            session.completion.leave()
            removeCompletedInvalidatedSession(session)
        }
        return try operation()
    }

    private func removeCompletedInvalidatedSession(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }
        guard !activeSessionIDs.contains(session.id),
              session.completion.isIdle,
              sessionCompletions[session.id] === session.completion else { return }
        sessionCompletions.removeValue(forKey: session.id)
    }
}

struct ProfileDeletionRecord: Codable, Equatable {
    let operationID: String
    private(set) var serverAcknowledged: Bool

    init(operationID: String, serverAcknowledged: Bool = false) {
        self.operationID = operationID
        self.serverAcknowledged = serverAcknowledged
    }

    mutating func markServerAcknowledged() {
        serverAcknowledged = true
    }
}

struct ProfileLifecycle {
    enum State: Equatable {
        case active
        case deleting
        case terminal
    }

    enum TransitionError: Error {
        case invalidTransition
        case deletionNotAcknowledged
    }

    private(set) var state: State

    init(
        deletionRecord: ProfileDeletionRecord?,
        legacyDeletionPending: Bool,
        terminallyDeleted: Bool
    ) {
        if deletionRecord != nil || legacyDeletionPending {
            state = .deleting
        } else if terminallyDeleted {
            state = .terminal
        } else {
            state = .active
        }
    }

    var suppressesSync: Bool {
        state != .active
    }

    mutating func beginDeletion() throws {
        guard state == .active else { throw TransitionError.invalidTransition }
        state = .deleting
    }

    mutating func finishDeletion(
        record: ProfileDeletionRecord,
        allowLocalOnly: Bool
    ) throws {
        guard state == .deleting else { throw TransitionError.invalidTransition }
        guard record.serverAcknowledged || allowLocalOnly else {
            throw TransitionError.deletionNotAcknowledged
        }
        state = .terminal
    }

    mutating func reactivateForUserCreation() throws {
        guard state == .terminal else { throw TransitionError.invalidTransition }
        state = .active
    }
}

struct ProfileTransferGeneration {
    struct Snapshot: Equatable {
        fileprivate let value: UInt64
    }

    private var value: UInt64 = 0

    func capture() -> Snapshot {
        Snapshot(value: value)
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        snapshot.value == value
    }

    mutating func invalidate() {
        value &+= 1
    }
}

enum ManualExchangeCode {
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func normalize(_ value: String) -> String? {
        let compact = value
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        let payload = compact.hasPrefix("YP") ? String(compact.dropFirst(2)) : compact
        guard payload.count == 12, payload.allSatisfy(alphabet.contains) else { return nil }
        return "YP-\(payload.prefix(4))-\(payload.dropFirst(4).prefix(4))-\(payload.dropFirst(8))"
    }
}

enum ExchangeCredential: Equatable {
    case token(String)
    case code(String)

    var exchangeToken: String? {
        if case .token(let value) = self { return value }
        return nil
    }

    var exchangeCode: String? {
        if case .code(let value) = self { return value }
        return nil
    }
}

struct PreparedExchange: Equatable {
    let credential: ExchangeCredential
    let expiresAt: Date

    enum ResolutionError: Error {
        case invalidResponse
    }

    static func resolve(
        method: String,
        exchangeToken: String?,
        exchangeCode: String?,
        expiresAt: Date?
    ) throws -> PreparedExchange {
        guard let expiresAt else { throw ResolutionError.invalidResponse }
        switch method {
        case "manual":
            guard exchangeToken == nil,
                  let exchangeCode,
                  let canonical = ManualExchangeCode.normalize(exchangeCode) else {
                throw ResolutionError.invalidResponse
            }
            return PreparedExchange(credential: .code(canonical), expiresAt: expiresAt)
        case "qr", "bluetooth", "photo":
            guard exchangeCode == nil,
                  let exchangeToken,
                  !exchangeToken.isEmpty else {
                throw ResolutionError.invalidResponse
            }
            return PreparedExchange(credential: .token(exchangeToken), expiresAt: expiresAt)
        default:
            throw ResolutionError.invalidResponse
        }
    }
}
