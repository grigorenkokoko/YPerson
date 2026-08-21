#!/usr/bin/env python3
"""Structural regression checks for deletion and async commit fences.

These checks intentionally bind an await to a later guard/commit. Moving a guard
above the await, or moving a mutation above its guard, must fail this harness.
"""

import ast
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def function_body(text: str, signature: str) -> str:
    start = text.find(signature)
    require(start >= 0, f"missing function: {signature}")
    opening = text.find("{", start)
    require(opening >= 0, f"missing function body: {signature}")
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


def function_bodies(text: str, signature: str) -> list[str]:
    bodies: list[str] = []
    cursor = 0
    while True:
        start = text.find(signature, cursor)
        if start < 0:
            return bodies
        bodies.append(function_body(text[start:], signature))
        cursor = start + len(signature)


def require_each_await_guarded(body: str, guards: tuple[str, ...], label: str) -> None:
    awaits: list[int] = []
    cursor = 0
    while True:
        position = body.find("await ", cursor)
        if position < 0:
            break
        awaits.append(position)
        cursor = position + len("await ")
    require(bool(awaits), f"{label}: expected at least one await")
    for index, position in enumerate(awaits):
        boundary = awaits[index + 1] if index + 1 < len(awaits) else len(body)
        guarded_region = body[position:boundary]
        require(
            any(guard in guarded_region for guard in guards),
            f"{label}: await #{index + 1} lacks a post-await lifecycle/epoch guard",
        )


def ordered(body: str, *needles: str) -> None:
    cursor = -1
    for needle in needles:
        position = body.find(needle, cursor + 1)
        require(position >= 0, f"missing ordered marker {needle!r}")
        require(position > cursor, f"marker out of order {needle!r}")
        cursor = position


def task_body(body: str, marker: str) -> str:
    return function_body(body, marker)


def require_originating_task_context(
    body: str,
    task_marker: str,
    generation_marker: str,
    coordinator_call: str,
    label: str,
    context_capture_marker: str = "captureProfileOperationContext()",
) -> None:
    ordered(
        body,
        context_capture_marker,
        task_marker,
    )
    task = task_body(body, task_marker)
    ordered(
        task,
        "guard !Task.isCancelled",
        generation_marker,
        "isCurrentProfileOperationContext(profileContext)",
        coordinator_call,
        "context: profileContext",
    )
    first_coordinator_access = task.find("syncCoordinator")
    entry_generation_guard = task.find(generation_marker)
    require(
        entry_generation_guard >= 0
        and first_coordinator_access >= 0
        and entry_generation_guard < first_coordinator_access,
        f"{label}: coordinator is accessed before the Task entry generation guard",
    )


script_tree = ast.parse(Path(__file__).read_text(encoding="utf-8"))
require(
    not any(isinstance(node, ast.Assert) for node in ast.walk(script_tree)),
    "Python assert statements make lifecycle checks disappear under optimization",
)


sync = source("YPerson/Networking/SyncCoordinator.swift")
bootstrap = function_body(sync, "func bootstrap(context:")
ordered(bootstrap, "profileLifecycle.state == .deleting", "await resumeDeletionIfNeeded()", "return")
require(
    "hasPendingDeletion" not in bootstrap,
    "bootstrap still infers acknowledgement from queue absence",
)
deletion = function_body(sync, "func deleteProfile(context:")
ordered(
    deletion,
    "persistDeletionRecord(record)",
    "profileOperationEpoch.invalidate()",
    "clearUserData()",
    "await prepareForProfileDeletion(",
    "isCurrentDeletion(record, epoch:",
    "await mediaTransfer.cancelAllProfileTransfersAndWait()",
    "await apiClient.sync(request)",
    "markDeletionServerAcknowledged",
    "finishDeletion",
)

finish = function_body(sync, "func finishDeletion(")
ordered(
    finish,
    "lifecycle.finishDeletion",
    "clearUserData()",
    "credentialStore.deleteCredential()",
    "profileTerminallyDeleted = true",
    "profileDeletionRecord = nil",
)

explicit = function_body(sync, "func explicitProfileClient()")
ordered(explicit, "guard !syncSuppressed", "credentialStore.createCredential()")
require(
    "profileLifecycle.suppressesSync" in sync,
    "sync suppression is not in-memory lifecycle based",
)

