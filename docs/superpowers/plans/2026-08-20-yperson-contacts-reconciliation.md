# YPerson Contacts Reconciliation Implementation Plan

> **Required sub-skill:** Use `superpowers:test-driven-development` for every behavior change and `superpowers:verification-before-completion` before reporting completion.

**Goal:** Make Contacts synchronization safe for every saved person: no false matches from empty fields, no silent choice of the first card, and no duplicate add when one unambiguous match can be updated after confirmation.

**Approved behavior:** `AppSpec.md` sections “Люди и Контакты” and Contacts permission; `AppPrivacy.yml` `permissions.contacts`.

**Architecture:** Put deterministic normalization and match classification in a Foundation-only helper so it can be exercised by a temporary command-line Swift harness. `PermissionCenter` remains the sole Contacts owner. `PeopleViewController` selects the intended YPerson card and presents an explicit add/update plan before the save request.

---

### Task 1: Add deterministic match policy

**Files:**
- Create: `YPerson/Permissions/ContactMatchPolicy.swift`
- Test temporarily: `/tmp/yperson-contact-match-harness.swift`

1. Write a harness that fails because `ContactMatchPolicy` does not exist.
2. Cover literal cases: empty phone/email never match; formatted Russian and international phones match on a stable last-10-digit key; a 7–9 digit value matches only an exact normalized value; email matching trims whitespace and ignores case; unrelated non-empty values do not match.
3. Implement the smallest pure helper and watch the harness pass against the production file.

### Task 2: Make Contacts mutation choose add versus update

**Files:**
- Modify: `YPerson/Permissions/PermissionCenter.swift`
- Modify generated project only as required to compile the new source: `YPerson.xcodeproj/project.pbxproj`

1. Fetch identifiers, names, organization, role, phones, and emails.
2. Return a reconciliation result with zero, one, or multiple candidates and a user-readable list of fields that would change.
3. Empty card fields must not erase existing Contacts fields.
4. Zero candidates produces an add action. One candidate produces an update action against a mutable copy. Multiple candidates produce no mutation until the user selects one.
5. Save only after the UI confirms the chosen action. Preserve unrelated phone/email values.

### Task 3: Let the user choose the YPerson card and keep import reachable

**Files:**
- Modify: `YPerson/UI/PeopleViewController.swift`

1. Show “Добавить из Контактов” in both empty and populated states.
2. Replace `people.first` with an action sheet/list that chooses the intended saved person.
3. Show the concrete add/update/no-change plan, candidate identity when known, and an explicit confirm button whose title matches the operation.
4. For multiple candidates, let the user choose the contact before displaying the plan; cancel changes nothing.
5. Report success accurately as added, updated, or already current.

### Task 4: Verify

1. Run the temporary pure Swift harness.
2. Regenerate the project with the repository's installed generator if needed and inspect the diff.
3. Build `YPerson` Release for `generic/platform=iOS Simulator` with signing disabled.
4. Confirm no source, UI, or payload sends system Contacts off device.
5. Record physical-device Contacts checks as pending; do not claim them from simulator evidence.

**Out of scope for this wave:** Persisting a long-lived Contacts identifier across an owner changing every match field; that belongs to the saved-person update/deletion wave and must include a migration and privacy-contract review.
