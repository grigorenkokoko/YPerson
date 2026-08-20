# YPerson Card Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all four card templates selectable, persistent, visually distinct, exportable, and transferable through every existing YPerson exchange path.

**Architecture:** Extend the additive version-2 `PersonCard` contract with a defaulted public `templateID`. Keep the template catalog and compatibility rules in the Foundation-only domain model, map catalog entries to UIKit palettes at the view layer, and let the existing editor save/publish path own persistence. The backend validates and stores only the identifier, while QR and sync reuse the existing card codecs.

**Tech Stack:** Swift 5, UIKit, Codable, iOS 15, Python 3.12, FastAPI, Pydantic v2, YDB, pytest, XcodeGen-managed Xcode project.

**Spec:** `docs/superpowers/specs/2026-08-20-yperson-card-templates-design.md`

## Global Constraints

- Preserve the iPhone-only iOS 15.0 application and existing programmatic UIKit architecture.
- Do not add an XCTest target, UI-test target, mocks, or persistent iOS test infrastructure.
- The four stable identifiers are exactly `standard-clean`, `standard-contrast`, `mint-conference`, and `indigo-studio`.
- Missing or unknown template identifiers render as `standard-clean`.
- ATT must never gate template selection or rendering.
- Transmit only `templateID`; never add palette values, ATT state, advertising identifiers, analytics consent, or analytics events to card payloads.
- Preserve the local-only exclusion of `meetingPlace` from QR/server publication.
- Keep the sync contract at version 2; the new field must remain additive and defaulted.
- Do not stage or commit the user's existing personal-build files: `.gitignore`, `Config/PersonalDebug.xcconfig`, `YPerson.xcodeproj/xcshareddata/xcschemes/YPerson Personal.xcscheme`, and `YPerson/YPersonPersonal.entitlements`.

---

### Task 1: Add the backward-compatible template contract

**Files:**
- Modify: `YPerson/Domain/Models.swift:24-105,375-399`
- Modify: `backend/app/schemas.py:41-56`
- Modify: `backend/tests/test_schemas.py:100-165`
- Modify: `backend/tests/test_storage.py:267-370`
- Modify: `backend/tests/test_sync_service.py:20-265`
- Test temporarily: `/tmp/yperson-template-contract/main.swift`

**Interfaces:**
- Consumes: existing `PersonCard`, `SyncWirePersonCard`, Pydantic `PersonCard`, QR `ExchangePayload`, and version-2 sync operations.
- Produces: `CardTemplateDefinition`, `CardTemplateCatalog.all`, `CardTemplateCatalog.resolve(_:)`, `PersonCard.templateID`, and backend `PersonCard.templateID`.

- [ ] **Step 1: Add failing backend schema tests**

Add tests that prove old payloads default safely, valid slugs survive, and invalid identifiers are rejected:

```python
def test_person_card_template_defaults_for_legacy_clients() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "publishCard",
            "card": {
                "id": "legacy-card",
                "name": "Legacy",
                "role": "Designer",
                "company": "YPerson",
                "phone": "",
                "email": "legacy@example.invalid",
                "tagline": "Hello",
                "hasAudioGreeting": False,
                "isBlocked": False,
            },
        }
    )
    assert request.card is not None
    assert request.card.templateID == "standard-clean"


def test_person_card_accepts_a_public_template_identifier() -> None:
    styled = PersonCard(
        id="styled-card", name="Styled", role="Designer", company="YPerson",
        phone="", email="styled@example.invalid", tagline="Hello",
        hasAudioGreeting=False, isBlocked=False, templateID="mint-conference",
    )
    assert styled.model_dump(mode="json")["templateID"] == "mint-conference"


@pytest.mark.parametrize("template_id", ["", "Mint Conference", "../mint", "a" * 65])
def test_person_card_rejects_invalid_template_identifiers(template_id: str) -> None:
    with pytest.raises(ValidationError):
        PersonCard(
            id="invalid-template", name="Invalid", role="Designer", company="YPerson",
            phone="", email="invalid@example.invalid", tagline="Hello",
            hasAudioGreeting=False, isBlocked=False, templateID=template_id,
        )
```

- [ ] **Step 2: Add failing storage and exchange assertions**

In `test_published_card_survives_refresh`, publish a styled model copy and assert YDB retains it while continuing to exclude `meetingPlace`:

