# YPerson QR Scanner Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing YPerson widget into a Home Screen and Lock Screen shortcut that opens the app directly in its existing QR scanner.

**Architecture:** A Foundation-only shared route owns the exact `yperson://scan` URL. The UIKit host app validates that route on cold and warm launches, selects the Exchange tab, and invokes the existing scanner through a small duplicate-launch gate; the WidgetKit extension renders only static launcher UI and holds no personal snapshot or App Group access.

**Tech Stack:** Swift 5, UIKit, SwiftUI, WidgetKit, AVFoundation in the host app only, transient Swift verification harnesses, XcodeGen 2.46.0, Xcode 26.5.

**Spec:** `docs/superpowers/specs/2026-08-20-yperson-qr-scanner-widget-design.md`

## Global Constraints

- Keep the application and widget minimum deployment target at iOS 15.0.
- Support `systemSmall`; on iOS 16+ also support `accessoryCircular` and `accessoryRectangular`.
- Use exactly `yperson://scan` and reject a path, query, fragment, credentials, port, or any other scheme/host.
- Keep camera capture and permission requests inside the host application; the widget must not import AVFoundation.
- Reuse `ExchangeViewController.scanQR()` and `QRCodeScannerViewController`; do not create a second scanner implementation.
- The widget must read no personal data, make no network request, and use no App Group entitlement.
- Preserve the existing `PersonalDebug` configuration, signing values, and all unrelated dirty-worktree changes.
- Do not add iOS 18-only Control Widgets, App Intent behavior, or locked camera capture extensions.
- Do not add a persistent XCTest/UI-test target or test files to this standalone app; run TDD for pure route/state types with temporary Swift harnesses outside the tracked project.

## File Map

**Create:**

- `YPersonShared/ScannerWidgetRoute.swift` — canonical deep-link URL and strict route validator shared by the app and widget.
- `YPerson/Experience/QRScannerLaunchGate.swift` — small state gate that coalesces repeated widget launches.

**Modify:**

- `project.yml` — URL scheme and removal of widget App Group configuration.
- `YPerson.xcodeproj/project.pbxproj` — regenerated from `project.yml` with existing `PersonalDebug` settings preserved.
- `YPerson/Resources/Info.plist` — regenerated URL scheme registration.
- `YPerson/App/AppDelegate.swift` — cold- and warm-launch URL handling.
- `YPerson/Experience/YPersonIntegrationContract.swift` — scanner entry point.
- `YPerson/App/AppFactory.swift` — retain the Exchange controller as the scanner route destination.
- `YPerson/UI/MainTabBarController.swift` — select Exchange and request scanner launch.
- `YPerson/UI/ExchangeViewController.swift` — coalesce repeated launches and invoke the existing permission flow.
- `YPersonWidget/YPersonWidget.swift` — static scanner shortcut UI and supported families.
- `YPersonWidget/Resources/Info.plist` — regenerated without `APP_GROUP_IDENTIFIER`.
- `YPerson/Storage/AppGroupSnapshotStore.swift` — remove live WidgetKit snapshot APIs while preserving deletion of obsolete keys.
- `YPerson/UI/CardViewController.swift` — stop publishing the obsolete update-count snapshot.
- `AppSpec.md`, `Design/design-spec.md`, `AppPrivacy.yml`, `Release/implementation-verification.md`, `Release/manual-device-checks.md` — scanner-widget product, privacy, and verification contract.

**Delete:**

- `YPersonShared/WidgetSnapshot.swift` — obsolete update-count transport.
- `YPersonWidget/YPersonWidget.entitlements` — the scanner shortcut needs no App Group capability.

---

### Task 1: Shared scanner route

**Files:**

- Create: `YPersonShared/ScannerWidgetRoute.swift`

**Interfaces:**

- Produces: `ScannerWidgetRoute.url: URL`
- Produces: `ScannerWidgetRoute.matches(_ url: URL) -> Bool`
- Consumed by: Task 2 host-app URL handling and Task 3 widget URL.

- [ ] **Step 1: Write a failing transient route harness**

Create `/tmp/yperson-scanner-route-tests/main.swift` outside the tracked project:

