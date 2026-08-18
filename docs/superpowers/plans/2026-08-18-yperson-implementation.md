# YPerson Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and simulator-verify the approved YPerson portrait-only iPhone application, its WidgetKit and notification extensions, AppMetrica consent behavior, and the minimal `/health`, `/config`, `/sync` backend.

**Architecture:** A programmatic UIKit application is composed in `AppFactory` and uses small instance-owned adapters for framework resources, networking, permissions, audio, and analytics. A single WidgetKit target reads a compact App Group snapshot and exposes `systemSmall` on iOS 15 plus `accessoryRectangular` on iOS 16+, while the two notification extensions remain isolated. The backend uses Node's standard HTTP library and in-memory state.

**Tech Stack:** Swift 6.3 compiler in Swift 5 language mode, UIKit, WidgetKit/SwiftUI, CoreBluetooth, AVFoundation/AVFAudio, Contacts, LocalAuthentication, CoreLocation, PhotoKit/Vision, AppTrackingTransparency, UserNotifications, AppMetrica 6.5.0 via Swift Package Manager, Node.js standard library, XcodeGen 2.46.0.

**Spec:** `/Users/grigornkokoko/YPerson/AppSpec.md`, `/Users/grigornkokoko/YPerson/AppPrivacy.yml`, and `/Users/grigornkokoko/YPerson/Design/design-spec.md`

## Global Constraints

- Main app minimum is iOS 15.0; every core flow remains useful on iOS 15+.
- One widget target also deploys to iOS 15.0 so `systemSmall` is real on iOS 15; Lock Screen `accessoryRectangular` is included only on iOS 16+.
- Main app and all extensions target iPhone only, portrait only where orientation applies, with Mac/Catalyst/vision compatibility disabled.
- All application UI is programmatic UIKit; SwiftUI is used only by WidgetKit; no storyboard or XIB files.
- All ten permission categories are reached only from their approved visible trigger and use the exact approved Russian purpose copy.
- No XCTest/UI-test targets, test files, fixtures, or mocks are added; the selected build-stage contract requires builds, launch inspection, framework-flow checks, backend smoke checks, and source inspection instead.
- AppMetrica is pinned exactly to 6.5.0; data sending is disabled until analytics consent, location tracking is disabled, IDFA use follows ATT, and custom events contain no sensitive values.
- The public unauthenticated `GET /config` endpoint accepts no PII, supports ETag, and cannot broaden permissions, tracking, collection, or retention.
- The final Apple identity, production URLs, API key, signing, APNs, hosted policy/support contacts, and production moderation operations remain release blockers.
- No commit is created automatically because the repository has no initial commit and contains pre-existing user-owned untracked files.

---

### Task 1: Reproducible project and immutable configuration

**Files:**
- Create: `project.yml`
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`
- Create: `YPerson/App/AppDelegate.swift`
- Create: `YPerson/App/AppFactory.swift`
- Create: `YPerson/Support/AppConfiguration.swift`
- Create: `YPerson/Resources/InfoPlist.strings`
- Create: `YPerson/Resources/PrivacyInfo.xcprivacy`
- Create: `YPerson/YPerson.entitlements`
- Create: extension Info.plist, entitlements, and PrivacyInfo.xcprivacy files under their target directories
- Create: `YPerson/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: generated 1024×1024 `AppIcon.png` derived from `Design/app-icon.png`

**Interfaces:**
- Produces: `AppConfiguration(bundle:) throws`, with immutable `apiBaseURL`, `privacyPolicyURL`, `supportURL`, `appGroupIdentifier`, and `appMetricaAPIKey`.
- Produces: `AppFactory(configuration:session:)` and `makeRootViewController() -> UIViewController`.

- [x] Define four target bundle identifiers: `com.yperson.app`, `.widget`, `.notification-service`, `.notification-content`.
- [x] Define iPhone-only platform settings, deployment targets, extension embedding, exact AppMetrica package pin, App Group, push capability, purpose keys, and config substitutions in `project.yml`.
- [x] Define Debug localhost `http://127.0.0.1:8080` and Release HTTPS placeholder values in xcconfig without secrets.
- [x] Add all exact permission strings to generated Info.plist settings and `InfoPlist.strings`.
- [x] Generate a 1024×1024 RGB icon from the approved master and declare it as the universal iOS marketing icon.
- [x] Run `xcodegen generate` and inspect the emitted target list, build settings, plist keys, and entitlements.

### Task 2: Models, configuration cache, and real backend client

**Files:**
- Create: `YPerson/Domain/Models.swift`
- Create: `YPerson/Networking/APIClient.swift`
- Create: `YPerson/Storage/AppGroupSnapshotStore.swift`

**Interfaces:**
- Produces: Codable `RemoteConfiguration`, `CardSnapshot`, `PersonCard`, `SyncRequest`, `SyncResponse`, `ModerationAction`, and `WidgetSnapshot`.
- Produces: `APIClient.fetchConfiguration() async throws -> RemoteConfiguration` and `sync(_:) async throws -> SyncResponse` using an injected `URLSession`.
- Produces: `AppGroupSnapshotStore.read() -> WidgetSnapshot` and `write(_:) throws`, followed by explicit widget timeline reload.

