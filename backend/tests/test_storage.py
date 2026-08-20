"""Critical installation authentication and durable-card storage semantics."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from hmac import compare_digest
from typing import Any

import pytest
import ydb

from app.schemas import PersonCard, SyncResponse
from app.storage import (
    InstallationRecord,
    InvalidCredential,
    StorageConflict,
    StorageIntegrityError,
    SyncSnapshot,
    SyncStore,
)
from app.ydb_store import YDBSyncStore


class ResultSet:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows


class TransactionResult:
    def __init__(self, result_sets: list[ResultSet]) -> None:
        self._result_sets = result_sets

    def __enter__(self) -> list[ResultSet]:
        return self._result_sets

    def __exit__(self, *_: object) -> None:
        return None


class RecordingTransaction:
    def __init__(self, pool: RecordingPool) -> None:
        self._pool = pool

    def execute(
        self,
        query: str,
        parameters: dict[str, Any] | None = None,
    ) -> TransactionResult:
        parameters = parameters or {}
        self._pool.transaction_calls.append((query, parameters))
        if "active-installation-guard" in query:
            return TransactionResult([ResultSet([{"installation_id": "active"}]), ResultSet([])])
        operation_key = (
            _parameter(parameters, "$installation_id"),
            _parameter(parameters, "$operation_id"),
        )
        if "FROM operations" in query:
            operation = self._pool.operations.get(operation_key)
            rows = []
            if operation is not None:
                rows = [{"operation_type": operation[0], "result_json": operation[1]}]
            return TransactionResult([ResultSet(rows)])
        if "SELECT version FROM cards" in query:
            card = self._pool.cards.get(str(operation_key[0]))
            rows = [{"version": card[0]}] if card is not None else []
            return TransactionResult([ResultSet(rows)])
        if "UPSERT INTO cards" in query:
            installation_id = str(_parameter(parameters, "$installation_id"))
            self._pool.cards[installation_id] = (
                int(_parameter(parameters, "$version")),
                str(_parameter(parameters, "$card_json")),
            )
            self._pool.operations[operation_key] = (
                "publishCard",
                str(_parameter(parameters, "$result_json")),
            )
        if "FROM exchange_claims" in query:
            return TransactionResult([ResultSet([])])
        if "UPSERT INTO exchange_claims" in query:
            self._pool.exchange_token_hashes.append(_parameter(parameters, "$token_hash"))
            self._pool.operations[operation_key] = (
                "prepareExchange",
                str(_parameter(parameters, "$result_json")),
            )
        return TransactionResult([])


class RecordingPool:
    def __init__(self) -> None:
        self.installations: dict[str, bytes] = {}
        self.cards: dict[str, tuple[int, str]] = {}
        self.operations: dict[tuple[object, object], tuple[str, str]] = {}
        self.read_calls: list[tuple[str, dict[str, Any], ydb.RetrySettings]] = []
        self.transaction_calls: list[tuple[str, dict[str, Any]]] = []
        self.transaction_settings: list[tuple[object, ydb.RetrySettings]] = []
        self.exchange_token_hashes: list[object] = []

    def execute_with_retries(
        self,
        query: str,
        parameters: dict[str, Any],
        *,
        retry_settings: ydb.RetrySettings,
    ) -> list[ResultSet]:
        self.read_calls.append((query, parameters, retry_settings))
        installation_id = str(_parameter(parameters, "$installation_id"))
        if "UPSERT INTO installations" in query:
            candidate_hash = _parameter(parameters, "$credential_hash")
            self.installations.setdefault(installation_id, candidate_hash)
            return [ResultSet([{"credential_hash": self.installations[installation_id]}])]
        if "SELECT credential_hash" in query:
            stored = self.installations.get(installation_id)
            rows = [{"credential_hash": stored}] if stored is not None else []
            return [ResultSet(rows)]
        if "INNER JOIN cards" in query:
            stored = self.cards.get(installation_id)
            own_rows = []
            if stored is not None:
                own_rows = [{"version": stored[0], "card_json": stored[1]}]
            return [ResultSet(own_rows), ResultSet([]), ResultSet([])]
        raise AssertionError("unexpected read query")

    def retry_tx_sync(
        self,
        callee: Any,
        *,
        tx_mode: object,
        retry_settings: ydb.RetrySettings,
    ) -> Any:
        self.transaction_settings.append((tx_mode, retry_settings))
        return callee(RecordingTransaction(self))


class ScriptedTransaction:
    def __init__(self, pool: ScriptedPool) -> None:
        self._pool = pool

    def execute(
        self,
        query: str,
        parameters: dict[str, Any] | None = None,
    ) -> TransactionResult:
        parameters = parameters or {}
        self._pool.transaction_calls.append((query, parameters))
        if "active-installation-guard" in query:
            if self._pool.active:
                return TransactionResult(
                    [ResultSet([{"installation_id": "active"}]), ResultSet([])]
                )
            return TransactionResult(
                [ResultSet([]), ResultSet([{"operation_id": "op-delete-committed"}])]
            )
        return TransactionResult(self._pool.transaction_handler(query, parameters))


class ScriptedPool:
    def __init__(
        self,
        *,
        transaction_handler: Any,
        read_handler: Any = None,
        active: bool = True,
    ) -> None:
        self.transaction_handler = transaction_handler
        self.read_handler = read_handler or (lambda _query, _parameters: [])
        self.active = active
        self.transaction_calls: list[tuple[str, dict[str, Any]]] = []
        self.read_calls: list[tuple[str, dict[str, Any]]] = []

    def execute_with_retries(
        self,
        query: str,
        parameters: dict[str, Any],
        *,
        retry_settings: ydb.RetrySettings,
    ) -> list[ResultSet]:
        assert retry_settings.idempotent
        self.read_calls.append((query, parameters))
        return self.read_handler(query, parameters)

    def retry_tx_sync(
        self,
        callee: Any,
        *,
        tx_mode: object,
        retry_settings: ydb.RetrySettings,
    ) -> Any:
        assert retry_settings.idempotent
        assert getattr(tx_mode, "_name", None) == "serializable_read_write"
        return callee(ScriptedTransaction(self))


def _parameter(parameters: dict[str, Any], name: str) -> Any:
    return parameters.get(name, (None,))[0]


class DeterministicStore:
    """Small in-memory contract fixture; cloud behavior is owned by the adapter."""

    def __init__(self) -> None:
        self._installations: dict[str, InstallationRecord] = {}
        self._cards: dict[str, tuple[int, PersonCard]] = {}
        self._operations: dict[tuple[str, str], int] = {}

    def authenticate_or_create(self, installation_id: str, bearer: str) -> None:
        candidate_hash = sha256(bearer.encode()).digest()
        stored = self._installations.get(installation_id)
        if stored is None:
            self._installations[installation_id] = InstallationRecord(
                installation_id=installation_id,
                credential_hash=candidate_hash,
            )
            return
        if not compare_digest(stored.credential_hash, candidate_hash):
            raise InvalidCredential

    def authenticate(self, installation_id: str, bearer: str) -> None:
        candidate_hash = sha256(bearer.encode()).digest()
        stored = self._installations.get(installation_id)
        if stored is None or not compare_digest(stored.credential_hash, candidate_hash):
            raise InvalidCredential

    def publish_card(
        self,
        installation_id: str,
        operation_id: str,
        card: PersonCard,
        audio_asset_id: str | None,
    ) -> int:
        operation_key = (installation_id, operation_id)
        if operation_key in self._operations:
            return self._operations[operation_key]
        version = self._cards.get(installation_id, (0, card))[0] + 1
        self._cards[installation_id] = (version, card)
        self._operations[operation_key] = version
        return version

    def refresh(self, installation_id: str, cursor: str | None) -> SyncSnapshot:
        card = self._cards.get(installation_id)
        return SyncSnapshot(
            own_card=card[1] if card else None,
            own_card_version=card[0] if card else None,
        )

    def debug_installation(self, installation_id: str) -> InstallationRecord:
        return self._installations[installation_id]


@pytest.fixture
def store() -> SyncStore:
    return DeterministicStore()


@pytest.fixture
def card() -> PersonCard:
    return PersonCard(
        id="card-owner",
        name="Owner",
        role="Designer",
        company="YPerson",
        phone="+79990000000",
        email="owner@example.invalid",
        tagline="Hello",
        hasAudioGreeting=False,
        meetingPlace=None,
        isBlocked=False,
    )


def test_installation_secret_is_hashed_and_mismatch_is_rejected(
    store: SyncStore,
) -> None:
    store.authenticate_or_create("installation-123", "first-secret")
    stored = store.debug_installation("installation-123")  # type: ignore[attr-defined]
    assert stored.credential_hash == sha256(b"first-secret").digest()
    with pytest.raises(InvalidCredential):
        store.authenticate_or_create("installation-123", "wrong-secret")

    pool = RecordingPool()
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    adapter.authenticate_or_create("installation-123", "first-secret")
    credential_parameter = pool.read_calls[0][1]["$credential_hash"][0]
    assert credential_parameter == sha256(b"first-secret").digest()
    assert pool.read_calls[0][2].idempotent is True
    with pytest.raises(InvalidCredential):
        adapter.authenticate_or_create("installation-123", "wrong-secret")
    adapter.authenticate("installation-123", "first-secret")
    with pytest.raises(InvalidCredential):
        adapter.authenticate("installation-unknown", "first-secret")
    assert not any(
        "UPSERT INTO installations" in query
        for query, parameters, _ in pool.read_calls
        if _parameter(parameters, "$installation_id") == "installation-unknown"
    )
    assert "first-secret" not in repr(pool.read_calls)
    assert "wrong-secret" not in repr(pool.read_calls)


def test_published_card_survives_refresh(
    store: SyncStore,
    card: PersonCard,
) -> None:
    store.authenticate_or_create("installation-owner", "owner-secret")
    version = store.publish_card("installation-owner", "op-publish-1", card, None)
    retried_version = store.publish_card("installation-owner", "op-publish-1", card, None)
    snapshot = store.refresh("installation-owner", None)
    assert version == 1
    assert retried_version == version
    assert snapshot.own_card == card

    pool = RecordingPool()
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    adapter.authenticate_or_create("installation-owner", "owner-secret")
    ydb_version = adapter.publish_card("installation-owner", "op-publish-1", card, None)
    ydb_retry = adapter.publish_card("installation-owner", "op-publish-1", card, None)
    ydb_snapshot = adapter.refresh("installation-owner", None)
    adapter.prepare_exchange(
        "installation-owner",
        "op-exchange-1",
        "qr",
        "raw-exchange-token",
        datetime.now(UTC) + timedelta(minutes=10),
    )
    adapter.prepare_exchange(
        "installation-owner",
        "op-exchange-1",
        "qr",
        "raw-exchange-token",
        datetime.now(UTC) + timedelta(minutes=10),
    )

    assert ydb_version == 1
    assert ydb_retry == ydb_version
    assert ydb_snapshot.own_card == card
    assert pool.exchange_token_hashes == [sha256(b"raw-exchange-token").digest()]
    assert "raw-exchange-token" not in repr(pool.transaction_calls)
    assert all(settings.idempotent for _, settings in pool.transaction_settings)
    assert all(
        getattr(mode, "_name", None) == "serializable_read_write"
        for mode, _ in pool.transaction_settings
    )
    stored_json = json.loads(pool.cards["installation-owner"][1])
    assert "meetingPlace" not in stored_json


def test_delete_lost_response_replays_tombstone_without_recreating_installation(
    card: PersonCard,
) -> None:
    credential_hash = sha256(b"owner-secret").digest()

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT credential_hash" in query:
            return [ResultSet([{"credential_hash": credential_hash}])]
        if "SELECT object_key" in query:
            return [ResultSet([{"object_key": "private/audio.m4a"}])]
        if "SELECT card_id FROM cards" in query:
            return [ResultSet([{"card_id": card.id}])]
        if "SELECT owner_installation_id, peer_installation_id" in query:
            return [
                ResultSet(
                    [
                        {
                            "owner_installation_id": "installation-owner",
                            "peer_installation_id": "installation-peer",
                        }
                    ]
                )
            ]
        return []

    deletion_result = {
        "credentialHash": credential_hash.hex(),
        "objectKeys": ["private/audio.m4a"],
    }

    def read_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if 'operation_type = "revocation"' in query:
            return [
                ResultSet([]),
                ResultSet([]),
                ResultSet(
                    [
                        {
                            "operation_id": f"revocation:op-delete-1:{card.id}",
                            "result_json": json.dumps({"cardID": card.id}),
                        }
                    ]
                ),
            ]
        if 'operation_type = "deleteProfile"' in query and "result_json" in query:
            return [
                ResultSet(
                    [
                        {
                            "operation_type": "deleteProfile",
                            "result_json": json.dumps(deletion_result),
                        }
                    ]
                )
            ]
        return [ResultSet([])]

    pool = ScriptedPool(
        transaction_handler=transaction_handler,
        read_handler=read_handler,
    )
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    assert adapter.delete_profile("installation-owner", "op-delete-1") == ["private/audio.m4a"]
    peer_refresh = adapter.refresh("installation-peer", None)
    assert peer_refresh.people == ()
    assert peer_refresh.revoked_card_ids == (card.id,)
    assert adapter.replay_deleted_profile(
        "installation-owner",
        "op-delete-1",
        "owner-secret",
    ) == ["private/audio.m4a"]
    with pytest.raises(InvalidCredential):
        adapter.authenticate_or_create("installation-owner", "owner-secret")

    all_queries = "\n".join(query for query, _ in pool.transaction_calls + pool.read_calls)
    assert 'operation_type = "deleteProfile"' in all_queries
    deletion_parameters = next(
        parameters
        for query, parameters in pool.transaction_calls
        if "DELETE FROM installations" in query
    )
    stored_result = json.loads(_parameter(deletion_parameters, "$result_json"))
    assert stored_result == deletion_result
    assert any(
        _parameter(parameters, "$revoked_card_id") == card.id
        for _, parameters in pool.transaction_calls
        if "$revoked_card_id" in parameters
    )


def test_exchange_token_rejects_second_operation_even_for_same_recipient(
    card: PersonCard,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "FROM exchange_claims AS claim" in query:
            return [
                ResultSet(
                    [
                        {
                            "issuer_installation_id": "installation-owner",
                            "expires_at": datetime.now(UTC) + timedelta(minutes=5),
                            "claimed_by_installation_id": "installation-peer",
                            "version": 1,
                            "card_json": json.dumps(card.model_dump(mode="json")),
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    with pytest.raises(StorageConflict):
        adapter.claim_exchange(
            "installation-peer",
            "op-claim-new",
            "already-claimed-token",
        )
    assert not any("UPDATE exchange_claims" in query for query, _ in pool.transaction_calls)


def test_claim_replay_is_bound_to_the_original_exchange_token(card: PersonCard) -> None:
    previous_result = {
        "person": {"card": card.model_dump(mode="json"), "version": 1},
        "tokenHash": sha256(b"original-token").hexdigest(),
    }

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [
                ResultSet(
                    [
                        {
                            "operation_type": "claimExchange",
                            "result_json": json.dumps(previous_result),
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    with pytest.raises(StorageConflict):
        adapter.claim_exchange(
            "installation-peer",
            "op-claim-1",
            "different-token",
        )
    assert not any("FROM exchange_claims AS claim" in query for query, _ in pool.transaction_calls)


def test_malformed_persisted_claim_result_is_storage_integrity_failure(card: PersonCard) -> None:
    previous_result = {
        "person": {"card": card.model_dump(mode="json"), "version": 1},
        "tokenHash": "not-hex",
    }

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [
                ResultSet(
                    [
                        {
                            "operation_type": "claimExchange",
                            "result_json": json.dumps(previous_result),
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    with pytest.raises(StorageIntegrityError):
        adapter.claim_exchange("installation-peer", "op-claim-1", "original-token")


@pytest.mark.parametrize(
    "stored_digest",
    [
        "not-hex",
        sha256(b"raw-token").hexdigest().upper(),
        f" {sha256(b'raw-token').hexdigest()}",
    ],
)
def test_noncanonical_persisted_prepare_exchange_digest_is_storage_integrity_failure(
    stored_digest: str,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [
                ResultSet(
                    [
                        {
                            "operation_type": "prepareExchange",
                            "result_json": json.dumps({"tokenHash": stored_digest}),
                        }
                    ]
                )
            ]
        return []

    store = YDBSyncStore(ScriptedPool(transaction_handler=transaction_handler))  # type: ignore[arg-type]

    with pytest.raises(StorageIntegrityError):
        store.prepare_exchange(
            "installation-owner",
            "op-prepare-corrupt",
            "qr",
            "raw-token",
            datetime.now(UTC) + timedelta(minutes=5),
        )


@pytest.mark.parametrize(
    "corruption",
    ["credential", "object_key", "empty_object_key", "whitespace_object_key"],
)
def test_malformed_persisted_delete_state_is_storage_integrity_failure(
    corruption: str,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT credential_hash" in query:
            credential = "not-binary" if corruption == "credential" else sha256(b"secret").digest()
            return [ResultSet([{"credential_hash": credential}])]
        if "SELECT object_key" in query:
            object_key_by_corruption = {
                "object_key": None,
                "empty_object_key": "",
                "whitespace_object_key": "   ",
            }
            object_key = object_key_by_corruption.get(corruption, "private/audio.m4a")
            return [ResultSet([{"object_key": object_key}])]
        if "SELECT card_id FROM cards" in query:
            return [ResultSet([])]
        if "SELECT owner_installation_id, peer_installation_id" in query:
            return [ResultSet([])]
        return []

    store = YDBSyncStore(ScriptedPool(transaction_handler=transaction_handler))  # type: ignore[arg-type]

    with pytest.raises(StorageIntegrityError):
        store.delete_profile("installation-owner", "op-delete-corrupt")


@pytest.mark.parametrize(
    "stored_digest",
    [
        sha256(b"owner-secret").hexdigest().upper(),
        f"{sha256(b'owner-secret').hexdigest()} ",
    ],
)
def test_noncanonical_persisted_delete_digest_is_storage_integrity_failure(
    stored_digest: str,
) -> None:
    def read_handler(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        return [
            ResultSet(
                [
                    {
                        "operation_type": "deleteProfile",
                        "result_json": json.dumps(
                            {"credentialHash": stored_digest, "objectKeys": []}
                        ),
                    }
                ]
            )
        ]

    store = YDBSyncStore(  # type: ignore[arg-type]
        ScriptedPool(transaction_handler=lambda _query, _parameters: [], read_handler=read_handler)
    )

    with pytest.raises(StorageIntegrityError):
        store.replay_deleted_profile(
            "installation-owner",
            "op-delete-corrupt",
            "owner-secret",
        )


@pytest.mark.parametrize("invalid_object_key", ["", "   "])
def test_replayed_delete_rejects_empty_persisted_object_key(invalid_object_key: str) -> None:
    result = {
        "credentialHash": sha256(b"owner-secret").hexdigest(),
        "objectKeys": [invalid_object_key],
    }

    def read_handler(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        return [
            ResultSet(
                [
                    {
                        "operation_type": "deleteProfile",
                        "result_json": json.dumps(result),
                    }
                ]
            )
        ]

    store = YDBSyncStore(  # type: ignore[arg-type]
        ScriptedPool(transaction_handler=lambda _query, _parameters: [], read_handler=read_handler)
    )

    with pytest.raises(StorageIntegrityError):
        store.replay_deleted_profile(
            "installation-owner",
            "op-delete-corrupt",
            "owner-secret",
        )


@pytest.mark.parametrize("coerced_boolean", ["true", 1])
def test_persisted_card_uses_strict_boolean_validation(
    card: PersonCard,
    coerced_boolean: object,
) -> None:
    card_json = card.model_dump(mode="json")
    card_json["hasAudioGreeting"] = coerced_boolean

    def read_handler(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        return [
            ResultSet([{"version": 1, "card_json": json.dumps(card_json)}]),
            ResultSet([]),
            ResultSet([]),
        ]

    store = YDBSyncStore(  # type: ignore[arg-type]
        ScriptedPool(transaction_handler=lambda _query, _parameters: [], read_handler=read_handler)
    )

    with pytest.raises(StorageIntegrityError):
        store.refresh("installation-owner", None)


def test_replayed_claim_uses_strict_nested_card_validation(card: PersonCard) -> None:
    card_json = card.model_dump(mode="json")
    card_json["isBlocked"] = 0
    raw_token = "original-token"
    previous_result = {
        "person": {"card": card_json, "version": 1},
        "tokenHash": sha256(raw_token.encode()).hexdigest(),
    }

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [
                ResultSet(
                    [
                        {
                            "operation_type": "claimExchange",
                            "result_json": json.dumps(previous_result),
                        }
                    ]
                )
            ]
        return []

    store = YDBSyncStore(ScriptedPool(transaction_handler=transaction_handler))  # type: ignore[arg-type]

    with pytest.raises(StorageIntegrityError):
        store.claim_exchange("installation-peer", "op-claim-corrupt", raw_token)


def test_malformed_persisted_auth_and_card_are_storage_integrity_failures() -> None:
    def auth_read(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        return [ResultSet([{"credential_hash": "not-binary"}])]

    auth_store = YDBSyncStore(  # type: ignore[arg-type]
        ScriptedPool(transaction_handler=lambda _query, _parameters: [], read_handler=auth_read)
    )
    with pytest.raises(StorageIntegrityError):
        auth_store.authenticate("installation-owner", "owner-secret")

    def card_read(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        return [
            ResultSet([{"version": 1, "card_json": b"\xff"}]),
            ResultSet([]),
            ResultSet([]),
        ]

    card_store = YDBSyncStore(  # type: ignore[arg-type]
        ScriptedPool(transaction_handler=lambda _query, _parameters: [], read_handler=card_read)
    )
    with pytest.raises(StorageIntegrityError):
        card_store.refresh("installation-owner", None)


def test_committed_delete_blocks_delayed_publish_and_claim(card: PersonCard) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM installations" in query:
            return [
                ResultSet([]),
                ResultSet([{"operation_id": "op-delete-committed"}]),
            ]
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT version FROM cards" in query:
            return [ResultSet([])]
        if "FROM exchange_claims AS claim" in query:
            return [
                ResultSet(
                    [
                        {
                            "issuer_installation_id": "installation-owner",
                            "expires_at": datetime.now(UTC) + timedelta(minutes=5),
                            "claimed_by_installation_id": None,
                            "version": 1,
                            "card_json": json.dumps(card.model_dump(mode="json")),
                        }
                    ]
                )
            ]
        return []

    publish_pool = ScriptedPool(transaction_handler=transaction_handler, active=False)
    publish_store = YDBSyncStore(publish_pool)  # type: ignore[arg-type]
    with pytest.raises(StorageConflict):
        publish_store.publish_card(
            "installation-deleted",
            "op-publish-delayed",
            card,
            None,
        )
    assert not any("UPSERT INTO cards" in query for query, _ in publish_pool.transaction_calls)

    claim_pool = ScriptedPool(transaction_handler=transaction_handler, active=False)
    claim_store = YDBSyncStore(claim_pool)  # type: ignore[arg-type]
    with pytest.raises(StorageConflict):
        claim_store.claim_exchange(
            "installation-deleted",
            "op-claim-delayed",
            "valid-unclaimed-token",
        )
    assert not any("UPDATE exchange_claims" in query for query, _ in claim_pool.transaction_calls)


def test_every_other_mutation_uses_the_same_active_installation_guard() -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT token_hash FROM exchange_claims" in query:
            return [ResultSet([])]
        return []

    actions = (
        lambda store: store.prepare_exchange(
            "installation-deleted",
            "op-prepare-delayed",
            "qr",
            "raw-token",
            datetime.now(UTC) + timedelta(minutes=5),
        ),
        lambda store: store.save_push_token(
            "installation-deleted",
            "op-push-delayed",
            "apns-token",
        ),
        lambda store: store.record_moderation(
            "installation-deleted",
            "op-report-delayed",
            "installation-subject",
            "report",
            "other",
        ),
        lambda store: store.delete_profile(
            "installation-deleted",
            "op-delete-delayed",
        ),
    )
    for action in actions:
        pool = ScriptedPool(transaction_handler=transaction_handler, active=False)
        store = YDBSyncStore(pool)  # type: ignore[arg-type]
        with pytest.raises(StorageConflict):
            action(store)
        assert "active-installation-guard" in pool.transaction_calls[0][0]


def test_block_is_symmetric_and_refresh_returns_durable_revocations(
    card: PersonCard,
) -> None:
    peer_card = card.model_copy(update={"id": "card-peer", "name": "Peer"})

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT installation_id, card_id" in query:
            return [
                ResultSet(
                    [
                        {"installation_id": "installation-owner", "card_id": card.id},
                        {"installation_id": "installation-peer", "card_id": peer_card.id},
                    ]
                )
            ]
        return []

    def read_handler(_query: str, parameters: dict[str, Any]) -> list[ResultSet]:
        installation_id = _parameter(parameters, "$installation_id")
        revoked = peer_card.id if installation_id == "installation-owner" else card.id
        return [
            ResultSet([]),
            ResultSet([]),
            ResultSet(
                [
                    {
                        "operation_id": f"revoke-{revoked}",
                        "result_json": json.dumps({"cardID": revoked}),
                    }
                ]
            ),
        ]

    pool = ScriptedPool(
        transaction_handler=transaction_handler,
        read_handler=read_handler,
    )
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    adapter.record_moderation(
        "installation-owner",
        "op-block-1",
        "installation-peer",
        "block",
        None,
    )
    owner = adapter.refresh("installation-owner", None)
    peer = adapter.refresh("installation-peer", None)
    assert owner.people == ()
    assert peer.people == ()
    assert owner.revoked_card_ids == (peer_card.id,)
    assert peer.revoked_card_ids == (card.id,)
    owner_after_cursor = adapter.refresh("installation-owner", owner.next_cursor)
    assert owner_after_cursor.revoked_card_ids == ()
    assert owner_after_cursor.next_cursor == owner.next_cursor

    all_queries = "\n".join(query for query, _ in pool.transaction_calls + pool.read_calls)
    assert "reverse.status" in all_queries
    assert "($subject_id, $installation_id" in all_queries
    revocation_parameters = [
        parameters for _, parameters in pool.transaction_calls if "$revoked_card_id" in parameters
    ]
    assert {_parameter(params, "$revoked_card_id") for params in revocation_parameters} == {
        card.id,
        peer_card.id,
    }


def test_uuid_block_and_delete_emit_fixed_width_response_safe_revocation_cursors() -> None:
    owner_card_id = "123e4567-e89b-12d3-a456-426614174000"
    peer_card_id = "123e4567-e89b-12d3-a456-426614174001"
    operation_id = "123e4567-e89b-12d3-a456-426614174002"

    def block_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT installation_id, card_id" in query:
            return [
                ResultSet(
                    [
                        {"installation_id": "installation-owner", "card_id": owner_card_id},
                        {"installation_id": "installation-peer", "card_id": peer_card_id},
                    ]
                )
            ]
        return []

    block_pool: ScriptedPool

    def block_read(_query: str, parameters: dict[str, Any]) -> list[ResultSet]:
        installation_id = _parameter(parameters, "$installation_id")
        revoked = peer_card_id if installation_id == "installation-owner" else owner_card_id
        revocation_id = next(
            _parameter(call_parameters, "$operation_id")
            for _, call_parameters in block_pool.transaction_calls
            if _parameter(call_parameters, "$revoked_card_id") == revoked
        )
        return [
            ResultSet([]),
            ResultSet([]),
            ResultSet(
                [
                    {
                        "operation_id": revocation_id,
                        "result_json": json.dumps({"cardID": revoked}),
                    }
                ]
            ),
        ]

    block_pool = ScriptedPool(transaction_handler=block_handler, read_handler=block_read)
    block_store = YDBSyncStore(block_pool)  # type: ignore[arg-type]
    block_store.record_moderation(
        "installation-owner",
        operation_id,
        "installation-peer",
        "block",
        None,
    )
    block_snapshot = block_store.refresh("installation-owner", None)

    credential_hash = sha256(b"owner-secret").digest()

    def delete_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT credential_hash" in query:
            return [ResultSet([{"credential_hash": credential_hash}])]
        if "SELECT object_key" in query:
            return [ResultSet([])]
        if "SELECT card_id FROM cards" in query:
            return [ResultSet([{"card_id": owner_card_id}])]
        if "SELECT owner_installation_id, peer_installation_id" in query:
            return [
                ResultSet(
                    [
                        {
                            "owner_installation_id": "installation-owner",
                            "peer_installation_id": "installation-peer",
                        }
                    ]
                )
            ]
        return []

    delete_pool: ScriptedPool

    def delete_read(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        revocation_id = next(
            _parameter(call_parameters, "$operation_id")
            for _, call_parameters in delete_pool.transaction_calls
            if "$revoked_card_id" in call_parameters
        )
        return [
            ResultSet([]),
            ResultSet([]),
            ResultSet(
                [
                    {
                        "operation_id": revocation_id,
                        "result_json": json.dumps({"cardID": owner_card_id}),
                    }
                ]
            ),
        ]

    delete_pool = ScriptedPool(transaction_handler=delete_handler, read_handler=delete_read)
    delete_store = YDBSyncStore(delete_pool)  # type: ignore[arg-type]
    delete_store.delete_profile("installation-owner", operation_id)
    delete_snapshot = delete_store.refresh("installation-peer", None)

    for snapshot in (block_snapshot, delete_snapshot):
        assert snapshot.next_cursor is not None
        assert len(snapshot.next_cursor) == 64
        assert snapshot.next_cursor.startswith("rv1_")
        SyncResponse(
            accepted=True,
            serverVersion="2",
            updateCount=1,
            message="refreshed",
            nextCursor=snapshot.next_cursor,
        )


def test_schema_rejects_an_incompatible_existing_table() -> None:
    from app.ydb_schema import EXPECTED_TABLES, SchemaMismatch, apply_schema

    class SchemaPool:
        def execute_with_retries(
            self,
            _query: str,
            *,
            retry_settings: ydb.RetrySettings,
        ) -> None:
            assert retry_settings.idempotent

    class Description:
        def __init__(self, columns: list[ydb.Column], primary_key: list[str]) -> None:
            self.columns = columns
            self.primary_key = primary_key

    def describe_table(table_name: str) -> Description:
        table = EXPECTED_TABLES[table_name]
        columns = [ydb.Column(name, column_type) for name, column_type in table.columns]
        if table_name == "installations":
            columns = [
                ydb.Column(
                    column.name,
                    ydb.PrimitiveType.Utf8 if column.name == "credential_hash" else column.type,
                )
                for column in columns
            ]
        return Description(columns, list(table.primary_key))

    with pytest.raises(SchemaMismatch, match="schema version 1"):
        apply_schema(SchemaPool(), describe_table)  # type: ignore[arg-type]
