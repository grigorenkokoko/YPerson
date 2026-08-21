# Reviewer assets

All identities and contact details below are fictional.

## Offline public QR card

- File: `test-qr.png`; its exact deterministic source is `offline-public-qr-payload.txt`.
- Payload: canonical `yperson:v2:` data accepted by the production decoder for the fictional Alexey Morozov (`Product Lead`, `North Star`). It contains no phone, private fields, meeting place, exchange token, or expiry.
- Path: Exchange → Scan QR → continue from the camera pre-prompt → scan the PNG displayed on another screen → review Alexey Morozov → Add person.
- Expected: the preview identifies the import as offline. Saving adds the public card only to this iPhone; it does not establish a cloud connection because the payload has no exchange token.

The fixture can be regenerated and checked with `verify-offline-public-qr.sh --write`. Verification compiles the real production models/codec and requires `ZXING_CORE_JAR` pointing to a local ZXing Core 3.5.3 jar, so PNG decoding fails closed when an independent decoder is unavailable.

## Runtime manual-code path

No bundled or static manual code works. On two authenticated online installations, create and save an own card on iPhone A, then choose Exchange → Show short code. On iPhone B choose Exchange → Enter short code, enter the current server-issued `YP-XXXX-XXXX-XXXX`, and tap Check before the expiry displayed on A. The code is one-time and server-validated. If only one device is available, use the offline QR fixture above.

## Two-iPhone nearby exchange

Open Exchange → Nearby on two physical iPhones. Start search on both; backend public-card and short-lived-token preparation begins before BLE discovery. Each installation independently claims the peer token only after its own local confirmation and saves its own connection. There is no peer-confirmation signal, so do not interpret one device's confirmation as proof that the other user confirmed. The exchanged cards remain public and omit phone. If physical BLE setup is unavailable to App Review, use the runtime manual-code path with two online installations, or the bundled offline QR when only one device is available.

## Notification payload shape

Production APNs must use category `YPERSON_CARD_UPDATE`, a public display name, public thumbnail URL, changed public-field categories, and a backend-signed technical card-update ID. Do not include private fields, meeting notes, Contacts data, QR payloads, or report text. Production APNs and signing credentials remain release blockers and are intentionally not stored here.
