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

bootstrap_block=$(sed -n '/^    func bootstrap()/,/^    func publish(/p' YPerson/Networking/SyncCoordinator.swift)
publish_block=$(sed -n '/^    func publish(/,/^    func prepareExchange(/p' YPerson/Networking/SyncCoordinator.swift)
prepare_block=$(sed -n '/^    func prepareExchange($/,/^    func prepareExchange($/p' YPerson/Networking/SyncCoordinator.swift)
moderation_block=$(sed -n '/^    func submitModeration(/,/^    func audioAsset(/p' YPerson/Networking/SyncCoordinator.swift)
audio_block=$(sed -n '/^    func audioAsset(/,/^    func updatePushToken(/p' YPerson/Networking/SyncCoordinator.swift)
delete_block=$(sed -n '/^    func deleteProfile()/,/^    private func explicitProfileClient()/p' YPerson/Networking/SyncCoordinator.swift)
retry_block=$(sed -n '/^    private func retryPendingOperations()/,/^    private func retryPushToken()/p' YPerson/Networking/SyncCoordinator.swift)
retry_push_block=$(sed -n '/^    private func retryPushToken()/,/^    private func markExpired(/p' YPerson/Networking/SyncCoordinator.swift)
finish_block=$(sed -n '/^    private func finishDeletion(/,/^    }/p' YPerson/Networking/SyncCoordinator.swift)
explicit_client_block=$(sed -n '/^    private func explicitProfileClient()/,/^    private var syncSuppressed:/p' YPerson/Networking/SyncCoordinator.swift)

for block in "$bootstrap_block" "$publish_block" "$prepare_block" "$claim_block" "$moderation_block" "$audio_block" "$retry_block"
do
    test -n "$block"
    printf '%s\n' "$block" | rg -F -q 'profileOperationEpoch'
done

test -n "$retry_push_block"
printf '%s\n' "$retry_push_block" | rg -F -q 'profileOperationEpoch'
printf '%s\n' "$retry_push_block" | rg -F -q 'guard isCurrentProfileOperation(operationEpoch) else { return }'

printf '%s\n' "$publish_block" | rg -F -q 'try requireCurrentProfileOperation(operationEpoch)'
printf '%s\n' "$prepare_block" | rg -F -q 'try requireCurrentProfileOperation(operationEpoch)'
printf '%s\n' "$claim_block" | rg -F -q 'try requireCurrentProfileOperation(operationEpoch)'
printf '%s\n' "$moderation_block" | rg -F -q 'try requireCurrentProfileOperation(operationEpoch)'
printf '%s\n' "$audio_block" | rg -F -q 'try requireCurrentProfileOperation(operationEpoch)'

invalidate_line=$(printf '%s\n' "$delete_block" | rg -n -F 'profileOperationEpoch.invalidate()' | cut -d: -f1)
initial_clear_line=$(printf '%s\n' "$delete_block" | rg -n -F 'snapshotStore?.clearUserData()' | head -n 1 | cut -d: -f1)
test -n "$invalidate_line"
test -n "$initial_clear_line"
test "$invalidate_line" -lt "$initial_clear_line"

printf '%s\n' "$finish_block" | rg -F -q 'snapshotStore?.clearUserData()'
final_clear_line=$(printf '%s\n' "$finish_block" | rg -n -F 'snapshotStore?.clearUserData()' | cut -d: -f1)
credential_clear_line=$(printf '%s\n' "$finish_block" | rg -n -F 'credentialStore.deleteCredential()' | cut -d: -f1)
test -n "$final_clear_line"
test -n "$credential_clear_line"
test "$final_clear_line" -lt "$credential_clear_line"

printf '%s\n' "$explicit_client_block" | rg -F -q 'guard !syncSuppressed else'

require_fixed 'Публичная карточка и короткоживущий токен уже подготовлены на сервере' YPerson/UI/ExchangeViewController.swift
require_absent 'До подтверждения карточка и токен не отправляются на сервер.' YPerson/UI/ExchangeViewController.swift
require_fixed 'when search starts' AppPrivacy.yml
require_absent 'YPerson backend only after confirmation' AppPrivacy.yml
require_fixed 'публичная карточка и токен отправляются серверу уже при запуске поиска' Release/manual-device-checks.md
require_absent 'сервер получает токен только после подтверждения' Release/manual-device-checks.md
require_fixed 'recipient-bound mutual pairing before any private Bluetooth claim' AppSpec.md

printf '%s\n' 'honest-exchange-source-contracts-pass'
