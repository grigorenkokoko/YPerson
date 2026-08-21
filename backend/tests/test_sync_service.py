"""Authenticated sync workflows through the real service and HTTP boundary."""

from __future__ import annotations

import json
import logging
from datetime import UTC, datetime
from hashlib import sha256
from hmac import compare_digest
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.observability import JsonRequestFormatter, request_logger
from app.schemas import PersonCard, SyncedPerson
from app.settings import Settings
from app.storage import (
    InvalidCredential,
    PublicContactReplyRecord,
    StorageConflict,
    StorageIntegrityError,
    SyncSnapshot,
)
from app.sync_service import SyncService, derive_exchange_token

NOW = datetime(2026, 8, 20, 12, 0, tzinfo=UTC)
OWNER = ("installation-owner-0001", "owner-bearer-secret-000000000000000000000000")
PEER = ("installation-peer-00002", "peer-bearer-secret-0000000000000000000000000")


def card(card_id: str, name: str) -> PersonCard:
    return PersonCard(
        id=card_id,
        name=name,
        role="Engineer",
        company="YPerson",
        phone="+70000000000",
        email=f"{card_id}@example.invalid",
        tagline="Hello",
        hasAudioGreeting=False,
        isBlocked=False,
    )


class MemoryStore:
    """Behavioral store double; YDB query semantics are tested by test_storage.py."""

    def __init__(self) -> None:
        self.installations: dict[str, bytes] = {}
        self.cards: dict[str, tuple[int, PersonCard]] = {}
        self.connections: set[tuple[str, str]] = set()
        self.push_tokens: dict[str, str] = {}
        self.claims: dict[str, tuple[str, datetime, str | None]] = {}
        self.deleted: dict[tuple[str, str], tuple[bytes, list[str]]] = {}
        self.auth_calls: list[str] = []
        self.moderation: list[tuple[str, str, str, str | None]] = []
        self.object_keys: dict[str, list[str]] = {}
        self.public_links: dict[str, tuple[str, PersonCard]] = {}
        self.public_replies: dict[str, dict[str, PublicContactReplyRecord]] = {}

    def authenticate_or_create(self, installation_id: str, bearer: str) -> None:
        self.auth_calls.append(installation_id)
        candidate = sha256(bearer.encode()).digest()
        stored = self.installations.setdefault(installation_id, candidate)
        if not compare_digest(stored, candidate):
            raise InvalidCredential

    def authenticate(self, installation_id: str, bearer: str) -> None:
        self.auth_calls.append(installation_id)
        candidate = sha256(bearer.encode()).digest()
        stored = self.installations.get(installation_id)
        if stored is None or not compare_digest(stored, candidate):
            raise InvalidCredential

    def publish_card(
        self,
        installation_id: str,
        operation_id: str,
        published_card: PersonCard,
        audio_asset_id: str | None,
    ) -> int:
        del operation_id, audio_asset_id
        version = self.cards.get(installation_id, (0, published_card))[0] + 1
        self.cards[installation_id] = (version, published_card)
        return version

    def refresh(self, installation_id: str, cursor: str | None) -> SyncSnapshot:
        people = tuple(
            SyncedPerson(
                installationID=peer,
                card=self.cards[peer][1],
                version=self.cards[peer][0],
            )
            for owner, peer in sorted(self.connections)
            if owner == installation_id and peer in self.cards
        )
        own = self.cards.get(installation_id)
        return SyncSnapshot(
            own_card=own[1] if own else None,
            own_card_version=own[0] if own else None,
            people=people,
            next_cursor=cursor,
            public_link_active=installation_id in self.public_links,
            public_replies=tuple(
                sorted(
                    self.public_replies.get(installation_id, {}).values(),
                    key=lambda reply: (reply.created_at, reply.id),
                )
            ),
        )

    def activate_public_link(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
        public_card: PersonCard,
    ) -> None:
        del operation_id
        self.public_links[installation_id] = (raw_token, public_card)

    def revoke_public_link(self, installation_id: str, operation_id: str) -> None:
        del operation_id
        self.public_links.pop(installation_id, None)

    def dismiss_public_reply(
        self,
        installation_id: str,
        operation_id: str,
        reply_id: str,
    ) -> None:
        del operation_id
        self.public_replies.get(installation_id, {}).pop(reply_id, None)

    def prepare_exchange(
        self,
        installation_id: str,
        operation_id: str,
        method: str,
        raw_token: str,
        expires_at: datetime,
    ) -> None:
        del operation_id, method
        previous = self.claims.get(raw_token)
        if previous is not None and previous[0] != installation_id:
            raise StorageConflict("exchange unavailable")
        self.claims[raw_token] = (installation_id, expires_at, previous[2] if previous else None)

    def claim_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> SyncedPerson:
        del operation_id
        claim = self.claims.get(raw_token)
        if claim is None or claim[1] <= NOW or claim[2] is not None:
            raise StorageConflict("exchange unavailable")
        issuer = claim[0]
        self.claims[raw_token] = (issuer, claim[1], installation_id)
        self.connections.update({(issuer, installation_id), (installation_id, issuer)})
        version, issuer_card = self.cards[issuer]
        return SyncedPerson(installationID=issuer, card=issuer_card, version=version)

    def cancel_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> None:
        del operation_id
        claim = self.claims.get(raw_token)
        if claim is None:
            return
        if claim[0] != installation_id or claim[2] is not None:
            raise StorageConflict("exchange unavailable")
        self.claims.pop(raw_token)

    def save_push_token(
        self,
        installation_id: str,
        operation_id: str,
        token: str | None,
    ) -> None:
        del operation_id
        if token is None:
            self.push_tokens.pop(installation_id, None)
        else:
            self.push_tokens[installation_id] = token

    def record_moderation(
        self,
        installation_id: str,
        operation_id: str,
        subject_id: str,
        action: str,
        category: str | None,
    ) -> None:
        del operation_id
        self.moderation.append((installation_id, subject_id, action, category))
        if action == "block":
            self.connections.discard((installation_id, subject_id))
            self.connections.discard((subject_id, installation_id))

    def delete_profile(self, installation_id: str, operation_id: str) -> list[str]:
        credential_hash = self.installations.pop(installation_id)
        object_keys = self.object_keys.pop(installation_id, [])
        self.cards.pop(installation_id, None)
        self.push_tokens.pop(installation_id, None)
        self.public_links.pop(installation_id, None)
        self.public_replies.pop(installation_id, None)
        self.connections = {
            connection for connection in self.connections if installation_id not in connection
        }
        self.deleted[(installation_id, operation_id)] = (credential_hash, object_keys)
        return object_keys

    def replay_deleted_profile(
        self,
        installation_id: str,
        operation_id: str,
        bearer: str,
    ) -> list[str] | None:
        deleted = self.deleted.get((installation_id, operation_id))
        if deleted is None:
            return None
        if not compare_digest(deleted[0], sha256(bearer.encode()).digest()):
            raise InvalidCredential
        return list(deleted[1])

    def snapshot(self, installation_id: str) -> SimpleNamespace | None:
        if installation_id not in self.installations:
            return None
        return SimpleNamespace(
            card=self.cards.get(installation_id),
            push_token=self.push_tokens.get(installation_id),
        )


