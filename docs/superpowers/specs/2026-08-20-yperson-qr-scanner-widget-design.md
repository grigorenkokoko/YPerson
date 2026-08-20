# YPerson QR Scanner Widget Design

**Date:** 2026-08-20

**Status:** Approved and implemented

**Supersedes:** `2026-08-20-yperson-qr-widget-design.md`

## Goal

Replace the generic update-count widget with a fast, unmistakable entry point to YPerson's QR scanner. The widget must take the user from the Home Screen or Lock Screen to a ready-to-use scanner with the fewest system-supported steps.

## Platform constraint

A regular WidgetKit widget cannot host a live camera preview. WidgetKit renders a snapshot, and a widget URL activates the containing application for app-owned functionality. The scanner therefore runs in YPerson, while the widget acts as its dedicated launcher.

This design keeps the application's minimum deployment target at iOS 15.0 and does not introduce a locked camera capture extension or an iOS 18-only Control Widget.

## Product behavior

- `systemSmall` shows a large `qrcode.viewfinder` symbol, the title `Сканировать QR`, and a short caption `Добавить визитку`.
- On iOS 16+, `accessoryCircular` shows the scanner symbol and `accessoryRectangular` shows `Сканировать QR` with a compact YPerson label.
- Every supported family uses the deep link `yperson://scan`.
- A tap opens YPerson on the Exchange tab and immediately begins the existing `Сканировать QR` flow.
- If camera access is already authorized, the scanner opens directly.
- If camera access is undetermined, YPerson shows its existing pre-permission explanation before the system prompt.
- If camera access is denied, restricted, or unavailable, YPerson shows the existing recovery or fallback state instead of presenting a broken camera screen.
- Repeated deep links must not stack duplicate scanner screens or permission prompts.

## Architecture

### Shared route

Add a small Foundation-only route definition in `YPersonShared` containing the canonical `yperson://scan` URL and strict validation for that route. Both the app and widget consume the same definition so their URLs cannot drift.

The route accepts exactly the `yperson` scheme and `scan` host, with no path, query, fragment, credentials, or port. Other URLs are ignored safely.

### Application routing

Add a scanner entry point to `YPersonEntryPoint`. `AppDelegate` handles the route both when the app is launched from a terminated state and when it is already running. `YPersonExperienceBuilder` and `MainTabBarController` select the Exchange tab, return it to its root, and request the existing `ExchangeViewController.scanQR()` flow after the interface is ready to present.

The existing permission explanation and `QRCodeScannerViewController` remain the single scanner implementation; the widget does not duplicate camera or permission logic.

### Widget extension

Replace the snapshot-driven provider with a static scanner-launcher entry. The widget does not read card data, make network requests, request camera permission, or import AVFoundation.

Because the new widget needs no shared user data, remove the widget extension's App Group entitlement and `APP_GROUP_IDENTIFIER` Info.plist value. The main app keeps its existing App Group for application storage.

Remove obsolete widget-snapshot writes and reads from the app and extension. Preserve cleanup of legacy widget-snapshot keys so an account deletion still removes data left by earlier builds.

## Data flow

1. WidgetKit renders a static scanner shortcut.
2. The user taps the widget.
3. iOS activates YPerson and delivers `yperson://scan`.
4. The app validates the route and selects the Exchange tab.
5. The existing permission flow either opens `QRCodeScannerViewController` or presents the appropriate permission fallback.
6. The existing scanner returns the decoded YPerson/vCard payload to the existing confirmation flow.

No personal data flows from the app to the widget.

## Visual and accessibility behavior

- Use the existing indigo brand color for the Home Screen widget and system tinting for accessory families.
- Keep the primary scanner symbol visually dominant and avoid presenting a decorative QR that could be mistaken for scannable content.
- The combined VoiceOver label is `Сканировать QR-код визитки в YPerson`.
- Text remains readable with Dynamic Type within WidgetKit's family constraints.
- The action is represented by both a symbol and text wherever the family has space; color is not the only signal.

## Failure handling

- Invalid or unknown URL: return `false` from the app URL handler and do not change navigation.
- Application configuration failure: retain the existing configuration-error screen; do not attempt to present the scanner.
- Scanner already visible: keep the current scanner instead of pushing another instance.
- Permission explanation already presented: keep the existing presentation instead of stacking another alert.
- Camera denial or restriction: preserve the existing alternative routes from the Exchange screen.

## Documentation changes

Update `AppSpec.md`, `Design/design-spec.md`, `AppPrivacy.yml`, `Release/implementation-verification.md`, and `Release/manual-device-checks.md` to describe the scanner shortcut and remove claims that the widget displays an update count or reads a personal snapshot.

## Verification

- Temporary executable Swift harnesses cover exact acceptance of `yperson://scan`, rejection of lookalike or extended URLs, and duplicate-launch gating without adding a persistent test target to the standalone app.
- Build the main application and widget extension for an iPhone simulator with iOS 15-compatible APIs.
- Inspect the built widget extension to confirm it has no App Group entitlement and no camera usage description.
- Verify `systemSmall`, `accessoryCircular`, and `accessoryRectangular` previews or screenshots.
- Verify cold-launch and warm-launch widget taps select Exchange and start the scanner flow.
- Verify authorized, undetermined, denied, and unavailable camera states on suitable simulator or physical-device configurations.
- Confirm the widget performs no network request and persists no personal data.

## Out of scope

- A live camera preview inside the widget.
- A locked camera capture extension or Control Center control.
- QR generation or display of the owner's card in the widget.
- Changes to QR decoding, card confirmation, or backend exchange semantics.
- iOS 18-only widget or App Intent behavior.
