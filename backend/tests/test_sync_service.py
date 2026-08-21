"""Authenticated sync workflows through the real service and HTTP boundary."""

from __future__ import annotations

import json
import logging
import re
from datetime import UTC, datetime
from hashlib import sha256
from hmac import compare_digest
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.observability import JsonRequestFormatter, request_logger
from app.schemas import PersonCard, PrivateCardFields, SyncedPerson
from app.settings import Settings
from app.storage import InvalidCredential, StorageConflict, StorageIntegrityError, SyncSnapshot
from app.sync_service import (
    SyncService,
    derive_exchange_code,
    derive_exchange_token,
    normalize_exchange_code,
)

NOW = datetime(2026, 8, 20, 12, 0, tzinfo=UTC)
OWNER = ("installation-owner-0001", "owner-bearer-secret-000000000000000000000000")
PEER = ("installation-peer-00002", "peer-bearer-secret-0000000000000000000000000")
OTHER = (
    "installation-other-0003",
    "other-bearer-secret-000000000000000000000000",
)


def card(card_id: str, name: str) -> PersonCard:
    return PersonCard(
        id=card_id,
        name=name,
        role="Engineer",
        company="YPerson",
        phone="",
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
        self.exchange_private_fields: dict[str, PrivateCardFields] = {}
        self.connection_private_fields: dict[tuple[str, str], PrivateCardFields] = {}
        self.operation_results: dict[tuple[str, str], dict[str, object]] = {}
        self.deleted: dict[tuple[str, str], tuple[bytes, list[str]]] = {}
        self.auth_calls: list[str] = []
        self.moderation: list[tuple[str, str, str, str | None]] = []
        self.object_keys: dict[str, list[str]] = {}

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
                card=self._card_for(installation_id, peer),
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
        )

    def prepare_exchange(
        self,
        installation_id: str,
        operation_id: str,
        method: str,
        public_card: PersonCard,
        private_fields: PrivateCardFields | None,
        raw_credential: str,
        expires_at: datetime,
    ) -> int:
        operation_key = (installation_id, operation_id)
        credential_hash = sha256(raw_credential.encode()).digest()
        result = self.operation_results.get(operation_key)
        if result is not None:
            if (
                result.get("operation") != "prepareExchange"
                or result.get("credential_hash") != credential_hash
            ):
                raise StorageConflict("operation identifier already used")
            version = result.get("card_version")
            if not isinstance(version, int):
                raise StorageIntegrityError
            return version

        previous = self.claims.get(raw_credential)
        if previous is not None and previous[0] != installation_id:
            raise StorageConflict("exchange unavailable")
        version = self.cards.get(installation_id, (0, public_card))[0] + 1
        self.cards[installation_id] = (version, public_card)
        self.claims[raw_credential] = (
            installation_id,
            expires_at,
            previous[2] if previous else None,
        )
        if private_fields is None:
            self.exchange_private_fields.pop(raw_credential, None)
        else:
            self.exchange_private_fields[raw_credential] = private_fields
        self.operation_results[operation_key] = {
            "operation": "prepareExchange",
            "credential_hash": credential_hash,
            "card_version": version,
            "method": method,
        }
        return version

    def claim_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> SyncedPerson:
        operation_key = (installation_id, operation_id)
        credential_hash = sha256(raw_token.encode()).digest()
        result = self.operation_results.get(operation_key)
        if result is not None:
            if (
                result.get("operation") != "claimExchange"
                or result.get("credential_hash") != credential_hash
            ):
                raise StorageConflict("operation identifier already used")
            issuer = result.get("issuer")
            if not isinstance(issuer, str) or issuer not in self.cards:
                raise StorageIntegrityError
            return SyncedPerson(
                installationID=issuer,
                card=self._card_for(installation_id, issuer),
                version=self.cards[issuer][0],
            )

        claim = self.claims.get(raw_token)
        if claim is None or claim[1] <= NOW or claim[2] is not None:
            raise StorageConflict("exchange unavailable")
        issuer = claim[0]
        if issuer == installation_id:
            raise StorageConflict("exchange unavailable")
        self.claims[raw_token] = (issuer, claim[1], installation_id)
        self.connections.update({(issuer, installation_id), (installation_id, issuer)})
        private_fields = self.exchange_private_fields.pop(raw_token, None)
        if private_fields is not None:
            self.connection_private_fields[(installation_id, issuer)] = private_fields
        self.operation_results[operation_key] = {
            "operation": "claimExchange",
            "credential_hash": credential_hash,
            "issuer": issuer,
        }
        version, _ = self.cards[issuer]
        return SyncedPerson(
            installationID=issuer,
            card=self._card_for(installation_id, issuer),
            version=version,
        )

    def cancel_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> None:
        operation_key = (installation_id, operation_id)
        credential_hash = sha256(raw_token.encode()).digest()
        result = self.operation_results.get(operation_key)
        if result is not None:
            if (
                result.get("operation") != "cancelExchange"
                or result.get("credential_hash") != credential_hash
            ):
                raise StorageConflict("operation identifier already used")
            return
        claim = self.claims.get(raw_token)
        if claim is None:
            raise StorageConflict("exchange unavailable")
        if claim[0] != installation_id or claim[1] <= NOW or claim[2] is not None:
            raise StorageConflict("exchange unavailable")
        self.claims.pop(raw_token)
        self.exchange_private_fields.pop(raw_token, None)
        self.operation_results[operation_key] = {
            "operation": "cancelExchange",
            "credential_hash": credential_hash,
        }

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
        self.connections = {
            connection for connection in self.connections if installation_id not in connection
        }
        self.connection_private_fields = {
            connection: private_fields
            for connection, private_fields in self.connection_private_fields.items()
            if installation_id not in connection
        }
        owned_credentials = {
            credential
            for credential, claim in self.claims.items()
            if claim[0] == installation_id or claim[2] == installation_id
        }
        for credential in owned_credentials:
            self.claims.pop(credential, None)
            self.exchange_private_fields.pop(credential, None)
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

    def _card_for(self, requester: str, peer: str) -> PersonCard:
        public_card = self.cards[peer][1]
        private_fields = self.connection_private_fields.get((requester, peer))
        if private_fields is None:
            return public_card
        return public_card.model_copy(update=private_fields.model_dump())


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


