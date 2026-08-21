import Foundation

private let harnessVersion = 8

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

let contactCommitBarrier = ContactReconciliationCommitBarrier()
guard let orphanContactSession = contactCommitBarrier.beginSession(),
      let liveContactSession = contactCommitBarrier.beginSession() else {
    fatalError("shared Contacts barrier did not admit active-profile sessions")
}
let firstCommitStarted = DispatchSemaphore(value: 0)
let secondCommitStarted = DispatchSemaphore(value: 0)
let releaseFirstCommit = DispatchSemaphore(value: 0)
let releaseSecondCommit = DispatchSemaphore(value: 0)
let commitsCompleted = DispatchSemaphore(value: 0)
for (session, started, release) in [
    (orphanContactSession, firstCommitStarted, releaseFirstCommit),
    (liveContactSession, secondCommitStarted, releaseSecondCommit)
] {
    DispatchQueue.global(qos: .userInitiated).async {
        try? contactCommitBarrier.performCommit(for: session) {
            started.signal()
            release.wait()
        }
        commitsCompleted.signal()
    }
}
require(firstCommitStarted.wait(timeout: .now() + 1) == .success, "first contact commit did not start")
require(secondCommitStarted.wait(timeout: .now() + 1) == .success, "second contact commit did not start")
contactCommitBarrier.invalidateSession(orphanContactSession)
require(
    !contactCommitBarrier.isCurrent(orphanContactSession),
    "a deinitialized presenter left its Contacts session active"
)
let contactInvalidation = contactCommitBarrier.beginDeletion()
require(
    contactCommitBarrier.beginSession() == nil,
    "Contacts admitted a new presenter session after deletion began"
)
require(!contactCommitBarrier.isCurrent(liveContactSession), "live contact session remained current")
requireThrows("orphan invalidated session began another Contacts write") {
    try contactCommitBarrier.performCommit(for: orphanContactSession) {}
}

let contactInvalidationFinished = DispatchSemaphore(value: 0)
Task.detached {
    await contactInvalidation.waitForInFlightCommits()
    contactInvalidationFinished.signal()
}
let independentProgress = DispatchSemaphore(value: 0)
Task.detached { independentProgress.signal() }
require(
    independentProgress.wait(timeout: .now() + 1) == .success,
    "async Contacts invalidation blocked unrelated progress"
)
require(
    contactInvalidationFinished.wait(timeout: .now() + 0.05) == .timedOut,
    "global invalidation completed before orphan and live commits"
)
releaseFirstCommit.signal()
releaseSecondCommit.signal()
require(commitsCompleted.wait(timeout: .now() + 1) == .success, "first contact commit did not complete")
require(commitsCompleted.wait(timeout: .now() + 1) == .success, "second contact commit did not complete")
require(contactInvalidationFinished.wait(timeout: .now() + 1) == .success, "global invalidation did not finish")
contactCommitBarrier.reactivateForUserCreation()
guard let reactivatedContactSession = contactCommitBarrier.beginSession() else {
    fatalError("Contacts barrier did not reactivate for explicit card creation")
}
require(
    contactCommitBarrier.isCurrent(reactivatedContactSession)
        && !contactCommitBarrier.isCurrent(orphanContactSession),
    "Contacts reactivation made an orphan session current"
)

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

let pendingPushUpdate = PendingPushTokenSyncRecord.update(
    token: "token-b",
    operationID: "push-b"
)
let pendingPushRemoval = PendingPushTokenSyncRecord.removal(operationID: "push-remove")
require(pendingPushUpdate.token == "token-b", "single-record APNs update lost its token")
require(pendingPushRemoval.token == nil, "single-record APNs removal synthesized a token")
let decodedPendingPushRemoval = try JSONDecoder().decode(
    PendingPushTokenSyncRecord.self,
    from: JSONEncoder().encode(pendingPushRemoval)
)
require(
    decodedPendingPushRemoval == pendingPushRemoval,
    "single-record APNs removal did not round-trip atomically"
)

let audioPlaceholderOperation = PendingSyncOperation(
    request: SyncRequest(
        operation: .publishCard,
        card: PersonCard(
            id: "audio-owner",
            name: "Audio Owner",
            role: "",
            company: "",
            phone: "",
            email: "",
            tagline: "",
            hasAudioGreeting: true,
            meetingPlace: nil,
            isBlocked: false
        ),
        audioAssetID: nil
    ),
    expiresAt: nil,
    localCardID: nil
)
require(
    ProfileBootstrapCredentialPolicy.requiresNewCredential(
        apiClientExists: false,
        pendingOperations: [audioPlaceholderOperation]
    ),
    "a recovered publication with no client did not request bootstrap credentials"
)
require(
    !ProfileBootstrapCredentialPolicy.requiresNewCredential(
        apiClientExists: false,
        pendingOperations: []
    ),
    "an empty app implicitly requested profile credentials"
)
require(
    !ProfileBootstrapCredentialPolicy.requiresNewCredential(
        apiClientExists: true,
        pendingOperations: [audioPlaceholderOperation]
    ),
    "bootstrap replaced an existing profile client"
)
require(
    PendingPublicationAudioRecoveryPolicy.action(
        for: audioPlaceholderOperation,
        savedGreetingAvailable: false
    ) == .waitForSavedGreeting,
    "audio placeholder was allowed to erase published audio after a crash"
)
require(
    PendingPublicationAudioRecoveryPolicy.action(
        for: audioPlaceholderOperation,
        savedGreetingAvailable: true
    ) == .uploadSavedGreeting,
    "recoverable public greeting was not selected for upload"
)
let recoveredAudioRequest = PendingPublicationAudioRecoveryPolicy.uploadedGreetingRequest(
    for: audioPlaceholderOperation,
    audioAssetID: "asset-recovered"
)
require(
    recoveredAudioRequest?.card?.hasAudioGreeting == true
        && recoveredAudioRequest?.audioAssetID == "asset-recovered"
        && recoveredAudioRequest?.operationID == audioPlaceholderOperation.id,
    "recovered audio request did not preserve the true+asset backend invariant"
)
let audioFreeOperation = PendingSyncOperation(
    request: SyncRequest(
        operation: .publishCard,
        card: audioPlaceholderOperation.request.card.map {
            var card = $0
            card.hasAudioGreeting = false
            return card
        }
    ),
    expiresAt: nil,
    localCardID: nil
)
require(
    PendingPublicationAudioRecoveryPolicy.action(
        for: audioFreeOperation,
        savedGreetingAvailable: false
    ) == .send,
    "ordinary audio-free publication was blocked"
)

