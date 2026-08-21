import Foundation

private let harnessVersion = 6

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func requireThrows(_ message: String, _ body: () throws -> Void) {
    do {
        try body()
        fatalError(message)
    } catch {
        // Expected.
    }
}

final class LockedStringEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AsyncTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isReleased = true
        let continuations = waiters
        waiters.removeAll()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }
}

let card = PersonCard(
    id: "owner",
    name: "Owner",
    role: "Engineer",
    company: "YPerson",
    phone: "  +7 900 555-10-20  ",
    email: "owner@example.invalid",
    tagline: "Hello",
    hasAudioGreeting: false,
    meetingPlace: "Moscow",
    isBlocked: false
)

require(card.exchangeCopy.phone.isEmpty, "public card leaked phone")
require(card.exchangeCopy.meetingPlace == nil, "public card leaked meeting place")
require(
    PrivateCardFields(card: card)?.phone == "+7 900 555-10-20",
    "private phone was not normalized"
)
require(
    ManualExchangeCode.normalize("yp 0123 4567 89ab") == "YP-0123-4567-89AB",
    "manual code normalization failed"
)
require(
    ManualExchangeCode.normalize("YP-O123-4567-89AB") == nil,
    "ambiguous manual code was accepted"
)

let expiry = Date(timeIntervalSince1970: 1_800_000_000)
let tokenPrepared = try PreparedExchange.resolve(
    method: "bluetooth",
    exchangeToken: "opaque-token",
    exchangeCode: nil,
    expiresAt: expiry
)
require(tokenPrepared.credential.exchangeToken == "opaque-token", "token was not routed as a token")
require(tokenPrepared.credential.exchangeCode == nil, "token was duplicated as a code")

let codePrepared = try PreparedExchange.resolve(
    method: "manual",
    exchangeToken: nil,
    exchangeCode: "yp 0123 4567 89ab",
    expiresAt: expiry
)
require(codePrepared.credential.exchangeToken == nil, "code was duplicated as a token")
require(
    codePrepared.credential.exchangeCode == "YP-0123-4567-89AB",
    "code was not routed canonically"
)
requireThrows("mixed prepared credentials were accepted") {
    _ = try PreparedExchange.resolve(
        method: "manual",
        exchangeToken: "opaque-token",
        exchangeCode: "YP-0123-4567-89AB",
        expiresAt: expiry
    )
}

let codeRequest = SyncRequest(
    operation: .claimExchange,
    exchangeCode: "YP-0123-4567-89AB"
)
let codeJSON = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(codeRequest)
) as! [String: Any]
require(codeJSON["exchangeCode"] as? String == "YP-0123-4567-89AB", "code was omitted")
require(codeJSON["exchangeToken"] == nil, "code was duplicated into exchangeToken")

let publicRequest = SyncRequest(
    operation: .prepareExchange,
    card: card.exchangeCopy,
    privateFields: nil,
    exchangeMethod: "qr"
)
let publicJSON = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(publicRequest)
) as! [String: Any]
let publicCard = publicJSON["card"] as! [String: Any]
require(publicCard["phone"] as? String == "", "QR request leaked phone")
require(publicJSON["privateFields"] == nil, "QR request leaked private fields")

var consent = PrivatePhoneShareConsent()
consent.authorize()
require(consent.isAuthorized, "authorization was not recorded")
require(
    consent.consume(forPreparationMethod: "bluetooth", card: card) == nil,
    "Bluetooth accepted private fields"
)
require(consent.isAuthorized, "public Bluetooth consumed manual-only consent")
require(
    consent.consume(forPreparationMethod: "manual", card: card)?.phone == "+7 900 555-10-20",
    "manual preparation did not consume the authorized phone"
)
require(!consent.isAuthorized, "manual preparation did not consume authorization")
require(
    consent.consume(forPreparationMethod: "manual", card: card) == nil,
    "one authorization was reused by a second preparation"
)

