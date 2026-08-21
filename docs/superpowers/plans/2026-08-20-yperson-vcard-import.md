# YPerson vCard Import Implementation Plan

> **Required sub-skill:** Use `superpowers:test-driven-development` for the parser and `superpowers:verification-before-completion` before reporting completion.

**Goal:** Make the already advertised “compatible vCard” camera and Photos paths actually import a useful local YPerson card after confirmation.

**Approved behavior:** `AppSpec.md` camera and photo-import sections; `AppPrivacy.yml` `permissions.camera` and `permissions.photo_library_read`.

**Architecture:** Add a small Foundation-only vCard parser that returns a local-only `PersonCard`. Reuse the existing confirmation and local persistence path by wrapping the parsed card in an offline `ExchangePayload`; no vCard data is sent to the backend merely because it was scanned. The save path must preserve this already-classified local card directly rather than applying `exchangeCopy` a second time, because that would discard the parsed phone. Genuine YPerson payload producers remain responsible for applying their public/private-field policy before encoding.

**Contract ruling:** `AppSpec.md` and `AppPrivacy.yml` require a confirmed scanned-card payload to synchronize, but the current backend has no operation or ownership model for a third-party vCard without a signed YPerson owner/exchange token. This wave keeps such vCards local-only, preserves cloud claim for genuine YPerson payloads, and records the unresolved conformance blocker in the roadmap rather than inventing a server owner. A future backend-import contract requires separate approval for ownership, retention, deletion, and update semantics.

---

### Task 1: Parse the supported vCard subset

**Files:**
- Create: `YPerson/Domain/VCardParser.swift`
- Test temporarily: `/tmp/yperson-vcard-harness.swift`

1. Start with a failing harness covering CRLF/LF input, folded lines, parameterized keys such as `TEL;TYPE=CELL`, escaping, and case-insensitive property names.
2. Map `FN` with `N` fallback to name, `TITLE` to role, `ORG` to company, the first non-empty `TEL` and `EMAIL`, and optional `NOTE` to tagline.
3. Reject missing `BEGIN:VCARD`/`END:VCARD`, missing usable name, and inputs exceeding a small documented size bound.
4. Generate a local UUID-based card identifier, set no source installation, no meeting place, no audio, no block, and `.localOnly` sync state.

### Task 2: Route camera and Photos candidates through the parser

**Files:**
- Modify: `YPerson/UI/ExchangeViewController.swift`
- Modify generated project only as required to compile the new source: `YPerson.xcodeproj/project.pbxproj`

1. In `handleScannedCode`, keep YPerson v2 decoding and add vCard parsing before unsupported-format failure.
2. In photo results, accept the first valid YPerson payload or vCard candidate and show the same confirmation UI.
3. Use offline confirmation text and do not attempt a cloud claim for vCard. Preserve its parsed phone when saving; do not weaken the existing public-field filtering performed by YPerson payload producers.
4. Make failure messages distinguish malformed vCard from unsupported content. Reject unsupported encoded-value parameters rather than importing their encoded bytes as visible text.

### Task 3: Verify

1. Run the temporary harness against the production parser.
2. Run a deterministic route/persistence assertion proving that a confirmed vCard retains its parsed phone while an already-filtered YPerson payload is not broadened.
3. Regenerate/inspect the project if needed.
4. Build the complete Release app and embedded extensions for an iPhone simulator with signing disabled.
5. Inspect the code path to prove raw images and raw vCard content are not uploaded.
6. Leave camera and full Photo-library device checks pending unless directly exercised.

**Out of scope:** vCard photos, custom labels, social profiles, arbitrary binary properties, automatic Contacts writes, and a new backend ownership/storage contract for third-party vCards.