def make_client(
    store: MemoryStore,
    *,
    cleaned: list[list[str]] | None = None,
) -> TestClient:
    cleanup_calls = cleaned if cleaned is not None else []
    service = SyncService(
        store,
        clock=lambda: NOW,
        object_cleanup=lambda keys: cleanup_calls.append(list(keys)),
    )
    return TestClient(create_app(Settings(_env_file=None), sync_service=service))


def post_sync(
    client: TestClient,
    credentials: tuple[str, str],
    operation: str,
    *,
    operation_id: str,
    **payload: object,
):
    installation_id, bearer = credentials
    return client.post(
        "/sync",
        headers={"Authorization": f"Bearer {bearer}"},
        json={
            "contractVersion": 2,
            "operationID": operation_id,
            "installationID": installation_id,
            "operation": operation,
            **payload,
        },
    )


def test_two_installations_claim_exchange_and_receive_peer_card() -> None:
    store = MemoryStore()
    owner_card = PersonCard.model_validate(
        card("card-owner", "Owner").model_dump(mode="json")
        | {"templateID": "indigo-studio"}
    )
    with make_client(store) as client:
        owner_bootstrap = post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-1")
        peer_bootstrap = post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-01")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-op-0001",
            card=owner_card.model_dump(mode="json"),
        )
        claimed = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-op-000001",
            exchangeToken=prepared.json()["exchangeToken"],
        )

    assert owner_bootstrap.status_code == peer_bootstrap.status_code == 200
    assert prepared.status_code == 200
    assert prepared.json()["exchangeToken"] == "eWQup1GlqgOm0k5ncRitNgHsikQEtrXKV9uM01_Y-W8"
    assert "=" not in prepared.json()["exchangeToken"]
    assert claimed.status_code == 200
    assert claimed.json()["people"][0]["card"]["id"] == "card-owner"
    assert claimed.json()["people"][0]["card"]["templateID"] == "indigo-studio"
    assert claimed.json()["people"][0]["installationID"] == OWNER[0]


