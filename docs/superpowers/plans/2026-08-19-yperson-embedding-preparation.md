# YPerson Embedding Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Подготовить существующий standalone YPerson к последующему извлечению в reusable experience, не добавляя новый target, host fixture, Bank-код или автоматические тесты.

**Architecture:** `YPerson.app` остаётся единственным composition root и создаёт текущий UI через внутренний `YPersonExperienceBuilder`. App и widget совместно компилируют один Foundation-only формат widget snapshot; storage переходит на namespaced keys с безопасным legacy fallback. Будущие Bool-selector, `bank://` router и Bank extensions остаются за пределами поставляемого YPerson.

**Tech Stack:** Swift 5, UIKit, WidgetKit, UserDefaults App Group, XcodeGen 2.46.0, iOS 15.0+, AppMetrica 6.5.0.

**Spec:** `docs/superpowers/specs/2026-08-19-yperson-embedding-preparation-design.md`

## Global Constraints

- Сохранить iOS deployment target `15.0`, portrait-only iPhone и существующие четыре product target'а.
- Не добавлять reusable target, host fixture, Bank types, Bank router, root flag, `bank://` или conditional root cache.
- Не добавлять автоматические test target'ы по прямому решению владельца продукта; использовать compile/build и ручную проверку из спецификации.
- Не менять пользовательские сценарии и UI существующих экранов.
- API, analytics, storage и permissions остаются собственными реализациями YPerson.
- `@main`, `AppDelegate`, `UIWindow`, signing, capabilities и executable extensions остаются в текущих shell target'ах.
- `project.yml` является источником правды; после изменения состава файлов или Info.plist запускать XcodeGen 2.46.0.
- Warnings остаются errors (`GCC_TREAT_WARNINGS_AS_ERRORS=YES`, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`).
- Не затрагивать существующие несвязанные изменения в `AppPrivacy.yml`, `Release/`, `backend/`, `docs/skill-translation-ru/` и serverless design/plan документах.

## File Structure

- `YPerson/Experience/YPersonIntegrationContract.swift` — внутренние entry point, context, lifecycle и output contracts.
- `YPerson/App/AppFactory.swift` — существующая сборка экранов под новым именем `YPersonExperienceBuilder`; сервисы YPerson остаются здесь.
- `YPerson/App/AppDelegate.swift` — standalone composition root и forwarding process-owned lifecycle events.
- `YPerson/UI/MainTabBarController.swift` — typed routing между корнем, карточкой и privacy-вкладкой.
- `YPerson/Support/AppConfiguration.swift` — конфигурация только из явно переданного bundle.
- `YPersonShared/WidgetSnapshot.swift` — Foundation-only snapshot, versioned envelope, keys и backward-compatible decoder.
- `YPerson/Storage/AppGroupSnapshotStore.swift` — namespaced app storage и идемпотентная legacy migration.
- `YPersonWidget/YPersonWidget.swift` — widget wrapper и presentation, использующие общий snapshot codec.
- `YPerson/Domain/Models.swift` — domain models без widget-specific duplicate.
- `project.yml` — target membership общего source folder и отсутствие custom URL scheme.
- `YPerson.xcodeproj/project.pbxproj`, `YPerson/Resources/Info.plist` — только результат штатной генерации XcodeGen.

---

### Task 1: Add the internal experience contract and typed root routing

**Files:**
- Create: `YPerson/Experience/YPersonIntegrationContract.swift`
- Modify: `YPerson/UI/MainTabBarController.swift:3-24`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: существующий `MainTabBarController` с вкладками card index `0` и privacy index `3`.
- Produces: `YPersonEntryPoint`, `YPersonExperienceContext`, `YPersonLifecycleEvent`, `YPersonExperienceOutput`, `MainTabBarController.route(to:)`.

- [ ] **Step 1: Create the exact integration contract**

Create `YPerson/Experience/YPersonIntegrationContract.swift` with:

```swift
import Foundation

enum YPersonEntryPoint: Sendable {
    case root
    case card
    case privacy
}

struct YPersonExperienceContext: Sendable {
    let entryPoint: YPersonEntryPoint
}

enum YPersonLifecycleEvent: Sendable {
    case didEnterForeground
    case pushTokenChanged(String?)
}

@MainActor
protocol YPersonExperienceOutput: AnyObject {
    func yPersonExperienceDidRequestDismiss()
}
```

- [ ] **Step 2: Add typed routing to the existing tab root**

Insert this method before `required init?(coder:)` in `MainTabBarController`:

```swift
func route(to entryPoint: YPersonEntryPoint) {
    switch entryPoint {
    case .root, .card:
        selectedIndex = 0
    case .privacy:
        selectedIndex = 3
    }
}
```

Do not change construction, titles, symbols, navigation controllers, tint, or background colors.

- [ ] **Step 3: Regenerate the project so the new source is compiled**

Run:

```bash
xcodegen generate --spec project.yml
```

Expected: exit `0`; `YPerson/Experience/YPersonIntegrationContract.swift` appears in the YPerson compile sources; target count remains four.

- [ ] **Step 4: Build the standalone scheme**

Run:

```bash
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`; no warnings promoted to errors.

- [ ] **Step 5: Commit the contract boundary**

```bash
git add YPerson/Experience/YPersonIntegrationContract.swift YPerson/UI/MainTabBarController.swift YPerson.xcodeproj/project.pbxproj
git commit -m "refactor: define YPerson experience contract"
```

---

### Task 2: Make the standalone shell consume YPersonExperienceBuilder

**Files:**
- Modify: `YPerson/App/AppFactory.swift:5-135`
- Modify: `YPerson/App/AppDelegate.swift:4-91`
- Modify: `YPerson/Support/AppConfiguration.swift:22`

**Interfaces:**
- Consumes: Task 1 types and `MainTabBarController.route(to:)`.
- Produces: `YPersonExperienceBuilder.init(configuration:)`, `makeRootViewController(context:output:)`, `route(to:)`, `handle(_:)`.

- [ ] **Step 1: Convert AppFactory into the experience builder without rewriting screen assembly**

In `YPerson/App/AppFactory.swift`:

1. Rename `final class AppFactory` to `final class YPersonExperienceBuilder`.
2. Add these retained boundaries after the existing service properties:

```swift
private weak var output: (any YPersonExperienceOutput)?
private weak var rootViewController: MainTabBarController?
```

3. Replace `func makeRootViewController() -> UIViewController` with:

```swift
func makeRootViewController(
    context: YPersonExperienceContext,
    output: any YPersonExperienceOutput
) -> UIViewController {
    self.output = output
```

Keep the existing body that activates analytics, creates the controllers, constructs `MainTabBarController`, and applies DEBUG verification state. Immediately after constructing `root`, add:

```swift
self.rootViewController = root
root.route(to: context.entryPoint)
```

Remove the direct `retryPendingProfileDeletion()` call from root construction so the semantic foreground event owns that behavior.

4. Insert these methods immediately before the DEBUG-only `applyVerificationState` block:

```swift
func route(to entryPoint: YPersonEntryPoint) {
    rootViewController?.route(to: entryPoint)
}

func handle(_ event: YPersonLifecycleEvent) {
    switch event {
    case .didEnterForeground:
        retryPendingProfileDeletion()
    case .pushTokenChanged(let token):
        updatePushToken(token)
    }
}
```

5. Change `func updatePushToken(_:)` to `private func updatePushToken(_:)`. Do not change its payload or network behavior.

- [ ] **Step 2: Make bundle ownership explicit**

In `AppConfiguration`, change:

```swift
init(bundle: Bundle = .main) throws {
```

to:

```swift
init(bundle: Bundle) throws {
```

Do not change the accepted Info.plist keys or URL validation.

- [ ] **Step 3: Update AppDelegate as the standalone composition root**

Make `AppDelegate` conform to `YPersonExperienceOutput` and replace its stored factory with:

```swift
private var experienceBuilder: YPersonExperienceBuilder?
```

Replace the launch construction block with:

```swift
let builder = YPersonExperienceBuilder(
    configuration: try AppConfiguration(bundle: .main)
)
self.experienceBuilder = builder
window.rootViewController = builder.makeRootViewController(
    context: YPersonExperienceContext(entryPoint: .root),
    output: self
)
```

Add semantic foreground forwarding after the orientation delegate method:

```swift
func applicationDidBecomeActive(_ application: UIApplication) {
    experienceBuilder?.handle(.didEnterForeground)
}
```

Replace push calls with:

```swift
experienceBuilder?.handle(
    .pushTokenChanged(deviceToken.map { String(format: "%02x", $0) }.joined())
)
```

and:

```swift
experienceBuilder?.handle(.pushTokenChanged(nil))
```

Add the standalone output implementation before the DEBUG block:

```swift
func yPersonExperienceDidRequestDismiss() {
    // The standalone experience owns the root and therefore has nothing to dismiss.
}
```

Keep notification categories, alert handling, orientation, accessibility evidence, `UIWindow`, and configuration error UI unchanged.

- [ ] **Step 4: Regenerate and build**

Run:

```bash
xcodegen generate --spec project.yml
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: generation exit `0`, then `** BUILD SUCCEEDED **`. `rg -n 'AppFactory' YPerson` returns no Swift type usage.

- [ ] **Step 5: Commit the standalone composition root**

```bash
git add YPerson/App/AppFactory.swift YPerson/App/AppDelegate.swift YPerson/Support/AppConfiguration.swift YPerson.xcodeproj/project.pbxproj
git commit -m "refactor: launch YPerson through experience builder"
```

---

### Task 3: Share one versioned widget snapshot codec

**Files:**
- Create: `YPersonShared/WidgetSnapshot.swift`
- Modify: `YPerson/Domain/Models.swift:80-86`
- Modify: `YPersonWidget/YPersonWidget.swift:1-29`
- Modify: `project.yml:48-50,121-123`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: legacy raw JSON payload stored at key `widget_snapshot`.
- Produces: `WidgetSnapshot`, `WidgetSnapshotStorage.currentKey`, `legacyKey`, `encode(_:)`, `decode(_:)`, `read(from:)`.

- [ ] **Step 1: Create the shared Foundation-only codec**

Create `YPersonShared/WidgetSnapshot.swift` with:

```swift
import Foundation

struct WidgetSnapshot: Codable, Equatable {
    let updateCount: Int
    let isOffline: Bool
    let updatedAt: Date

    static let empty = WidgetSnapshot(
        updateCount: 0,
        isOffline: false,
        updatedAt: .distantPast
    )
}

enum WidgetSnapshotStorage {
    static let currentKey = "yperson.v1.widget_snapshot"
    static let legacyKey = "widget_snapshot"

    private struct Envelope: Codable {
        let schemaVersion: Int
        let snapshot: WidgetSnapshot
    }

    static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        try JSONEncoder().encode(
            Envelope(schemaVersion: 1, snapshot: snapshot)
        )
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data),
           envelope.schemaVersion == 1 {
            return envelope.snapshot
        }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func read(from defaults: UserDefaults) -> WidgetSnapshot? {
        if let data = defaults.data(forKey: currentKey),
           let snapshot = decode(data) {
            return snapshot
        }
        guard let legacyData = defaults.data(forKey: legacyKey) else {
            return nil
        }
        return decode(legacyData)
    }
}
```

Do not import UIKit, SwiftUI, WidgetKit, AppMetrica, or any application-only framework in this file.

- [ ] **Step 2: Compile the shared folder into only the app and widget targets**

Update the `YPerson` source list in `project.yml` to:

```yaml
sources:
  - path: YPerson
  - path: YPersonShared
```

Update the `YPersonWidget` source list to:

```yaml
sources:
  - path: YPersonWidget
  - path: YPersonShared
```

Do not add `YPersonShared` to notification extension targets.

- [ ] **Step 3: Remove duplicate snapshot declarations**

Delete `WidgetSnapshot` from `YPerson/Domain/Models.swift` and delete the private `Snapshot` struct from `YPersonWidget/YPersonWidget.swift`. Do not move `PersonCard`, `RemoteConfiguration`, sync models, or analytics events.

- [ ] **Step 4: Make the widget provider use the shared decoder with legacy fallback**

Replace `Provider.readEntry()` with:

```swift
private func readEntry() -> Entry {
    guard let group = Bundle.main.object(
        forInfoDictionaryKey: "APP_GROUP_IDENTIFIER"
    ) as? String,
          let defaults = UserDefaults(suiteName: group),
          let snapshot = WidgetSnapshotStorage.read(from: defaults) else {
        return Entry(date: Date(), updateCount: 0, isOffline: false)
    }
    return Entry(
        date: snapshot.updatedAt,
        updateCount: snapshot.updateCount,
        isOffline: snapshot.isOffline
    )
}
```

Leave widget kind, families, labels, accessibility and `.widgetURL` unchanged until Task 5.

- [ ] **Step 5: Regenerate and build both consumers**

Run:

```bash
xcodegen generate --spec project.yml
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPersonWidget -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds end with `** BUILD SUCCEEDED **`; `WidgetSnapshot` has one source declaration shared by two compile targets.

- [ ] **Step 6: Commit the shared codec**

```bash
git add YPersonShared/WidgetSnapshot.swift YPerson/Domain/Models.swift YPersonWidget/YPersonWidget.swift project.yml YPerson.xcodeproj/project.pbxproj
git commit -m "refactor: share versioned widget snapshot codec"
```

---

### Task 4: Namespace App Group storage and migrate legacy values

**Files:**
- Modify: `YPerson/Storage/AppGroupSnapshotStore.swift:4-72`

**Interfaces:**
- Consumes: `WidgetSnapshotStorage` from Task 3 and legacy keys currently written by released code.
- Produces: namespaced `yperson.v1.*` keys with idempotent migration and preserved pending-deletion semantics.

- [ ] **Step 1: Replace the key table with namespaced and legacy keys**

Use:

```swift
private enum Key {
    static let ownCard = "yperson.v1.own_card"
    static let remoteConfiguration = "yperson.v1.remote_configuration"
    static let remoteConfigurationETag = "yperson.v1.remote_configuration_etag"
    static let analyticsConsent = "yperson.v1.analytics_consent"
    static let profileDeletionPending = "yperson.v1.profile_deletion_pending"

    enum Legacy {
        static let ownCard = "own_card"
        static let remoteConfiguration = "remote_configuration"
        static let remoteConfigurationETag = "remote_configuration_etag"
        static let analyticsConsent = "analytics_consent"
        static let profileDeletionPending = "profile_deletion_pending"
    }
}
```

Widget snapshot keys continue to come from `WidgetSnapshotStorage` so app and widget cannot drift.

- [ ] **Step 2: Run migration when the suite is opened**

After assigning `self.defaults` in `init?(appGroupIdentifier:)`, call `migrateLegacyValues()`.

Add these exact helpers at the end of the class:

```swift
private func migrateLegacyValues() {
    migrateCodable(
        PersonCard.self,
        from: Key.Legacy.ownCard,
        to: Key.ownCard
    )
    migrateWidgetSnapshot()
    migrateCodable(
        RemoteConfiguration.self,
        from: Key.Legacy.remoteConfiguration,
        to: Key.remoteConfiguration
    )
    migrateString(
        from: Key.Legacy.remoteConfigurationETag,
        to: Key.remoteConfigurationETag
    )
    migrateBool(
        from: Key.Legacy.analyticsConsent,
        to: Key.analyticsConsent
    )
    migrateBool(
        from: Key.Legacy.profileDeletionPending,
        to: Key.profileDeletionPending
    )
}

private func migrateCodable<Value: Decodable>(
    _ type: Value.Type,
    from legacyKey: String,
    to currentKey: String
) {
    guard defaults.object(forKey: currentKey) == nil,
          let data = defaults.data(forKey: legacyKey),
          (try? decoder.decode(type, from: data)) != nil else {
        return
    }
    defaults.set(data, forKey: currentKey)
    defaults.removeObject(forKey: legacyKey)
}

private func migrateWidgetSnapshot() {
    guard defaults.object(forKey: WidgetSnapshotStorage.currentKey) == nil,
          let data = defaults.data(forKey: WidgetSnapshotStorage.legacyKey),
          let snapshot = WidgetSnapshotStorage.decode(data),
          let encoded = try? WidgetSnapshotStorage.encode(snapshot) else {
        return
    }
    defaults.set(encoded, forKey: WidgetSnapshotStorage.currentKey)
    defaults.removeObject(forKey: WidgetSnapshotStorage.legacyKey)
}

private func migrateString(from legacyKey: String, to currentKey: String) {
    guard defaults.object(forKey: currentKey) == nil,
          let value = defaults.string(forKey: legacyKey) else {
        return
    }
    defaults.set(value, forKey: currentKey)
    defaults.removeObject(forKey: legacyKey)
}

private func migrateBool(from legacyKey: String, to currentKey: String) {
    guard defaults.object(forKey: currentKey) == nil,
          let value = defaults.object(forKey: legacyKey) as? NSNumber else {
        return
    }
    defaults.set(value.boolValue, forKey: currentKey)
    defaults.removeObject(forKey: legacyKey)
}
```

The decode guard is required: corrupt legacy data must remain untouched instead of being deleted.

- [ ] **Step 3: Move all reads and writes to current keys**

Make these exact substitutions:

```swift
func readWidgetSnapshot() -> WidgetSnapshot {
    WidgetSnapshotStorage.read(from: defaults) ?? .empty
}

func writeWidgetSnapshot(_ snapshot: WidgetSnapshot) throws {
    defaults.set(
        try WidgetSnapshotStorage.encode(snapshot),
        forKey: WidgetSnapshotStorage.currentKey
    )
    WidgetCenter.shared.reloadAllTimelines()
}
```

Use `Key.ownCard`, `Key.remoteConfiguration`, `Key.remoteConfigurationETag`, `Key.analyticsConsent`, and `Key.profileDeletionPending` everywhere else. Preserve existing PersonCard and RemoteConfiguration JSON wire formats.

- [ ] **Step 4: Keep deletion retry state while clearing user-visible data**

Replace the body of `clearUserData()` with:

```swift
let removableKeys = [
    Key.ownCard,
    WidgetSnapshotStorage.currentKey,
    Key.remoteConfiguration,
    Key.remoteConfigurationETag,
    Key.analyticsConsent,
    Key.Legacy.ownCard,
    WidgetSnapshotStorage.legacyKey,
    Key.Legacy.remoteConfiguration,
    Key.Legacy.remoteConfigurationETag,
    Key.Legacy.analyticsConsent
]
removableKeys.forEach(defaults.removeObject(forKey:))
WidgetCenter.shared.reloadAllTimelines()
```

Do not clear either current or legacy `profileDeletionPending`; the existing retry contract depends on it surviving local data cleanup.

- [ ] **Step 5: Build app and widget after migration changes**

Run:

```bash
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPersonWidget -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds end with `** BUILD SUCCEEDED **`; `rg -n '"own_card"|"widget_snapshot"|"remote_configuration"|"analytics_consent"' YPerson YPersonWidget YPersonShared` shows legacy literals only in the `Legacy` table and `WidgetSnapshotStorage.legacyKey`.

- [ ] **Step 6: Commit storage isolation**

```bash
git add YPerson/Storage/AppGroupSnapshotStore.swift
git commit -m "refactor: namespace YPerson shared storage"
```

---

### Task 5: Remove standalone custom URL ownership

**Files:**
- Modify: `project.yml:94-97`
- Modify: `YPersonWidget/YPersonWidget.swift:53-54`
- Regenerate: `YPerson/Resources/Info.plist`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: current `CFBundleURLTypes` entry and `.widgetURL(URL(string: "yperson://card"))`.
- Produces: standalone app with no custom URL scheme; widget tap opens the containing app root.

- [ ] **Step 1: Remove URL scheme from the XcodeGen source of truth**

Delete this complete block from the YPerson Info properties in `project.yml`:

```yaml
CFBundleURLTypes:
  - CFBundleURLName: com.yperson.app
    CFBundleURLSchemes:
      - yperson
```

Do not add `bank`, `bank://`, associated domains, or replacement schemes.

- [ ] **Step 2: Remove the widget deep link**

Delete only this modifier from `WidgetView.body`:

```swift
.widgetURL(URL(string: "yperson://card"))
```

Keep accessibility, layout, families, widget kind and display metadata unchanged.

- [ ] **Step 3: Regenerate and verify generated configuration**

Run:

```bash
xcodegen generate --spec project.yml
plutil -lint YPerson/Resources/Info.plist
rg -n 'CFBundleURLTypes|yperson://|bank://' project.yml YPerson YPersonWidget YPersonShared YPerson/Resources/Info.plist
```

Expected: XcodeGen and `plutil` exit `0`; `rg` produces no matches.

- [ ] **Step 4: Build the app and standalone widget**

Run:

```bash
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPersonWidget -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingDerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds end with `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit URL ownership cleanup**

```bash
git add project.yml YPersonWidget/YPersonWidget.swift YPerson/Resources/Info.plist YPerson.xcodeproj/project.pbxproj
git commit -m "refactor: remove standalone deep link ownership"
```

---

### Task 6: Verify all standalone products and hand off

**Files:**
- Verify only: all changed files from Tasks 1-5
- Preserve: all unrelated dirty files listed in Global Constraints

**Interfaces:**
- Consumes: completed builder, shared snapshot codec, namespaced store and generated product configuration.
- Produces: evidence that all existing executable products still build independently.

- [ ] **Step 1: Run clean product builds**

Run each command and require `** BUILD SUCCEEDED **`:

```bash
xcodebuild -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingFinalDerivedData CODE_SIGNING_ALLOWED=NO clean build
xcodebuild -project YPerson.xcodeproj -scheme YPersonWidget -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingFinalDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPersonNotificationService -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingFinalDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project YPerson.xcodeproj -scheme YPersonNotificationContent -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/YPersonEmbeddingFinalDerivedData CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 2: Validate generated property lists and extension safety**

Run:

```bash
plutil -lint YPerson/Resources/Info.plist YPersonWidget/Resources/Info.plist YPersonNotificationService/Resources/Info.plist YPersonNotificationContent/Resources/Info.plist
xcodebuild -project YPerson.xcodeproj -target YPersonWidget -configuration Debug -showBuildSettings | rg 'APPLICATION_EXTENSION_API_ONLY = YES'
xcodebuild -project YPerson.xcodeproj -target YPersonNotificationService -configuration Debug -showBuildSettings | rg 'APPLICATION_EXTENSION_API_ONLY = YES'
xcodebuild -project YPerson.xcodeproj -target YPersonNotificationContent -configuration Debug -showBuildSettings | rg 'APPLICATION_EXTENSION_API_ONLY = YES'
```

Expected: all plists report `OK`; each target prints exactly one enabled extension-only setting.

- [ ] **Step 3: Launch on an already booted simulator when available**

Run:

```bash
xcrun simctl bootstatus booted -b
xcrun simctl install booted /tmp/YPersonEmbeddingFinalDerivedData/Build/Products/Debug-iphonesimulator/YPerson.app
xcrun simctl launch booted com.yperson.app
```

Expected: the app launches to the existing four-tab YPerson root. If no simulator is booted, boot an available iPhone simulator in Xcode, then run the three commands unchanged.

Manually confirm that the Card and Privacy tabs open, the standalone widget opens the app root, and notification extension UI/processing remains unchanged.

- [ ] **Step 4: Audit scope and formatting**

Run:

```bash
git diff --check
rg -n 'bank://|CFBundleURLTypes|yperson://' project.yml YPerson YPersonWidget YPersonShared
git status --short
```

Expected: `git diff --check` is silent; the route search is silent; status contains only planned implementation files plus the pre-existing unrelated paths from Global Constraints.

- [ ] **Step 5: Record completion without changing release metadata**

Do not edit `Release/`, `AppPrivacy.yml`, backend files, App Store metadata, signing, capabilities, or privacy manifests. Report the exact build results, simulator result, commit hashes, and the remaining limitation that no reusable target/host fixture or automated test target exists.

