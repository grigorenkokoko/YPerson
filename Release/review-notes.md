# App Review notes — YPerson 1.0

YPerson is an iPhone-only, portrait-only digital business-card app (minimum iOS 15). No login is required; a cloud profile is scoped to the installation. All sample names, companies, email addresses, and phone numbers are fictional.

Review prerequisites before submission: the production backend and public Privacy/Support URLs must be live. This file is prepared locally and does not claim those blockers are resolved.

First launch intentionally contains no prefilled profile or people. Core path: open Card → Create Card, enter reviewer-owned values, and tap Done → Show QR. On another iPhone open Exchange → Scan QR, or scan the supplied `reviewer-assets/test-qr.png`. Confirm the fictional Alexey Morozov card before saving. Manual fallback: Exchange → Enter short code → `YP-1234`.

Permission paths and fallbacks:

1. Camera: Exchange → Scan QR. Fallback: supplied image/manual code.
2. Bluetooth: Exchange → Nearby; open this on two iPhones and confirm on both. Fallback: QR/manual code.
3. Contacts: first import the supplied reviewer card, then People → Contacts Sync; inspect the proposed changes before confirming. Fallback: cards remain in YPerson/system single-contact form.
4. Face ID: Card → Open private fields, or enable private fields in Exchange. Device passcode/public card remain available.
5. Location While Using: after importing the reviewer card, People → Alexey → Add current place. The label remains only on device; manual place/skip is available.
6. Microphone: Card → Edit → Record up to 10 seconds. Preview/delete is available; text remains the fallback.
7. Photos read: Exchange → Find cards in Photos. Limited/single-image alternatives are available; raw images stay on device.
8. Photos add: Card menu or received card → Save to Photos. Share Sheet remains available.
9. Tracking: Card → Edit → Appearance and templates → Help measure ads. ATT is only for AppMetrica attribution; denial keeps every free template and core feature.
10. Notifications: Settings → Enable card updates. Denial keeps updates on the People screen.

Widget: add YPerson `systemSmall` on iOS 15. On iOS 16+, also add the Lock Screen rectangular widget. It shows only a neutral shortcut/update count.

Notifications: a local sample can be scheduled after notification permission. Production remote content requires APNs and a signed payload; Service Extension fails open to original text and Content Extension offers Review and Block. It never updates Contacts directly.

Safety: after importing the reviewer card, People → Alexey → ••• offers Report, Block, and Delete Connection. Block hides future updates immediately. Production moderation contact/SLA must be live before submission.

Account deletion: Settings → Delete Profile. The confirmation lists card/assets, connections, exchange claims, APNs/auth tokens, and local data. Active data is deleted immediately; backups within 30 days. A restricted closed abuse report may remain up to 180 days.

Backend: public `GET /config` accepts no personal data, supports ETag/304, and can only disable disclosed features/analytics. It cannot add permissions, data collection, tracking, code, or secrets. `/health` and `/sync` provide health and combined profile/exchange/moderation sync.

Offline: the card remains available; pending sync/report/deletion is retried. QR/manual fallbacks do not require two physical devices.

No purchases, subscriptions, paid unlocks, external payments, public feed, or anonymous/random chat are present.
