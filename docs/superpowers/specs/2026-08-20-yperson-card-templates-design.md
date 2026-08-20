# YPerson Card Templates Design

**Date:** 2026-08-20

**Status:** Approved for implementation

## Goal

Turn the existing Appearance screen from a confirmation-only placeholder into a working card-template flow. A selected template must remain attached to the owner's public card, render consistently in YPerson and exported images, and follow the card through QR, Bluetooth, manual-code, and server-backed exchange.

## Product behavior

- YPerson ships four available templates: `standard-clean`, `standard-contrast`, `mint-conference`, and `indigo-studio`.
- The Appearance screen shows a real card preview, the four template choices, and a non-color selected indicator.
- Choosing a template updates the editor draft and preview immediately. The owner commits the choice together with the remaining card edits by tapping `Готово` in the editor.
- Leaving the editor without saving discards the draft template change, matching the behavior of the other editable card fields.
- The selected template applies to the owner's card, received cards, saved card images, and shared card images.
- Sponsored templates remain free and selectable regardless of ATT status. ATT continues to control advertising attribution only.

## Domain model and compatibility

Add a public `templateID` string to `PersonCard`. New cards default to `standard-clean`.

The Swift decoder uses `standard-clean` when persisted or remote data omits the field. Rendering also falls back to `standard-clean` for an unknown identifier, so a future or malformed identifier cannot make a card unreadable.

The backend `PersonCard` schema accepts and returns `templateID`, defaults missing values to `standard-clean`, and constrains supplied identifiers to a short lowercase ASCII slug. The YDB card document stores `templateID`; the existing exclusion of local-only `meetingPlace` remains unchanged.

This is an additive version-2 contract change:

- New clients can read cards created by older clients and stored before this change.
- Existing clients ignore the additional JSON key when decoding a response.
- Older clients publishing a card without `templateID` receive the default from the backend.
- No contract-version increase is required because the field is optional on input and has a deterministic default.

## Template catalog and rendering

A small app-owned catalog resolves the four stable identifiers to a title, sponsorship category, and accessible palette. It is the single source used by the Appearance screen and `CardSummaryView`.

- `standard-clean`: existing light/dark surface, indigo accent, semantic ink text.
- `standard-contrast`: dark navy surface, mint accent, white text.
- `mint-conference`: pale mint surface, dark green accent, dark navy text.
- `indigo-studio`: indigo surface, mint accent, white text.

The catalog must provide sufficient contrast in light and dark appearances. Template selection is communicated by a checkmark, text, and VoiceOver state rather than color alone.

`CardSummaryView` applies the resolved surface, accent, and text colors to every visible card element. Existing image saving and sharing already render this view, so those outputs automatically preserve the selected design.

## Editor and appearance flow

`CardEditorViewController` owns `selectedTemplateID` as draft state initialized from the existing card or `standard-clean`. It supplies a preview card and selection callback when opening `AppearanceViewController`.

`AppearanceViewController` owns only presentation state for the current draft. Selecting a template:

1. updates its preview;
2. marks the matching button as selected;
3. reports `sponsored_template_selected` only for sponsored choices;
4. returns the identifier to the editor callback.

It does not write storage or publish independently. `CardEditorViewController.done()` places the identifier into the saved `PersonCard`; the existing `CardViewController` save and publish path persists and synchronizes it.

## Exchange and server data flow

`templateID` is public card presentation metadata:

1. The editor saves it in the local owner card.
2. `SyncWirePersonCard` includes it in publish and prepare-exchange requests.
3. The backend validates and stores it with the published card.
4. QR payloads retain it through `exchangeCopy`.
5. Claim, refresh, photo import, and manual-code flows decode it through `PersonCard`.
6. `CardSummaryView` resolves and displays it for both owners and recipients.

Only the identifier is transmitted. Palette values, ATT state, attribution identifiers, analytics consent, and sponsored-template interaction events are not included in a card payload.

## Analytics and privacy

- Selecting `mint-conference` reports the existing anonymous category `sponsored_event`.
- Selecting `indigo-studio` reports the existing anonymous category `sponsored_studio`.
- Standard selections do not reuse the unrelated `card_created` event.
- Template availability and rendering never depend on ATT authorization.
- `AppSpec.md` and `AppPrivacy.yml` must identify `templateID` as public presentation metadata sent with an explicitly published or exchanged card.

## Failure handling

- Missing or unknown `templateID`: render `standard-clean` without blocking the card.
- Backend rejects a syntactically invalid identifier: preserve the existing locally saved card and use the current visible synchronization failure behavior.
- Missing local storage: retain the existing editor behavior and on-screen card for the current session.
- Sponsored analytics disabled or unavailable: selection and rendering still succeed.

## Verification

- Add backend tests first for the missing-field default, accepted valid identifier, invalid identifier rejection, YDB persistence, and exchange preservation.
- Use a temporary Foundation-only Swift harness before implementation to prove the desired `PersonCard` decoding default and template resolver behavior without adding a prohibited XCTest target to the standalone app.
- Build the Release application and every embedded extension for an iPhone simulator.
- Run the complete backend pytest suite.
- Inspect the source and encoded wire path to confirm `meetingPlace` remains excluded while `templateID` is included.
- Manually verify all four previews, editor cancellation, saved selection, received-card rendering, VoiceOver selection state, Dynamic Type, dark mode, and saved/shared images on a simulator or physical device.

## Out of scope

- Downloadable template artwork or arbitrary remote CSS-like styling.
- Paid templates, subscriptions, external purchases, or ATT-gated availability.
- User-authored colors, fonts, backgrounds, or layout editors.
- Migrating existing cards to a non-default design.
- A new iOS XCTest or UI-test target.