```swift
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

require(ScannerWidgetRoute.url.absoluteString == "yperson://scan", "canonical URL")
require(ScannerWidgetRoute.matches(ScannerWidgetRoute.url), "canonical route")

let rejected = [
    "https://scan",
    "yperson://card",
    "yperson://scan/extra",
    "yperson://scan?source=widget",
    "yperson://scan#fragment",
    "yperson://user@scan",
    "yperson://scan:443"
]

for value in rejected {
    guard let url = URL(string: value) else { fatalError(value) }
    require(!ScannerWidgetRoute.matches(url), value)
}

print("scanner route checks passed")
```

- [ ] **Step 2: Run the route harness and verify the expected failure**

Run:

```bash
swiftc /tmp/yperson-scanner-route-tests/main.swift YPersonShared/ScannerWidgetRoute.swift -o /tmp/yperson-scanner-route-tests/route-checks
```

Expected: FAIL because `ScannerWidgetRoute` does not exist.

- [ ] **Step 3: Implement the exact shared route**

Create `YPersonShared/ScannerWidgetRoute.swift`:

```swift
import Foundation

enum ScannerWidgetRoute {
    static let url = URL(string: "yperson://scan")!

    static func matches(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }

        return components.scheme == "yperson"
            && components.host == "scan"
            && components.path.isEmpty
            && components.query == nil
            && components.fragment == nil
            && components.user == nil
            && components.password == nil
            && components.port == nil
    }
}
```

- [ ] **Step 4: Run the focused route harness**

Run the command from Step 2, then execute:

```bash
/tmp/yperson-scanner-route-tests/route-checks
```

Expected: exit 0 and `scanner route checks passed`.

- [ ] **Step 5: Commit the shared route**

```bash
git add YPersonShared/ScannerWidgetRoute.swift
git commit -m "test: add scanner widget route contract"
```

---

### Task 2: Cold/warm deep linking and duplicate-launch protection

**Files:**

- Create: `YPerson/Experience/QRScannerLaunchGate.swift`
- Modify: `YPerson/Experience/YPersonIntegrationContract.swift:3-7`
- Modify: `YPerson/App/AppDelegate.swift:9-34`
- Modify: `YPerson/App/AppFactory.swift:40-67`
- Modify: `YPerson/UI/MainTabBarController.swift:3-28`
- Modify: `YPerson/UI/ExchangeViewController.swift:38-48`
- Modify: `project.yml:68-112`
- Regenerate: `YPerson/Resources/Info.plist`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`

**Interfaces:**

- Consumes: `ScannerWidgetRoute.matches(_:)` from Task 1.
- Produces: `YPersonEntryPoint.scanQR`.
- Produces: `QRScannerLaunchGate.begin(alreadyPresenting:) -> Bool` and `complete()`.
- Produces: `ExchangeViewController.openScannerFromWidget()` for `MainTabBarController`.

- [ ] **Step 1: Write a failing transient duplicate-launch harness**

Create `/tmp/yperson-scanner-gate-tests/main.swift` outside the tracked project:

```swift
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

var gate = QRScannerLaunchGate()
require(gate.begin(alreadyPresenting: false), "first request")
require(!gate.begin(alreadyPresenting: false), "pending request")
gate.complete()
require(!gate.begin(alreadyPresenting: true), "visible scanner or prompt")
require(gate.begin(alreadyPresenting: false), "request after completion")
print("scanner launch gate checks passed")
```

- [ ] **Step 2: Run the launch-gate harness and verify the expected failure**

Run:

```bash
swiftc /tmp/yperson-scanner-gate-tests/main.swift YPerson/Experience/QRScannerLaunchGate.swift -o /tmp/yperson-scanner-gate-tests/gate-checks
```

Expected: FAIL because `QRScannerLaunchGate` does not exist.

- [ ] **Step 3: Implement the minimal launch gate**

Create `YPerson/Experience/QRScannerLaunchGate.swift`:

```swift
struct QRScannerLaunchGate {
    private(set) var isPending = false

    mutating func begin(alreadyPresenting: Bool) -> Bool {
        guard !isPending, !alreadyPresenting else { return false }
        isPending = true
        return true
    }

