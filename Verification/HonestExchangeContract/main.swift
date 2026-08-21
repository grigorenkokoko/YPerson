import Foundation

private let harnessVersion = 3

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
let firstProfileOperation = profileEpoch.capture()
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

let cancel = PendingSyncOperation(
    request: SyncRequest(operation: .cancelExchange, exchangeCode: "YP-0123-4567-89AB"),
    expiresAt: nil,
    localCardID: nil
)
defaults.set(
    try JSONEncoder().encode([publish, claim, cancel]),
    forKey: "yperson.v2.pending_operations"
)
store.purgeNonDurablePendingOperations()
require(store.pendingOperations == [publish], "legacy raw claim/cancel credentials were not purged")

print("honest-exchange-contract-v\(harnessVersion)-pass")
