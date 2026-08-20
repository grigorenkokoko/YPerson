"""Critical installation authentication and durable-card storage semantics."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from hmac import compare_digest
from typing import Any

import pytest
import ydb

from app.schemas import PersonCard
from app.storage import InstallationRecord, InvalidCredential, SyncSnapshot, SyncStore
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
        if "INNER JOIN cards" in query:
            stored = self.cards.get(installation_id)
            own_rows = []
            if stored is not None:
                own_rows = [{"version": stored[0], "card_json": stored[1]}]
            return [ResultSet(own_rows), ResultSet([])]
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