    mutating func complete() {
        isPending = false
    }
}
```

- [ ] **Step 4: Run the launch-gate harness**

Run the command from Step 2, then execute:

```bash
/tmp/yperson-scanner-gate-tests/gate-checks
```

Expected: exit 0 and `scanner launch gate checks passed`.

- [ ] **Step 5: Register the custom URL scheme**

Add this to the main target's `info.properties` in `project.yml`:

```yaml
CFBundleURLTypes:
  - CFBundleTypeRole: Viewer
    CFBundleURLName: com.yperson.app.scanner
    CFBundleURLSchemes:
      - yperson
```

Run:

```bash
xcodegen generate
plutil -p YPerson/Resources/Info.plist | rg -n 'CFBundleURLTypes|yperson'
```

Expected: the generated app plist contains the single `yperson` scheme and the existing `PersonalDebug` configuration remains in the project.

- [ ] **Step 6: Add the scanner entry point and app URL handling**

Add `scanQR` to `YPersonEntryPoint`:

```swift
enum YPersonEntryPoint: Sendable {
    case root
    case card
    case scanQR
    case privacy
}
```

In `AppDelegate`, select the cold-launch context from `launchOptions` and handle warm URLs:

```swift
let launchURL = launchOptions?[.url] as? URL
let entryPoint: YPersonEntryPoint = launchURL.map(ScannerWidgetRoute.matches) == true
    ? .scanQR
    : .root

window.rootViewController = builder.makeRootViewController(
    context: YPersonExperienceContext(entryPoint: entryPoint),
    output: self
)
```

```swift
func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool {
    guard ScannerWidgetRoute.matches(url), let experienceBuilder else {
        return false
    }
    experienceBuilder.route(to: .scanQR)
    return true
}
```

- [ ] **Step 7: Route Exchange to the existing scanner without stacking**

Change `MainTabBarController` to retain a weak typed reference to the Exchange controller and add the new route:

```swift
private weak var exchangeController: ExchangeViewController?

init(
    card: UIViewController,
    exchange: ExchangeViewController,
    people: UIViewController,
    privacy: UIViewController
) {
    self.exchangeController = exchange
    super.init(nibName: nil, bundle: nil)
    // Keep the existing viewControllers and appearance setup unchanged.
}
```

```swift
case .scanQR:
    selectedIndex = 1
    exchangeController?.openScannerFromWidget()
```

In `ExchangeViewController`, add a gate and route method while retaining the existing `scanQR()` permission copy and scanner callback:

```swift
private var scannerLaunchGate = QRScannerLaunchGate()

func openScannerFromWidget() {
    let scannerIsVisible = navigationController?.topViewController
        is QRCodeScannerViewController
    let alreadyPresenting = scannerIsVisible || presentedViewController != nil
    guard scannerLaunchGate.begin(alreadyPresenting: alreadyPresenting) else {
        return
    }

    navigationController?.popToRootViewController(animated: false)
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.scannerLaunchGate.complete()
        self.scanQR()
    }
}
```

Add a defensive guard at the start of `scanQR()`:

```swift
guard presentedViewController == nil,
      !(navigationController?.topViewController is QRCodeScannerViewController) else {
    return
}
```

`AppFactory` continues constructing one `ExchangeViewController` and passes that typed instance into `MainTabBarController`.

- [ ] **Step 8: Run route and gate harnesses, then build the app**

Run:

```bash
/tmp/yperson-scanner-route-tests/route-checks
/tmp/yperson-scanner-gate-tests/gate-checks
xcodebuild build -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: both harnesses print their passing messages and the app build ends with `BUILD SUCCEEDED`.

- [ ] **Step 9: Commit app routing**

```bash
git add YPerson/App/AppDelegate.swift YPerson/App/AppFactory.swift YPerson/Experience/YPersonIntegrationContract.swift YPerson/Experience/QRScannerLaunchGate.swift YPerson/UI/MainTabBarController.swift YPerson/UI/ExchangeViewController.swift
git add -p project.yml YPerson.xcodeproj/project.pbxproj YPerson/Resources/Info.plist
git commit -m "feat: route scanner widget into QR capture"
```

Stage only scanner-route hunks from files that were dirty before this plan.

---

### Task 3: Scanner-launcher widget UI

**Files:**

- Modify: `YPersonWidget/YPersonWidget.swift:1-79`

**Interfaces:**

