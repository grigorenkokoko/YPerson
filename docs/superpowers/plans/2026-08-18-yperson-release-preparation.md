# YPerson Release Preparation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare the implementation-verified YPerson project for App Store review as far as current local evidence and supplied production configuration allow, without uploading or mutating App Store Connect.

**Architecture:** Reconcile the approved product/privacy contract with current primary Apple and AppMetrica requirements, then generate deterministic release artifacts from the existing project. Archive status fails closed: missing final identity, signing, production services, credentials, or reachable policy surfaces keep the project at `implementation-verified` and are recorded with owners and evidence instead of being replaced with invented values.

**Tech Stack:** Xcode 26.5, Swift 6.3.2 in Swift 5 language mode, XcodeGen 2.46.0, UIKit, WidgetKit, AppMetrica 6.5.0, Node.js 25.4.0, JSON/YAML/plist validation, official Apple Developer/App Store Connect Help sources.

**Spec:** `/Users/grigornkokoko/YPerson/AppSpec.md`, `/Users/grigornkokoko/YPerson/AppPrivacy.yml`, `/Users/grigornkokoko/YPerson/Release/release-manifest.json`

## Global Constraints

- Keep `implementation-verified -> archive-validated -> release-ready -> submitted` as the only status progression.
- Preserve iPhone-only, portrait-only, minimum iOS 15.0, all ten permission categories, WidgetKit, notification extensions, AppMetrica, `/health`, `/config`, and `/sync` behavior.
- Do not create XCTest or UI-test targets and do not run unit or UI tests.
- Do not create a signed/validated status from a simulator or unsigned product.
- Do not invent legal identity, contact information, rights, pricing, credentials, production URLs, AppMetrica keys, Apple Team IDs, Bundle IDs, App Groups, or signing assets.
- Do not upload a build, edit App Store Connect, start TestFlight review, or submit to App Review without a new explicit approval immediately before that external action.
- Keep credentials, profiles, archives, and private keys out of version control.

---

### Task 1: Current primary compliance sources

**Files:**
- Create: `Release/compliance-sources.json`

**Interfaces:**
- Consumes: current official Apple Developer, App Store Connect Help, and AppMetrica documentation.
- Produces: dated source decisions referenced by every later release artifact.

- [x] Verify current App Review Guidelines, review checklist, accepted Xcode/SDK requirements, privacy manifests/reports/SDK signatures, privacy details, metadata/screenshots, age rating, signing/archive, and export-compliance requirements.
- [x] Verify current official AppMetrica iOS version, modules, privacy guidance, manifests, domains, and provider terms.
- [x] Record direct URLs, check date, applicable decision, and affected artifact in valid deterministic JSON.

### Task 2: Approval and source-of-truth reconciliation

**Files:**
- Modify: `AppPrivacy.yml`
- Create: `Release/reconciliation.json`

**Interfaces:**
- Consumes: user release-stage approval, AppSpec, AppPrivacy, design artifacts, source, built products, backend, and implementation evidence.
- Produces: exact mismatch/blocker inventory with owner and evidence path.

- [x] Append the implementation approval without changing the verified implementation facts.
- [x] Compare all ten permissions, extensions, backend/AppMetrica, account deletion, UGC, icon, URLs, identity, entitlements, and metadata requirements.
- [x] Record each blocker as `user`, `developer-account`, `backend-operations`, `privacy-legal`, or `release-engineering` owned; do not convert unresolved external facts into defaults.

### Task 3: Production and archive readiness audit

**Files:**
- Create: `Release/archive-validation.json`
- Modify: `Release/release-manifest.json`

**Interfaces:**
- Consumes: Release xcconfig, generated target settings, entitlements, resolved packages, signing identities/profiles visible to Xcode, and current Apple upload requirements.
- Produces: either a real signed archive validation record or an evidence-backed blocked record retaining `implementation-verified`.

- [x] Inspect final/provisional Bundle IDs, Apple Team, App Group, versions, production API/policy/support URLs, AppMetrica key, notification signing key, APNs entitlement, profiles, and signing identities without exposing secrets.
- [x] Compile a clean Release build for generic iOS device with signing disabled only as a structural check; label it non-validating.
- [x] Attempt no signed archive when production identity/configuration is missing; record the exact prerequisite failure and the command that becomes valid after resolution.
- [x] Inspect the available Release products for embedded extensions, platforms, deployment targets, processed purpose strings, privacy manifests, icon, placeholder/debug values, and unexpected frameworks.

