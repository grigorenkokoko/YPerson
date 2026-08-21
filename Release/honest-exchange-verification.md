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

The reproducible harness now lives in the repository at `Verification/HonestExchangeContract/`. Version 4 compiles real Foundation production sources and covers public/private projection, manual-code normalization, typed credential exclusivity/routing, public QR, public-only Bluetooth policy, single-use manual consent, App Group persistence policy, crash-safe deletion-record survival, lifecycle transitions, transfer-generation invalidation, legacy sensitive-queue cleanup, and ordered async commit fences in UIKit/coordinator/media sources.

```bash
Verification/HonestExchangeContract/run.sh
```

The earlier Task 8 PASS below was produced by the historical `/tmp` harness and remains historical evidence. The broad parallel fix wave must rerun the repository command above as part of its final integrated gate; no new PASS result or aggregate count is added to this file by the contract-path update.

### Fresh unsigned simulator builds

The terminal history immediately before the accepted Debug build contains this exact preparation command:

```bash
rm -rf /tmp/yperson-honest-exchange-final-debug && \
  test ! -e /tmp/yperson-honest-exchange-final-debug && \
  test ! -e Config/PersonalDebug.xcconfig
```

Result: combined exit `0`; the Debug derived-data path and PersonalDebug placeholder were absent before the accepted build.

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-final-debug \
  CODE_SIGNING_ALLOWED=NO clean build
```

Result: exit `0`; configuration `Debug`; destination `generic/platform=iOS Simulator`; signing disabled; successful quiet invocation emitted no compiler warnings.

The terminal history immediately before the Release build contains this exact precondition command:

```bash
test ! -e /tmp/yperson-honest-exchange-final-release && \
  test ! -e Config/PersonalDebug.xcconfig && \
  test -d /tmp/yperson-honest-exchange-final-debug/Build/Products/Debug-iphonesimulator/YPerson.app
```

Result: combined exit `0`; the Release derived-data path and PersonalDebug placeholder were absent, while the accepted Debug app existed.

```bash
xcodebuild -quiet -project YPerson.xcodeproj -scheme YPerson -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/yperson-honest-exchange-final-release \
  CODE_SIGNING_ALLOWED=NO clean build