- Consumes: `ScannerWidgetRoute.url` from Task 1.
- Produces: WidgetKit families `.systemSmall`, `.accessoryCircular`, and `.accessoryRectangular`.
- Produces: accessibility label `Сканировать QR-код визитки в YPerson`.

- [ ] **Step 1: Replace the update-count entry/provider with a static scanner entry**

Use a single entry and a never-refresh timeline because the widget has no dynamic data:

```swift
private struct ScannerEntry: TimelineEntry {
    let date: Date
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ScannerEntry {
        ScannerEntry(date: Date())
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ScannerEntry) -> Void
    ) {
        completion(ScannerEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ScannerEntry>) -> Void
    ) {
        completion(Timeline(
            entries: [ScannerEntry(date: Date())],
            policy: .never
        ))
    }
}
```

- [ ] **Step 2: Implement family-specific launcher views**

Replace the old update-count body with layouts that contain no decorative QR payload:

```swift
private struct ScannerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ScannerEntry

    var body: some View {
        Group {
            if #available(iOSApplicationExtension 16.0, *),
               family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2.bold())
                }
            } else if #available(iOSApplicationExtension 16.0, *),
                      family == .accessoryRectangular {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Сканировать QR").font(.headline)
                        Text("YPerson").font(.caption)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 42, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("Сканировать QR")
                        .font(.headline)
                    Text("Добавить визитку")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.82))
                }
                .foregroundColor(.white)
                .padding(16)
                .scannerWidgetBackground()
            }
        }
        .widgetURL(ScannerWidgetRoute.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Сканировать QR-код визитки в YPerson")
    }
}
```

Add an iOS 15/17-compatible background modifier:

```swift
private extension View {
    @ViewBuilder
    func scannerWidgetBackground() -> some View {
        let indigo = Color(red: 0.31, green: 0.37, blue: 0.91)
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(indigo, for: .widget)
        } else {
            background(indigo)
        }
    }
}
```

- [ ] **Step 3: Update widget metadata and supported families**

Keep the existing widget kind and replace its display text/families:

```swift
StaticConfiguration(kind: "com.yperson.app.widget", provider: Provider()) {
    entry in
    ScannerWidgetView(entry: entry)
}
.configurationDisplayName("Сканер визиток")
.description("Открывает YPerson сразу для сканирования QR-кода визитки.")
.supportedFamilies(supportedFamilies)
```

```swift
private var supportedFamilies: [WidgetFamily] {
    if #available(iOSApplicationExtension 16.0, *) {
        return [.systemSmall, .accessoryCircular, .accessoryRectangular]
    }
    return [.systemSmall]
}
```

- [ ] **Step 4: Build the widget target with iOS 15 availability checking**

Run:

```bash
xcodebuild build -project YPerson.xcodeproj -target YPersonWidget -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`, with no availability or localization warning promoted to an error.

- [ ] **Step 5: Commit the widget UI**

```bash
git add YPersonWidget/YPersonWidget.swift
git commit -m "feat: turn widget into QR scanner shortcut"
```

---

### Task 4: Remove obsolete snapshot and widget App Group access

**Files:**

- Delete: `YPersonShared/WidgetSnapshot.swift`
- Delete: `YPersonWidget/YPersonWidget.entitlements`
- Modify: `YPerson/Storage/AppGroupSnapshotStore.swift:1-150`
- Modify: `YPerson/UI/CardViewController.swift:48-89`
- Modify: `project.yml:125-153`
- Regenerate: `YPersonWidget/Resources/Info.plist`
- Regenerate: `YPerson.xcodeproj/project.pbxproj`

**Interfaces:**

- Removes: `WidgetSnapshot`, `WidgetSnapshotStorage`, `readWidgetSnapshot()`, and `writeWidgetSnapshot(_:)`.
- Preserves: `AppGroupSnapshotStore.readOwnCard()`, `writeOwnCard(_:)`, configuration cache, consent, pending deletion, and removal of obsolete snapshot keys during account deletion.

- [ ] **Step 1: Record the obsolete dependency surface before cleanup**

Run:

```bash
rg -n 'WidgetSnapshot|writeWidgetSnapshot|readWidgetSnapshot|WidgetCenter|APP_GROUP_IDENTIFIER|CODE_SIGN_ENTITLEMENTS' YPerson YPersonShared YPersonWidget project.yml
```