```python
styled_card = PersonCard.model_validate(
    card.model_dump(mode="json") | {"templateID": "mint-conference"}
)
version = store.publish_card("installation-owner", "op-publish-1", styled_card, None)
# Use styled_card for the retry and equality assertions in this test.
stored_json = json.loads(pool.cards["installation-owner"][1])
assert stored_json["templateID"] == "mint-conference"
assert "meetingPlace" not in stored_json
```

In `test_two_installations_claim_exchange_and_receive_peer_card`, prepare with a styled owner card and verify the claim:

```python
owner_card = PersonCard.model_validate(
    card("card-owner", "Owner").model_dump(mode="json")
    | {"templateID": "indigo-studio"}
)
# Pass owner_card.model_dump(mode="json") to prepareExchange.
assert claimed.json()["people"][0]["card"]["templateID"] == "indigo-studio"
```

- [ ] **Step 3: Run the focused backend tests and verify RED**

```bash
backend/.venv/bin/pytest -q \
  backend/tests/test_schemas.py \
  backend/tests/test_storage.py::test_published_card_survives_refresh \
  backend/tests/test_sync_service.py::test_two_installations_claim_exchange_and_receive_peer_card
```

Expected: failures because backend `PersonCard` forbids or lacks `templateID` and the legacy default does not exist.

- [ ] **Step 4: Create and run a failing temporary Swift contract harness**

Create `/tmp/yperson-template-contract/main.swift` with:

```swift
import Foundation

let legacyJSON = Data(#"{
  "id":"legacy-card","name":"Legacy","role":"Designer","company":"YPerson",
  "phone":"","email":"legacy@example.invalid","tagline":"Hello",
  "hasAudioGreeting":false,"meetingPlace":null,"isBlocked":false
}"#.utf8)
let decoded = try JSONDecoder().decode(PersonCard.self, from: legacyJSON)
precondition(decoded.templateID == "standard-clean")
precondition(CardTemplateCatalog.resolve("mint-conference").id == "mint-conference")
precondition(CardTemplateCatalog.resolve("future-template").id == "standard-clean")
var exchanged = decoded.exchangeCopy
exchanged.templateID = "indigo-studio"
let encoded = try JSONEncoder().encode(exchanged)
let roundTrip = try JSONDecoder().decode(PersonCard.self, from: encoded)
precondition(roundTrip.templateID == "indigo-studio")
print("template-contract-pass")
```

Run:

```bash
xcrun swiftc YPerson/Domain/Models.swift /tmp/yperson-template-contract/main.swift \
  -o /tmp/yperson-template-contract/check
```

Expected: compilation fails because `templateID` and `CardTemplateCatalog` do not exist.

- [ ] **Step 5: Implement the Foundation-only Swift catalog and card field**

Add these domain interfaces near `PersonCard` in `Models.swift`:

```swift
struct CardTemplateDefinition: Equatable {
    let id: String
    let title: String
    let sponsoredCategory: String?
}

enum CardTemplateCatalog {
    static let standardClean = CardTemplateDefinition(id: "standard-clean", title: "Чистый", sponsoredCategory: nil)
    static let standardContrast = CardTemplateDefinition(id: "standard-contrast", title: "Контрастный", sponsoredCategory: nil)
    static let mintConference = CardTemplateDefinition(id: "mint-conference", title: "Mint Conference", sponsoredCategory: "sponsored_event")
    static let indigoStudio = CardTemplateDefinition(id: "indigo-studio", title: "Indigo Studio", sponsoredCategory: "sponsored_studio")
    static let all = [standardClean, standardContrast, mintConference, indigoStudio]

    static func resolve(_ id: String?) -> CardTemplateDefinition {
        all.first(where: { $0.id == id }) ?? standardClean
    }
}
```

Add `var templateID: String`, default the initializer parameter to `CardTemplateCatalog.standardClean.id`, include it in `CodingKeys`, and decode with:

```swift
templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
    ?? CardTemplateCatalog.standardClean.id
```

Keep `exchangeCopy` from clearing `templateID`. Add `templateID` to `SyncWirePersonCard` and initialize it from `card.templateID` while continuing to set `meetingPlace = nil`.

- [ ] **Step 6: Implement backend validation and persistence compatibility**

Add this Pydantic field to `backend/app/schemas.py`:

```python
templateID: str = Field(
    default="standard-clean",
    min_length=1,
    max_length=64,
    pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$",
)
```

Do not change the YDB schema or contract version. The current `card.model_dump(..., exclude={"meetingPlace"})` automatically stores the new public field while preserving the location exclusion.