def test_owner_can_cancel_prepared_exchange_idempotently_before_peer_claim() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-cancel")
        post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-cancel")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-op-cancel",
            card=card("card-owner", "Owner").model_dump(mode="json"),
        )
        token = prepared.json()["exchangeToken"]
        first = post_sync(
            client,
            OWNER,
            "cancelExchange",
            operation_id="cancel-op-stable",
            exchangeToken=token,
        )
        replay = post_sync(
            client,
            OWNER,
            "cancelExchange",
            operation_id="cancel-op-stable",
            exchangeToken=token,
        )
        claim = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-after-cancel",
            exchangeToken=token,
        )

    assert first.status_code == replay.status_code == 200
    assert first.json()["message"] == replay.json()["message"] == "exchange cancelled"
    assert claim.status_code == 409
    assert store.connections == set()


def test_exchange_token_derivation_length_prefixes_ambiguous_components() -> None:
    bearer = "high-entropy-bearer-secret-00000000000000000000"

    first = derive_exchange_token(
        bearer,
        "installation-left\0right",
        "operation-tail",
    )
    second = derive_exchange_token(
        bearer,
        "installation-left",
        "right\0operation-tail",
    )

    assert first != second


def test_wrong_bearer_returns_generic_401_without_installation_enumeration() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        first = post_sync(client, OWNER, "refresh", operation_id="refresh-op-0001")
        response = post_sync(
            client,
            (OWNER[0], "wrong-bearer-secret-00000000000000000000000"),
            "refresh",
            operation_id="refresh-op-0002",
        )

    assert first.status_code == 200
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"
    assert set(response.json()) == {"error", "requestID"}
    assert OWNER[0] not in response.text


def test_activate_public_link_stores_only_exchange_copy() -> None:
    store = MemoryStore()
    private_card = card("card-owner", "Owner").model_copy(
        update={"meetingPlace": "Private office", "hasAudioGreeting": True}
    )
    with make_client(store) as client:
        bootstrap = post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-link")
        response = post_sync(
            client,
            OWNER,
            "activatePublicLink",
            operation_id="activate-link-0001",
            card=private_card.model_dump(mode="json"),
            publicLinkToken="A" * 43,
        )

    assert bootstrap.status_code == response.status_code == 200
    assert response.json()["publicLinkActive"] is True
    stored_card = store.public_links[OWNER[0]][1]
    assert stored_card.phone == ""
    assert stored_card.meetingPlace is None
    assert stored_card.hasAudioGreeting is False