consent.authorize()
let cardWithoutPhone = PersonCard(
    id: "owner-without-phone",
    name: "Owner",
    role: "Engineer",
    company: "YPerson",
    phone: "",
    email: "owner@example.invalid",
    tagline: "Hello",
    hasAudioGreeting: false,
    meetingPlace: nil,
    isBlocked: false
)
require(
    consent.consume(forPreparationMethod: "manual", card: cardWithoutPhone) == nil,
    "empty phone unexpectedly produced private fields"
)
require(!consent.isAuthorized, "failed private-field projection left authorization reusable")

var profileEpoch = ProfileOperationEpoch()
let firstProfileOperation: ProfileOperationContext = profileEpoch.capture()
require(
    profileEpoch.isCurrent(firstProfileOperation),
    "a newly captured profile operation epoch was not current"
)
profileEpoch.invalidate()
require(
    !profileEpoch.isCurrent(firstProfileOperation),
    "profile deletion did not invalidate an older operation epoch"
)
let replacementProfileOperation = profileEpoch.capture()
require(
    profileEpoch.isCurrent(replacementProfileOperation),
    "a post-invalidation profile operation epoch was not current"
)
require(
    replacementProfileOperation != firstProfileOperation,
    "profile epoch invalidation reused the stale snapshot"
)
profileEpoch.invalidate()
let recreatedProfileOperation: ProfileOperationContext = profileEpoch.capture()
require(
    !profileEpoch.isCurrent(firstProfileOperation),
    "an old UI context became current after profile recreation"
)
require(
    profileEpoch.isCurrent(recreatedProfileOperation),
    "a fresh post-recreation context was not usable"
)

var contactProfileLifecycle = ContactReconciliationProfileLifecycle()
require(contactProfileLifecycle.isActive, "Contacts did not begin in the active profile lifecycle")
contactProfileLifecycle.beginDeletion()
require(!contactProfileLifecycle.isActive, "Contacts stayed active during profile deletion")
contactProfileLifecycle.reactivateForUserCreation()
require(contactProfileLifecycle.isActive, "Contacts did not reactivate after explicit card creation")

let firstContactFence = ContactReconciliationSessionFence()
let secondContactFence = ContactReconciliationSessionFence()
let firstContactSession = firstContactFence.begin()
let secondContactSession = secondContactFence.begin()
let firstCommitStarted = DispatchSemaphore(value: 0)
let secondCommitStarted = DispatchSemaphore(value: 0)
let releaseFirstCommit = DispatchSemaphore(value: 0)
let releaseSecondCommit = DispatchSemaphore(value: 0)
let commitsCompleted = DispatchSemaphore(value: 0)
for (fence, session, started, release) in [
    (firstContactFence, firstContactSession, firstCommitStarted, releaseFirstCommit),
    (secondContactFence, secondContactSession, secondCommitStarted, releaseSecondCommit)
] {
    DispatchQueue.global(qos: .userInitiated).async {
        try? fence.performCommit(for: session) {
            started.signal()
            release.wait()
        }
        commitsCompleted.signal()
    }
}
require(firstCommitStarted.wait(timeout: .now() + 1) == .success, "first contact commit did not start")
require(secondCommitStarted.wait(timeout: .now() + 1) == .success, "second contact commit did not start")

let replacementFirstContactSession = firstContactFence.begin()
require(
    firstContactFence.isCurrent(replacementFirstContactSession),
    "replacement session on the first presenter did not become current"
)
let firstInvalidation = firstContactFence.beginInvalidation()
let secondInvalidation = secondContactFence.beginInvalidation()
require(!firstContactFence.isCurrent(firstContactSession), "first contact session remained current")
require(!secondContactFence.isCurrent(secondContactSession), "second contact session remained current")
requireThrows("first invalidated session began another Contacts write") {
    try firstContactFence.performCommit(for: firstContactSession) {}
}
requireThrows("second invalidated session began another Contacts write") {
    try secondContactFence.performCommit(for: secondContactSession) {}
}

