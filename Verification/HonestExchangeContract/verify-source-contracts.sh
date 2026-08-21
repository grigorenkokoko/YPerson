#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd -P)
cd "$REPO_ROOT"

for path in \
    YPerson/UI/ExchangeViewController.swift \
    YPerson/UI/CardViewController.swift \
    YPerson/UI/CardEditorViewController.swift \
    YPerson/Permissions/PermissionCenter.swift \
    YPerson/Networking/SyncCoordinator.swift
do
    test -f "$path"
    test -r "$path"
done

require_fixed() {
    rg -F -q -- "$1" "$2"
}

require_absent() {
    set +e
    rg -F -q -- "$1" "$2"
    status=$?
    set -e
    test "$status" -eq 1
}

nearby_block=$(sed -n '/@objc private func startNearby()/,/private func handleNearbyState/p' YPerson/UI/ExchangeViewController.swift)
test -n "$nearby_block"
printf '%s\n' "$nearby_block" | rg -F -q 'privateFields: nil'
set +e
printf '%s\n' "$nearby_block" | rg -F -q 'privateFields: privateSelection.fields'
nearby_private_status=$?
set -e
test "$nearby_private_status" -eq 1

require_fixed 'Поделиться телефоном по коду · Face ID' YPerson/UI/ExchangeViewController.swift
require_fixed 'QR и Bluetooth остаются публичными.' YPerson/UI/ExchangeViewController.swift
require_fixed 'guard shortCodePrepareTask == nil else { return }' YPerson/UI/ExchangeViewController.swift
require_fixed 'privatePhoneConsent.consume(' YPerson/UI/ExchangeViewController.swift
require_fixed 'forPreparationMethod: "manual"' YPerson/UI/ExchangeViewController.swift
require_fixed '.transmitPrivatePhoneByShortCode' YPerson/UI/ExchangeViewController.swift
require_fixed '.revealPrivateFields' YPerson/UI/CardViewController.swift
require_fixed '.revealPrivateFields' YPerson/UI/CardEditorViewController.swift
require_fixed 'Подтвердить передачу телефона по короткому коду' YPerson/Permissions/PermissionCenter.swift

claim_block=$(sed -n '/^    func claimExchange($/,/^    func claimExchange($/p' YPerson/Networking/SyncCoordinator.swift)
test -n "$claim_block"
set +e
printf '%s\n' "$claim_block" | rg -F -q 'snapshotStore?.enqueue'
claim_enqueue_status=$?
set -e
test "$claim_enqueue_status" -eq 1

cancel_block=$(sed -n '/func cancelExchange(credential:/,/func cancelExchange(token:/p' YPerson/Networking/SyncCoordinator.swift)
test -n "$cancel_block"
set +e
printf '%s\n' "$cancel_block" | rg -F -q 'snapshotStore?.enqueue'
cancel_enqueue_status=$?
set -e
test "$cancel_enqueue_status" -eq 1

require_fixed 'PendingSyncOperationPersistencePolicy.allowsDurablePersistence' YPerson/Networking/SyncCoordinator.swift
require_absent 'snapshotStore?.enqueue(pending)' YPerson/Networking/SyncCoordinator.swift

require_fixed 'Публичная карточка и короткоживущий токен уже подготовлены на сервере' YPerson/UI/ExchangeViewController.swift
require_fixed 'сигнала о его подтверждении нет' YPerson/UI/ExchangeViewController.swift
require_absent 'До подтверждения карточка и токен не отправляются на сервер.' YPerson/UI/ExchangeViewController.swift
require_absent 'Подтвердите обмен на обоих iPhone' YPerson/UI/ExchangeViewController.swift
require_fixed 'when search starts' AppPrivacy.yml
require_fixed 'no peer-confirmation signal' AppPrivacy.yml
require_absent 'YPerson backend only after confirmation' AppPrivacy.yml
require_fixed 'backend preparation публичной карточки и токена начинается до discovery' Release/manual-device-checks.md
require_absent 'сервер получает токен только после подтверждения' Release/manual-device-checks.md
require_fixed 'There is no peer-confirmation signal' Release/reviewer-assets/README.md
require_fixed 'recipient-bound mutual pairing before any private Bluetooth claim' AppSpec.md

printf '%s\n' 'honest-exchange-source-contracts-pass'
