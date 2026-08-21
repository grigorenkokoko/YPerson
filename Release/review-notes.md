# App Review notes — YPerson 1.0

YPerson is an iPhone-only, portrait-only digital business-card app (minimum iOS 15). No login is required; a cloud profile is scoped to the installation. All sample names, companies, email addresses, and phone numbers are fictional.

Review prerequisites before submission: the production backend and public Privacy/Support URLs must be live. This file is prepared locally and does not claim those blockers are resolved.

Universal sharing package 1: Show QR presents an ordinary Camera-compatible HTTPS QR as the primary sharing path. A guest without YPerson can scan it in Camera, view the mobile web card, and download its vCard without installing or creating a web account. A guest contact reply requires explicit consent and exactly one contact method; the owner must separately confirm before YPerson saves it as a person. Phone, meeting place, audio, and photos are excluded from the package-1 public card. Incoming replies currently arrive when the owner brings YPerson to the foreground and refreshes; package 1 does not claim APNs delivery for this flow.

Universal sharing remains a manual review blocker until the versioned YDB schema is applied before the matching backend revision, the gateway is deployed, AASA is verified directly in production, and all six checks in `Release/manual-device-checks.md` pass on physical iPhones. No production or physical-device result is claimed by these notes.

First launch intentionally contains no prefilled profile or people. Core path: open Card → Create Card, enter reviewer-owned values, and tap Done → Show QR. On another iPhone open Exchange → Scan QR, or scan the supplied `reviewer-assets/test-qr.png`. Confirm the fictional Alexey Morozov card before saving. Manual fallback: Exchange → Enter short code → `YP-1234`.

Appearance reviewer path: Card → Edit → Appearance. The screen presents a live preview and four templates: `standard-clean`, `standard-contrast`, `mint-conference`, and `indigo-studio`; the selected row has a checkmark and `Выбрано` subtitle. Choose a template, return to the editor, and tap Done to save it with the card. Leaving the editor without Done discards the draft selection. To verify that same selected template on a received card, show the updated QR on the first iPhone, then on a second iPhone open Exchange → Scan QR, scan it, confirm adding the card, and open the received card. The supplied QR fixture and manual code remain separate exchange fallbacks for their own fictional card and do not demonstrate the current card's selected template. Card menu → Save to Photos exports the selected appearance. Card payloads carry only the public `templateID`, not palette values or ATT state.

Permission paths and fallbacks:

1. Camera: Exchange → Scan QR. Fallback: supplied image/manual code.
2. Bluetooth: Exchange → Nearby; open this on two iPhones and confirm on both. Fallback: QR/manual code.
3. Contacts: with an empty People list, tap Add from Contacts and select one or more entries in the system picker; this does not request full address-book access and keeps imported cards on device. For full reconciliation, import the supplied reviewer card, then People → Contacts Sync; inspect the proposed changes before confirming. Fallback: cards remain in YPerson/system single-contact form.
4. Face ID: Card → Open private fields, or enable private fields in Exchange. Device passcode/public card remain available.
5. Location While Using: before exchange, enable Save meeting place, then complete the reviewer exchange and inspect the local label on the received person. Cancel a second exchange and verify that its pending label is not persisted. People → Alexey → Add current place remains available afterward; manual place/skip is available and nothing is transmitted.
6. Microphone: Card → Edit → Record up to 10 seconds. Preview/delete is available; text remains the fallback.
7. Photos read: Exchange → Find cards in Photos. Limited/single-image alternatives are available; raw images stay on device.
8. Photos add: Card menu or received card → Save to Photos. Share Sheet remains available.
9. Tracking: Card → Edit → Appearance and templates → Help measure ads. ATT is only for AppMetrica attribution; denial does not change or restrict templates and keeps every free template and core feature.
10. Notifications: Settings → Enable card updates. Denial keeps updates on the People screen.

Widget: add YPerson `systemSmall` on the Home Screen on iOS 15. On iOS 16+, also add the `accessoryCircular` and `accessoryRectangular` shortcuts on the Lock Screen. Every family opens `yperson://scan`, selects Exchange, and starts the existing Scan QR permission/recovery flow. The extension is a stateless launcher: it has no card data, QR payload, update count, cached snapshot, App Group entitlement, camera purpose string or access, analytics, or network client.

Notifications: a local sample can be scheduled after notification permission. Production remote content requires APNs and a signed payload; Service Extension fails open to original text and Content Extension offers Review and Block. It never updates Contacts directly.

Safety: after importing the reviewer card, People → Alexey → ••• offers Report, Block, and Delete Connection. Block hides future updates immediately. Production moderation contact/SLA must be live before submission.

Account deletion: Settings → Delete Profile. The confirmation lists card/assets, connections, exchange claims, APNs/auth tokens, and local data. Active data is deleted immediately; backups within 30 days. A restricted closed abuse report may remain up to 180 days.

Backend: public `GET /config` accepts no personal data, supports ETag/304, and can only disable disclosed features/analytics. It cannot add permissions, data collection, tracking, code, or secrets. `/health` and `/sync` provide health and combined profile/exchange/moderation sync.

Offline: the card remains available; pending sync/report/deletion is retried. QR/manual fallbacks do not require two physical devices.

No purchases, subscriptions, paid unlocks, external payments, public feed, or anonymous/random chat are present.