let firstInvalidationFinished = DispatchSemaphore(value: 0)
let secondInvalidationFinished = DispatchSemaphore(value: 0)
Task.detached {
    await firstInvalidation.waitForInFlightCommits()
    firstInvalidationFinished.signal()
}
Task.detached {
    await secondInvalidation.waitForInFlightCommits()
    secondInvalidationFinished.signal()
}
let independentProgress = DispatchSemaphore(value: 0)
Task.detached { independentProgress.signal() }
require(
    independentProgress.wait(timeout: .now() + 1) == .success,
    "async Contacts invalidation blocked unrelated progress"
)
require(
    firstInvalidationFinished.wait(timeout: .now() + 0.05) == .timedOut,
    "first invalidation completed before its crossed commit"
)
require(
    secondInvalidationFinished.wait(timeout: .now() + 0.05) == .timedOut,
    "second invalidation completed before its crossed commit"
)
releaseFirstCommit.signal()
releaseSecondCommit.signal()
require(commitsCompleted.wait(timeout: .now() + 1) == .success, "first contact commit did not complete")
require(commitsCompleted.wait(timeout: .now() + 1) == .success, "second contact commit did not complete")
require(firstInvalidationFinished.wait(timeout: .now() + 1) == .success, "first invalidation did not finish")
require(secondInvalidationFinished.wait(timeout: .now() + 1) == .success, "second invalidation did not finish")

var bootstrapOwnership = ProfileBootstrapTaskOwnership()
let firstActiveBootstrap = bootstrapOwnership.beginActive().ticket
let replacementActiveStart = bootstrapOwnership.beginActive()
require(
    replacementActiveStart.replaced == firstActiveBootstrap,
    "a newer active bootstrap did not replace the previous active task"
)
bootstrapOwnership.finish(firstActiveBootstrap)
require(
    bootstrapOwnership.isCurrent(replacementActiveStart.ticket),
    "late cleanup from an old active bootstrap cleared its replacement"
)
guard let deletionRecovery = bootstrapOwnership.beginDeletionRecovery() else {
    fatalError("deletion recovery did not acquire ownership")
}
require(
    bootstrapOwnership.beginDeletionRecovery() == nil,
    "a foreground refresh duplicated deletion recovery"
)
require(
    bootstrapOwnership.invalidateActive() == replacementActiveStart.ticket,
    "profile deletion did not invalidate the active bootstrap"
)
require(
    bootstrapOwnership.isCurrent(deletionRecovery),
    "profile deletion callback invalidated its own recovery task"
)
bootstrapOwnership.finish(deletionRecovery)
require(
    bootstrapOwnership.beginDeletionRecovery() != nil,
    "completed recovery ownership was never released"
)

let operationGate = AsyncFIFOOperationGate()
let firstGateEntered = DispatchSemaphore(value: 0)
let releaseFirstGate = AsyncTestLatch()
let secondGateAttempted = DispatchSemaphore(value: 0)
let secondGateEntered = DispatchSemaphore(value: 0)
let gateOperationsFinished = DispatchSemaphore(value: 0)
let gateEvents = LockedStringEvents()
Task.detached {
    guard let lease = try? await operationGate.acquire() else { return }
    gateEvents.append("A")
    firstGateEntered.signal()
    await releaseFirstGate.wait()
    operationGate.release(lease)
    gateOperationsFinished.signal()
}
require(firstGateEntered.wait(timeout: .now() + 1) == .success, "first FIFO operation did not start")
Task.detached {
    secondGateAttempted.signal()
    guard let lease = try? await operationGate.acquire() else { return }
    gateEvents.append("B")
    secondGateEntered.signal()
    operationGate.release(lease)
    gateOperationsFinished.signal()
}
require(secondGateAttempted.wait(timeout: .now() + 1) == .success, "second FIFO operation was not queued")
require(
    secondGateEntered.wait(timeout: .now() + 0.05) == .timedOut,
    "newer FIFO operation overtook an in-flight older operation"
)
releaseFirstGate.release()
require(secondGateEntered.wait(timeout: .now() + 1) == .success, "second FIFO operation never started")
require(gateOperationsFinished.wait(timeout: .now() + 1) == .success, "first FIFO operation did not finish")
require(gateOperationsFinished.wait(timeout: .now() + 1) == .success, "second FIFO operation did not finish")
let orderedGateEvents = gateEvents.values()
require(orderedGateEvents == ["A", "B"], "FIFO operation order was not stable")