### Task 4: Privacy, AppMetrica, and conditional policy package

**Files:**
- Create: `Release/app-store-privacy.json`
- Create: `Release/policy-module-audit.json`

**Interfaces:**
- Consumes: semantic `AppPrivacy.yml`, owned/SDK privacy manifests, resolved AppMetrica source, current App Store privacy questions, account deletion, UGC, encryption, and hardware rules.
- Produces: conservative App Store privacy answers and pass/block decisions for selected conditional modules.

- [x] Map every off-device collected type to purpose, linkage, tracking, and source; keep truly local-only data excluded.
- [x] Record AppMetrica modules, manifest-declared data/domains, custom-event restrictions, ATT dependency, and all policy/contract facts that still require production confirmation.
- [x] Audit selected account-deletion and UGC modules plus not-applicable login, payments, children, regulated-domain, and special-hardware modules for contradictions.
- [x] Derive the current export-compliance answer from standard TLS/CryptoKit use but retain App Store Connect confirmation as an external gate.

### Task 5: App Store metadata and reviewer package

**Files:**
- Create: `Release/app-store-metadata/ru-RU.json`
- Create: `Release/app-store-metadata/README.md`
- Create: `Release/app-store-metadata/screenshots/README.md`
- Create or copy: accurate screenshot PNGs under `Release/app-store-metadata/screenshots/`
- Create: `Release/review-notes.md`
- Create: `Release/reviewer-assets/README.md`
- Create: `Release/reviewer-assets/test-qr.png`

**Interfaces:**
- Consumes: implemented Russian UI, evidence screenshots, reviewer paths, privacy answers, backend behavior, widget/notification flows, and current metadata rules.
- Produces: locally complete truthful Russian metadata and reviewer instructions, with legally/user-owned fields explicitly blocked rather than invented.

- [x] Prepare localized name, subtitle, promotional text, description, keywords, suggested primary/secondary categories, business model, feature list, and compatibility language that matches the binary.
- [x] Copy only current implemented screenshots; document required App Store display-size recapture/export work without fabricating a device frame or unsupported screen.
- [x] Generate a non-secret static test QR matching the implemented scanner contract and document sample cards/manual code.
- [x] Write exact reviewer steps for ten permissions, S1–S8, widget, notifications, account deletion, moderation, backend configuration, offline behavior, and two-iPhone Bluetooth with QR/manual fallbacks.
- [x] Mark missing copyright owner, review contact, production URLs, demo/backend readiness, and rights declarations as release blockers.

### Task 6: Final release-stage verification and handoff

**Files:**
- Modify: `Release/manual-device-checks.md`
- Modify: `Release/release-manifest.json`
- Modify: this plan checkbox state.

**Interfaces:**
- Consumes: Tasks 1–5 artifacts and fresh archive/configuration/build checks.
- Produces: the highest evidence-supported status and an actionable release handoff.

- [x] Validate every JSON/YAML/plist artifact, scan release metadata for unlabelled placeholders/secrets/debug endpoints, and verify source-to-artifact consistency.
- [x] Run fresh generic-device Release compile and backend smoke checks; record actual exit/status results.
- [x] Preserve unchecked physical-device items separately and do not create a pipeline status for them.
- [x] Keep status `implementation-verified` if signing/archive, production services, policy URLs, contacts, AppMetrica, moderation operations, or required metadata remain blocked; never claim `archive-validated` or `release-ready` without evidence.
- [x] Stop before any upload or App Store Connect mutation and report the exact next action requiring user-supplied configuration or a new external-action approval.

## Self-review

- Spec coverage: all release-skill phases map to Tasks 1–6; physical-device checks stay non-gating and external upload stays separately approval-gated.
- Placeholder policy: unresolved production/user facts are named blockers with owners, never invented submission values.
- Status consistency: no task can write `archive-validated` from unsigned or simulator evidence, and no task can write `submitted` without confirmed App Store submission.