resume = function_body(sync, "func resumeDeletionIfNeeded()")
ordered(resume, "guard let record = deletionRecord", "record.serverAcknowledged", "finishDeletion")
ordered(
    resume,
    "await prepareForProfileDeletion(",
    "isCurrentDeletion(record, epoch:",
    "await mediaTransfer.cancelAllProfileTransfersAndWait()",
    "operationID: record.operationID",
    "await apiClient.sync(request)",
    "markDeletionServerAcknowledged",
    "finishDeletion",
)

bootstrap_active = bootstrap[bootstrap.find("guard let context"):]
require(bootstrap_active, "bootstrap active-profile branch is missing")
for label, body in [
    ("bootstrap", bootstrap_active),
    ("publish", function_body(sync, "func publish(")),
    ("submitModeration", function_body(sync, "func submitModeration(")),
    ("audioAsset", function_body(sync, "func audioAsset(")),
    ("updatePushToken", function_body(sync, "func updatePushToken(")),
    ("deleteProfile", deletion),
    ("retryPendingOperations", function_body(sync, "func retryPendingOperations(context:")),
    ("retryPushToken", function_body(sync, "func retryPushToken(context:")),
    ("resumeDeletionIfNeeded", resume),
]:
    require_each_await_guarded(
        body,
        (
            "requireCurrentProfileOperation",
            "isCurrentProfileOperation",
            "isCurrentDeletion",
            "profileOperationEpoch.isCurrent",
        ),
        label,
    )

prepare_bodies = function_bodies(sync, "func prepareExchange(")
require(len(prepare_bodies) == 2, "expected both prepareExchange overloads")
for index, body in enumerate(prepare_bodies):
    require_each_await_guarded(body, ("requireCurrentProfileOperation",), f"prepareExchange[{index}]")

claim_bodies = function_bodies(sync, "func claimExchange(")
require(len(claim_bodies) == 2, "expected both claimExchange overloads")
for index, body in enumerate(claim_bodies):
    require_each_await_guarded(body, ("requireCurrentProfileOperation",), f"claimExchange[{index}]")

for signature, awaited, guarded, committed in [
    ("func publish(", "await client.sync", "requireCurrentProfileOperation", "try apply"),
    ("func prepareExchange(\n", "await apiClient.sync", "requireCurrentProfileOperation", "return try PreparedExchange.resolve"),
    ("func claimExchange(\n", "await apiClient.sync", "requireCurrentProfileOperation", "try apply"),
    ("func submitModeration(", "await apiClient.sync", "requireCurrentProfileOperation", "removePendingOperation"),
    ("func audioAsset(", "await apiClient.sync", "requireCurrentProfileOperation", "try apply"),
]:
    body = function_body(sync, signature)
    ordered(body, awaited, guarded, committed)

media = source("YPerson/Networking/MediaTransferClient.swift")
upload = function_body(media, "func upload(")
ordered(upload, "profileTransferGeneration.capture()", "await", "requireCurrentProfileTransfer", "validate(response)")
download = function_body(media, "func download(")
ordered(download, "await", "requireCurrentDownload", "moveItem")
cached_audio = function_body(media, "func cachedAudio(")
ordered(cached_audio, "profileTransferGeneration.capture()", "audioCacheGeneration.capture()", "await refresh()", "requireCurrentDownload", "download(")
cancel_transfers = function_body(media, "func cancelAllProfileTransfersAndWait()")
ordered(cancel_transfers, "profileTransferGeneration.invalidate()", "audioCacheGeneration.invalidate()", ".cancel()", "await transfer.completion.value", "removeItem")
cache_only = function_body(media, "func removeAllCachedAudio()")
ordered(cache_only, "audioCacheGeneration.invalidate()", ".kind == .download", ".cancel()", "removeItem")
perform_upload = function_body(media, "func performUpload(")
ordered(perform_upload, "track(task, kind: .upload)", "await task.value")
perform_download = function_body(media, "func performDownload(")
ordered(perform_download, "track(task, kind: .download)", "await task.value")

person = source("YPerson/UI/PersonViewController.swift")
audio = function_body(person, "func playAudioGreeting()")
ordered(audio, "lifecycleGeneration", "await self.syncCoordinator.audioAsset", "guard self.isCurrentProfileLifecycle", "await self.mediaTransfer.cachedAudio")
ordered(audio, "await self.mediaTransfer.cachedAudio", "guard self.isCurrentProfileLifecycle", "self.audio.play")
place = function_body(person, "func saveMeetingPlace(")
ordered(place, "guard isCurrentProfileLifecycle", "snapshotStore?.upsertPerson")

card = source("YPerson/UI/CardViewController.swift")
save = function_body(card, "func editCard()")
ordered(save, "let isNew", "reactivateAndStoreUserCreatedCard", "self.card = updatedCard")