- [x] Encode only approved `/config` fields and reject any unknown permission/tracking expansion by decoding into a closed model.
- [x] Implement ETag request/304 handling plus a last-known-good JSON cache in App Group defaults.
- [x] Implement `/sync` with a 12-second timeout, cancellation, explicit JSON errors, installation identifier, optional bearer value/APNs token, and prohibited-field-free payloads.
- [x] Add deterministic sample cards and UI states used by reviewer paths and future screenshots.
- [x] Verify source contains no `URLSession.shared`, mutable globals, or sensitive payload fields.

### Task 3: Consent-aware AppMetrica and ten framework permission adapters

**Files:**
- Create: `YPerson/Analytics/AppMetricaAnalyticsClient.swift`
- Create: `YPerson/Permissions/PermissionCenter.swift`
- Create: `YPerson/Features/NearbyExchangeController.swift`
- Create: `YPerson/Features/QRCodeScannerViewController.swift`
- Create: `YPerson/Features/AudioGreetingController.swift`
- Create: `YPerson/Features/PhotoCardScanner.swift`
- Create: `YPerson/Features/CardImageSaver.swift`

**Interfaces:**
- Produces: `AppMetricaAnalyticsClient.activateIfConsented()`, `setConsent(_:)`, `setTrackingAuthorized(_:)`, and `report(_:)` with one-per-process `launch` enforcement.
- Produces: `PermissionCenter` request/status APIs for Contacts, Face ID, location, Photos read/add, ATT, and notifications.
- Produces: instance-owned start/stop lifecycles for Bluetooth central/peripheral exchange, QR scanning, audio record/play/delete, photo scan, and image save.

- [x] Activate AppMetrica only with a non-empty key, disable location and initial sending, and report `launch` once only after successful consent-aware activation.
- [x] Gate advertising identifier tracking on ATT and leave templates/core app unchanged for denied or restricted states.
- [x] Implement retained Bluetooth central/peripheral resources that advertise and scan the approved service UUID and expose only an ephemeral token.
- [x] Implement camera QR capture, Contacts whole-book duplicate count with explicit save/update confirmation, Face ID/passcode protection, one-shot current location and local label, full audio lifecycle, PhotoKit/Vision scanning, add-only save with UIKit alerts, ATT, and notification request/local demonstration.
- [x] Handle notDetermined, authorized/limited, denied, restricted, unavailable, and unknown states where the framework exposes them, including deliberate Settings recovery.
- [x] Inspect all resource teardown paths for stopped scan/session/location/recording/timers and weak callback captures.

### Task 4: Approved UIKit screen inventory and policy surfaces

**Files:**
- Create: `YPerson/UI/YPStyle.swift`
- Create: `YPerson/UI/MainTabBarController.swift`
- Create: `YPerson/UI/CardViewController.swift`
- Create: `YPerson/UI/ExchangeViewController.swift`
- Create: `YPerson/UI/PeopleViewController.swift`
- Create: `YPerson/UI/PersonViewController.swift`
- Create: `YPerson/UI/CardEditorViewController.swift`
- Create: `YPerson/UI/AppearanceViewController.swift`
- Create: `YPerson/UI/PrivacyViewController.swift`

**Interfaces:**
- Consumes: `APIClient`, `PermissionCenter`, feature resource controllers, analytics client, configuration, and sample models through initializers.
- Produces: the exact S1–S8 screen and state paths approved in `Design/design-spec.md`.

- [x] Implement the four-item bottom navigation with Card, central Exchange, People, and Settings destinations.
- [x] Implement S1 own card, QR presentation, private-field lock, edit path, audio playback, photo save, and visible sync/offline state.
- [x] Implement S2 five exchange methods and public/private share selection, connecting each real permission-backed action only to its approved button.
- [x] Implement S3 people/update list and Contacts reconciliation; implement S4 meeting place, Contacts/photo actions, report/block/delete connection.
- [x] Implement S5 editable public/private fields and complete audio states; implement S6 standard/sponsored templates and separate ATT explanation/action.
- [x] Implement S7 permission status/recovery, push, analytics withdrawal, in-app privacy policy/Safari fallback, support link, and full-scope account deletion confirmation.
- [x] Match the approved light/dark colors, Dynamic Type, 44-point targets, VoiceOver order/labels, non-color status cues, and Reduce Motion behavior.

### Task 5: Widget and notification extensions

**Files:**
- Create: `YPersonWidget/YPersonWidget.swift`
- Create: `YPersonNotificationService/NotificationService.swift`
- Create: `YPersonNotificationContent/NotificationViewController.swift`