```

Result: exit `0`; configuration `Release`; destination `generic/platform=iOS Simulator`; signing disabled; successful quiet invocation emitted no compiler warnings.

The initial sandboxed Debug attempt stopped before compilation with exit `74` because CoreSimulator access and DNS/package resolution were unavailable. The partial directory was removed by the exact preparation command above; the unchanged Debug command was then run with required access and reached the final exit `0`. The Release command started after its exact non-existence precondition passed.

Toolchain observed for both builds: Xcode `26.5` (`17F42`).

The artifact checks were rerun individually:

```bash
YP_RELEASE_APP=/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app
YP_RELEASE_BINARY=/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/YPerson
test -d "$YP_RELEASE_APP"
test -d "$YP_RELEASE_APP/PlugIns/YPersonWidget.appex"
test -d "$YP_RELEASE_APP/PlugIns/YPersonNotificationService.appex"
test -d "$YP_RELEASE_APP/PlugIns/YPersonNotificationContent.appex"
test -f "$YP_RELEASE_BINARY"
```

Individual results:

- `YPerson.app` `test -d`: exit `0`.
- `YPersonWidget.appex` `test -d`: exit `0`.
- `YPersonNotificationService.appex` `test -d`: exit `0`.
- `YPersonNotificationContent.appex` `test -d`: exit `0`.
- `YPerson` executable `test -f`: exit `0`.

### Privacy, source, branch, and binary scans

Review RED used only harmless markers and non-existent `/tmp` paths:

Review-fix baseline: `8f41f9e4e6441f7af588d48ac3fde8d513b8cde1`.

```bash
! rg -n 'review-safe-marker' /tmp/yperson-review-nonexistent-source-dir
! strings /tmp/yperson-review-nonexistent-binary | rg 'review-safe-marker'
```

Both negated forms misleadingly returned status `0` even though `rg` and `strings` reported missing-path errors. The accepted scans below therefore do not use a negated command or negated pipeline.

The positive privacy scan first verified that every expected scope path existed and was readable: `backend`, `YPerson`, `AppSpec.md`, `AppPrivacy.yml`, `Release`, and `deploy` each produced `test -e` status `0` and `test -r` status `0`. Each required term was then searched separately over that exact scope:

```bash
rg -n -F 'exchangeCode' backend YPerson AppSpec.md AppPrivacy.yml Release deploy
rg -n -F 'exchangeExpiresAt' backend YPerson AppSpec.md AppPrivacy.yml Release deploy
rg -n -F 'privateFields' backend YPerson AppSpec.md AppPrivacy.yml Release deploy
rg -n -F 'connection_private_fields' backend YPerson AppSpec.md AppPrivacy.yml Release deploy
rg -n -F 'exchange_private_fields' backend YPerson AppSpec.md AppPrivacy.yml Release deploy
```

Final per-term results are recorded independently: `exchangeCode` exit `0`, `72` matches; `exchangeExpiresAt` exit `0`, `35` matches; `privateFields` exit `0`, `52` matches; `connection_private_fields` exit `0`, `20` matches; `exchange_private_fields` exit `0`, `27` matches. A zero-match status for any term fails this gate.

The banned source scan used a fail-closed status contract:

```bash
set -e
test -d YPerson
test -r YPerson
rg --files YPerson >/tmp/yperson-honest-exchange-source-scope-files.txt
set +e
rg -n 'YP-1234|Date\(\)\.addingTimeInterval\(10 \* 60\)' YPerson
BANNED_SOURCE_STATUS=$?
set -e
test "$BANNED_SOURCE_STATUS" -eq 1
```

Results: scope existence status `0`; scope readability status `0`; enumeration status `0` with `44` files; raw banned-pattern `rg` status exactly `1`; final gate exit `0`. Status `0` means a banned match and status greater than `1` means a scan error, so either fails the equality check.

```bash
git diff --check origin/main...HEAD
```

Result: exit `0`, no output.

The Release executable scan also used a fail-closed two-stage contract and an explicit safe `/tmp` output:

```bash
YP_RELEASE_BINARY=/tmp/yperson-honest-exchange-final-release/Build/Products/Release-iphonesimulator/YPerson.app/YPerson
YP_RELEASE_STRINGS=/tmp/yperson-honest-exchange-final-release-binary.strings
set -e
test -f "$YP_RELEASE_BINARY"
set +e
strings "$YP_RELEASE_BINARY" >"$YP_RELEASE_STRINGS"
STRINGS_STATUS=$?
set -e
test "$STRINGS_STATUS" -eq 0
test -f "$YP_RELEASE_STRINGS"
set +e
rg -n 'person-alexey|\+7 900 555-10-20|bearer-sentinel|YP-0123-4567-89AB' "$YP_RELEASE_STRINGS"
SENTINEL_RG_STATUS=$?
set -e
test "$SENTINEL_RG_STATUS" -eq 1
```

Results: Release executable `test -f` status `0`; `strings` status exactly `0`; safe strings-output `test -f` status `0`; raw sentinel `rg` status exactly `1`; final gate exit `0`. None of the four exact sentinels was present, while a missing/unreadable executable or failed `strings` extraction would fail before the no-match assertion.

## Device, live-service, and external PENDING

The following remain explicitly unverified and are not implied by any automated PASS above:

- Physical-device Face ID success/cancel/lockout and device-passcode fallback.
- Two-installation manual-code display, normalized entry, one-time claim, cancellation, and real expiry.
- Two-way public Bluetooth exchange with an independent local claim on each physical iPhone and no peer-confirmation signal; phone absence must be verified even when manual-code consent was authorized. Private Bluetooth remains deferred until recipient-bound mutual pairing exists.
- App backgrounding, clipboard inspection, VoiceOver traversal/labels/announcements, Dynamic Type, iOS 15 behavior, APNs, widgets, and the wider permission matrix in `Release/manual-device-checks.md`.
- Live YDB schema application/query compilation, Object Storage/Lockbox/IAM configuration, Serverless Container deployment, API Gateway routing, external `/health`/`/config`/`/sync` smoke, monitoring, backup/restore, and production AppMetrica traffic.
- Apple signing identities, final bundle/App Group/provisioning/APNs configuration, signed archive creation/validation, archive privacy report, App Store Connect mutation, or upload.

Existing release blockers remain open, including production API and public support/privacy endpoints, Apple identity/signing, production AppMetrica and APNs configuration, moderation operations, owner-supplied review metadata, the physical-device matrix, third-party vCard conformance, recipient-specific private-audio persistence, and connection-level private-grant revoke/update/later-phone propagation.
