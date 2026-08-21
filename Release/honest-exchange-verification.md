# YPerson Honest Exchange — final local verification

Recorded at `2026-08-21T16:26:13Z` on branch `codex/honest-exchange`.

Verification baseline: `eae256521846bcb1f543d1b16bc21e578d854565` (`fix: harden nearby and audio card commits`).

## Release status

The Honest Exchange implementation passed the final integrated local gate on the exact baseline above. The product remains `implementation-verified`, not `archive-validated` and not `release-ready`. `Release/release-manifest.json` remains `releaseReady: false`; no readiness flag or existing external blocker was removed.

This evidence covers backend tests and formatting, the repository Foundation contract runner, unsigned Debug and Release generic-iOS-Simulator arm64 builds, all four built products, fail-closed privacy/source/manual-code/reviewer-QR/binary scans, privacy manifests, tracked JSON/YAML parsing, and branch/worktree validation. It is not live YDB, deployment, physical-device, signing, archive, or App Store evidence.

## Automated PASS

### Backend quality gates

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q backend/tests
```

Result: exit `0`; `274 passed, 1 warning in 11.27s`.

The single warning is the existing warning below; there were no test failures:

```text
StarletteDeprecationWarning: Using `httpx` with `starlette.testclient` is deprecated; install `httpx2` instead.
```

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m ruff check backend/app backend/tests
```

Result: exit `0`; `All checks passed!`.

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m ruff format --check backend/app backend/tests
```

Result: exit `0`; `25 files already formatted`.

Toolchain: Python `3.12.14`; Ruff `0.16.3`.

### Repository contract runner

```bash
Verification/HonestExchangeContract/run.sh
```

Result: exit `0` with all three repository markers:

```text
honest-exchange-contract-v9-pass
honest-exchange-source-contracts-pass
honest-exchange-lifecycle-order-pass
```

The runner compiles the real Foundation production models and exchange contract. Version 9 covers the public/private exchange boundary, manual-code normalization and single-use flow, credential and operation routing, public QR/Bluetooth policy, persistence and deletion recovery, Contacts and media commit barriers, audio publication recovery, APNs record ownership, scanner launch behavior, lifecycle transitions, transfer-generation invalidation, and ordered async source contracts.

The lifecycle verifier was also run with Python assertions disabled:

```bash
env PYTHONOPTIMIZE=1 python3 Verification/HonestExchangeContract/verify-lifecycle-order.py
```

Result: exit `0`; `honest-exchange-lifecycle-order-pass`.

### Fresh unsigned arm64 simulator builds

The accepted Debug and Release builds used fresh, previously absent DerivedData directories, destination `generic/platform=iOS Simulator`, `ARCHS=arm64`, `ONLY_ACTIVE_ARCH=NO`, and `CODE_SIGNING_ALLOWED=NO`.

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/yperson-honest-exchange-eae25652-1621-debug -clonedSourcePackagesDirPath /tmp/yperson-honest-exchange-eae25652-1621-sourcepackages ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO clean build
```

