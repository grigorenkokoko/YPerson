# YPerson QR Widget Design

**Date:** 2026-08-20

**Status:** Approved in chat; awaiting written-spec review

## Goal

Replace the generic update-count widget with a widget that represents YPerson's core purpose: a personal digital card that another person can scan directly from the Home Screen.

## Product behavior

- `systemSmall` shows a large QR code, the public card owner's name, and the label `Моя визитка`.
- `systemMedium` shows the public name, role, and company on the left and a large QR code on the right.
- Tapping either widget opens YPerson on the owner's card screen.
- When no card exists, the widget shows `Создайте визитку в YPerson`; tapping it opens the same card entry point so the user can create one.
- Lock Screen accessory families are not supported because their available area cannot provide a reliably scannable QR code.

## Privacy boundary

The widget snapshot contains only the public presentation fields required by the widget:

- card identifier;
- name;
- role;
- company;
- snapshot update date.

The QR payload is derived from the card identifier using the application's existing format:

```text
yperson:card:<card-id>
```

The snapshot and QR must not contain a phone number, email address, tagline, audio data, private-field state, analytics identifiers, or authentication tokens. This is intentionally a stable public-card identifier, not a short-lived server exchange token.

## Architecture

### Shared snapshot

Extend the versioned model in `YPersonShared/WidgetSnapshot.swift` to carry the optional public card summary. Keep decoding backward-compatible with the existing version-1 update-count snapshot so installed widgets do not fail during upgrade.

`AppGroupSnapshotStore` remains the only persistence boundary. It writes the snapshot to the existing App Group and requests WidgetKit timeline reloads after card creation, editing, and removal.

### Widget rendering

`YPersonWidget` reads the shared snapshot and generates a QR image locally with Core Image. The QR view includes a sufficient quiet zone, high contrast, and nearest-neighbor scaling so the modules remain sharp.

The widget uses semantic system colors and scales text conservatively. The QR image receives a VoiceOver label identifying it as the public YPerson card for the named owner. The surrounding widget combines the visible card summary into a concise accessibility label.

### Navigation

The widget uses the custom URL `yperson://my-card`. The application registers the `yperson` scheme, accepts only the `my-card` host for this feature, and forwards it through the existing `YPersonExperienceBuilder` lifecycle to `YPersonEntryPoint.card`. Unknown routes are ignored safely.

## Data flow

1. The user creates, edits, or removes their card in the application.
2. `CardViewController` builds a privacy-reduced `WidgetSnapshot`.
3. `AppGroupSnapshotStore` writes the versioned snapshot and reloads WidgetKit timelines.
4. `YPersonWidget` reads the latest snapshot and renders the appropriate widget family.
5. Another device scans the existing `yperson:card:<card-id>` payload through the established YPerson QR flow.
6. Tapping the widget opens the owning application at the card entry point.

## Failure handling

- Missing or corrupt snapshot: show the create-card state rather than stale personal data.
- Missing or empty card identifier: do not generate a QR code.
- QR generation failure: retain the card summary and show `Откройте YPerson`, with the widget deep link still active.
- App Group unavailable: use the same safe empty state.

## Scope changes to existing documentation

The implementation must update `AppSpec.md` and `Design/design-spec.md`, which currently prohibit QR content in the widget. The new privacy rule is narrower: QR is allowed only as a stable public-card identifier; private fields and direct contact values remain prohibited.

## Verification

- Unit tests cover snapshot round trips, version-1 migration, corrupt data, and privacy-reduced mapping from `PersonCard`.
- Build the application and WidgetKit extension for an iPhone simulator.
- Verify empty, small, and medium widget previews or screenshots.
- Confirm QR decoding returns the expected `yperson:card:<card-id>` payload.
- Confirm edits reload the widget and removal clears its public summary.
- Confirm the widget URL opens the card entry point and unknown URLs are ignored.
- Review generated entitlements and the built app to ensure the widget and application share only the intended App Group.

## Out of scope

- Displaying phone, email, private fields, or audio in the widget.
- Network requests from the widget extension.
- Interactive buttons that require iOS 17.
- Configurable cards, Live Activities, or Lock Screen QR widgets.