def test_qr_exchange_returns_only_token_and_claims_peer_card() -> None:
    store = MemoryStore()
    owner_card = PersonCard.model_validate(
        card("card-owner", "Owner").model_dump(mode="json") | {"templateID": "indigo-studio"}
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
            exchangeMethod="qr",
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
    assert prepared.json()["exchangeCode"] is None
    assert prepared.json()["exchangeExpiresAt"] == "2026-08-20T12:10:00Z"
    assert "=" not in prepared.json()["exchangeToken"]
    assert claimed.status_code == 200
    assert claimed.json()["people"][0]["card"]["id"] == "card-owner"
    assert claimed.json()["people"][0]["card"]["templateID"] == "indigo-studio"
    assert claimed.json()["people"][0]["installationID"] == OWNER[0]


def test_manual_private_phone_is_directional_and_survives_refresh() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-private")
        post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-private")
        post_sync(client, OTHER, "refresh", operation_id="other-bootstrap-private")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-private-code-1",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="manual",
            privateFields={"phone": "+70000000000"},
        )
        assert prepared.json()["exchangeToken"] is None
        assert prepared.json()["exchangeCode"].startswith("YP-")
        assert prepared.json()["exchangeExpiresAt"] == "2026-08-20T12:10:00Z"
        claimed = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-private-code-01",
            exchangeCode=prepared.json()["exchangeCode"],
        )
        assert claimed.json()["people"][0]["card"]["phone"] == "+70000000000"
        public_prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-public-code-01",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="manual",
        )
        post_sync(
            client,
            OTHER,
            "claimExchange",
            operation_id="claim-public-code-001",
            exchangeCode=public_prepared.json()["exchangeCode"],
        )
        refreshed_peer = post_sync(
            client,
            PEER,
            "refresh",
            operation_id="peer-refresh-private",
        )
        refreshed_other = post_sync(
            client,
            OTHER,
            "refresh",
            operation_id="other-refresh-public",
        )
        assert refreshed_peer.json()["people"][0]["card"]["phone"] == "+70000000000"
        assert refreshed_other.json()["people"][0]["installationID"] == OWNER[0]
        assert all(item["card"]["phone"] == "" for item in refreshed_other.json()["people"])


def test_prepare_replay_returns_stable_credential_expiry_and_card_version() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-replay")
        payload = {
            "card": card("card-owner", "Owner").model_dump(mode="json"),
            "exchangeMethod": "manual",
            "privateFields": {"phone": "+70000000000"},
        }
        first = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-replay-0001",
            **payload,
        )
        replay = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-replay-0001",
            **payload,
        )

    assert first.status_code == replay.status_code == 200
    assert first.json() == replay.json()
    assert first.json()["ownCardVersion"] == 1
    assert len(store.claims) == 1


def test_legacy_code_in_exchange_token_can_claim_manual_exchange() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-legacy")
        post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-legacy")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-legacy-code",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="manual",
        )
        claimed = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-legacy-code-01",
            exchangeToken=prepared.json()["exchangeCode"],
        )

    assert claimed.status_code == 200
    assert claimed.json()["people"][0]["installationID"] == OWNER[0]


def test_manual_exchange_code_accepts_tolerant_human_formatting() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-format")
        post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-format")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-format-code",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="manual",
        )
        formatted_code = prepared.json()["exchangeCode"].lower().replace("-", " ")
        claimed = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-format-code-01",
            exchangeCode=formatted_code,
        )

    assert claimed.status_code == 200
    assert claimed.json()["people"][0]["installationID"] == OWNER[0]


@pytest.mark.parametrize("operation", ["claimExchange", "cancelExchange"])
def test_invalid_manual_code_returns_sanitized_conflict(operation: str) -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-invalid")
        response = post_sync(
            client,
            OWNER,
            operation,
            operation_id=f"invalid-code-{operation}",
            exchangeCode="not-a-manual-code",
        )

    assert response.status_code == 409
    assert set(response.json()) == {"error", "requestID"}
    assert response.json()["error"] == "conflict"
    assert "manual" not in response.text