Expected: references appear in `WidgetSnapshot.swift`, `AppGroupSnapshotStore.swift`, `CardViewController.swift`, widget Info.plist/entitlements, and the widget target configuration.

- [ ] **Step 2: Remove snapshot publishing and decoding**

Remove the two `writeWidgetSnapshot` calls from `CardViewController.render()`.

In `AppGroupSnapshotStore`, remove `import WidgetKit`, `readWidgetSnapshot()`, `writeWidgetSnapshot(_:)`, and `migrateWidgetSnapshot()`. Replace the storage references with literal obsolete keys used only by `clearUserData()`:

```swift
private enum Key {
    static let obsoleteWidgetSnapshot = "yperson.v1.widget_snapshot"
    // Keep all existing live keys.

    enum Legacy {
        static let obsoleteWidgetSnapshot = "widget_snapshot"
        // Keep all existing live legacy keys.
    }
}
```

Include both obsolete keys in `clearUserData()`:

```swift
Key.obsoleteWidgetSnapshot,
Key.Legacy.obsoleteWidgetSnapshot,
```

Delete `YPersonShared/WidgetSnapshot.swift` after no production code consumes it.

- [ ] **Step 3: Remove the widget capability and Info.plist value**

In the `YPersonWidget` target in `project.yml`, remove:

```yaml
CODE_SIGN_ENTITLEMENTS: YPersonWidget/YPersonWidget.entitlements
```

and remove this widget-only Info property:

```yaml
APP_GROUP_IDENTIFIER: $(APP_GROUP_IDENTIFIER)
```

Delete `YPersonWidget/YPersonWidget.entitlements`, then regenerate:

```bash
xcodegen generate
```

- [ ] **Step 4: Verify the obsolete surface is gone and live app storage remains**

Run:

```bash
rg -n 'WidgetSnapshot|writeWidgetSnapshot|readWidgetSnapshot|WidgetCenter' YPerson YPersonShared YPersonWidget project.yml
rg -n 'APP_GROUP_IDENTIFIER|CODE_SIGN_ENTITLEMENTS' YPersonWidget project.yml
rg -n 'readOwnCard|writeOwnCard|cachedConfiguration|analyticsConsent|profileDeletionPending|obsoleteWidgetSnapshot' YPerson/Storage/AppGroupSnapshotStore.swift
```

Expected: the first two searches return no widget snapshot/App Group capability references for the extension; the last search confirms the app's live storage and obsolete-key cleanup remain.

- [ ] **Step 5: Re-run harnesses and build all embedded extensions**

Run:

```bash
/tmp/yperson-scanner-route-tests/route-checks
/tmp/yperson-scanner-gate-tests/gate-checks
xcodebuild build -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: both harnesses pass and the application plus all embedded extensions build successfully.

- [ ] **Step 6: Commit snapshot and entitlement removal**

```bash
git add YPersonWidget/Resources/Info.plist YPerson/Storage/AppGroupSnapshotStore.swift YPerson/UI/CardViewController.swift YPersonShared/WidgetSnapshot.swift YPersonWidget/YPersonWidget.entitlements
git add -p project.yml YPerson.xcodeproj/project.pbxproj YPerson/Resources/Info.plist
git commit -m "refactor: remove widget personal snapshot access"
```

Stage only widget-cleanup hunks from the pre-existing dirty project files.

---

### Task 5: Reconcile product/privacy documentation and verify the finished flow

**Files:**

- Modify: `AppSpec.md:175-180`
- Modify: `Design/design-spec.md:152-159`
- Modify: `AppPrivacy.yml:531-537`
- Modify: `AppPrivacy.yml:710-721`
- Modify: `AppPrivacy.yml:754-764`
- Modify: `Release/implementation-verification.md:89-99`
- Modify: `Release/manual-device-checks.md:1-36`

**Interfaces:**

- Consumes: all production behavior from Tasks 1-4.
- Produces: one consistent product, privacy, review, and manual-device contract for the scanner shortcut.

- [ ] **Step 1: Update the product and design contracts**

Replace the update-count/Lock Screen-card statements with these exact decisions:

```markdown
### QR scanner widget