require(
    PublicGreetingCommitPolicy.restoreAction(
        expectedPublic: false,
        committedExists: false,
        legacyExists: true
    ) == .none,
    "an uncommitted legacy draft was promoted without a public card"
)
require(
    PublicGreetingCommitPolicy.restoreAction(
        expectedPublic: true,
        committedExists: true,
        legacyExists: true
    ) == .useCommitted,
    "an existing committed greeting lost precedence over a later draft"
)
require(
    PublicGreetingCommitPolicy.restoreAction(
        expectedPublic: true,
        committedExists: false,
        legacyExists: true
    ) == .requireExplicitResave,
    "an untrusted legacy file was auto-promoted from own-card metadata alone"
)
require(
    PublicGreetingCommitPolicy.shouldPromoteDraft(
        explicitPublicChoice: true,
        cardSaveSucceeded: true,
        draftIsValid: true
    ),
    "a valid explicitly-public draft could not commit after card save"
)
require(
    !PublicGreetingCommitPolicy.shouldPromoteDraft(
        explicitPublicChoice: true,
        cardSaveSucceeded: false,
        draftIsValid: true
    ),
    "public selection alone promoted a draft before card save"
)
require(
    !PublicGreetingCommitPolicy.shouldPromoteDraft(
        explicitPublicChoice: false,
        cardSaveSucceeded: true,
        draftIsValid: true
    ),
    "a private/cancelled draft was allowed to become the committed public greeting"
)
require(
    PublicGreetingCommitPolicy.playbackSource(
        hasUncommittedDraft: true,
        committedPublicEnabled: true
    ) == .draft,
    "audio preview did not prefer its explicit uncommitted draft"
)
require(
    PublicGreetingCommitPolicy.playbackSource(
        hasUncommittedDraft: false,
        committedPublicEnabled: true
    ) == .committedPublic,
    "a committed public greeting could not play after promotion/relaunch"
)
require(
    PublicGreetingCommitPolicy.playbackSource(
        hasUncommittedDraft: false,
        committedPublicEnabled: false
    ) == .none,
    "audio playback synthesized a source without a draft or committed greeting"
)

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
let journalCard = PersonCard(
    id: card.id,
    name: "Journal owner",
    role: card.role,
    company: card.company,
    phone: card.phone,
    email: card.email,
    tagline: card.tagline,
    hasAudioGreeting: true,
    meetingPlace: card.meetingPlace,
    isBlocked: false
)
let journalOperation = PendingSyncOperation(
    request: SyncRequest(operation: .publishCard, card: journalCard.exchangeCopy),
    expiresAt: nil,
    localCardID: nil
)
store.pendingCardPublicationJournal = CardPublicationJournal(
    card: journalCard,
    operation: journalOperation
)
guard let recoveredStore = AppGroupSnapshotStore(appGroupIdentifier: suiteName) else {
    fatalError("publication journal recovery store unavailable")
}
require(recoveredStore.readOwnCard() == journalCard, "bootstrap did not recover journaled own card")
require(
    recoveredStore.pendingOperations == [journalOperation],
    "bootstrap did not recover the matching durable publication intent"
)
require(recoveredStore.pendingCardPublicationJournal == nil, "bootstrap did not clear the recovered journal")
let atomicallySavedCard = PersonCard(
    id: card.id,
    name: "Atomically saved owner",
    role: card.role,
    company: card.company,
    phone: card.phone,
    email: card.email,
    tagline: card.tagline,
    hasAudioGreeting: false,
    meetingPlace: card.meetingPlace,
    isBlocked: false
)
let atomicallyStaged = try recoveredStore.writeOwnCardAndStagePublication(atomicallySavedCard)
require(recoveredStore.readOwnCard() == atomicallySavedCard, "atomic save did not commit own card")
require(
    recoveredStore.pendingOperations == [atomicallyStaged],
    "atomic save did not compact to the matching publication intent"
)
store.pendingOperations = []
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
store.pendingPushTokenSyncRecord = pendingPushUpdate
store.pendingPushTokenSyncRecord = pendingPushRemoval
require(
    store.pendingPushTokenSyncRecord == pendingPushRemoval,
    "APNs removal tore across token/removal/operationID storage"
)
require(
    !store.clearPendingPushTokenSyncRecord(ifCurrent: pendingPushUpdate)
        && store.pendingPushTokenSyncRecord == pendingPushRemoval,
    "late APNs update cleanup erased a newer removal"
)
require(store.clearPendingPushTokenSyncRecord(ifCurrent: pendingPushRemoval), "current APNs removal did not clear")
require(store.pendingPushTokenSyncRecord == nil, "cleared APNs record remained durable")
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
