# App Review notes — YPerson 1.0

YPerson is an iPhone-only, portrait-only digital business-card app (minimum iOS 15). No login is required; a cloud profile is scoped to the installation. All sample names, companies, email addresses, and phone numbers are fictional.

Review prerequisites before submission: the production backend and public Privacy/Support URLs must be live. This file is prepared locally and does not claim those blockers are resolved.

Release blocker: third-party vCards are intentionally imported local-only, while the approved product contract still requires synchronization of confirmed photo/scanned card payloads. Submission remains blocked until an approved backend ownership/retention/deletion/update contract exists for third-party imports or `AppSpec.md` and `AppPrivacy.yml` are explicitly re-approved for local-only behavior.

First launch intentionally contains no prefilled profile or people. Core path: open Card → Create Card, enter reviewer-owned values, and tap Done → Show QR. On another iPhone open Exchange → Scan QR, or scan the supplied `reviewer-assets/test-qr.png`. Confirm the fictional Alexey Morozov card before saving. Public QR never contains the phone. There is no static manual code: on the authenticated online issuer choose Exchange → Show short code, then enter the server-issued `YP-XXXX-XXXX-XXXX` on another authenticated installation before its displayed `exchangeExpiresAt` (at most 10 minutes). The code is one-time; unknown, expired, cancelled, already claimed, and self-claimed values intentionally show the same safe failure.

Private-phone path: save a phone on the issuer, enable `Поделиться телефоном по коду · Face ID`, complete Face ID or device-passcode authentication, then choose Show short code. The authorization is single-use: it is consumed before that manual preparation request and the switch resets immediately. A repeated tap, failed/cancelled preparation, or later private attempt requires a new authentication. Only the confirmed manual-code recipient receives that phone as a directional connection grant; the reciprocal view, unrelated connections, stored public card, every QR, and the current Bluetooth path remain phone-free. Private Bluetooth is deferred until a recipient-bound mutual pairing protocol exists. Physical-device Face ID/passcode, public mutual Bluetooth, and two-installation manual claim are still pending and are not claimed by the local deployment-contract tests.

Appearance reviewer path: Card → Edit → Appearance. The screen presents a live preview and four templates: `standard-clean`, `standard-contrast`, `mint-conference`, and `indigo-studio`; the selected row has a checkmark and `Выбрано` subtitle. Choose a template, return to the editor, and tap Done to save it with the card. Leaving the editor without Done discards the draft selection. To verify that same selected template on a received card, show the updated QR on the first iPhone, then on a second iPhone open Exchange → Scan QR, scan it, confirm adding the card, and open the received card. The supplied QR fixture and a runtime server-issued manual code are separate exchange paths and do not demonstrate the current card's selected template. Card menu → Save to Photos exports the selected appearance. Card payloads carry only the public `templateID`, not palette values or ATT state.

Permission paths and fallbacks:

1. Camera: Exchange → Scan QR. Fallback: supplied image/manual code.
2. Bluetooth: Exchange → Nearby; open this on two iPhones and confirm on both. This path exchanges only a public card and never sends `privateFields`. Fallback: QR/manual code.
3. Contacts: with an empty People list, tap Add from Contacts and select one or more entries in the system picker; this does not request full address-book access and keeps imported cards on device. For full reconciliation, import the supplied reviewer card, then People → Contacts Sync; inspect the proposed changes before confirming. Fallback: cards remain in YPerson/system single-contact form.
4. Face ID: Card → Open private fields, or enable `Поделиться телефоном по коду · Face ID` in Exchange for exactly the next manual preparation. Device passcode and the phone-free public card/QR/Bluetooth paths remain available.
5. Location While Using: before exchange, enable Save meeting place, then complete the reviewer exchange and inspect the local label on the received person. Cancel a second exchange and verify that its pending label is not persisted. People → Alexey → Add current place remains available afterward; manual place/skip is available and nothing is transmitted.
6. Microphone: Card → Edit → Record up to 10 seconds. Preview/delete is available; text remains the fallback.
7. Photos read: Exchange → Find cards in Photos. Limited/single-image alternatives are available; raw images stay on device.
8. Photos add: Card menu or received card → Save to Photos. Share Sheet remains available.
9. Tracking: Card → Edit → Appearance and templates → Help measure ads. ATT is only for AppMetrica attribution; denial does not change or restrict templates and keeps every free template and core feature.
10. Notifications: Settings → Enable card updates. Denial keeps updates on the People screen.

Widget: add YPerson `systemSmall` on the Home Screen on iOS 15. On iOS 16+, also add the `accessoryCircular` and `accessoryRectangular` shortcuts on the Lock Screen. Every family opens `yperson://scan`, selects Exchange, and starts the existing Scan QR permission/recovery flow. The extension is a stateless launcher: it has no card data, QR payload, update count, cached snapshot, App Group entitlement, camera purpose string or access, analytics, or network client.

Notifications: a local sample can be scheduled after notification permission. Production remote content requires APNs and a signed payload; Service Extension fails open to original text and Content Extension offers Review and Block. It never updates Contacts directly.

Safety: after importing the reviewer card, People → Alexey → ••• offers Report, Block, and Delete Connection. Block hides future updates immediately. Production moderation contact/SLA must be live before submission.

Account deletion: Settings → Delete Profile. The confirmation lists card/assets, connections, temporary private exchange fields, directional grants, exchange claims, APNs/auth tokens, and local data. Active data is deleted immediately; backups within 30 days. A restricted closed abuse report may remain up to 180 days.

Backend: public `GET /config` accepts no personal data, supports ETag/304, and can only disable disclosed features/analytics. It cannot add permissions, data collection, tracking, code, or secrets. `/health` and authenticated `/sync` provide health and combined profile/exchange/moderation sync. Sync v2 uses request `privateFields`/`exchangeCode` and response `exchangeCode`/`exchangeExpiresAt`; `privateFields` is manual-only and temporary private fields share the claim's maximum 10-minute TTL. Backend storage contains only normalized SHA-256 credential digests. On iOS raw token/code remains in active memory: claim/cancel is attempted immediately, never persisted in App Group `UserDefaults`, and legacy pending claim/cancel entries are removed without sending.

Offline: the card and phone-free offline QR remain available; non-sensitive pending sync/report/deletion keeps stable retry. Claim/cancel credentials are deliberately not durable-retried, so a failed claim requires a new user attempt and a failed cancellation relies on one-time expiry. A real manual code requires network access and authenticated issuer/claimant installations; it is not a static offline fallback.

Known unfinished scope: recipient-specific private-audio persistence and recipient-bound mutual pairing for private Bluetooth are not implemented; Bluetooth therefore remains public-only. A manual private-phone grant retains the confirmed value until connection/profile deletion, but connection-level private-grant revoke/update and propagation of later phone edits are not implemented. These limitations, the physical-device checks, and the third-party vCard conformance blocker above remain open; this document does not make the build release-ready.

No purchases, subscriptions, paid unlocks, external payments, public feed, or anonymous/random chat are present.
