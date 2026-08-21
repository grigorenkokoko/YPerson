# YPerson Honest Exchange Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Face ID-authorized phone sharing recipient-specific and add a real server-issued, one-time manual exchange code without exposing the phone in public cards or QR payloads.

**Architecture:** Keep `PersonCard.exchangeCopy` as the only public projection and transmit `PrivateCardFields` separately during online preparation. The backend atomically publishes the public card, stores temporary private fields by credential digest, and converts them into a directional connection grant on claim; manual preparation uses a 60-bit Crockford code while QR/Bluetooth retain opaque tokens. Swift uses typed credentials so UI and coordinator cannot mix code and token fields.

**Tech Stack:** Swift 5, UIKit, Foundation/Codable, iOS 15, Python 3.12, FastAPI, Pydantic v2, YDB Serverless, pytest, Ruff, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-21-yperson-honest-exchange-design.md`

## Global Constraints

- The public card always strips `phone` and local-only `meetingPlace`.
- Private phone sharing is allowed only after local Face ID/device-passcode approval and only for Bluetooth or manual-code preparation.
- QR and photo payloads remain public-only.
- Manual codes use `YP-XXXX-XXXX-XXXX`, twelve unambiguous Crockford Base32 characters, at most 10 minutes, and one successful claim.
- Raw exchange tokens and codes are never stored server-side or sent to analytics/logs.
- Contract version stays at 2; new wire fields are optional and QR/Bluetooth compatibility is preserved.
- iOS deployment target remains 15.0 and no XCTest/UI-test target is added.
- Every production change starts with a failing focused test or Foundation-only harness and ends with a focused green run.
- User PersonalDebug configuration in the primary checkout must not be modified.

---

### Task 1: Strict wire schema and manual-code primitives

**Files:**
- Modify: `backend/app/schemas.py:41-205`
- Modify: `backend/app/sync_service.py:1-23,254-272`
- Modify: `backend/tests/test_schemas.py`
- Modify: `backend/tests/test_sync_service.py`

**Interfaces:**
- Produces: `PrivateCardFields(phone: str)`.
- Produces: optional request fields `privateFields: PrivateCardFields | None` and `exchangeCode: str | None`.
- Produces: optional response fields `exchangeCode: str | None` and `exchangeExpiresAt: datetime | None`.
- Produces: `derive_exchange_code(bearer: str, installation_id: str, operation_id: str) -> str`.
- Produces: `normalize_exchange_code(value: str) -> str`, raising `ValueError` for invalid input.

- [x] **Step 1: Add failing schema tests**

Add tests that accept a trimmed phone only on `prepareExchange`, reject empty/over-64/unknown private fields, require exactly one credential for claim/cancel, and decode the new response fields:

```python
def public_card() -> dict[str, object]:
    return {
        "id": "card-owner",
        "name": "Owner",
        "role": "Engineer",
        "company": "YPerson",
        "phone": "",
        "email": "owner@example.invalid",
        "tagline": "Hello",
        "hasAudioGreeting": False,
        "meetingPlace": None,
        "isBlocked": False,
    }


def test_prepare_exchange_accepts_strict_private_phone() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "prepareExchange",
            "card": public_card(),
            "exchangeMethod": "manual",
            "privateFields": {"phone": "  +7 900 555-10-20  "},
        }
    )
    assert request.privateFields == PrivateCardFields(phone="+7 900 555-10-20")


@pytest.mark.parametrize("phone", ["", "   ", "1" * 65])
def test_private_phone_is_bounded(phone: str) -> None:
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(
            valid_request()
            | {
                "operation": "prepareExchange",
                "card": public_card(),
                "privateFields": {"phone": phone},
            }
        )


def test_claim_exchange_requires_exactly_one_credential() -> None:
    SyncRequest.model_validate(
        valid_request() | {"operation": "claimExchange", "exchangeCode": "YP-0123-4567-89AB"}
    )
    with pytest.raises(ValidationError, match="exactly one"):
        SyncRequest.model_validate(valid_request() | {"operation": "claimExchange"})
    with pytest.raises(ValidationError, match="exactly one"):
        SyncRequest.model_validate(
            valid_request()
            | {
                "operation": "claimExchange",
                "exchangeToken": "opaque-token",
                "exchangeCode": "YP-0123-4567-89AB",
            }
        )