Result: exit `0`; successful quiet Debug build.

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/yperson-honest-exchange-eae25652-1623-release-final -clonedSourcePackagesDirPath /tmp/yperson-honest-exchange-eae25652-1621-sourcepackages -disableAutomaticPackageResolution ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO clean build
```

Result: exit `0`; successful quiet Release build.

Toolchain: Xcode `26.5` (`17F42`).

Both build products were inspected individually. In Debug and Release the following four executables existed and `file` identified each as `Mach-O 64-bit executable arm64`:

- `YPerson.app/YPerson`
- `YPerson.app/PlugIns/YPersonWidget.appex/YPersonWidget`
- `YPerson.app/PlugIns/YPersonNotificationService.appex/YPersonNotificationService`
- `YPerson.app/PlugIns/YPersonNotificationContent.appex/YPersonNotificationContent`

One earlier Release invocation reached the product directory at the process-yield boundary without returning a reliable final status to the verifier. It was not accepted as evidence. The Release command recorded above used a different fresh directory and returned an explicit exit `0`.

### Fail-closed privacy, source, manual-code, QR, and binary gates

The positive privacy inventory first required all six scopes to exist and be readable: `backend`, `YPerson`, `AppSpec.md`, `AppPrivacy.yml`, `Release`, and `deploy`. Every required term then had a positive match count:

- `exchangeCode=75`
- `exchangeExpiresAt=37`
- `privateFields=58`
- `connection_private_fields=20`
- `exchange_private_fields=35`

The shipping-source scope enumerated `44` files under `YPerson`. A fail-closed scan across `YPerson` and `Release/reviewer-assets` searched for the obsolete static code `YP-1234` and the obsolete client-generated ten-minute expiry expression. Raw `rg` status was exactly `1`: status `0` would mean a banned match, and status greater than `1` would mean a scan error.

The reviewer QR verifier ran with a readable compatible local ZXing Core jar:

```bash
env ZXING_CORE_JAR=/Users/grigornkokoko/.gradle/caches/modules-2/files-2.1/com.google.zxing/core/3.4.1/1869da97e9b2b60b5ff2fcaf55899174b93ae25d/core-3.4.1.jar Release/reviewer-assets/verify-offline-public-qr.sh
```

Result: exit `0`. Production Swift models decoded the public offline payload; ZXing decoded the exact `578`-byte payload from the `808x808` PNG. `test-qr.png` SHA-256 was `7a5114756228a495ed58d50c28da5ca7150fe86c3ec2d3a4aa7d1c8743690bb7`.

The Release binary sentinel scan required the app plus all three extension executables to exist, then searched the complete Release app bundle with `rg -a`. It checked the screenshot-state marker, fixture policy/credential/URL protocol/store types, fixture identities and UUID, bearer sentinel, old example code, and legacy static code. Raw status was exactly `1`; any match or scan error failed the gate.

The source `PrivacyInfo.xcprivacy` and all `25` privacy manifests in the built Release app bundle passed `plutil -lint`.

### JSON/YAML, diff, and worktree gates

All tracked configuration documents parsed successfully: `9` JSON files and `5` YAML files. The parser also asserted the unchanged status contract:

- `Release/release-manifest.json`: `implementationStatus == implementation-verified`
- `Release/release-manifest.json`: `releaseReady == false`
- `AppPrivacy.yml`: implementation and release-preparation `release_ready == false`

Before evidence edits, both commands returned exit `0` with no output, and `git status --short` was empty:

```bash
git diff --check
git diff --check origin/main...HEAD
```

The evidence-only diff and clean post-commit state are verified again before this gate is reported complete.

## Device, live-service, and external PENDING

The following remain explicitly unverified and are not implied by the automated PASS above:

- Physical-device Face ID success/cancel/lockout and device-passcode fallback.
- Two-installation manual-code display, normalized entry, one-time claim, cancellation, and real server expiry.
- Two-way public Bluetooth exchange with an independent local claim on each physical iPhone and no peer-confirmation signal; phone absence must be verified even when manual-code consent was authorized. Private Bluetooth remains deferred until recipient-bound mutual pairing exists.
- App backgrounding, clipboard inspection, VoiceOver traversal/labels/announcements, Dynamic Type, iOS 15 behavior, APNs, widgets, and the wider permission matrix in `Release/manual-device-checks.md`.
- Live YDB schema application/query compilation, Object Storage/Lockbox/IAM configuration, Serverless Container deployment, API Gateway routing, external `/health`/`/config`/`/sync` smoke, monitoring, backup/restore, and production AppMetrica traffic.
- Apple signing identities, final bundle/App Group/provisioning/APNs configuration, signed archive creation/validation, archive privacy report, App Store Connect mutation, or upload.

Existing release blockers remain open, including production API and public support/privacy endpoints, Apple identity/signing, production AppMetrica and APNs configuration, moderation operations, owner-supplied review metadata, the physical-device matrix, third-party vCard conformance, recipient-specific private-audio persistence, and connection-level private-grant revoke/update/later-phone propagation.