- [ ] **Step 7: Run the focused tests and verify GREEN**

Run the focused pytest command from Step 3, then:

```bash
xcrun swiftc YPerson/Domain/Models.swift /tmp/yperson-template-contract/main.swift \
  -o /tmp/yperson-template-contract/check
/tmp/yperson-template-contract/check
```

Expected: focused pytest passes and the harness prints `template-contract-pass`.

- [ ] **Step 8: Commit the contract without personal-build files**

```bash
git commit --only -m "feat: add card template contract" -- \
  YPerson/Domain/Models.swift backend/app/schemas.py \
  backend/tests/test_schemas.py backend/tests/test_storage.py \
  backend/tests/test_sync_service.py
```

### Task 2: Apply templates in the editor, preview, card, and exported image

**Files:**
- Modify: `YPerson/UI/YPStyle.swift:1-140`
- Modify: `YPerson/UI/AppearanceViewController.swift:1-32`
- Modify: `YPerson/UI/CardEditorViewController.swift:1-105`
- Modify: `YPerson/App/AppFactory.swift:60-70,140-170`
- Test temporarily: `/tmp/yperson-template-ui-contract.py`

**Interfaces:**
- Consumes: `CardTemplateCatalog`, `PersonCard.templateID`, existing `CardSummaryView`, editor save callback, image saver, permissions, and analytics.
- Produces: `CardTemplatePalette`, template-aware `CardSummaryView`, draft-aware `AppearanceViewController`, and a three-argument `makeAppearance` factory.

- [ ] **Step 1: Create a failing UI wiring contract**

Create `/tmp/yperson-template-ui-contract.py` with:

```python
from pathlib import Path

root = Path("YPerson")
appearance = (root / "UI/AppearanceViewController.swift").read_text()
editor = (root / "UI/CardEditorViewController.swift").read_text()
style = (root / "UI/YPStyle.swift").read_text()
factory = (root / "App/AppFactory.swift").read_text()

assert "CardSummaryView(card: previewCard)" in appearance
assert "accessibilityTraits.insert(.selected)" in appearance
assert 'showMessage("Шаблон выбран"' not in appearance
assert "templateID: selectedTemplateID" in editor
assert "CardTemplatePalette" in style
assert "CardTemplateCatalog.resolve(card.templateID)" in style
assert "AppearanceViewController(" in factory
assert "selectedTemplateID: selectedTemplateID" in factory
print("template-ui-contract-pass")
```

- [ ] **Step 2: Run the UI contract and verify RED**

```bash
python3 /tmp/yperson-template-ui-contract.py
```

Expected: assertion failure because the current Appearance screen has no preview or selection state and the card renderer has no palette.

- [ ] **Step 3: Add accessible palettes and render them in `CardSummaryView`**

Add a UIKit-only palette next to `YPStyle`:

```swift
struct CardTemplatePalette {
    let surface: UIColor
    let accent: UIColor
    let text: UIColor
}

extension CardTemplateDefinition {
    var palette: CardTemplatePalette {
        switch id {
        case CardTemplateCatalog.standardContrast.id:
            return .init(surface: UIColor(hex: 0x142033), accent: UIColor(hex: 0xAEEBD3), text: .white)
        case CardTemplateCatalog.mintConference.id:
            return .init(surface: UIColor(hex: 0xE6F8F0), accent: UIColor(hex: 0x146B4A), text: UIColor(hex: 0x142033))
        case CardTemplateCatalog.indigoStudio.id:
            return .init(surface: UIColor(hex: 0x4F5FE7), accent: UIColor(hex: 0xAEEBD3), text: .white)
        default:
            return .init(surface: YPStyle.surface, accent: YPStyle.indigo, text: YPStyle.ink)
        }
    }
}
```

In `CardSummaryView.init`, resolve `CardTemplateCatalog.resolve(card.templateID)`, set the view background and avatar tint from the palette, and set every generated text label's `textColor` to the palette text color. Keep the existing VoiceOver summary and layout. The existing `CardImageSaver.render(cardView)` will then export the applied colors without a new export path.

- [ ] **Step 4: Replace the placeholder Appearance screen with preview and selection state**

Change the initializer to:

```swift
init(
    card: PersonCard,
    selectedTemplateID: String,
    permissions: PermissionCenter,
    analytics: AppMetricaAnalyticsClient,
    onSelect: @escaping (String) -> Void
)
```