```

- [x] **Step 2: Run the schema tests and record RED**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_schemas.py -k 'private or credential or exchange_response'
```

Expected: failures because `PrivateCardFields`, `privateFields`, `exchangeCode`, and `exchangeExpiresAt` do not exist.

- [x] **Step 3: Add strict Pydantic fields and operation validation**

Implement the model and additive fields:

```python
class PrivateCardFields(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    phone: str = Field(min_length=1, max_length=64)
```

Allow `privateFields` only for `prepareExchange`; allow `exchangeCode` only for claim/cancel. Replace the fixed token requirement for claim/cancel with an after-validator that enforces exactly one non-`None` value across `exchangeToken` and `exchangeCode`. Add both response fields with bounded types.

- [x] **Step 4: Add failing code-format tests**

```python
def test_manual_code_is_deterministic_unambiguous_and_domain_separated() -> None:
    first = derive_exchange_code(OWNER[1], OWNER[0], "prepare-manual-0001")
    replay = derive_exchange_code(OWNER[1], OWNER[0], "prepare-manual-0001")
    other = derive_exchange_code(OWNER[1], OWNER[0], "prepare-manual-0002")
    assert first == replay
    assert first != other
    assert re.fullmatch(r"YP-[0-9A-HJKMNP-TV-Z]{4}(?:-[0-9A-HJKMNP-TV-Z]{4}){2}", first)


@pytest.mark.parametrize(
    ("value", "canonical"),
    [
        ("yp 0123 4567 89ab", "YP-0123-4567-89AB"),
        ("0123-4567-89AB", "YP-0123-4567-89AB"),
        ("YP-0123-4567-89AB", "YP-0123-4567-89AB"),
    ],
)
def test_manual_code_normalization(value: str, canonical: str) -> None:
    assert normalize_exchange_code(value) == canonical
```

Also reject wrong length, `I`, `L`, `O`, `U`, punctuation other than separators, and arbitrary token text.

- [x] **Step 5: Run the code-format tests and record RED**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_sync_service.py -k 'manual_code'
```

Expected: import failures for the missing code helpers.

- [x] **Step 6: Implement code derivation and normalization**

Refactor token derivation through a shared domain-separated digest and implement the code without modulo bias:

```python
EXCHANGE_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def derive_exchange_code(bearer: str, installation_id: str, operation_id: str) -> str:
    digest = _derive_exchange_digest(
        b"yperson.exchange.code.v1", bearer, installation_id, operation_id
    )
    value = int.from_bytes(digest[:8], "big") >> 4
    payload = "".join(
        EXCHANGE_CODE_ALPHABET[(value >> shift) & 31]
        for shift in range(55, -1, -5)
    )
    return f"YP-{payload[:4]}-{payload[4:8]}-{payload[8:]}"
```

`normalize_exchange_code` uppercases, removes ASCII spaces and hyphens, removes one optional `YP` prefix, validates exactly 12 alphabet characters, and returns the grouped canonical representation.

- [x] **Step 7: Run focused tests GREEN**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_schemas.py backend/tests/test_sync_service.py -k 'private or credential or manual_code or exchange_response'
```

Expected: all selected tests pass.

- [x] **Step 8: Commit the wire primitives**

```bash
git add backend/app/schemas.py backend/app/sync_service.py \
  backend/tests/test_schemas.py backend/tests/test_sync_service.py
git commit -m "feat: define honest exchange wire contract"
```

---

### Task 2: Atomic service round trip and recipient isolation

**Files:**
- Modify: `backend/app/storage.py:45-93`
- Modify: `backend/app/sync_service.py:88-184`
- Modify: `backend/tests/test_sync_service.py:20-330`
- Modify: `backend/tests/test_review_contract.py`

**Interfaces:**
- Consumes: `PrivateCardFields`, `derive_exchange_code`, `normalize_exchange_code` from Task 1.
- Produces: `SyncStore.prepare_exchange(installation_id, operation_id, method, public_card, private_fields, raw_credential, expires_at) -> int`.
- Produces: service preparation responses containing exactly one credential and `exchangeExpiresAt`.
- Produces: claim/refresh responses overlaid with only the requester's directional private grant.

- [x] **Step 1: Change service fixtures to public cards and add failing round-trip tests**