**Interfaces:**
- Consumes: compact App Group `WidgetSnapshot` JSON only.
- Produces: iOS 15 `systemSmall`, iOS 16+ `accessoryRectangular`, time-bounded public-avatar enrichment, and programmatic review/block notification content.

- [x] Render neutral card shortcut and update count without QR, contact details, or private fields.
- [x] Reload widget timelines explicitly after app snapshot writes; do not observe shared defaults.
- [x] Validate the notification's signed-card identifier shape, remove technical token text, fetch only an HTTPS public thumbnail with a short timeout, and always call the content handler with best content.
- [x] Render public identity/change categories and expose `Просмотреть и обновить` and `Заблокировать` actions without direct Contacts mutation.
- [x] Verify no AppMetrica product is linked or activated by extensions.

### Task 6: Standard-library backend with required `/config`

**Files:**
- Create: `backend/server.mjs`
- Create: `backend/README.md`
- Create: `backend/.gitignore`

**Interfaces:**
- Produces: `GET /health -> {status:"ok"}`, public `GET /config` with ETag/304, and `POST /sync` with deterministic Codable-compatible JSON.

- [x] Implement explicit methods, content types, body-size limit, JSON validation, status codes, request identifiers, and no third-party dependencies.
- [x] Return configuration version, minimum contract, maintenance, feature availability, sponsored templates, privacy/support URLs, moderation categories, analytics kill switch, and no permission/data/tracking expansion values.
- [x] Keep connection/profile/APNs data in memory, expire exchange tokens after ten minutes, and reject prohibited snapshot keys.
- [x] Document one start command and exact health/config/sync curl commands.
- [x] Start the service and verify health 200, config 200 with ETag, config 304 with `If-None-Match`, valid sync 200, invalid payload 400, and unknown path 404.

### Task 7: Build, launch, and direct application inspection

**Files:**
- Modify only source/project files implicated by concrete verification failures.
- Create: `Release/evidence/` screenshots and text inspections.

**Interfaces:**
- Produces: warning-free Debug and Release simulator products for the main app and all extensions plus launch evidence for principal screens.

- [ ] Resolve AppMetrica 6.5.0 and inspect its signed package identity, selected products, and bundled privacy manifests. Official URL, exact tag/revision, selected products, and manifests are inspected; cryptographic provenance must be rechecked in the signed release archive.
- [x] Build the main scheme Debug and Release with `CODE_SIGNING_ALLOWED=NO` against an available iPhone simulator SDK.
- [x] Build each extension target and inspect deployment targets, platform/device-family flags, bundle identifiers, embedding, entitlements sources, and processed Info.plists.
- [x] Install and launch on an iOS 18.5 iPhone simulator, wait for the meaningful hierarchy, navigate through S1–S8, and capture screenshots/accessibility hierarchy before and after important permission paths.
- [x] Exercise every permission trigger; retry one simulator interaction failure once, then classify hardware-only checks honestly.
- [x] Verify empty AppMetrica key keeps the app useful and produces no activation; record valid-key event verification as pending without inventing credentials.
- [x] Search for storyboards/XIBs/test targets, mutable static state, app-owned singletons, observers/KVO/Combine, `URLSession.shared`, unsupported platforms, missing exact strings, and extension AppMetrica linkage.

### Task 8: Deterministic implementation handoff

**Files:**
- Modify: `AppPrivacy.yml`
- Modify: `AppSpec.md`
- Create: `Release/release-manifest.json`
- Create: `Release/manual-device-checks.md`
- Create: `Release/implementation-verification.md`

**Interfaces:**
- Produces: evidence-backed `implementation-verified` only if all simulator-verifiable contract items pass.

- [x] Compare all ten permission mappings, exact strings, screens, denial behavior, data inventory, `/config` and `/sync`, AppMetrica/ATT, widget, notifications, account deletion, UGC controls, icon, and accessibility against all approved sources.
- [x] Record real commands/results, processed Info.plist values, privacy manifests, entitlements source status, screenshots, extension identifiers, deterministic screenshot states, and backend evidence.
- [x] List physical-device checks for Bluetooth, camera, Contacts, Face ID, location, microphone, PhotoKit, ATT, APNs, signing, and hardware behavior without creating a pipeline status.
- [x] Preserve production API/privacy/support, Apple identity/signing, APNs, AppMetrica project/retention, moderation operations, policy answers, hardware, and archive as explicit release blockers.
- [x] Update status to `implementation-verified` only after the evidence supports it; otherwise retain `design-approved` and report exact blockers.

## Self-review

- Spec coverage: every S1–S8 screen, all ten permissions, three extensions, AppMetrica/ATT, privacy/account deletion/UGC, `/health`, `/config`, `/sync`, iOS 15 fallback, and release evidence map to a task.
- Placeholder scan: the plan contains no deferred implementation choices; only approved production credentials/URLs and device/release evidence remain explicit external blockers.
- Type consistency: configuration, models, API client, snapshot store, analytics, permissions, feature controllers, UI, and extension consumers have one named producer and matching consumers.
