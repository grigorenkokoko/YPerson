# YPerson Honest Exchange Design

**Date:** 2026-08-21

**Status:** Design approved; awaiting written-spec review

## Goal

Make the Exchange screen truthful and useful: Face ID consent must actually share the selected private field with only the confirmed recipient, and the manual flow must use a real server-issued short code instead of presenting a long exchange token as one.

This design covers private phone sharing and manual-code exchange. Audio-greeting relaunch persistence remains a separate Wave 2 task.

## Product behavior

- The owner's public card never contains the private phone number.
- The switch is renamed to `Поделиться телефоном · Face ID` and its explanatory text states that it applies only to the next outgoing Bluetooth or short-code exchange.
- Successful Face ID or device-passcode authentication enables the switch for the current visit to the Exchange screen. Leaving the screen turns it off and clears the authorization.
- `Показать мой QR` remains explicitly public. Both online and offline QR payloads continue to omit the phone number.
- A new `Показать короткий код` action prepares an online one-time exchange and displays the server-issued code and its expiry.
- `Ввести короткий код` accepts the displayed code with or without the `YP-` prefix, spaces, or separators, normalizes it locally, and asks the server to claim it.
- Closing the displayed-code screen cancels the unclaimed code on a best-effort basis. A claimed, cancelled, or expired code cannot be claimed again.
- Bluetooth continues to exchange opaque tokens. When private sharing is authorized, the resulting confirmed recipient receives the phone through the same recipient-specific grant used by a short code.
- A received private phone survives later refreshes. A different connection never receives that phone unless the owner separately authorizes it.

## Privacy boundary

`PersonCard.exchangeCopy` remains the public projection and continues to remove `phone` and local-only `meetingPlace`. Private data is never restored into that projection.

The version-2 request gains a separate optional `privateFields` object. Its initial schema contains only `phone`: a trimmed, non-empty display string of at most 64 Unicode characters. The iOS client may include it only in `prepareExchange`, and only after successful local authentication. The public `card` in the same request is always `exchangeCopy`.

The backend rejects `privateFields` on every other operation and never writes it into the shared `cards.card_json` record, QR payload, analytics, notification payload, or logs. A prepared exchange temporarily associates the validated private fields with the digest of its one-time credential. A successful claim moves that access into the directional connection from recipient to issuer.

The grant is directional: if installation B claims installation A's credential, only B's view of A receives A's private phone. A's reciprocal view of B remains public unless B separately shares its phone.

Private-field grants are removed with profile deletion. Connection-level revocation and propagation of later private-field edits belong to the later owner-update/connection-management wave; until that contract exists, a grant retains the phone value shared at confirmation time.

## Short-code contract

Manual preparation returns a human-enterable code in the form `YP-XXXX-XXXX-XXXX`. The twelve payload characters use the unambiguous Crockford Base32 alphabet and provide 60 bits of search space. Codes are derived server-side with a domain-separated HMAC over the authenticated installation and stable operation identifier. This preserves idempotent retries without storing the raw code.

The code:

- expires at the server-provided `exchangeExpiresAt`, at most 10 minutes after preparation;
- is valid for one successful claimant other than its issuer;
- is stored only as a SHA-256 digest after normalization;
- produces the same sanitized conflict response for unknown, expired, cancelled, already claimed, and self-claimed values;
- is never sent to AppMetrica or included in user-visible error diagnostics.

The existing 43-character base64url token remains the credential for QR and Bluetooth. Those flows keep their current entropy and payload validation.

## Wire contract

Add the following optional version-2 fields:

- request `privateFields`: `{ "phone": String }`, allowed only for `prepareExchange`;
- request `exchangeCode`: the manual credential, allowed only for `claimExchange` and `cancelExchange`;
- response `exchangeCode`: present only after manual preparation;
- response `exchangeExpiresAt`: authoritative expiry for every prepared online exchange.

`prepareExchange` behavior depends on `exchangeMethod`:

- `manual` returns `exchangeCode` and no `exchangeToken`;
- `qr` and `bluetooth` return `exchangeToken` and no `exchangeCode`;
- `photo` remains accepted for compatibility and uses an opaque token.

Claim and cancellation accept exactly one credential field. The server also continues accepting a correctly formatted manual code in the legacy `exchangeToken` field so an older installed client can claim a code displayed by a newer client. New iOS code always uses `exchangeCode` for the manual path.

The change remains additive within contract version 2. Older clients ignore new response keys, and existing QR/Bluetooth requests remain valid.

## Backend storage and data flow

Schema version 2 adds two tables instead of altering the already deployed version-1 tables:

- `exchange_private_fields`: one validated private-field JSON document keyed by credential digest, with the same expiry as the exchange claim;
- `connection_private_fields`: one validated private-field JSON document keyed by `(owner_installation_id, peer_installation_id)`.