Make the default `card()` helper return `phone=""`; pass `privateFields={"phone": "+70000000000"}` only in private tests. Add a three-installation test:

```python
OTHER = (
    "installation-other-0003",
    "other-bearer-secret-000000000000000000000000",
)


def test_manual_private_phone_is_directional_and_survives_refresh() -> None:
    prepared = post_sync(
        client,
        OWNER,
        "prepareExchange",
        operation_id="prepare-private-code-1",
        card=card("card-owner", "Owner").model_dump(mode="json"),
        exchangeMethod="manual",
        privateFields={"phone": "+70000000000"},
    )
    assert prepared.json()["exchangeToken"] is None
    assert prepared.json()["exchangeCode"].startswith("YP-")
    claimed = post_sync(
        client,
        PEER,
        "claimExchange",
        operation_id="claim-private-code-01",
        exchangeCode=prepared.json()["exchangeCode"],
    )
    assert claimed.json()["people"][0]["card"]["phone"] == "+70000000000"
    refreshed_peer = post_sync(client, PEER, "refresh", operation_id="peer-refresh-private")
    refreshed_other = post_sync(client, OTHER, "refresh", operation_id="other-refresh-public")
    assert refreshed_peer.json()["people"][0]["card"]["phone"] == "+70000000000"
    assert all(item["card"]["phone"] == "" for item in refreshed_other.json()["people"])
```

Add tests for deterministic prepare replay, QR token response, legacy formatted code in `exchangeToken`, one-time claim, cancellation, expiry, self-claim, and public-card rejection when `phone` or `meetingPlace` is non-empty.

- [x] **Step 2: Run service round-trip tests and record RED**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_sync_service.py -k 'manual_private or prepare_replay or public_card or legacy_code'
```

Expected: failures because the store boundary and service still publish and claim a single public card/token path.

- [x] **Step 3: Replace the test store with explicit temporary fields and directional grants**

The `MemoryStore` keeps:

```python
self.claims: dict[str, tuple[str, datetime, str | None]] = {}
self.exchange_private_fields: dict[str, PrivateCardFields] = {}
self.connection_private_fields: dict[tuple[str, str], PrivateCardFields] = {}
self.operation_results: dict[tuple[str, str], dict[str, object]] = {}
```

`prepare_exchange` performs card versioning, claim creation, optional temporary-field storage, and stable replay in one method. `claim_exchange` copies fields to key `(claimant, issuer)`. `refresh` overlays only `connection_private_fields[(requester, peer)]` on a copy of the public card.

- [x] **Step 4: Implement service credential routing and public-card guard**

Use one helper for public-card enforcement:

```python
def _require_public_card(card: PersonCard) -> None:
    if card.phone or card.meetingPlace is not None:
        raise StorageConflict("public card required")
```

Manual preparation derives/returns `exchangeCode`; other methods derive/return `exchangeToken`. Both return `exchangeExpiresAt`. Claim/cancel use normalized `exchangeCode` when present and otherwise preserve the opaque token exactly. Pass the public card and optional fields to the atomic store method.

- [x] **Step 5: Extend secret-free logging regression coverage**

Add an exchange-code sentinel and private-phone sentinel to `test_logs_exclude_hostile_url_and_sync_secrets`; send them in a rejected prepare/claim request and assert neither appears in captured logs or response details.

- [x] **Step 6: Run service and review-contract tests GREEN**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_sync_service.py backend/tests/test_review_contract.py
```

Expected: both files pass; QR/Bluetooth token assertions remain green.

- [x] **Step 7: Commit the service behavior**

```bash
git add backend/app/storage.py backend/app/sync_service.py \
  backend/tests/test_sync_service.py backend/tests/test_review_contract.py
git commit -m "feat: isolate private fields by exchange recipient"
```

---

### Task 3: YDB schema version 2 and durable directional grants

**Files:**
- Modify: `backend/app/ydb_schema.py:1-225`
- Modify: `backend/app/ydb_store.py:380-770,930-1045`
- Modify: `backend/tests/test_storage.py`
- Modify: `backend/tests/test_deployment_files.py`

**Interfaces:**
- Consumes: the `SyncStore` method signatures from Task 2.
- Produces: `exchange_private_fields(token_hash, fields_json, expires_at)` with TTL.
- Produces: `connection_private_fields(owner_installation_id, peer_installation_id, fields_json, updated_at)`.
- Produces: YDB refresh and claim paths that validate `PrivateCardFields` before overlay.