exchange = source("YPerson/UI/ExchangeViewController.swift")
manual_place = function_body(exchange, "func requestManualMeetingPlace(")
ordered(manual_place, "lifecycleGeneration == generation", "UIAlertController", "lifecycleGeneration == generation", "setPendingMeetingPlace")
for signature, minimum_generation_guards in (
    ("func toggleMeetingPlace(", 2),
    ("func requestManualMeetingPlace(", 3),
    ("func showNearbySearch(", 2),
    ("func confirmNearby(", 3),
    ("func confirmImportedCard(", 3),
    ("func presentPhotoFallback(", 3),
    ("func enterCode(", 2),
):
    body = function_body(exchange, signature)
    require(
        body.count("lifecycleGeneration == generation") >= minimum_generation_guards,
        f"{signature}: a stale alert action can mutate the recreated profile",
    )
photo_fallback = function_body(exchange, "func presentPhotoFallback(")
ordered(
    photo_fallback,
    "Изменить выбранные фото",
    "lifecycleGeneration == generation",
    "presentLimitedPhotoManager",
)
for signature in ("func startNearby()", "func scanPhotos()", "func enterCode()", "func showShortCode()"):
    body = function_body(exchange, signature)
    ordered(body, "syncCoordinator.isProfileActive", "lifecycleGeneration")

store = source("YPerson/Storage/AppGroupSnapshotStore.swift")
clear_user_data = function_body(store, "func clearUserData()")
require(
    "profileDeletionRecord" not in clear_user_data,
    "clearUserData removes the deletion record",
)

for signature in (
    "func publish(",
    "func prepareExchange(\n",
    "func claimExchange(\n",
    "func submitModeration(",
    "func audioAsset(",
    "func cancelExchange(\n",
):
    body = function_body(sync, signature)
    ordered(body, "isCurrentProfileOperationContext(context)", "await")
    require(
        "profileOperationEpoch.capture()" not in body,
        f"{signature}: recaptures a later profile epoch instead of using its originating context",
    )

for signature in ("func retryPendingOperations(context:", "func retryPushToken(context:"):
    body = function_body(sync, signature)
    ordered(body, "isCurrentProfileOperationContext(context)", "await")
    require(
        "profileOperationEpoch.capture()" not in body,
        f"{signature}: recaptures a later profile epoch instead of using its originating context",
    )

ordered(
    bootstrap_active,
    "await retryPendingOperations(context: context)",
    "isCurrentProfileOperationContext(context)",
    "await retryPushToken(context: context)",
)

publish = function_body(sync, "func publish(")
ordered(
    publish,
    "PublicationCardOwnership(card: publicationCard)",
    "snapshotStore?.enqueue",
    "publicationGate.acquire()",
    "publicationGate.release(",
    "await client.sync(request)",
    "isCurrentPublicationIntent(",
    "writePublishedOwnCard",
    "removePendingOperation(id: request.operationID)",
    "onOwnCardChanged",
)
require(
    publish.find("writePublishedOwnCard") > publish.find("await client.sync(request)"),
    "publication ownership is checked before, rather than after, the server response",
)
ordered(
    publish,
    "try await mediaTransfer.upload",
    "isCurrentPublicationIntent(",
    "await client.sync(request)",
)
require(
    publish.count("isCurrentPublicationIntent(") >= 3,
    "publication ownership is not rechecked at gate entry, immediately before send, and after response",
)
publication_intent = function_body(sync, "private func isCurrentPublicationIntent(")
ordered(
    publication_intent,
    "containsPendingOperation(id: operationID)",
    "ownership.matches(snapshotStore.readOwnCard())",
)
retry_publish = function_body(sync, "func retryPendingPublish(")
ordered(
    retry_publish,
    "publicationGate.acquire()",
    "revalidatePendingPublication(operation)",
    "await apiClient.sync(request)",
    "revalidatePendingPublication(operation)",
    "removePendingOperation(id: operation.id)",
)
retry_pending = function_body(sync, "func retryPendingOperations(context:")
ordered(retry_pending, "operation.request.operation == .publishCard", "retryPendingPublish(")

retry_push = function_body(sync, "func retryPushToken(context:")
ordered(
    retry_push,
    "capturePushTokenOwnership()",
    "pushTokenGate.acquire()",
    "isCurrentPushTokenOwnership(ownership)",
    "await apiClient.sync(request)",
    "isCurrentPushTokenOwnership(ownership)",
    "clearPendingOperationID",
)
ordered(
    function_body(sync, "func updatePushToken("),
    "await retryPushToken(context: context)",
    "isCurrentProfileOperationContext(context)",
)