Both documents are decoded through the strict `PrivateCardFields` model before use. Unknown keys or malformed values fail closed.

Preparation is one atomic store operation rather than the current separate publish-then-prepare calls:

1. authenticate the issuer;
2. publish only the public card projection;
3. derive either the opaque token or the manual code;
4. create the one-time exchange claim;
5. when present, store the private fields under the same credential digest and expiry;
6. return exactly one credential plus the authoritative expiry.

The storage boundary therefore accepts the public card, optional private fields, method, credential, and expiry together and returns the public-card version. An operation-identifier replay must reproduce the same version and credential digest or fail as a conflict; it must never create a second claim.

Claim proceeds atomically:

1. normalize and digest the supplied credential;
2. validate issuer, expiry, claimant, and one-time status;
3. create the two reciprocal confirmed connections;
4. copy the issuer's prepared private fields only into the claimant-to-issuer directional grant;
5. mark the claim consumed;
6. return the issuer's current public card overlaid with that grant.

Refresh always starts from the peer's current public card and overlays only the requester's directional grant. This preserves the shared phone across refresh without exposing it to other connections.

Claim idempotency records contain the credential digest and issuer identifier, not a private card snapshot. A replay reconstructs the response from the current public card plus the existing directional grant, avoiding a second private-data copy in the operations table.

Cancellation removes the unclaimed claim and its temporary private fields. TTL remains a cleanup backstop. Profile deletion removes temporary private fields and every directional grant in which the installation is owner or peer.

## iOS components and flow

`PrivateCardFields` is a small Codable value derived from the full local card only after successful authentication. `SyncRequest`, `SyncWireRequest`, and `SyncResponse` gain the additive fields above.

`SyncCoordinator` returns a typed prepared credential rather than a bare string. The type distinguishes token from code, carries `expiresAt`, creates the correct claim/cancel request, and prevents the UI from accidentally placing a manual code into QR or Bluetooth payloads.

`ExchangeViewController` owns a persistent switch reference and clears it on exit. It passes private fields only to outgoing Bluetooth and `Показать короткий код`. The code presentation keeps the preparation alive while visible and cancels it when closed. The existing input action normalizes and validates manual text before calling the coordinator.

`CardViewController` continues to request a token for public QR and uses the server-provided expiry instead of calculating ten minutes from the device clock. Offline fallback remains public.

## Failure handling

- Authentication denied or cancelled: switch returns off; public exchange remains available.
- No saved phone: the app explains that there is no private phone to share and leaves the switch off.
- No network during private preparation: no private payload or code is created; the app offers public QR instead of silently broadening or downgrading consent.
- Invalid manual syntax: rejected locally without a network call.
- Unknown, expired, cancelled, already claimed, or self-claimed code: generic `Код не подтверждён` recovery copy; no account or claim state is revealed.
- Cancellation request fails: the code still expires within 10 minutes and remains one-time.
- Malformed persisted private fields: backend fails closed and returns the existing sanitized temporary-unavailable response.

## Verification

Implementation follows red-green-refactor.

- Backend schema tests cover allowed fields, operation exclusivity, code normalization, response shape, and rejection of malformed private fields.
- Service round-trip tests prove manual code format, deterministic retry, one-time claim, cancellation, expiry, self-claim rejection, and unchanged QR/Bluetooth token behavior.
- Storage tests prove recipient isolation, directional grants, refresh overlay, absence from the public card and operation result, and cleanup on cancellation and profile deletion.
- Foundation-only Swift harnesses prove public/private projection, request encoding, code normalization, typed credential routing, and QR exclusion without adding an iOS XCTest target.
- The complete backend suite and Ruff checks pass.
- Debug and Release simulator builds pass with signing disabled; embedded extensions remain present.
- Manual-device checks cover successful and cancelled Face ID/passcode, code display and entry on two installations, Bluetooth private sharing, VoiceOver labels, Dynamic Type, app backgrounding, and expiry. Physical-device-only results remain explicitly recorded when unavailable.

## Documentation updates

Update `AppSpec.md`, `AppPrivacy.yml`, the YDB schema description, deployment smoke contract, release manifest evidence, and manual-device checklist to name `privateFields`, `exchangeCode`, `exchangeExpiresAt`, recipient-specific retention, and the public-only QR boundary.

## Out of scope

- Private audio-greeting visibility and relaunch persistence.
- Automatic propagation or revocation of a private phone after it was shared.
- A connection-deletion API and UI.
- Private fields in QR or photo payloads.
- Anonymous or unauthenticated code claims.
- Four-digit numeric codes, reusable invitation codes, account lookup, or public profile discovery.
- A new iOS XCTest or UI-test target.