- [x] **Step 1: Add failing schema-version tests**

Assert `SCHEMA_VERSION == 2`, both new exact table descriptions exist, `exchange_private_fields` has expiry TTL DDL, and all existing version-1 table definitions remain byte-for-byte compatible.

```python
assert EXPECTED_TABLES["exchange_private_fields"].primary_key == ("token_hash",)
assert EXPECTED_TABLES["connection_private_fields"].primary_key == (
    "owner_installation_id",
    "peer_installation_id",
)
```

- [x] **Step 2: Run schema tests and record RED**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_storage.py backend/tests/test_deployment_files.py -k 'schema or private_fields'
```

Expected: failures because schema version 1 has neither table.

- [x] **Step 3: Add the two additive tables and bump schema version**

Add exact DDL:

```sql
CREATE TABLE IF NOT EXISTS exchange_private_fields (
    token_hash String NOT NULL,
    fields_json JsonDocument NOT NULL,
    expires_at Timestamp NOT NULL,
    PRIMARY KEY (token_hash)
) WITH (
    TTL = Interval("PT0S") ON expires_at
)
```

```sql
CREATE TABLE IF NOT EXISTS connection_private_fields (
    owner_installation_id Utf8 NOT NULL,
    peer_installation_id Utf8 NOT NULL,
    fields_json JsonDocument NOT NULL,
    updated_at Timestamp NOT NULL,
    PRIMARY KEY (owner_installation_id, peer_installation_id)
)
```

Update the schema docstring and tests to expect nine applied tables.

- [x] **Step 4: Add failing YDB adapter tests**

Script transactions that verify:

- prepare writes the public card, claim digest, optional private document, expiry, and one operation result in the same serializable transaction;
- prepare replay returns the original version and verifies the credential digest;
- claim copies fields only to `(claimant, issuer)` and records only `tokenHash` plus `issuerInstallationID` in operations;
- refresh overlays the grant for its requester but leaves another requester public;
- cancel deletes `exchange_private_fields` with the claim;
- profile deletion removes temporary rows and connection grants where the installation is either side;
- malformed JSON or an unknown private key raises `StorageIntegrityError`.

- [x] **Step 5: Run adapter tests and record RED**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_storage.py -k 'prepare_exchange or claim_exchange or refresh_private or delete_private'
```

Expected: signature mismatches and missing-query assertions.

- [x] **Step 6: Implement atomic prepare, claim overlay, refresh overlay, and cleanup**

Use `_json_document(_json(private_fields.model_dump(mode="json")))` only after Pydantic validation. Add helpers that reuse the adapter's existing `_json_value` decoder:

```python
def _stored_optional_private_fields(row: object, key: str) -> PrivateCardFields | None:
    value = _stored_value(row, key)
    if value is None:
        return None
    try:
        return PrivateCardFields.model_validate(_json_value(value), strict=True)
    except ValidationError as error:
        raise StorageIntegrityError from error


def _overlay_private_fields(
    card: PersonCard,
    fields: PrivateCardFields | None,
) -> PersonCard:
    if fields is None:
        return card
    return card.model_copy(update={"phone": fields.phone})
```

Keep the operation result secret-minimal:

```python
result_json = _json(
    {"tokenHash": token_hash.hex(), "issuerInstallationID": issuer_id}
)
```

On replay, load the issuer's current public card and the claimant's directional grant rather than deserializing a stored private card snapshot.

- [x] **Step 7: Run YDB and service tests GREEN**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_storage.py backend/tests/test_sync_service.py \
  backend/tests/test_deployment_files.py
```

Expected: all selected files pass.

- [x] **Step 8: Commit durable storage**

```bash
git add backend/app/ydb_schema.py backend/app/ydb_store.py \
  backend/tests/test_storage.py backend/tests/test_deployment_files.py