def test_revoke_public_link_is_idempotent_and_returns_inactive_snapshot() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-revoke")
        activated = post_sync(
            client,
            OWNER,
            "activatePublicLink",
            operation_id="activate-link-0002",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            publicLinkToken="A" * 43,
        )
        first = post_sync(
            client,
            OWNER,
            "revokePublicLink",
            operation_id="revoke-link-0001",
        )
        replay = post_sync(
            client,
            OWNER,
            "revokePublicLink",
            operation_id="revoke-link-0001",
        )

    assert activated.json()["publicLinkActive"] is True
    assert first.status_code == replay.status_code == 200
    assert first.json()["publicLinkActive"] is False
    assert replay.json()["publicLinkActive"] is False


def test_refresh_returns_ordered_pending_public_replies_without_contacts_in_message() -> None:
    store = MemoryStore()
    later = PublicContactReplyRecord(
        id="123e4567-e89b-12d3-a456-426614174002",
        name="Later Name Sentinel",
        email=None,
        phone="+79990000002",
        created_at=datetime(2026, 8, 20, 12, 2, tzinfo=UTC),
    )
    first_by_id = PublicContactReplyRecord(
        id="123e4567-e89b-12d3-a456-426614174000",
        name="First Name Sentinel",
        email="first-contact@example.invalid",
        phone=None,
        created_at=datetime(2026, 8, 20, 12, 1, tzinfo=UTC),
    )
    second_by_id = PublicContactReplyRecord(
        id="123e4567-e89b-12d3-a456-426614174001",
        name="Second Name Sentinel",
        email="second-contact@example.invalid",
        phone=None,
        created_at=first_by_id.created_at,
    )
    store.public_replies[OWNER[0]] = {
        later.id: later,
        second_by_id.id: second_by_id,
        first_by_id.id: first_by_id,
    }
    captured: list[str] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            captured.append(self.format(record))

    logger = request_logger()
    handler = Capture()
    handler.setFormatter(JsonRequestFormatter())
    logger.addHandler(handler)
    try:
        with make_client(store) as client:
            response = post_sync(
                client,
                OWNER,
                "refresh",
                operation_id="refresh-public-replies",
            )
    finally:
        logger.removeHandler(handler)

    assert response.status_code == 200
    body = response.json()
    assert [reply["id"] for reply in body["publicReplies"]] == [
        first_by_id.id,
        second_by_id.id,
        later.id,
    ]
    assert body["publicReplies"][0]["name"] == first_by_id.name
    assert body["publicReplies"][0]["email"] == first_by_id.email
    assert body["message"] == "refreshed"
    assert all(
        secret not in body["message"]
        for secret in (
            first_by_id.name,
            first_by_id.email,
            second_by_id.name,
            second_by_id.email,
            later.name,
            later.phone,
        )
    )
    output = "\n".join(captured)
    assert all(
        secret not in output
        for secret in (
            first_by_id.name,
            first_by_id.email,
            second_by_id.name,
            second_by_id.email,
            later.name,
            later.phone,
        )
    )


def test_dismiss_public_reply_returns_post_delete_snapshot_and_replays() -> None:
    store = MemoryStore()
    dismissed = PublicContactReplyRecord(
        id="123e4567-e89b-12d3-a456-426614174000",
        name="Dismissed",
        email="dismissed@example.invalid",
        phone=None,
        created_at=NOW,
    )
    remaining = PublicContactReplyRecord(
        id="123e4567-e89b-12d3-a456-426614174001",
        name="Remaining",
        email=None,
        phone="+79990000001",
        created_at=NOW,
    )
    store.public_replies[OWNER[0]] = {
        dismissed.id: dismissed,
        remaining.id: remaining,
    }
    with make_client(store) as client:
        bootstrap = post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-dismiss")
        first = post_sync(
            client,
            OWNER,
            "dismissPublicReply",
            operation_id="dismiss-reply-0001",
            publicReplyID=dismissed.id,
        )
        replay = post_sync(
            client,
            OWNER,
            "dismissPublicReply",
            operation_id="dismiss-reply-0001",
            publicReplyID=dismissed.id,
        )

    assert bootstrap.status_code == first.status_code == replay.status_code == 200
    expected_ids = [remaining.id]
    assert [reply["id"] for reply in first.json()["publicReplies"]] == expected_ids
    assert [reply["id"] for reply in replay.json()["publicReplies"]] == expected_ids