let pushA = PushTokenSyncOwnership(token: "token-a", isRemoval: false, operationID: "push-a")
let pushB = PushTokenSyncOwnership(token: "token-b", isRemoval: false, operationID: "push-b")
let pushRemoval = PushTokenSyncOwnership(token: nil, isRemoval: true, operationID: "push-remove")
require(pushA.matches(token: "token-a", isRemoval: false, operationID: "push-a"), "push A lost ownership")
require(!pushA.matches(token: "token-b", isRemoval: false, operationID: "push-b"), "late push A matched push B")
require(pushB.matches(token: "token-b", isRemoval: false, operationID: "push-b"), "push B lost ownership")
require(!pushB.matches(token: nil, isRemoval: true, operationID: "push-remove"), "push B matched removal")
require(pushRemoval.matches(token: nil, isRemoval: true, operationID: "push-remove"), "removal lost ownership")

var deletionAttempts = ProfileDeletionAttemptOwnership()
let firstDeletionAttempt = deletionAttempts.begin()
require(
    deletionAttempts.acceptsOutcome(for: firstDeletionAttempt, profileIsActive: false),
    "expected profile-deletion apply suppressed its own outcome"
)
let laterDeletionAttempt = deletionAttempts.begin()
require(
    !deletionAttempts.acceptsOutcome(for: firstDeletionAttempt, profileIsActive: false),
    "a later deletion attempt kept an older outcome valid"
)
require(
    deletionAttempts.acceptsOutcome(for: laterDeletionAttempt, profileIsActive: false),
    "current deletion outcome was rejected"
)
require(deletionAttempts.finish(laterDeletionAttempt), "current deletion attempt did not clear")
require(!deletionAttempts.finish(laterDeletionAttempt), "deletion outcome could be emitted twice")
let recreationInvalidatedAttempt = deletionAttempts.begin()
deletionAttempts.invalidateForProfileRecreation()
require(
    !deletionAttempts.acceptsOutcome(for: recreationInvalidatedAttempt, profileIsActive: true),
    "profile recreation kept a stale deletion outcome valid"
)

var scannerGate = QRScannerLaunchGate()
require(scannerGate.begin(alreadyPresenting: false), "widget scanner launch did not begin")
require(scannerGate.isPending, "widget scanner launch was not marked pending")
scannerGate.reset()
require(!scannerGate.isPending, "profile deletion left the widget launch gate pending")
require(
    scannerGate.begin(alreadyPresenting: false),
    "widget scanner could not launch after profile recreation"
)
scannerGate.complete()

let deletionRecord = ProfileDeletionRecord(operationID: "stable-delete-operation")
require(!deletionRecord.serverAcknowledged, "new deletion record started acknowledged")
let encodedDeletion = try JSONEncoder().encode(deletionRecord)
let decodedDeletion = try JSONDecoder().decode(ProfileDeletionRecord.self, from: encodedDeletion)
require(
    decodedDeletion == deletionRecord,
    "deletion record did not round-trip"
)

