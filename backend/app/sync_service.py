"""Authenticated orchestration for the version 2 synchronization contract."""

from __future__ import annotations

import base64
import hmac
from collections.abc import Callable, Sequence
from datetime import UTC, datetime, timedelta
from hashlib import sha256

from .media_service import MediaInvalid, MediaService
from .schemas import PublicContactReply, SyncedPerson, SyncOperation, SyncRequest, SyncResponse
from .storage import StorageConflict, SyncSnapshot, SyncStore

EXCHANGE_TOKEN_LIFETIME = timedelta(minutes=10)


class SyncUnavailable(Exception):
    """A required private sync dependency is not available yet or is unhealthy."""


ExchangeTokenDeriver = Callable[[str, str, str], str]
ObjectCleanup = Callable[[Sequence[str]], None]


class SyncService:
    """Authenticate one installation and dispatch one durable sync operation."""

    def __init__(
        self,
        store: SyncStore,
        *,
        clock: Callable[[], datetime] | None = None,
        exchange_token_deriver: ExchangeTokenDeriver | None = None,
        object_cleanup: ObjectCleanup | None = None,
        media_service: MediaService | None = None,
    ) -> None:
        self._store = store
        self._clock = clock or (lambda: datetime.now(UTC))
        self._exchange_token_deriver = exchange_token_deriver or derive_exchange_token
        self._object_cleanup = object_cleanup or _fail_closed_object_cleanup
        self._media_service = media_service

    def handle(self, request: SyncRequest, bearer: str) -> SyncResponse:
        """Return a secret-free response for one authenticated request.

        Deletion replay is checked before normal bootstrap because a successful
        deletion intentionally removes the installation authentication row.
        """

        if request.operation is SyncOperation.delete_profile:
            replayed_keys = self._store.replay_deleted_profile(
                request.installationID,
                request.operationID,
                bearer,
            )
            if replayed_keys is not None:
                self._object_cleanup(replayed_keys)
                return _response("profile deleted")

        if request.operation in {SyncOperation.refresh, SyncOperation.publish_card}:
            self._store.authenticate_or_create(request.installationID, bearer)
        else:
            self._store.authenticate(request.installationID, bearer)

        match request.operation:
            case SyncOperation.refresh:
                return self._refresh(request)
            case SyncOperation.publish_card:
                return self._publish(request)
            case SyncOperation.prepare_exchange:
                return self._prepare_exchange(request, bearer)
            case SyncOperation.claim_exchange:
                return self._claim_exchange(request)
            case SyncOperation.cancel_exchange:
                return self._cancel_exchange(request)
            case SyncOperation.prepare_audio_upload:
                return self._prepare_audio_upload(request)
            case SyncOperation.update_push_token:
                return self._update_push(request)
            case SyncOperation.remove_push_token:
                return self._remove_push(request)
            case SyncOperation.report | SyncOperation.block:
                return self._moderate(request)
            case SyncOperation.activate_public_link:
                return self._activate_public_link(request)
            case SyncOperation.revoke_public_link:
                return self._revoke_public_link(request)
            case SyncOperation.dismiss_public_reply:
                return self._dismiss_public_reply(request)
            case SyncOperation.delete_profile:
                return self._delete(request, bearer)

    def _refresh(self, request: SyncRequest) -> SyncResponse:
        snapshot = self._store.refresh(request.installationID, request.cursor)
        people = self._people_with_audio(request.installationID, snapshot.people)
        return _snapshot_response(snapshot, people=people)

    def _publish(self, request: SyncRequest) -> SyncResponse:
        if request.card is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing card")
        if request.card.hasAudioGreeting and request.audioAssetID is None:
            raise StorageConflict("audio unavailable")
        if request.audioAssetID is not None and not request.card.hasAudioGreeting:
            raise StorageConflict("audio unavailable")
        if request.audioAssetID is not None:
            if self._media_service is None:
                raise SyncUnavailable
            try:
                self._media_service.finalize_upload(
                    request.installationID,
                    request.audioAssetID,
                )
            except MediaInvalid as error:
                raise StorageConflict("audio unavailable") from error
        if request.audioAssetID is not None and self._media_service is None:
            raise SyncUnavailable
        version = self._store.publish_card(
            request.installationID,
            request.operationID,
            request.card,
            request.audioAssetID,
        )
        return _response("card published", update_count=1, ownCardVersion=version)

    def _prepare_exchange(self, request: SyncRequest, bearer: str) -> SyncResponse:
        if request.card is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing card")
        card_operation_id = _sub_operation_id(request.operationID, "prepareExchange.card")
        version = self._store.publish_card(
            request.installationID,
            card_operation_id,
            request.card,
            None,
        )
        raw_token = self._exchange_token_deriver(
            bearer,
            request.installationID,
            request.operationID,
        )
        self._store.prepare_exchange(
            request.installationID,
            request.operationID,
            request.exchangeMethod or "manual",
            raw_token,
            self._clock() + EXCHANGE_TOKEN_LIFETIME,
        )
        return _response(
            "exchange prepared",
            update_count=1,
            ownCardVersion=version,
            exchangeToken=raw_token,
        )

    def _claim_exchange(self, request: SyncRequest) -> SyncResponse:
        if request.exchangeToken is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing exchange token")
        person = self._store.claim_exchange(
            request.installationID,
            request.operationID,
            request.exchangeToken,
        )
        person = self._person_with_audio(request.installationID, person)
        return _response("exchange claimed", update_count=1, people=[person])

    def _prepare_audio_upload(self, request: SyncRequest) -> SyncResponse:
        if request.audioSizeBytes is None or request.audioDurationMS is None:
            raise ValueError("missing audio metadata")
        if self._media_service is None:
            raise SyncUnavailable
        try:
            upload = self._media_service.prepare_upload(
                request.installationID,
                request.operationID,
                request.audioSizeBytes,
                request.audioDurationMS,
            )
        except MediaInvalid as error:
            raise StorageConflict("audio unavailable") from error
        return _response("audio upload prepared", audioUpload=upload)

    def _cancel_exchange(self, request: SyncRequest) -> SyncResponse:
        if request.exchangeToken is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing exchange token")
        self._store.cancel_exchange(
            request.installationID,
            request.operationID,
            request.exchangeToken,
        )
        return _response("exchange cancelled")

    def _update_push(self, request: SyncRequest) -> SyncResponse:
        if request.apnsToken is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing push token")
        self._store.save_push_token(
            request.installationID,
            request.operationID,
            request.apnsToken,
        )
        return _response(
            "push token updated",
            notificationConfiguration={"remoteNotifications": True},
        )

    def _remove_push(self, request: SyncRequest) -> SyncResponse:
        self._store.save_push_token(request.installationID, request.operationID, None)
        return _response(
            "push token removed",
            notificationConfiguration={"remoteNotifications": False},
        )

    def _moderate(self, request: SyncRequest) -> SyncResponse:
        if request.subjectInstallationID is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing moderation subject")
        self._store.record_moderation(
            request.installationID,
            request.operationID,
            request.subjectInstallationID,
            request.operation.value,
            request.moderationCategory,
        )
        return _response(f"{request.operation.value} recorded", update_count=1)

    def _activate_public_link(self, request: SyncRequest) -> SyncResponse:
        if request.card is None or request.publicLinkToken is None:
            raise ValueError("missing public link data")
        public_card = request.card.model_copy(
            update={
                "phone": "",
                "meetingPlace": None,
                "hasAudioGreeting": False,
            }
        )
        self._store.activate_public_link(
            request.installationID,
            request.operationID,
            request.publicLinkToken,
            public_card,
        )
        return self._refresh(request)

    def _revoke_public_link(self, request: SyncRequest) -> SyncResponse:
        self._store.revoke_public_link(request.installationID, request.operationID)
        return self._refresh(request)

    def _dismiss_public_reply(self, request: SyncRequest) -> SyncResponse:
        if request.publicReplyID is None:
            raise ValueError("missing public reply identifier")
        self._store.dismiss_public_reply(
            request.installationID,
            request.operationID,
            request.publicReplyID,
        )
        return self._refresh(request)

    def _delete(self, request: SyncRequest, bearer: str) -> SyncResponse:
        try:
            object_keys = self._store.delete_profile(request.installationID, request.operationID)
        except StorageConflict:
            replayed_keys = self._store.replay_deleted_profile(
                request.installationID,
                request.operationID,
                bearer,
            )
            if replayed_keys is None:
                raise
            object_keys = replayed_keys
        self._object_cleanup(object_keys)
        return _response("profile deleted")

    def _people_with_audio(
        self,
        requester_installation_id: str,
        people: Sequence[SyncedPerson],
    ) -> list[SyncedPerson]:
        return [self._person_with_audio(requester_installation_id, person) for person in people]

    def _person_with_audio(
        self,
        requester_installation_id: str,
        person: SyncedPerson,
    ) -> SyncedPerson:
        if self._media_service is None or not person.card.hasAudioGreeting:
            return person
        audio = self._media_service.download_for_owner(
            requester_installation_id,
            person.installationID,
        )
        return person.model_copy(update={"audio": audio})


