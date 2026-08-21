#!/bin/bash
set -euo pipefail

asset_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$asset_dir/../.." && pwd)"
verification_tmp="$(mktemp -d)"
cleanup() {
  verification_status=$?
  rm -r "$verification_tmp"
  exit "$verification_status"
}
trap cleanup EXIT

if [[ "${1:-}" == "--write" ]]; then
  node "$asset_dir/render-offline-public-qr.cjs"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--write]" >&2
  exit 64
fi

if [[ -z "${ZXING_CORE_JAR:-}" ]]; then
  echo "Set ZXING_CORE_JAR to a compatible local ZXing Core jar for fail-closed PNG decoding" >&2
  exit 65
fi
[[ -f "$ZXING_CORE_JAR" ]] || {
  echo "ZXING_CORE_JAR does not name a readable file" >&2
  exit 66
}

env \
  SWIFT_MODULECACHE_PATH="$verification_tmp/swift-module-cache" \
  CLANG_MODULE_CACHE_PATH="$verification_tmp/swift-module-cache" \
  swiftc \
    -DREVIEWER_ASSET_TOOL \
    "$repo_dir/YPerson/Domain/Models.swift" \
    "$asset_dir/generate-and-verify-offline-public-qr.swift" \
    -o "$verification_tmp/verify-offline-public-qr"

"$verification_tmp/verify-offline-public-qr"
java \
  -cp "$ZXING_CORE_JAR" \
  "$asset_dir/VerifyOfflinePublicQR.java" \
  "$asset_dir/test-qr.png" \
  "$asset_dir/offline-public-qr-payload.txt"
shasum -a 256 "$asset_dir/test-qr.png"