def test_delete_profile_replays_cleanup_without_recreating_installation() -> None:
    store = MemoryStore()
    cleaned: list[list[str]] = []
    store.object_keys[OWNER[0]] = ["private/object-key-sentinel"]
    with make_client(store, cleaned=cleaned) as client:
        post_sync(
            client,
            OWNER,
            "publishCard",
            operation_id="publish-op-0001",
            card=card("card-owner", "Owner").model_dump(mode="json"),
        )
        post_sync(
            client,
            OWNER,
            "updatePushToken",
            operation_id="push-op-0000001",
            apnsToken="apns-token-value",
        )
        store.public_links[OWNER[0]] = (
            "A" * 43,
            card("card-owner", "Owner").model_copy(update={"phone": ""}),
        )
        reply = PublicContactReplyRecord(
            id="123e4567-e89b-12d3-a456-426614174000",
            name="Pending",
            email="pending@example.invalid",
            phone=None,
            created_at=NOW,
        )
        store.public_replies[OWNER[0]] = {reply.id: reply}
        store.auth_calls.clear()
        first = post_sync(client, OWNER, "deleteProfile", operation_id="delete-op-0001")
        retried = post_sync(client, OWNER, "deleteProfile", operation_id="delete-op-0001")
        wrong = post_sync(
            client,
            (OWNER[0], "wrong-bearer-secret-00000000000000000000000"),
            "deleteProfile",
            operation_id="delete-op-0001",
        )

    assert first.status_code == retried.status_code == 200
    assert wrong.status_code == 401
    assert store.auth_calls == [OWNER[0]]
    assert store.snapshot(OWNER[0]) is None
    assert OWNER[0] not in store.public_links
    assert OWNER[0] not in store.public_replies
    assert cleaned == [
        ["private/object-key-sentinel"],
        ["private/object-key-sentinel"],
    ]


def test_delete_with_private_objects_fails_closed_without_cleanup_service() -> None:
    store = MemoryStore()
    store.object_keys[OWNER[0]] = ["private/object-key-sentinel"]
    service = SyncService(store, clock=lambda: NOW)
    with TestClient(create_app(Settings(_env_file=None), sync_service=service)) as client:
        bootstrap = post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-2")
        response = post_sync(client, OWNER, "deleteProfile", operation_id="delete-op-0002")
        retried = post_sync(client, OWNER, "deleteProfile", operation_id="delete-op-0002")

    assert bootstrap.status_code == 200
    assert response.status_code == retried.status_code == 503
    assert response.json()["error"] == "temporarily_unavailable"
    assert store.snapshot(OWNER[0]) is None


def test_card_refresh_push_and_moderation_operations_use_authenticated_store() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        published = post_sync(
            client,
            OWNER,
            "publishCard",
            operation_id="publish-op-0002",
            card=card("card-owner", "Owner").model_dump(mode="json"),
        )
        push = post_sync(
            client,
            OWNER,
            "updatePushToken",
            operation_id="push-op-0000002",
            apnsToken="apns-token-value",
        )
        report = post_sync(
            client,
            OWNER,
            "report",
            operation_id="report-op-00001",
            subjectInstallationID=PEER[0],
            moderationCategory="spam",
        )
        block = post_sync(
            client,
            OWNER,
            "block",
            operation_id="block-op-000001",
            subjectInstallationID=PEER[0],
        )
        removed = post_sync(
            client,
            OWNER,
            "removePushToken",
            operation_id="remove-op-00001",
        )
        refreshed = post_sync(client, OWNER, "refresh", operation_id="refresh-op-0003")

    assert published.json()["ownCardVersion"] == 1
    assert push.json()["notificationConfiguration"] == {"remoteNotifications": True}
    assert report.status_code == block.status_code == removed.status_code == 200
    assert store.push_tokens == {}
    assert store.moderation == [
        (OWNER[0], PEER[0], "report", "spam"),
        (OWNER[0], PEER[0], "block", None),
    ]
    assert refreshed.json()["ownCardVersion"] == 1