def derive_exchange_token(bearer: str, installation_id: str, operation_id: str) -> str:
    """Derive the stable raw exchange token without storing it or the bearer.

    The domain-separated message is deliberately fixed and versioned. The
    YDB adapter stores only SHA-256 of the returned base64url token.
    """

    message = b"".join(
        _length_prefixed(component)
        for component in (
            b"yperson.exchange.v1",
            SyncOperation.prepare_exchange.value.encode("utf-8"),
            installation_id.encode("utf-8"),
            operation_id.encode("utf-8"),
        )
    )
    digest = hmac.new(bearer.encode("utf-8"), message, sha256).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def _length_prefixed(component: bytes) -> bytes:
    return len(component).to_bytes(4, "big") + component


def _sub_operation_id(operation_id: str, purpose: str) -> str:
    payload = f"yperson.operation.v1\0{purpose}\0{operation_id}".encode()
    return sha256(payload).hexdigest()


def _fail_closed_object_cleanup(object_keys: Sequence[str]) -> None:
    if object_keys:
        raise SyncUnavailable


def _snapshot_response(
    snapshot: SyncSnapshot,
    *,
    people: Sequence[SyncedPerson] | None = None,
) -> SyncResponse:
    update_count = len(snapshot.people) + len(snapshot.revoked_card_ids)
    replies = [
        PublicContactReply(
            id=item.id,
            name=item.name,
            email=item.email,
            phone=item.phone,
            createdAt=item.created_at,
        )
        for item in snapshot.public_replies
    ]
    return _response(
        "refreshed",
        update_count=update_count,
        nextCursor=snapshot.next_cursor,
        ownCardVersion=snapshot.own_card_version,
        people=list(snapshot.people if people is None else people),
        revokedCardIDs=list(snapshot.revoked_card_ids),
        publicLinkActive=snapshot.public_link_active,
        publicReplies=replies,
    )


def _response(message: str, *, update_count: int = 0, **fields: object) -> SyncResponse:
    return SyncResponse(
        accepted=True,
        serverVersion="2",
        updateCount=update_count,
        message=message,
        **fields,
    )