Store `previewCard`, normalize the selection through `CardTemplateCatalog.resolve`, add a preview stack before the two template sections, and keep a `[String: UIButton]` dictionary. Selection must use:

```swift
private func select(_ template: CardTemplateDefinition) {
    selectedTemplateID = template.id
    previewCard.templateID = template.id
    onSelect(template.id)
    if let category = template.sponsoredCategory {
        analytics.report(.sponsoredTemplateSelected(category))
    }
    renderPreview()
    renderSelection()
    UIAccessibility.post(notification: .announcement, argument: "Выбран шаблон \(template.title)")
}
```

`renderPreview()` must recreate `CardSummaryView(card: previewCard)`. `renderSelection()` must set a checkmark plus `configuration?.subtitle = "Выбрано"` and call `accessibilityTraits.insert(.selected)` only on the selected button, removing `.selected` from the others. Remove the misleading success alert and the standard-template `.cardCreated` event. Preserve the independent ATT explanation/action below the sponsored templates.

- [ ] **Step 5: Keep the selection as editor draft state**

Change `makeAppearance` in `CardEditorViewController` to:

```swift
private let makeAppearance: (
    PersonCard,
    String,
    @escaping (String) -> Void
) -> UIViewController
```

Initialize:

```swift
private var selectedTemplateID: String
// In init:
self.selectedTemplateID = CardTemplateCatalog.resolve(card?.templateID).id
```

Extract card construction into:

```swift
private func makeCard(name: String) -> PersonCard {
    PersonCard(
        id: existingCard?.id ?? UUID().uuidString.lowercased(),
        name: name,
        role: trimmed(roleField),
        company: trimmed(companyField),
        phone: privateFieldsStack.isHidden ? (existingCard?.phone ?? "") : trimmed(phoneField),
        email: trimmed(emailField),
        tagline: existingCard?.tagline ?? "",
        hasAudioGreeting: audio.state != .empty,
        meetingPlace: existingCard?.meetingPlace,
        isBlocked: existingCard?.isBlocked ?? false,
        templateID: selectedTemplateID
    )
}
```

Use `makeCard(name:)` from `done()`. Open Appearance with the current trimmed name or `Ваша визитка`, and update only `selectedTemplateID` in the callback. Storage remains owned by `done()`, so backing out of the editor discards the draft choice.

- [ ] **Step 6: Update application factory wiring**

Replace the zero-argument appearance factory in `AppFactory.swift` with:

```swift
let makeAppearance = { [permissions, analytics]
    (card: PersonCard, selectedTemplateID: String, onSelect: @escaping (String) -> Void) in
    AppearanceViewController(
        card: card,
        selectedTemplateID: selectedTemplateID,
        permissions: permissions,
        analytics: analytics,
        onSelect: onSelect
    )
}
```

Update the DEBUG `S6` verification route to supply `.reviewOwn`, its template identifier, and a no-op selection callback. Keep all existing screenshot routes and editor wiring.

- [ ] **Step 7: Verify UI wiring and compilation GREEN**

```bash
python3 /tmp/yperson-template-ui-contract.py
xcodebuild -quiet \
  -project YPerson.xcodeproj \
  -scheme YPerson \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-template-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: the source contract prints `template-ui-contract-pass`; the Release build exits 0 with no app-owned warnings.

- [ ] **Step 8: Commit the UI behavior without personal-build files**

```bash
git commit --only -m "fix: apply selected card templates" -- \
  YPerson/UI/YPStyle.swift YPerson/UI/AppearanceViewController.swift \
  YPerson/UI/CardEditorViewController.swift YPerson/App/AppFactory.swift
```

### Task 3: Synchronize product, privacy, design, and review evidence

**Files:**
- Modify: `AppSpec.md`
- Modify: `AppPrivacy.yml`
- Modify: `Design/design-spec.md`
- Modify: `Release/manual-device-checks.md`
- Modify: `Release/review-notes.md`
- Modify: `Release/implementation-verification.md`
- Modify: `Release/release-manifest.json`

**Interfaces:**
- Consumes: implemented `templateID` behavior and the approved design spec.
- Produces: reviewer-visible product/privacy truth matching the source and wire contract.

- [ ] **Step 1: Add a failing documentation consistency check**

Create `/tmp/yperson-template-doc-contract.py` with:

```python
import json
from pathlib import Path