def test_exchange_can_only_be_claimed_once() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        for credentials, operation_id in (
            (OWNER, "owner-bootstrap-once"),
            (PEER, "peer-bootstrap-once"),
            (OTHER, "other-bootstrap-once"),
        ):
            post_sync(client, credentials, "refresh", operation_id=operation_id)
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-claim-once",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="qr",
        )
        token = prepared.json()["exchangeToken"]
        first = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-once-peer-01",
            exchangeToken=token,
        )
        second = post_sync(
            client,
            OTHER,
            "claimExchange",
            operation_id="claim-once-other-1",
            exchangeToken=token,
        )

    assert first.status_code == 200
    assert second.status_code == 409
    assert (OTHER[0], OWNER[0]) not in store.connections


def test_expired_exchange_cannot_be_claimed() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-expired")
        post_sync(client, PEER, "refresh", operation_id="peer-bootstrap-expired")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-expired-code",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="manual",
        )
        code = prepared.json()["exchangeCode"]
        issuer, _, claimant = store.claims[code]
        store.claims[code] = (issuer, NOW, claimant)
        claimed = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-expired-code-1",
            exchangeCode=code,
        )

    assert claimed.status_code == 409
    assert store.connections == set()


def test_owner_cannot_claim_own_exchange() -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-self")
        prepared = post_sync(
            client,
            OWNER,
            "prepareExchange",
            operation_id="prepare-self-code-1",
            card=card("card-owner", "Owner").model_dump(mode="json"),
            exchangeMethod="manual",
        )
        claimed = post_sync(
            client,
            OWNER,
            "claimExchange",
            operation_id="claim-self-code-001",
            exchangeCode=prepared.json()["exchangeCode"],
        )

    assert claimed.status_code == 409
    assert store.connections == set()


@pytest.mark.parametrize("operation", ["publishCard", "prepareExchange"])
@pytest.mark.parametrize(
    "private_public_field",
    [
        {"phone": "+70000000000"},
        {"meetingPlace": "Secret meeting place"},
    ],
)
def test_public_card_rejects_private_fields(
    operation: str,
    private_public_field: dict[str, str],
) -> None:
    store = MemoryStore()
    with make_client(store) as client:
        post_sync(client, OWNER, "refresh", operation_id="owner-bootstrap-public")
        public_card = card("card-owner", "Owner").model_dump(mode="json") | private_public_field
        response = post_sync(
            client,
            OWNER,
            operation,
            operation_id=f"reject-public-{operation}",
            card=public_card,
        )

    assert response.status_code == 409
    assert OWNER[0] not in store.cards


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
            exchangeMethod="manual",
            privateFields={"phone": "+70000000000"},
        )
        code = prepared.json()["exchangeCode"]
        first = post_sync(
            client,
            OWNER,
            "cancelExchange",
            operation_id="cancel-op-stable",
            exchangeCode=code.lower().replace("-", " "),
        )
        replay = post_sync(
            client,
            OWNER,
            "cancelExchange",
            operation_id="cancel-op-stable",
            exchangeCode=code,
        )
        claim = post_sync(
            client,
            PEER,
            "claimExchange",
            operation_id="claim-after-cancel",
            exchangeCode=code,
        )

    assert first.status_code == replay.status_code == 200
    assert first.json()["message"] == replay.json()["message"] == "exchange cancelled"
    assert claim.status_code == 409
    assert store.connections == set()
    assert store.exchange_private_fields == {}


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


def test_manual_code_is_deterministic_unambiguous_and_domain_separated() -> None:
    first = derive_exchange_code(OWNER[1], OWNER[0], "prepare-manual-0001")
    replay = derive_exchange_code(OWNER[1], OWNER[0], "prepare-manual-0001")
    other = derive_exchange_code(OWNER[1], OWNER[0], "prepare-manual-0002")

    assert first == replay
    assert first != other
    assert re.fullmatch(r"YP-[0-9A-HJKMNP-TV-Z]{4}(?:-[0-9A-HJKMNP-TV-Z]{4}){2}", first)


@pytest.mark.parametrize(
    ("value", "canonical"),
    [
        ("yp 0123 4567 89ab", "YP-0123-4567-89AB"),
        ("0123-4567-89AB", "YP-0123-4567-89AB"),
        ("YP-0123-4567-89AB", "YP-0123-4567-89AB"),
    ],
)
def test_manual_code_normalization(value: str, canonical: str) -> None:
    assert normalize_exchange_code(value) == canonical


@pytest.mark.parametrize(
    "value",
    [
        "YP-0123-4567-89A",
        "YP-0123-4567-89AI",
        "YP-0123-4567-89AL",
        "YP-0123-4567-89AO",
        "YP-0123-4567-89AU",
        "YP-0123-4567-89A!",
        "arbitrary-token-text",
    ],
)
def test_manual_code_normalization_rejects_invalid_values(value: str) -> None:
    with pytest.raises(ValueError):
        normalize_exchange_code(value)


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
