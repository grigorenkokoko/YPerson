"""Authenticated orchestration for the version 2 synchronization contract."""

from __future__ import annotations

import base64
import hmac
from collections.abc import Callable, Sequence
from datetime import UTC, datetime, timedelta
from hashlib import sha256

from .schemas import SyncOperation, SyncRequest, SyncResponse
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
    ) -> None:
        self._store = store
        self._clock = clock or (lambda: datetime.now(UTC))
        self._exchange_token_deriver = exchange_token_deriver or derive_exchange_token
        self._object_cleanup = object_cleanup or _fail_closed_object_cleanup

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
            case SyncOperation.prepare_audio_upload:
                raise SyncUnavailable
            case SyncOperation.update_push_token:
                return self._update_push(request)
            case SyncOperation.remove_push_token:
                return self._remove_push(request)
            case SyncOperation.report | SyncOperation.block:
                return self._moderate(request)
            case SyncOperation.delete_profile:
                return self._delete(request, bearer)

    def _refresh(self, request: SyncRequest) -> SyncResponse:
        snapshot = self._store.refresh(request.installationID, request.cursor)
        return _snapshot_response(snapshot)

    def _publish(self, request: SyncRequest) -> SyncResponse:
        if request.card is None:  # Pydantic enforces this before dispatch.
            raise ValueError("missing card")
        if request.audioAssetID is not None:
            raise SyncUnavailable
        version = self._store.publish_card(
            request.installationID,
            request.operationID,
            request.card,
            None,
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
        return _response("exchange claimed", update_count=1, people=[person])

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


def _snapshot_response(snapshot: SyncSnapshot) -> SyncResponse:
    update_count = len(snapshot.people) + len(snapshot.revoked_card_ids)
    return _response(
        "refreshed",
        update_count=update_count,
        nextCursor=snapshot.next_cursor,
        ownCardVersion=snapshot.own_card_version,
        people=list(snapshot.people),
        revokedCardIDs=list(snapshot.revoked_card_ids),
    )


def _response(message: str, *, update_count: int = 0, **fields: object) -> SyncResponse:
    return SyncResponse(
        accepted=True,
        serverVersion="2",
        updateCount=update_count,
        message=message,
        **fields,
    )
