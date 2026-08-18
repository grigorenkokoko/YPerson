# Reviewer assets

All identities and contact details below are fictional.

## QR card

- File: `test-qr.png`
- Payload: `yperson:card:person-anna:review-token`
- Path: Exchange → Scan QR → continue from the camera pre-prompt → scan the file displayed on another screen → review Alexey Morozov → Add person.

## Manual fallback

- Code: `YP-1234`
- Path: Exchange → Enter short code → enter the code → Check.
- Expected: a fictional Alexey Morozov card preview; no address-book write occurs automatically.

## Two-iPhone nearby exchange

Open Exchange → Nearby on two physical iPhones. Start discovery on both, select the test card, and confirm on both devices. The exchange token is short lived and is not claimed before mutual confirmation. If physical BLE setup is unavailable to App Review, use the QR or manual path, which exercises the same receive/confirm UI.

## Notification payload shape

Production APNs must use category `YPERSON_CARD_UPDATE`, a public display name, public thumbnail URL, changed public-field categories, and a backend-signed technical card-update ID. Do not include private fields, meeting notes, Contacts data, QR payloads, or report text. Production APNs and signing credentials remain release blockers and are intentionally not stored here.