def test_audio_upload_preparation_fails_closed_until_media_service_is_injected() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        bootstrap = post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-3")
        response = post_sync(
            client,
            OWNER,
            "prepareAudioUpload",
            operation_id="audio-op-000001",
            audioSizeBytes=1024,
            audioDurationMS=1000,
        )

    assert bootstrap.status_code == 200
    assert response.status_code == 503
    assert response.json()["error"] == "temporarily_unavailable"


def test_unavailable_exchange_returns_sanitized_conflict() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        bootstrap = post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-02")
        response = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-op-unknown",
            exchangeToken="unknown-exchange-token",
        )

    assert bootstrap.status_code == 200
    assert response.status_code == 409
    assert set(response.json()) == {"error", "requestID"}
    assert response.json()["error"] == "conflict"
    assert "exchange" not in response.text


@pytest.mark.parametrize(
    "operation",
    [
        "prepareExchange",
        "claimExchange",
        "cancelExchange",
        "prepareAudioUpload",
        "updatePushToken",
        "removePushToken",
        "deleteProfile",
        "report",
        "block",
        "activatePublicLink",
        "revokePublicLink",
        "dismissPublicReply",
    ],
)
def test_unknown_non_bootstrap_operation_never_creates_installation(operation: str) -> None:
    store = MemoryStore()
    payload: dict[str, object] = {}
    if operation == "prepareExchange":
        payload["card"] = card("card-owner", "Owner").model_dump(mode="json")
    elif operation in {"claimExchange", "cancelExchange"}:
        payload["exchangeToken"] = "unknown-exchange-token"
    elif operation == "prepareAudioUpload":
        payload.update(audioSizeBytes=1024, audioDurationMS=1000)
    elif operation == "updatePushToken":
        payload["apnsToken"] = "apns-token"
    elif operation == "report":
        payload.update(subjectInstallationID=OWNER[0], moderationCategory="spam")
    elif operation == "block":
        payload["subjectInstallationID"] = OWNER[0]
    elif operation == "activatePublicLink":
        payload.update(
            card=card("card-owner", "Owner").model_dump(mode="json"),
            publicLinkToken="A" * 43,
        )
    elif operation == "dismissPublicReply":
        payload["publicReplyID"] = "123e4567-e89b-12d3-a456-426614174000"
    with make_client(store) as client:
        response = post_sync(
            client,
            PEER,
            operation,
            operation_id="unknown-operation-01",
            **payload,
        )

    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"
    assert store.snapshot(PEER[0]) is None


def test_storage_integrity_failure_returns_sanitized_503() -> None:
    class CorruptStore(MemoryStore):
        def authenticate_or_create(self, installation_id: str, bearer: str) -> None:
            del installation_id, bearer
            raise StorageIntegrityError

    with make_client(CorruptStore()) as client:
        response = post_sync(client, OWNER, "refresh", operation_id="corrupt-refresh-1")

    assert response.status_code == 503
    assert set(response.json()) == {"error", "requestID"}
    assert response.json()["error"] == "temporarily_unavailable"


