#!/usr/bin/env python3
"""Structural regression checks for deletion and async commit fences.

These checks intentionally bind an await to a later guard/commit. Moving a guard
above the await, or moving a mutation above its guard, must fail this harness.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def function_body(text: str, signature: str) -> str:
    start = text.find(signature)
    assert start >= 0, f"missing function: {signature}"
    opening = text.find("{", start)
    assert opening >= 0, f"missing function body: {signature}"
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
    assert awaits, f"{label}: expected at least one await"
    for index, position in enumerate(awaits):
        boundary = awaits[index + 1] if index + 1 < len(awaits) else len(body)
        guarded_region = body[position:boundary]
        assert any(guard in guarded_region for guard in guards), (
            f"{label}: await #{index + 1} lacks a post-await lifecycle/epoch guard"
        )


def ordered(body: str, *needles: str) -> None:
    cursor = -1
    for needle in needles:
        position = body.find(needle, cursor + 1)
        assert position >= 0, f"missing ordered marker {needle!r}"
        assert position > cursor, f"marker out of order {needle!r}"
        cursor = position


sync = source("YPerson/Networking/SyncCoordinator.swift")
bootstrap = function_body(sync, "func bootstrap()")
ordered(bootstrap, "profileLifecycle.state == .deleting", "await resumeDeletionIfNeeded()", "return")
assert "hasPendingDeletion" not in bootstrap, "bootstrap still infers acknowledgement from queue absence"
deletion = function_body(sync, "func deleteProfile() async -> Bool")
ordered(
    deletion,
    "persistDeletionRecord(record)",
    "profileOperationEpoch.invalidate()",
    "clearUserData()",
    "onProfileDeleted?()",
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
assert "profileLifecycle.suppressesSync" in sync, "sync suppression is not in-memory lifecycle based"

resume = function_body(sync, "func resumeDeletionIfNeeded()")
ordered(resume, "guard let record = deletionRecord", "record.serverAcknowledged", "finishDeletion")
ordered(resume, "operationID: record.operationID", "await apiClient.sync(request)", "markDeletionServerAcknowledged", "finishDeletion")

for label, body in [
    ("bootstrap", bootstrap[bootstrap.find("guard !syncSuppressed"):]),
    ("publish", function_body(sync, "func publish(")),
    ("submitModeration", function_body(sync, "func submitModeration(")),
    ("audioAsset", function_body(sync, "func audioAsset(")),
    ("updatePushToken", function_body(sync, "func updatePushToken(")),
    ("deleteProfile", deletion),
    ("retryPendingOperations", function_body(sync, "func retryPendingOperations()")),
    ("retryPushToken", function_body(sync, "func retryPushToken()")),
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
assert len(prepare_bodies) == 2, "expected both prepareExchange overloads"
for index, body in enumerate(prepare_bodies):
    require_each_await_guarded(body, ("requireCurrentProfileOperation",), f"prepareExchange[{index}]")

claim_bodies = function_bodies(sync, "func claimExchange(")
assert len(claim_bodies) == 2, "expected both claimExchange overloads"
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
for signature in ("func startNearby()", "func scanPhotos()", "func enterCode()", "func showShortCode()"):
    body = function_body(exchange, signature)
    ordered(body, "syncCoordinator.isProfileActive", "lifecycleGeneration")

store = source("YPerson/Storage/AppGroupSnapshotStore.swift")
clear_user_data = function_body(store, "func clearUserData()")
assert "profileDeletionRecord" not in clear_user_data, "clearUserData removes the deletion record"

print("honest-exchange-lifecycle-order-pass")
