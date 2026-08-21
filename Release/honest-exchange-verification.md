# YPerson Honest Exchange — final local verification

Recorded at `2026-08-21T10:46:01Z` on branch `codex/honest-exchange`.

Verification baseline: `b984b554154256c34eac562a79d1287d0cd0a40d` (`style: format honest exchange backend`).

## Release status

The Honest Exchange implementation is locally automated-verification complete. The product remains `implementation-verified`, not `archive-validated` and not `release-ready`. `Release/release-manifest.json` remains `releaseReady: false`; no readiness flag or existing blocker was removed.

This evidence covers local backend tests and linting, a Foundation-only Swift contract harness, unsigned Debug and Release generic-iOS-Simulator builds, exact product inspection, source/privacy scans, branch whitespace validation, and an exact Release binary sentinel scan. It does not constitute live YDB, deployment, device, signing, archive, or App Store evidence.

## Verification history

The first independent Task 8 run started from `d8e873f95e598d00935cd3aad3c10c394cc9850e`. The complete backend suite passed with `207 passed, 1 warning`, and Ruff check passed, but the required Ruff format check failed: exactly `backend/app/schemas.py`, `backend/app/sync_service.py`, `backend/app/ydb_store.py`, and `backend/tests/test_storage.py` required formatting. Task 8 was stopped without PASS checkboxes or an evidence commit.

Formatting was then applied in the separate, formatting-only integration commit `b984b554154256c34eac562a79d1287d0cd0a40d`. Every required command below was rerun from scratch on that baseline; none of the earlier gate results was reused.

## Automated PASS

### Backend quality gates

```bash
/Users/grigornkokoko/YPerson/backend/.venv/bin/python -m pytest -q backend/tests
```

Result: exit `0`; `207 passed, 1 warning in 13.36s`.

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

Toolchain observed for this run: Python `3.12.14`; Ruff `0.16.3`.

### Swift contract harness

The existing Task 5 harness at `/tmp/yperson-honest-exchange-contract/main.swift` contains the public/private projection, manual-code normalization, typed credential, response exclusivity/failure, request-routing, and public-QR assertions recorded by Tasks 4 and 5.

```bash
xcrun swiftc YPerson/Domain/Models.swift YPerson/Domain/ExchangeContract.swift \
  /tmp/yperson-honest-exchange-contract/main.swift \
  -o /tmp/yperson-honest-exchange-contract/check
/tmp/yperson-honest-exchange-contract/check
```

Result: compile exit `0`; binary exit `0`; marker `honest-exchange-contract-pass`.

The first sandboxed compile could not write the user Clang module cache and did not reach source verification. The unchanged compile command was rerun with module-cache access and produced the PASS result above.

Toolchain observed for this run: Apple Swift `6.3.2` (`swift-driver 1.148.6`).

### Fresh unsigned simulator builds

Before final accepted builds, the exact derived-data directories were removed and their absence verified. `Config/PersonalDebug.xcconfig` was absent throughout; no placeholder was created and neither build required it.

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-final-debug \
  CODE_SIGNING_ALLOWED=NO clean build
```

Result: exit `0`; configuration `Debug`; destination `generic/platform=iOS Simulator`; signing disabled; successful quiet invocation emitted no compiler warnings.

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-final-release \
  CODE_SIGNING_ALLOWED=NO clean build
```

Result: exit `0`; configuration `Release`; destination `generic/platform=iOS Simulator`; signing disabled; successful quiet invocation emitted no compiler warnings.

The initial sandboxed Debug attempt stopped before compilation with exit `74` because CoreSimulator access and DNS/package resolution were unavailable. The partial directory was removed; the unchanged Debug command was then run from a fresh directory with required access and reached the final exit `0`. The Release build likewise used a fresh directory.

Toolchain observed for both builds: Xcode `26.5` (`17F42`).

The following exact Release paths were verified as directories:

- `/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app`
- `/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/PlugIns/YPersonWidget.appex`
- `/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/PlugIns/YPersonNotificationService.appex`
- `/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/PlugIns/YPersonNotificationContent.appex`

The executable `/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/YPerson` was also verified as a file.

### Privacy, source, branch, and binary scans

```bash
rg -n 'exchangeCode|exchangeExpiresAt|privateFields|connection_private_fields|exchange_private_fields' \
  backend YPerson AppSpec.md AppPrivacy.yml Release deploy
```

Result: exit `0`. Expected contract references were present across backend schema/service/storage/tests, iOS models/coordinator/UI, deployment smoke code, and canonical product/privacy/release documentation.

```bash
! rg -n 'YP-1234|Date\(\)\.addingTimeInterval\(10 \* 60\)' YPerson
```

Result: exit `0`, no matches. The iOS source contains neither the banned static manual-code placeholder nor the banned device-clock ten-minute expiry expression.

```bash
git diff --check origin/main...HEAD
```

Result: exit `0`, no output.

```bash
YP_RELEASE_BINARY=/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/YPerson
! strings "$YP_RELEASE_BINARY" | rg 'person-alexey|\+7 900 555-10-20|bearer-sentinel|YP-0123-4567-89AB'
```

Result: exit `0`, no matches. None of the four exact sentinels was present in the Release executable.

## Device, live-service, and external PENDING

The following remain explicitly unverified and are not implied by any automated PASS above:

- Physical-device Face ID success/cancel/lockout and device-passcode fallback.
- Two-installation manual-code display, normalized entry, one-time claim, cancellation, and real expiry.
- Mutual Bluetooth exchange and directional private-phone isolation on two physical iPhones.
- App backgrounding, clipboard inspection, VoiceOver traversal/labels/announcements, Dynamic Type, iOS 15 behavior, APNs, widgets, and the wider permission matrix in `Release/manual-device-checks.md`.
- Live YDB schema application/query compilation, Object Storage/Lockbox/IAM configuration, Serverless Container deployment, API Gateway routing, external `/health`/`/config`/`/sync` smoke, monitoring, backup/restore, and production AppMetrica traffic.
- Apple signing identities, final bundle/App Group/provisioning/APNs configuration, signed archive creation/validation, archive privacy report, App Store Connect mutation, or upload.

Existing release blockers remain open, including production API and public support/privacy endpoints, Apple identity/signing, production AppMetrica and APNs configuration, moderation operations, owner-supplied review metadata, the physical-device matrix, third-party vCard conformance, recipient-specific private-audio persistence, and connection-level private-grant revoke/update/later-phone propagation.