var activeLifecycle = ProfileLifecycle(
    deletionRecord: nil,
    legacyDeletionPending: false,
    terminallyDeleted: false
)
require(activeLifecycle.state == .active, "fresh lifecycle was not active")
require(!activeLifecycle.suppressesSync, "fresh lifecycle suppressed sync")
try activeLifecycle.beginDeletion()
require(activeLifecycle.state == .deleting, "deletion did not suppress the lifecycle")
require(activeLifecycle.suppressesSync, "deleting lifecycle allowed sync")
requireThrows("unacknowledged remote deletion became terminal") {
    try activeLifecycle.finishDeletion(record: deletionRecord, allowLocalOnly: false)
}
var acknowledgedDeletion = deletionRecord
acknowledgedDeletion.markServerAcknowledged()
try activeLifecycle.finishDeletion(record: acknowledgedDeletion, allowLocalOnly: false)
require(activeLifecycle.state == .terminal, "acknowledged deletion did not become terminal")
require(activeLifecycle.suppressesSync, "terminal lifecycle allowed stale sync")
try activeLifecycle.reactivateForUserCreation()
require(activeLifecycle.state == .active, "explicit creation did not reactivate lifecycle")

var deletingLifecycle = ProfileLifecycle(
    deletionRecord: deletionRecord,
    legacyDeletionPending: false,
    terminallyDeleted: false
)
require(deletingLifecycle.state == .deleting, "durable deletion record was ignored")
requireThrows("deleting lifecycle allowed profile recreation") {
    try deletingLifecycle.reactivateForUserCreation()
}
try deletingLifecycle.finishDeletion(record: deletionRecord, allowLocalOnly: true)
require(deletingLifecycle.state == .terminal, "local-only deletion did not become terminal")

let legacyDeletingLifecycle = ProfileLifecycle(
    deletionRecord: nil,
    legacyDeletionPending: true,
    terminallyDeleted: false
)
require(legacyDeletingLifecycle.state == .deleting, "legacy pending deletion was not recovered")
let terminalLifecycle = ProfileLifecycle(
    deletionRecord: nil,
    legacyDeletionPending: false,
    terminallyDeleted: true
)
require(terminalLifecycle.state == .terminal, "durable terminal deletion was not restored")

var transferGeneration = ProfileTransferGeneration()
let transferBeforeDeletion = transferGeneration.capture()
transferGeneration.invalidate()
require(
    !transferGeneration.isCurrent(transferBeforeDeletion),
    "profile transfer generation allowed a post-deletion cache commit"
)

require(
    !PendingSyncOperationPersistencePolicy.allowsDurablePersistence(.claimExchange),
    "claim credential was allowed into durable pending storage"
)
require(
    !PendingSyncOperationPersistencePolicy.allowsDurablePersistence(.cancelExchange),
    "cancel credential was allowed into durable pending storage"
)
require(
    PendingSyncOperationPersistencePolicy.allowsDurablePersistence(.publishCard),
    "non-sensitive publish retry was disabled"
)
require(
    PendingSyncOperationPersistencePolicy.allowsDurablePersistence(.report),
    "non-sensitive moderation retry was disabled"
)

let suiteName = "app.yperson.honest-exchange-harness.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    fatalError("temporary UserDefaults suite unavailable")
}
defaults.removePersistentDomain(forName: suiteName)
defer { defaults.removePersistentDomain(forName: suiteName) }

