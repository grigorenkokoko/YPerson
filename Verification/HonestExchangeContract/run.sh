#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yperson-honest-exchange-contract.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

cd "$REPO_ROOT"
xcrun swiftc \
    -module-cache-path "$BUILD_DIR/module-cache" \
    YPerson/Domain/Models.swift \
    YPerson/Domain/ExchangeContract.swift \
    YPerson/Experience/QRScannerLaunchGate.swift \
    YPerson/Storage/AppGroupSnapshotStore.swift \
    Verification/HonestExchangeContract/main.swift \
    -o "$BUILD_DIR/check"
"$BUILD_DIR/check"
"$SCRIPT_DIR/verify-source-contracts.sh"
python3 "$SCRIPT_DIR/verify-lifecycle-order.py"