WidgetKit provides a `systemSmall` Home Screen shortcut on iOS 15 and
`accessoryCircular`/`accessoryRectangular` Lock Screen shortcuts on iOS 16+.
Every family opens `yperson://scan`; YPerson selects Exchange and starts the
existing QR scanner permission flow. The widget contains no card data, QR
payload, update count, camera access, analytics, or network client.
```

Use the existing Russian terminology around it and remove every claim that the widget reads a personal snapshot or displays unread updates.

- [ ] **Step 2: Update privacy and release verification**

Record that the widget is a stateless launcher, has no App Group entitlement, and cannot access the camera. Keep the main application's App Group and camera declaration unchanged because the app still stores its own data and performs scanning after explicit user action.

Update the manual matrix to require:

```markdown
- [ ] На iOS 15 проверить `systemSmall`: нажатие открывает «Обмен» и запускает существующий сценарий «Сканировать QR».
- [ ] На iOS 16+ проверить `accessoryCircular` и `accessoryRectangular` на Lock Screen с тем же переходом.
- [ ] Проверить cold launch, warm launch, повторное нажатие без дублирования, а также authorized/notDetermined/denied/restricted состояния камеры.
- [ ] Подтвердить, что у widget extension нет App Group entitlement, camera purpose string, сетевого клиента и персонального snapshot.
```

- [ ] **Step 3: Scan for contradictory documentation**

Run:

```bash
rg -n -i 'update count|unread|непросмотр|обновлен.*виджет|Lock Screen widget|личн.*snapshot|compact App Group snapshot|не отображает QR' AppSpec.md Design/design-spec.md AppPrivacy.yml Release
```

Expected: no active statement says that the widget displays update counts or reads card data; historical references unrelated to the live widget contract are clearly labeled if retained.

- [ ] **Step 4: Run the full automated verification**

Run:

```bash
git diff --check
xcodegen generate
/tmp/yperson-scanner-route-tests/route-checks
/tmp/yperson-scanner-gate-tests/gate-checks
xcodebuild build -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/yperson-qr-scanner-widget-derived CODE_SIGNING_ALLOWED=NO
```

Expected: `git diff --check` is silent, both harnesses pass, and the final build ends with `BUILD SUCCEEDED`.

- [ ] **Step 5: Inspect the built extension privacy boundary**

Run:

```bash
plutil -p /tmp/yperson-qr-scanner-widget-derived/Build/Products/Debug-iphonesimulator/YPerson.app/PlugIns/YPersonWidget.appex/Info.plist
xcodebuild -project YPerson.xcodeproj -target YPersonWidget -configuration Debug -showBuildSettings | rg 'CODE_SIGN_ENTITLEMENTS|APP_GROUP_IDENTIFIER|PRODUCT_BUNDLE_IDENTIFIER'
rg -n 'AVFoundation|URLSession|UserDefaults|WidgetSnapshot|APP_GROUP_IDENTIFIER' YPersonWidget YPersonShared/ScannerWidgetRoute.swift
```

Expected: the widget plist has no camera or App Group key; build settings have no `CODE_SIGN_ENTITLEMENTS` or `APP_GROUP_IDENTIFIER` assignment for `YPersonWidget`; source inspection shows none of the prohibited APIs or snapshot types.

- [ ] **Step 6: Exercise warm and cold scanner links in Simulator**

With the Debug app installed on a booted iPhone simulator, run:

```bash
xcrun simctl openurl booted yperson://scan
xcrun simctl terminate booted com.yperson.app
xcrun simctl openurl booted yperson://scan
```

Expected: warm and cold launches both select Exchange and present the existing camera explanation/scanner path; a second tap while the prompt or scanner is visible does not stack another presentation.

- [ ] **Step 7: Commit documentation and verification updates**

```bash
git add AppSpec.md Design/design-spec.md
git add -p AppPrivacy.yml Release/implementation-verification.md Release/manual-device-checks.md
git commit -m "docs: document scanner shortcut widget"
```

Stage only scanner-widget documentation hunks from the three release files
that were already modified before this work.

- [ ] **Step 8: Record physical-device limitations accurately**

Leave the iOS 15 device, signed App Group removal, real camera, Lock Screen widget, and permission-state checks unchecked in `Release/manual-device-checks.md` until they are completed on signed physical devices. Report them as remaining release checks rather than automated successes.