git commit -m "feat: persist recipient private field grants"
```

---

### Task 4: Swift exchange contract and typed credentials

**Files:**
- Create: `YPerson/Domain/ExchangeContract.swift`
- Modify: `YPerson/Domain/Models.swift:123-286,394-418`
- Modify: `YPerson/Networking/APIClient.swift:113-132`
- Modify: `project.yml`
- Modify: `YPerson.xcodeproj/project.pbxproj` via XcodeGen

**Interfaces:**
- Produces: `PrivateCardFields.init?(card: PersonCard)`.
- Produces: `ManualExchangeCode.normalize(_ value: String) -> String?`.
- Produces: `ExchangeCredential.token(String)` and `.code(String)` with `exchangeToken`/`exchangeCode` projections.
- Produces: `PreparedExchange(credential: ExchangeCredential, expiresAt: Date)`.
- Produces: additive Codable fields on Swift request/response/wire models.

- [x] **Step 1: Write a temporary failing Foundation harness**

Create `/tmp/yperson-honest-exchange-contract/main.swift` with:

```swift
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let card = PersonCard(
    id: "owner", name: "Owner", role: "Engineer", company: "YPerson",
    phone: "+7 900 555-10-20", email: "owner@example.invalid", tagline: "Hello",
    hasAudioGreeting: false, meetingPlace: "Moscow", isBlocked: false
)
require(card.exchangeCopy.phone.isEmpty, "public card leaked phone")
require(card.exchangeCopy.meetingPlace == nil, "public card leaked meeting place")
require(PrivateCardFields(card: card)?.phone == "+7 900 555-10-20", "private phone missing")
require(ManualExchangeCode.normalize("yp 0123 4567 89ab") == "YP-0123-4567-89AB", "normalization failed")
require(ManualExchangeCode.normalize("YP-O123-4567-89AB") == nil, "ambiguous code accepted")
let prepared = PreparedExchange(
    credential: .code("YP-0123-4567-89AB"),
    expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
)
require(prepared.credential.exchangeToken == nil, "code routed as token")
require(prepared.credential.exchangeCode == "YP-0123-4567-89AB", "code missing")
print("honest-exchange-contract-pass")
```

- [x] **Step 2: Compile the harness and record RED**

Run:

```bash
xcrun swiftc YPerson/Domain/Models.swift \
  /tmp/yperson-honest-exchange-contract/main.swift \
  -o /tmp/yperson-honest-exchange-contract/check
```

Expected: compile errors for `PrivateCardFields`, `ManualExchangeCode`, and `PreparedExchange`.

- [x] **Step 3: Implement the focused Swift contract file**

```swift
struct PrivateCardFields: Codable, Equatable {
    let phone: String

    init?(card: PersonCard) {
        let value = card.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return nil }
        phone = value
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
}
```

Implement manual normalization with the same alphabet and separators as Python. Add the new optional properties to `SyncRequest`, `SyncResponse`, and `SyncWireRequest`, then pass them through `APIClient.makeWireRequest`.

- [x] **Step 4: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
git diff --check
```

Expected: the project references `ExchangeContract.swift`; PersonalDebug source files and local signing values are unchanged.

- [x] **Step 5: Compile and run the harness GREEN**

Run:

```bash
xcrun swiftc YPerson/Domain/Models.swift YPerson/Domain/ExchangeContract.swift \
  /tmp/yperson-honest-exchange-contract/main.swift \
  -o /tmp/yperson-honest-exchange-contract/check
/tmp/yperson-honest-exchange-contract/check
```

Expected: `honest-exchange-contract-pass`.

- [x] **Step 6: Commit the Swift contract**

```bash
git add YPerson/Domain/ExchangeContract.swift YPerson/Domain/Models.swift \
  YPerson/Networking/APIClient.swift project.yml YPerson.xcodeproj/project.pbxproj
git commit -m "feat: add typed iOS exchange credentials"
```

---

### Task 5: Coordinator routing and public QR compatibility

**Files:**
- Modify: `YPerson/Networking/SyncCoordinator.swift:1-215,280-335`
- Modify: `YPerson/UI/CardViewController.swift:115-220,300-315`
- Modify: `/tmp/yperson-honest-exchange-contract/main.swift`

**Interfaces:**
- Consumes: `PrivateCardFields`, `ExchangeCredential`, `PreparedExchange` from Task 4.
- Produces: `prepareExchange(card:method:privateFields:greeting:) async throws -> PreparedExchange`.
- Produces: `claimExchange(credential:expiresAt:localCardID:ownCard:greeting:) async throws -> SyncResponse`.
- Produces: `cancelExchange(credential:) async`.

- [x] **Step 1: Extend the harness with failing request-routing assertions**