card_source = source("YPerson/UI/CardViewController.swift")
require_originating_task_context(
    function_body(card_source, "func showQR()"),
    "prepareQRTask = Task",
    "lifecycleGeneration == profileGeneration",
    "prepareExchange(",
    "Card QR prepare",
)
require_originating_task_context(
    function_body(card_source, "func editCard()"),
    "publishTask = Task",
    "lifecycleGeneration == profileGeneration",
    "publish(",
    "Card publish",
)
card_deletion = function_body(card_source, "func applyProfileDeletion()")
ordered(card_deletion, "prepareQRTask?.cancel()", "publishTask?.cancel()")

exchange_source = source("YPerson/UI/ExchangeViewController.swift")
for signature, task_marker, coordinator_call, label, context_marker in (
    ("func startNearby()", "nearbyPrepareTask = Task", "prepareExchange(", "BLE prepare", "captureProfileOperationContext()"),
    ("func showShortCode()", "shortCodePrepareTask = Task", "prepareExchange(", "manual prepare", "captureProfileOperationContext()"),
    ("func claimNearby(", "claimTasks[taskID] = Task", "claimExchange(", "BLE claim", "let profileContext = ownedCredential.context"),
    ("func saveImportedCard(", "claimTasks[taskID] = Task", "claimExchange(", "QR cloud claim", "captureProfileOperationContext()"),
    ("func claimManualCode(", "claimTasks[taskID] = Task", "claimExchange(", "manual claim", "captureProfileOperationContext()"),
):
    require_originating_task_context(
        function_body(exchange_source, signature),
        task_marker,
        "lifecycleGeneration == generation",
        coordinator_call,
        label,
        context_marker,
    )
exchange_deletion = function_body(exchange_source, "func applyProfileDeletion()")
ordered(
    exchange_deletion,
    "nearbyPrepareTask?.cancel()",
    "shortCodePrepareTask?.cancel()",
    "claimTasks.values.forEach",
    "cancellationTasks.values.forEach",
    "scannerLaunchGate.reset()",
)

person_source = source("YPerson/UI/PersonViewController.swift")
require_originating_task_context(
    function_body(person_source, "func playAudioGreeting()"),
    "audioTask = Task",
    "isCurrentProfileLifecycle(generation)",
    "audioAsset(",
    "Person audio",
)
require_originating_task_context(
    function_body(person_source, "func submitSafety("),
    "moderationTasks[taskID] = Task",
    "isCurrentProfileLifecycle(generation)",
    "submitModeration(",
    "Person moderation",
)
person_deletion = function_body(person_source, "func beginProfileDeletion()")
ordered(
    person_deletion,
    "contactReconciliation.beginProfileDeletion()",
    "audioTask?.cancel()",
    "moderationTasks.values.forEach",
    "return invalidation",
)

privacy_source = source("YPerson/UI/PrivacyViewController.swift")
require_originating_task_context(
    function_body(privacy_source, "func performDeletion("),
    "deletionTask = Task",
    "lifecycleGeneration == generation",
    "deleteProfile(",
    "Profile deletion",
)
privacy_deletion = function_body(privacy_source, "func applyProfileDeletion()")
require("lifecycleGeneration = UUID()" in privacy_deletion, "Profile deletion does not invalidate its originating UI generation")
require(
    "deletionAttemptOwnership" not in privacy_deletion,
    "expected profile-deletion apply invalidates its own outcome ownership",
)
privacy_perform = function_body(privacy_source, "func performDeletion(")
ordered(
    privacy_perform,
    "deletionAttemptOwnership.begin()",
    "deletionTask = Task",
    "guard let self",
    "defer {",
    "guard !Task.isCancelled",
    "await syncCoordinator.deleteProfile",
    "deletionAttemptOwnership.acceptsOutcome",
    "showMessage",
)
require(
    "lifecycleGeneration == generation" not in privacy_perform[privacy_perform.find("await syncCoordinator.deleteProfile"):],
    "expected deletion apply still suppresses the deletion result",
)
privacy_reactivation = function_body(privacy_source, "func applyProfileReactivation()")
ordered(
    privacy_reactivation,
    "deletionAttemptOwnership.invalidateForProfileRecreation()",
    "deletionTask?.cancel()",
    "deletionTask = nil",
)