spec = Path("AppSpec.md").read_text()
privacy = Path("AppPrivacy.yml").read_text()
design = Path("Design/design-spec.md").read_text()
review = Path("Release/review-notes.md").read_text()
checks = Path("Release/manual-device-checks.md").read_text()
manifest = json.loads(Path("Release/release-manifest.json").read_text())

assert "templateID" in spec
assert "templateID" in privacy
assert "standard-clean" in design and "indigo-studio" in design
assert "выбранное оформление" in checks
assert "template" in review.lower()
assert "templateID" in json.dumps(manifest, ensure_ascii=False)
print("template-doc-contract-pass")
```

- [ ] **Step 2: Run the documentation contract and verify RED**

```bash
python3 /tmp/yperson-template-doc-contract.py
```

Expected: assertion failure because current documents describe availability but not persistence or the public identifier.

- [ ] **Step 3: Update the coordinated sources of truth**

Record these exact facts consistently:

- `AppSpec.md`: template choice is saved with the owner card, rendered for recipients and image export, and transferred as `templateID` through approved exchange paths.
- `AppPrivacy.yml`: `templateID` is public presentation metadata collected only as part of explicitly published Contact Info for App Functionality; palette values and ATT state are not transmitted.
- `Design/design-spec.md`: list the four stable identifiers, live preview, checkmark/subtitle selection state, draft cancellation behavior, and four palettes.
- `Release/manual-device-checks.md`: check that every template renders in light/dark mode, survives save/relaunch, appears on a received card and exported image, and remains available when ATT is denied.
- `Release/review-notes.md`: explain the Appearance reviewer path and that ATT denial does not change templates.
- `Release/implementation-verification.md`: record automated contract/build evidence and explicitly leave visual/device verification pending until exercised.
- `Release/release-manifest.json`: add `templateID` to the public card payload/evidence without changing pipeline status or claiming a new archive validation.

- [ ] **Step 4: Run documentation and syntax checks GREEN**

```bash
python3 /tmp/yperson-template-doc-contract.py
python3 -m json.tool Release/release-manifest.json >/dev/null
git diff --check
```

Expected: contract prints `template-doc-contract-pass`; JSON and diff checks exit 0.

- [ ] **Step 5: Commit documentation without personal-build files**

```bash
git commit --only -m "docs: document transferable card templates" -- \
  AppSpec.md AppPrivacy.yml Design/design-spec.md \
  Release/manual-device-checks.md Release/review-notes.md \
  Release/implementation-verification.md Release/release-manifest.json
```

### Task 4: Run complete verification and inspect repository scope

**Files:**
- Verify only; modify a task file only if a failing check identifies a defect in that task.

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: fresh evidence for the exact integrated branch state.

- [ ] **Step 1: Run the complete backend suite**

```bash
backend/.venv/bin/pytest -q backend/tests
```

Expected: all tests pass; the existing Starlette/httpx deprecation warning may remain and must be reported rather than hidden.

- [ ] **Step 2: Run all temporary contract harnesses**

```bash
/tmp/yperson-template-contract/check
python3 /tmp/yperson-template-ui-contract.py
python3 /tmp/yperson-template-doc-contract.py
```

Expected: each prints its corresponding `*-pass` marker.

- [ ] **Step 3: Run a fresh Release build**

```bash
xcodebuild -quiet \
  -project YPerson.xcodeproj \
  -scheme YPerson \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-template-final-derived \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: app, widget, notification service extension, and notification content extension build successfully with exit code 0 and no app-owned warnings.

- [ ] **Step 4: Inspect privacy boundaries and changed-file scope**

```bash
rg -n 'templateID|meetingPlace = nil|exclude=\{"meetingPlace"\}' \
  YPerson/Domain/Models.swift backend/app/schemas.py backend/app/ydb_store.py AppPrivacy.yml
git diff --check
git status --short
git log --oneline --max-count=6
```

Expected: `templateID` is present in local/public/wire models; Swift and backend still remove `meetingPlace` from publication; no unplanned files are modified; the four personal-build files remain outside feature commits.

- [ ] **Step 5: Perform available visual checks and report the hardware remainder**

Open the DEBUG `S6` verification state when an iPhone simulator is available. Inspect preview selection, all four palettes, VoiceOver selected state, Dynamic Type, editor cancellation, saved selection, and saved/shared image rendering. Record simulator-limited or physical-device-only checks in `Release/manual-device-checks.md`; do not claim they passed without direct evidence.