Encode token and code requests and inspect their JSON dictionaries:

```swift
let codeRequest = SyncRequest(
    operation: .claimExchange,
    exchangeCode: "YP-0123-4567-89AB"
)
let codeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(codeRequest)) as! [String: Any]
require(codeJSON["exchangeCode"] as? String == "YP-0123-4567-89AB", "code omitted")
require(codeJSON["exchangeToken"] == nil, "code duplicated as token")

let publicRequest = SyncRequest(
    operation: .prepareExchange,
    card: card.exchangeCopy,
    exchangeMethod: "qr"
)
let publicJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(publicRequest)) as! [String: Any]
let publicCard = publicJSON["card"] as! [String: Any]
require(publicCard["phone"] as? String == "", "QR request leaked phone")
require(publicJSON["privateFields"] == nil, "QR request leaked private fields")
```

- [x] **Step 2: Compile the harness and record RED**

Run the Task 4 compile command. Expected: initializer errors for the missing `exchangeCode` and `privateFields` routing.

- [x] **Step 3: Refactor coordinator methods to typed credentials**

Preparation sends `card.exchangeCopy` plus explicitly supplied private fields. It validates response exclusivity and method:

```swift
let expiresAt = response.exchangeExpiresAt
guard let expiresAt else { throw APIClient.ClientError.invalidResponse }
switch method {
case "manual":
    guard let code = response.exchangeCode,
          response.exchangeToken == nil,
          let canonical = ManualExchangeCode.normalize(code) else {
        throw APIClient.ClientError.invalidResponse
    }
    return PreparedExchange(credential: .code(canonical), expiresAt: expiresAt)
default:
    guard let token = response.exchangeToken, !token.isEmpty,
          response.exchangeCode == nil else {
        throw APIClient.ClientError.invalidResponse
    }
    return PreparedExchange(credential: .token(token), expiresAt: expiresAt)
}
```

Claim/cancel construct `SyncRequest` from `credential.exchangeToken` and `credential.exchangeCode`. Pending-operation retry keeps the encoded request unchanged.

- [x] **Step 4: Update Card QR to require a token and server expiry**

`CardViewController` requests preparation with `privateFields: nil`, rejects `.code`, encodes `prepared.expiresAt`, and cancels through `.token(token)`. Offline fallback continues to use `card.exchangeCopy` with no token.

- [x] **Step 5: Run the harness GREEN and build Debug**

Run:

```bash
xcrun swiftc YPerson/Domain/Models.swift YPerson/Domain/ExchangeContract.swift \
  /tmp/yperson-honest-exchange-contract/main.swift \
  -o /tmp/yperson-honest-exchange-contract/check
/tmp/yperson-honest-exchange-contract/check
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-debug \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: harness pass marker and Xcode exit 0.

- [x] **Step 6: Commit coordinator and QR changes**

```bash
git add YPerson/Networking/SyncCoordinator.swift YPerson/UI/CardViewController.swift
git commit -m "feat: route exchange codes separately from tokens"
```

---

### Task 6: Truthful Exchange UI and code presentation

**Files:**
- Create: `YPerson/UI/ShortCodeViewController.swift`
- Modify: `YPerson/UI/ExchangeViewController.swift:6-78,204-280,494-558`
- Modify: `project.yml`
- Modify: `YPerson.xcodeproj/project.pbxproj` via XcodeGen
- Modify: `Release/manual-device-checks.md`

**Interfaces:**
- Consumes: typed coordinator methods from Task 5.
- Produces: `ShortCodeViewController(code:expiresAt:onClose:)` with once-only cancellation callback.
- Produces: outgoing Bluetooth/manual private-field selection and manual code input normalization.

- [x] **Step 1: Add a failing source-contract check to the Swift harness workflow**

Before UI edits, verify the intended source markers are absent:

```bash
! rg -q 'Показать короткий код' YPerson/UI/ExchangeViewController.swift
! rg -q 'Поделиться телефоном · Face ID' YPerson/UI/ExchangeViewController.swift
```

Expected: both commands exit 0 because the truthful controls are not implemented yet.

- [x] **Step 2: Implement an accessible short-code screen**

Create a UIKit controller that displays:

- title `Короткий код`;
- the canonical code in a large monospaced label with `accessibilityLabel = "Короткий код обмена: …"`;
- `Код действует до HH:mm и сработает один раз.` using the server expiry;
- a `Скопировать код` button that writes only the short-lived code to `UIPasteboard.general.string` and announces success;
- a once-only `onClose` callback from `viewDidDisappear` when the controller is popped or dismissed.

Do not include the owner's name, phone, or card payload in the clipboard.

- [x] **Step 3: Replace the local private switch with owned truthful state**

Add properties:

```swift
private let privateSwitch = UISwitch()
private let privateStatus = YPStyle.label(
    "Телефон передаётся только через Bluetooth или ваш короткий код. QR остаётся публичным.",
    style: .footnote
)
private var includePrivatePhone = false
private var nearbyCredential: ExchangeCredential?
```

Place the switch and status before outgoing exchange actions. On screen exit, set the switch off and clear `includePrivatePhone`. If the saved card has no valid `PrivateCardFields`, authentication is not started and the user sees `В визитке пока нет телефона для передачи.`

- [x] **Step 4: Wire authenticated Bluetooth and manual preparation**

Bluetooth passes `PrivateCardFields(card: card)` only when `includePrivatePhone` is true and requires a token result. Add `showShortCode()` that requests method `manual`, pushes `ShortCodeViewController`, and cancels its `.code` credential on close.

Keep lifecycle ownership separate: `viewWillDisappear` cancels only active nearby discovery; the code controller owns its own cancellation so pushing it does not invalidate the code immediately.

- [x] **Step 5: Normalize the entered code and route it as `.code`**

Set the input hint to `YP-XXXX-XXXX-XXXX`. Reject locally when `ManualExchangeCode.normalize` returns `nil`; otherwise call `claimExchange(credential: .code(canonical), ...)`. Preserve the generic server failure copy and do not echo the submitted code.

- [x] **Step 6: Regenerate, inspect, and build**

Run:

```bash
xcodegen generate
rg -n 'Показать короткий код|Поделиться телефоном · Face ID|YP-XXXX-XXXX-XXXX|QR остаётся публичным' \
  YPerson/UI/ExchangeViewController.swift YPerson/UI/ShortCodeViewController.swift
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-ui \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: all copy markers found and build exit 0.

- [x] **Step 7: Record physical-device-only limitations**

Add checklist entries for two-device manual claim, Bluetooth private sharing, successful/cancelled Face ID/passcode, code expiry, app backgrounding, clipboard content, VoiceOver, and Dynamic Type. Mark them pending when no physical devices are available; do not claim simulator evidence for Face ID/Bluetooth mutual exchange.

- [x] **Step 8: Commit the UI**

```bash
git add YPerson/UI/ShortCodeViewController.swift YPerson/UI/ExchangeViewController.swift \
  project.yml YPerson.xcodeproj/project.pbxproj Release/manual-device-checks.md
git commit -m "feat: show real short exchange codes"
```

---

### Task 7: Deployment and privacy contract alignment

**Files:**
- Modify: `deploy/yandex/serverless/deploy.sh`
- Modify: `backend/tests/test_serverless_deployment.py`
- Modify: `AppSpec.md`
- Modify: `AppPrivacy.yml`
- Modify: `Release/release-manifest.json`
- Modify: `Release/implementation-verification.md`
- Modify: `Release/review-notes.md`

**Interfaces:**
- Consumes: final wire and schema fields from Tasks 1-6.
- Produces: deployment smoke coverage for both opaque token and manual code.
- Produces: canonical privacy/release documentation matching actual storage and UI behavior.

- [x] **Step 1: Add failing deployment-contract assertions**

Require the deployment script to read `exchangeCode` and `exchangeExpiresAt`, prepare manual exchange with `exchangeMethod: "manual"`, claim through `exchangeCode`, and keep the existing QR token smoke path.