def test_unexpected_sync_failure_logs_only_safe_diagnostic_classes() -> None:
    exception_secret = "exception-message-secret-sentinel"
    bearer_secret = "bearer-secret-sentinel-000000000000000000000000"
    installation_secret = "installation-secret-sentinel"

    class ExplodingSyncService:
        def handle(self, request, bearer):
            del request, bearer
            try:
                raise ValueError(exception_secret)
            except ValueError as error:
                raise RuntimeError(exception_secret) from error

    captured: list[str] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            captured.append(self.format(record))

    logger = request_logger()
    handler = Capture()
    handler.setFormatter(JsonRequestFormatter())
    logger.addHandler(handler)
    try:
        with TestClient(
            create_app(Settings(_env_file=None), sync_service=ExplodingSyncService())
        ) as client:
            response = client.post(
                "/sync",
                headers={"Authorization": f"Bearer {bearer_secret}"},
                json={
                    "contractVersion": 2,
                    "operationID": "diagnostic-operation-sentinel",
                    "installationID": installation_secret,
                    "operation": "refresh",
                },
            )
    finally:
        logger.removeHandler(handler)

    assert response.status_code == 503
    failures = [event for line in captured if (event := json.loads(line))["event"] == "sync_failed"]
    assert len(failures) == 1
    assert failures[0]["requestID"] == response.json()["requestID"]
    assert failures[0]["operation"] == "refresh"
    assert failures[0]["failureTypes"] == ["builtins.RuntimeError", "builtins.ValueError"]
    output = "\n".join(captured)
    assert exception_secret not in output
    assert bearer_secret not in output
    assert installation_secret not in output
    assert "diagnostic-operation-sentinel" not in output


def test_concurrent_duplicate_delete_replays_tombstone_after_conflict() -> None:
    class ConcurrentDeleteStore(MemoryStore):
        def delete_profile(self, installation_id: str, operation_id: str) -> list[str]:
            super().delete_profile(installation_id, operation_id)
            raise StorageConflict("installation unavailable")

    store = ConcurrentDeleteStore()
    cleaned: list[list[str]] = []
    store.object_keys[OWNER[0]] = ["private/object-key-sentinel"]
    with make_client(store, cleaned=cleaned) as client:
        bootstrap = post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-4")
        response = post_sync(client, OWNER, "deleteProfile", operation_id="delete-op-race-1")

    assert bootstrap.status_code == 200
    assert response.status_code == 200
    assert cleaned == [["private/object-key-sentinel"]]
    assert store.snapshot(OWNER[0]) is None


@pytest.mark.parametrize(
    "operation",
    [
        "refresh",
        "publishCard",
        "prepareExchange",
        "claimExchange",
        "prepareAudioUpload",
        "updatePushToken",
        "removePushToken",
        "deleteProfile",
        "report",
        "block",
        "activatePublicLink",
        "revokePublicLink",
        "dismissPublicReply",
    ],
)
def test_every_operation_requires_authentication_before_store_access(operation: str) -> None:
    store = MemoryStore()
    payload: dict[str, object] = {}
    if operation in {"publishCard", "prepareExchange"}:
        payload["card"] = card("card-owner", "Owner").model_dump(mode="json")
    elif operation == "claimExchange":
        payload["exchangeToken"] = "exchange-token"
    elif operation == "prepareAudioUpload":
        payload.update(audioSizeBytes=1024, audioDurationMS=1000)
    elif operation == "updatePushToken":
        payload["apnsToken"] = "apns-token"
    elif operation == "report":
        payload.update(subjectInstallationID=PEER[0], moderationCategory="spam")
    elif operation == "block":
        payload["subjectInstallationID"] = PEER[0]
    elif operation == "activatePublicLink":
        payload.update(
            card=card("card-owner", "Owner").model_dump(mode="json"),
            publicLinkToken="A" * 43,
        )
    elif operation == "dismissPublicReply":
        payload["publicReplyID"] = "123e4567-e89b-12d3-a456-426614174000"

    with make_client(store) as client:
        response = client.post(
            "/sync",
            json={
                "contractVersion": 2,
                "operationID": "missing-auth-01",
                "installationID": OWNER[0],
                "operation": operation,
                **payload,
            },
        )

    assert response.status_code == 401
    assert store.auth_calls == []