guard let store = AppGroupSnapshotStore(appGroupIdentifier: suiteName) else {
    fatalError("temporary snapshot store unavailable")
}
store.profileDeletionRecord = deletionRecord
store.profileDeletionPending = true
store.clearUserData()
require(
    store.profileDeletionRecord == deletionRecord,
    "clearUserData erased the crash-safe deletion record"
)
var storedAcknowledgement = deletionRecord
storedAcknowledgement.markServerAcknowledged()
store.profileDeletionRecord = storedAcknowledgement
require(
    store.profileDeletionRecord?.serverAcknowledged == true,
    "server acknowledgement was not durably recorded"
)
try store.writeOwnCard(card)
let crashWindowPublish = PendingSyncOperation(
    request: SyncRequest(operation: .publishCard, card: card.exchangeCopy),
    expiresAt: nil,
    localCardID: nil
)
store.enqueue(crashWindowPublish)
let crashRecoveredCard = PersonCard(
    id: card.id,
    name: "Crash-recovered owner",
    role: card.role,
    company: card.company,
    phone: card.phone,
    email: card.email,
    tagline: card.tagline,
    hasAudioGreeting: false,
    meetingPlace: card.meetingPlace,
    isBlocked: false
)
try store.writeOwnCard(crashRecoveredCard)
require(
    !store.revalidatePendingPublication(crashWindowPublish),
    "bootstrap retry accepted a durable publication for stale local content"
)
require(
    store.pendingOperations.count == 1
        && store.pendingOperations[0].id != crashWindowPublish.id
        && store.pendingOperations[0].request.card == crashRecoveredCard.exchangeCopy,
    "bootstrap retry did not atomically replace stale A with current public B"
)
store.pendingOperations = []
let claim = PendingSyncOperation(
    request: SyncRequest(operation: .claimExchange, exchangeToken: "raw-claim-token"),
    expiresAt: expiry,
    localCardID: "local-card"
)
store.enqueue(claim)
require(store.pendingOperations.isEmpty, "new raw claim credential reached UserDefaults")

let publish = PendingSyncOperation(
    request: SyncRequest(operation: .publishCard, card: card.exchangeCopy),
    expiresAt: nil,
    localCardID: nil
)
store.enqueue(publish)
require(store.pendingOperations == [publish], "durable publish retry was not persisted")

let firstPublicationOwnership = PublicationCardOwnership(card: card)
var publishedFirstCard = card
publishedFirstCard.version = 2
publishedFirstCard.syncState = .synced
require(
    firstPublicationOwnership.matches(publishedFirstCard),
    "server-managed publication metadata changed local-card ownership"
)
let newerLocalCard = PersonCard(
    id: card.id,
    name: "Newer Owner",
    role: card.role,
    company: card.company,
    phone: card.phone,
    email: card.email,
    tagline: card.tagline,
    hasAudioGreeting: false,
    meetingPlace: card.meetingPlace,
    isBlocked: false
)
try store.writeOwnCard(newerLocalCard)
let latePublicationApplied = try store.writePublishedOwnCard(
    publishedFirstCard,
    ifCurrent: firstPublicationOwnership
)
require(
    !latePublicationApplied,
    "a late older publication response overwrote a newer local card"
)
require(
    store.readOwnCard() == newerLocalCard,
    "a rejected older publication response changed newer local content"
)

let newerPublish = PendingSyncOperation(
    request: SyncRequest(
        operation: .publishCard,
        card: newerLocalCard.exchangeCopy
    ),
    expiresAt: nil,
    localCardID: nil
)
let moderation = PendingSyncOperation(
    request: SyncRequest(operation: .report, moderationCategory: "spam"),
    expiresAt: nil,
    localCardID: nil
)
store.enqueue(moderation)
store.enqueue(newerPublish)
require(
    store.pendingOperations.filter { $0.request.operation == .publishCard } == [newerPublish],
    "newer durable publish did not compact its predecessor"
)
require(
    store.containsPendingOperation(id: newerPublish.id),
    "latest durable publish ownership was not queryable"
)
require(
    !store.containsPendingOperation(id: publish.id),
    "compacted publish retained pending ownership"
)
store.removePendingOperation(id: publish.id)
require(
    store.containsPendingOperation(id: newerPublish.id),
    "late cleanup for an older publication removed the newer durable intent"
)

let cancel = PendingSyncOperation(
    request: SyncRequest(operation: .cancelExchange, exchangeCode: "YP-0123-4567-89AB"),
    expiresAt: nil,
    localCardID: nil
)
defaults.set(
    try JSONEncoder().encode([newerPublish, claim, cancel]),
    forKey: "yperson.v2.pending_operations"
)
store.purgeNonDurablePendingOperations()
require(store.pendingOperations == [newerPublish], "legacy raw claim/cancel credentials were not purged")

print("honest-exchange-contract-v\(harnessVersion)-pass")