- [x] **Step 2: Run deployment tests and record RED**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_serverless_deployment.py backend/tests/test_deployment_files.py
```

Expected: new assertions fail because the script only exercises `exchangeToken`.

- [x] **Step 3: Extend the serverless smoke exchange**

Use separate stable operation IDs for QR preparation/claim and manual preparation/claim. Store the manual response value only in the process variable `SMOKE_EXCHANGE_CODE`; never print it. Assert both responses provide `exchangeExpiresAt`, and unset token/code variables before cleanup output.

- [x] **Step 4: Align canonical product and privacy documents**

Document:

- `privateFields`, `exchangeCode`, and `exchangeExpiresAt` in the v2 request/response lists;
- phone as a recipient-specific connection grant, never part of public QR/card storage;
- temporary private fields sharing the claim's 10-minute TTL;
- directional grant retention until connection/profile deletion;
- manual code format, one-time use, digest-only storage, and authenticated claims;
- private-audio persistence and connection-level revoke/update as explicit remaining work.

Do not mark physical-device Face ID/Bluetooth checks complete.

- [x] **Step 5: Validate JSON/YAML and deployment tests GREEN**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q \
  backend/tests/test_serverless_deployment.py backend/tests/test_deployment_files.py
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -c \
  'import json, pathlib, yaml; json.load(open("Release/release-manifest.json")); yaml.safe_load(pathlib.Path("AppPrivacy.yml").read_text())'
```

Expected: tests pass and parsers exit 0.

- [x] **Step 6: Commit contract documentation**

```bash
git add deploy/yandex/serverless/deploy.sh backend/tests/test_serverless_deployment.py \
  AppSpec.md AppPrivacy.yml Release/release-manifest.json \
  Release/implementation-verification.md Release/review-notes.md
git commit -m "docs: align release contract with private exchange"
```

---

### Task 8: Full verification and review-ready evidence

**Files:**
- Modify: `docs/superpowers/plans/2026-08-21-yperson-honest-exchange.md` (checkbox progress only)
- Create: `Release/honest-exchange-verification.md`

**Interfaces:**
- Consumes: all tasks.
- Produces: reproducible final verification evidence and a clean review boundary.

- [x] **Step 1: Run full backend quality gates**

Run:

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q backend/tests
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m ruff check backend/app backend/tests
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m ruff format --check backend/app backend/tests
```

Expected: complete pytest suite passes; Ruff reports no errors or formatting changes.

- [x] **Step 2: Re-run the Swift contract harness**

Run the Task 5 harness compile and binary. Expected: `honest-exchange-contract-pass`.

- [x] **Step 3: Build Debug and Release in fresh derived-data directories**

Run:

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-final-debug \
  CODE_SIGNING_ALLOWED=NO clean build
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-final-release \
  CODE_SIGNING_ALLOWED=NO clean build
```

Expected: both commands exit 0; the Release products contain `YPerson.app`, `YPersonWidget.appex`, `YPersonNotificationService.appex`, and `YPersonNotificationContent.appex`.

Verify those exact paths:

```bash
YP_RELEASE_APP=/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app
test -d "$YP_RELEASE_APP"
test -d "$YP_RELEASE_APP/PlugIns/YPersonWidget.appex"
test -d "$YP_RELEASE_APP/PlugIns/YPersonNotificationService.appex"
test -d "$YP_RELEASE_APP/PlugIns/YPersonNotificationContent.appex"
```

- [x] **Step 4: Run privacy and secret scans**

Run:

```bash
rg -n 'exchangeCode|exchangeExpiresAt|privateFields|connection_private_fields|exchange_private_fields' \
  backend YPerson AppSpec.md AppPrivacy.yml Release deploy
! rg -n 'YP-1234|Date\(\)\.addingTimeInterval\(10 \* 60\)' YPerson
git diff --check origin/main...HEAD
```

Inspect the Release app binary with exact sentinels:

```bash
YP_RELEASE_BINARY=/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/YPerson
! strings "$YP_RELEASE_BINARY" | rg 'person-alexey|\+7 900 555-10-20|bearer-sentinel|YP-0123-4567-89AB'
```

- [x] **Step 5: Write verification evidence**

Record exact commands, counts, build configurations, product paths, known Starlette warning, and pending physical-device checks in `Release/honest-exchange-verification.md`. Separate automated PASS from device-only PENDING.

- [x] **Step 6: Mark plan progress and commit evidence**

Check only steps actually completed, then run:

```bash
git add docs/superpowers/plans/2026-08-21-yperson-honest-exchange.md \
  Release/honest-exchange-verification.md
git commit -m "test: verify honest exchange end to end"
```

- [x] **Step 7: Review the complete branch**

Run:

```bash
git status --short
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
```

Expected: clean worktree, focused commits, and no whitespace errors. Request code review before pushing or opening the pull request.