contacts = source("YPerson/UI/ContactReconciliationPresenter.swift")
contact_start = function_body(contacts, "func start(")
ordered(contact_start, "guard profileLifecycle.isActive", "sessionFence.begin()", "dismissOwnedUI()", "isCurrent(session)", "explainPermission")
contact_apply = function_body(contacts, "func apply(")
ordered(contact_apply, "isCurrent(session)", "permissions.apply(", "session: session", "sessionFence: sessionFence")
contact_invalidate = function_body(contacts, "func beginProfileDeletion()")
ordered(
    contact_invalidate,
    "sessionFence.beginInvalidation()",
    "profileLifecycle.beginDeletion()",
    "dismissOwnedUI()",
    "return invalidation",
)
contact_reactivation = function_body(contacts, "func applyProfileReactivation()")
ordered(contact_reactivation, "profileLifecycle.reactivateForUserCreation()")
require("waitForInFlightCommits" not in contact_invalidate, "Contacts presenter blocks while invalidating UI")
contract = source("YPerson/Domain/ExchangeContract.swift")
require("NSCondition" not in contract, "Contacts invalidation still uses a blocking condition wait")
for signature, minimum_guards in (
    ("func start(", 2),
    ("func continueAfterPermission(", 2),
    ("func handleRequestedState(", 1),
    ("func loadPlan(", 4),
    ("func chooseContact(", 2),
    ("func present(\n", 3),
    ("func apply(\n", 2),
    ("func offerPlanRefresh(", 2),
    ("func offerLimitedAccess(", 3),
    ("func offerReadUnavailableFallback(", 3),
    ("func presentSystemContactForm(", 2),
    ("func contactViewController(", 1),
    ("func presentLimitedAccessManager(", 4),
    ("func presentOwned(", 2),
):
    body = function_body(contacts, signature)
    require(
        body.count("isCurrent(session)") >= minimum_guards,
        f"{signature}: missing a session guard at a permission/plan/alert/form callback or action",
    )

permission_center = source("YPerson/Permissions/PermissionCenter.swift")
permission_apply = function_body(permission_center, "func apply(\n")
ordered(
    permission_apply,
    "sessionFence.performCommit(for: session)",
    "contactStore.execute(request)",
)
contact_commit = function_body(permission_apply, "sessionFence.performCommit(for: session)")
require(
    contact_commit.count("contactStore.execute(request)") == 1,
    "CNContactStore.execute is not enclosed exactly once by the session commit fence",
)

people_source = source("YPerson/UI/PeopleViewController.swift")
people_deletion = function_body(people_source, "func beginProfileDeletion()")
ordered(people_deletion, "contactReconciliation.beginProfileDeletion()", "lifecycleGeneration = UUID()", "return invalidation")
people_reactivation = function_body(people_source, "func applyProfileReactivation()")
ordered(people_reactivation, "lifecycleGeneration = UUID()", "contactReconciliation.applyProfileReactivation()")

app_factory = source("YPerson/App/AppFactory.swift")
require("bootstrapTask?.cancel()" not in app_factory, "deletion recovery can still cancel itself")
refresh_people = function_body(app_factory, "func refreshPeople()")
ordered(
    refresh_people,
    "captureProfileOperationContext()",
    "if let profileContext",
    "startActiveBootstrap",
    "needsDeletionRecovery",
    "startDeletionRecoveryBootstrap",
)
active_bootstrap = function_body(app_factory, "func startActiveBootstrap(")
ordered(active_bootstrap, "beginActive()", "cancelBootstrapTask", "Task", "bootstrap(context: profileContext)")
recovery_bootstrap = function_body(app_factory, "func startDeletionRecoveryBootstrap()")
ordered(recovery_bootstrap, "beginDeletionRecovery()", "Task", "bootstrap(context: nil)")
require("cancelBootstrapTask" not in recovery_bootstrap, "foreground recovery replaces/cancels the recovery owner")
deletion_preparation = function_body(app_factory, "syncCoordinator.onProfileDeletionPreparation =")
ordered(
    deletion_preparation,
    "people?.beginProfileDeletion()",
    "personControllers.map",
    "cancelActiveBootstrapTask()",
    "await invalidation.waitForInFlightCommits()",
)
require(
    deletion_preparation.find("personControllers.map") < deletion_preparation.find("await "),
    "AppFactory awaits before every Person Contacts session is invalidated",
)
reactivation = function_body(app_factory, "syncCoordinator.onProfileReactivated =")
ordered(
    reactivation,
    "people?.applyProfileReactivation()",
    "privacy?.applyProfileReactivation()",
)

print("honest-exchange-lifecycle-order-pass")
