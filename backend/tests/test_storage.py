"""Critical installation authentication and durable-card storage semantics."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from hmac import compare_digest
from typing import Any

import pytest
import ydb

from app.schemas import PersonCard, PrivateCardFields, SyncResponse
from app.storage import (
    InstallationRecord,
    InvalidCredential,
    PreparedExchangeResult,
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
        if "authentication-bootstrap" in query:
            installation_id = str(_parameter(parameters, "$installation_id"))
            stored = self._pool.installations.get(installation_id)
            installation_rows = [{"credential_hash": stored}] if stored is not None else []
            return TransactionResult([ResultSet(installation_rows), ResultSet([])])
        if "UPSERT INTO installations" in query:
            installation_id = str(_parameter(parameters, "$installation_id"))
            candidate_hash = _parameter(parameters, "$credential_hash")
            self._pool.installations.setdefault(installation_id, candidate_hash)
            return TransactionResult([])
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
    assert pool.transaction_settings
    assert all(settings.idempotent for _, settings in pool.transaction_settings)
    assert all(
        getattr(mode, "_name", None) == "serializable_read_write"
        for mode, _ in pool.transaction_settings
    )
    credential_parameter = next(
        parameters["$credential_hash"][0]
        for query, parameters in pool.transaction_calls
        if "UPSERT INTO installations" in query
    )
    assert credential_parameter == sha256(b"first-secret").digest()
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
    assert "first-secret" not in repr(pool.transaction_calls)
    assert "wrong-secret" not in repr(pool.transaction_calls)


def test_published_card_survives_refresh(
    store: SyncStore,
    card: PersonCard,
) -> None:
    store.authenticate_or_create("installation-owner", "owner-secret")
    styled_card = PersonCard.model_validate(
        card.model_dump(mode="json") | {"templateID": "mint-conference"}
    )
    public_card = styled_card.model_copy(update={"phone": ""})
    private_fields = PrivateCardFields(phone=styled_card.phone)
    version = store.publish_card("installation-owner", "op-publish-1", styled_card, None)
    retried_version = store.publish_card("installation-owner", "op-publish-1", styled_card, None)
    snapshot = store.refresh("installation-owner", None)
    assert version == 1
    assert retried_version == version
    assert snapshot.own_card == styled_card

    pool = RecordingPool()
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]
    adapter.authenticate_or_create("installation-owner", "owner-secret")
    ydb_version = adapter.publish_card("installation-owner", "op-publish-1", styled_card, None)
    ydb_retry = adapter.publish_card("installation-owner", "op-publish-1", styled_card, None)
    ydb_snapshot = adapter.refresh("installation-owner", None)
    adapter.prepare_exchange(
        "installation-owner",
        "op-exchange-1",
        "bluetooth",
        public_card,
        private_fields,
        "raw-exchange-token",
        datetime.now(UTC) + timedelta(minutes=10),
    )
    adapter.prepare_exchange(
        "installation-owner",
        "op-exchange-1",
        "bluetooth",
        public_card,
        private_fields,
        "raw-exchange-token",
        datetime.now(UTC) + timedelta(minutes=10),
    )

    assert ydb_version == 1
    assert ydb_retry == ydb_version
    assert ydb_snapshot.own_card == public_card
    assert pool.exchange_token_hashes == [sha256(b"raw-exchange-token").digest()]
    assert "raw-exchange-token" not in repr(pool.transaction_calls)
    assert all(settings.idempotent for _, settings in pool.transaction_settings)
    assert all(
        getattr(mode, "_name", None) == "serializable_read_write"
        for mode, _ in pool.transaction_settings
    )
    stored_json = json.loads(pool.cards["installation-owner"][1])
    assert stored_json["templateID"] == "mint-conference"
    assert stored_json["phone"] == ""
    assert stored_json["meetingPlace"] is None


def test_public_card_writes_project_phone_and_meeting_place(card: PersonCard) -> None:
    legacy_card = card.model_copy(update={"meetingPlace": "Legacy room"})
    expires_at = datetime(2026, 8, 21, 12, 30, tzinfo=UTC)
    pool = RecordingPool()
    store = YDBSyncStore(pool)  # type: ignore[arg-type]
    store.authenticate_or_create("installation-owner", "owner-secret")

    store.publish_card("installation-owner", "op-publish-public", legacy_card, None)
    store.prepare_exchange(
        "installation-owner",
        "op-prepare-public",
        "qr",
        legacy_card,
        None,
        "raw-public-token",
        expires_at,
    )

    stored_cards = [
        json.loads(_parameter(parameters, "$card_json"))
        for query, parameters in pool.transaction_calls
        if "UPSERT INTO cards" in query
    ]
    assert len(stored_cards) == 2
    assert all(stored["phone"] == "" for stored in stored_cards)
    assert all(stored["meetingPlace"] is None for stored in stored_cards)


def test_legacy_public_card_rows_are_projected_before_refresh(card: PersonCard) -> None:
    legacy_card = card.model_copy(update={"meetingPlace": "Legacy room"})

    def read_handler(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        stored = legacy_card.model_dump(mode="json")
        return [
            ResultSet([{"version": 2, "card_json": stored}]),
            ResultSet(
                [
                    {
                        "installation_id": "installation-peer",
                        "version": 3,
                        "card_json": stored,
                        "fields_json": None,
                    }
                ]
            ),
            ResultSet([]),
        ]

    store = YDBSyncStore(  # type: ignore[arg-type]
        ScriptedPool(
            transaction_handler=lambda _query, _parameters: [],
            read_handler=read_handler,
        )
    )

    snapshot = store.refresh("installation-owner", None)

    assert snapshot.own_card is not None
    assert snapshot.own_card.phone == ""
    assert snapshot.own_card.meetingPlace is None
    assert snapshot.people[0].card.phone == ""
    assert snapshot.people[0].card.meetingPlace is None


def test_prepare_exchange_atomically_persists_public_card_private_fields_and_expiry(
    card: PersonCard,
) -> None:
    expires_at = datetime(2026, 8, 21, 12, 30, tzinfo=UTC)
    raw_credential = "credential-never-persist-me"
    public_card = card.model_copy(update={"phone": ""})
    private_fields = PrivateCardFields(phone=card.phone)

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "SELECT token_hash FROM exchange_claims" in query:
            return [ResultSet([])]
        if "SELECT version FROM cards" in query:
            return [ResultSet([{"version": 4}])]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    result = store.prepare_exchange(
        "installation-owner",
        "op-prepare-private",
        "bluetooth",
        public_card,
        private_fields,
        raw_credential,
        expires_at,
    )

    assert result == PreparedExchangeResult(card_version=5, expires_at=expires_at)
    mutation_query, mutation_parameters = next(
        (query, parameters)
        for query, parameters in pool.transaction_calls
        if "UPSERT INTO exchange_claims" in query
    )
    assert "UPSERT INTO cards" in mutation_query
    assert "UPSERT INTO exchange_private_fields" in mutation_query
    assert "token_hash, issuer_installation_id, fields_json, expires_at" in mutation_query
    assert "$token_hash, $installation_id, $fields_json, $expires_at" in mutation_query
    assert mutation_query.count("UPSERT INTO operations") == 1
    assert json.loads(_parameter(mutation_parameters, "$card_json"))["phone"] == ""
    assert json.loads(_parameter(mutation_parameters, "$fields_json")) == {
        "phone": card.phone
    }
    assert _parameter(mutation_parameters, "$expires_at") == expires_at
    assert json.loads(_parameter(mutation_parameters, "$result_json")) == {
        "expiresAt": expires_at.isoformat(),
        "tokenHash": sha256(raw_credential.encode()).hexdigest(),
        "version": 5,
    }
    assert raw_credential not in repr(pool.transaction_calls)


def test_prepare_without_private_fields_deletes_orphaned_digest_before_reuse(
    card: PersonCard,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query or "FROM exchange_claims" in query:
            return [ResultSet([])]
        if "SELECT version FROM cards" in query:
            return [ResultSet([])]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    store.prepare_exchange(
        "installation-owner",
        "op-prepare-orphan",
        "manual",
        card,
        None,
        "reused-orphaned-digest",
        datetime.now(UTC) + timedelta(minutes=5),
    )

    mutation_query = next(
        query for query, _ in pool.transaction_calls if "UPSERT INTO exchange_claims" in query
    )
    assert "DELETE FROM exchange_private_fields WHERE token_hash = $token_hash" in mutation_query
    assert "UPSERT INTO exchange_private_fields" not in mutation_query


def test_prepare_exchange_replay_returns_original_version_and_expiry() -> None:
    raw_credential = "original-credential"
    original_expiry = datetime(2026, 8, 21, 12, 30, tzinfo=UTC)
    persisted = json.dumps(
        {
            "expiresAt": original_expiry.isoformat(),
            "tokenHash": sha256(raw_credential.encode()).hexdigest(),
            "version": 7,
        }
    )

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [
                ResultSet(
                    [{"operation_type": "prepareExchange", "result_json": persisted}]
                )
            ]
        return []

    store = YDBSyncStore(ScriptedPool(transaction_handler=transaction_handler))  # type: ignore[arg-type]
    proposed_expiry = original_expiry + timedelta(hours=1)
    public_card = PersonCard(
        id="card-owner",
        name="Owner",
        role="Designer",
        company="YPerson",
        phone="",
        email="owner@example.invalid",
        tagline="Hello",
        hasAudioGreeting=False,
        isBlocked=False,
    )

    result = store.prepare_exchange(
        "installation-owner",
        "op-prepare-replay",
        "manual",
        public_card,
        PrivateCardFields(phone="+79990000000"),
        raw_credential,
        proposed_expiry,
    )

    assert result == PreparedExchangeResult(card_version=7, expires_at=original_expiry)
    with pytest.raises(StorageConflict):
        store.prepare_exchange(
            "installation-owner",
            "op-prepare-replay",
            "manual",
            public_card,
            None,
            "different-credential",
            proposed_expiry,
        )


@pytest.mark.parametrize("method", ["qr", "photo"])
def test_prepare_exchange_rejects_private_fields_for_nondisclosing_methods(
    card: PersonCard,
    method: str,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query or "FROM exchange_claims" in query:
            return [ResultSet([])]
        if "SELECT version FROM cards" in query:
            return [ResultSet([])]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    with pytest.raises(StorageConflict):
        store.prepare_exchange(
            "installation-owner",
            "op-prepare-method",
            method,
            card,
            PrivateCardFields(phone=card.phone),
            "raw-method-token",
            datetime.now(UTC) + timedelta(minutes=5),
        )

    assert not any("UPSERT INTO cards" in query for query, _ in pool.transaction_calls)


@pytest.mark.parametrize(
    "persisted_result",
    [
        {
            "expiresAt": "not-a-timestamp",
            "tokenHash": sha256(b"raw-token").hexdigest(),
            "version": 2,
        },
        {
            "expiresAt": datetime(2026, 8, 21, 12, 30, tzinfo=UTC).isoformat(),
            "tokenHash": sha256(b"raw-token").hexdigest(),
            "version": 0,
        },
    ],
)
def test_prepare_exchange_replay_validates_persisted_result(
    persisted_result: dict[str, object],
    card: PersonCard,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [
                ResultSet(
                    [
                        {
                            "operation_type": "prepareExchange",
                            "result_json": json.dumps(persisted_result),
                        }
                    ]
                )
            ]
        return []

    store = YDBSyncStore(ScriptedPool(transaction_handler=transaction_handler))  # type: ignore[arg-type]
    with pytest.raises(StorageIntegrityError):
        store.prepare_exchange(
            "installation-owner",
            "op-prepare-invalid",
            "qr",
            card.model_copy(update={"phone": ""}),
            None,
            "raw-token",
            datetime.now(UTC) + timedelta(minutes=5),
        )


def test_delete_private_state_and_profile_replays_without_recreating_installation(
    card: PersonCard,
) -> None:
    credential_hash = sha256(b"owner-secret").digest()

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "authentication-bootstrap" in query:
            return [ResultSet([]), ResultSet([{"operation_id": "op-delete-1"}])]
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
    deletion_query, deletion_parameters = next(
        (query, parameters)
        for query, parameters in pool.transaction_calls
        if "DELETE FROM installations" in query
    )
    assert """DELETE FROM exchange_private_fields
                WHERE issuer_installation_id = $installation_id;""" in deletion_query
    assert """DELETE FROM connection_private_fields
                WHERE owner_installation_id = $installation_id
                   OR peer_installation_id = $installation_id;""" in deletion_query
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
                            "method": "qr",
                            "expires_at": datetime.now(UTC) + timedelta(minutes=5),
                            "claimed_by_installation_id": "installation-peer",
                            "version": 1,
                            "card_json": json.dumps(card.model_dump(mode="json")),
                            "fields_json": None,
                            "private_issuer_installation_id": None,
                            "private_expires_at": None,
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


def test_claim_accepts_native_ydb_json_document(card: PersonCard) -> None:
    legacy_card = card.model_copy(update={"meetingPlace": "Legacy room"})

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
                            "claimed_by_installation_id": None,
                            "method": "qr",
                            "version": 1,
                            "card_json": legacy_card.model_dump(mode="json"),
                            "fields_json": None,
                            "private_issuer_installation_id": None,
                            "private_expires_at": None,
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    adapter = YDBSyncStore(pool)  # type: ignore[arg-type]

    person = adapter.claim_exchange(
        "installation-peer",
        "op-claim-native-json",
        "unclaimed-token",
    )

    assert person.installationID == "installation-owner"
    assert person.card == card.model_copy(update={"phone": "", "meetingPlace": None})


def test_claim_exchange_copies_private_fields_only_to_claimant_direction(
    card: PersonCard,
) -> None:
    raw_token = "claim-private-token"
    public_card = card.model_copy(update={"phone": ""})
    claim_expiry = datetime.now(UTC) + timedelta(minutes=5)

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "FROM exchange_claims AS claim" in query:
            return [
                ResultSet(
                    [
                        {
                            "issuer_installation_id": "installation-owner",
                            "expires_at": claim_expiry,
                            "claimed_by_installation_id": None,
                            "method": "bluetooth",
                            "version": 3,
                            "card_json": public_card.model_dump(mode="json"),
                            "fields_json": {"phone": card.phone},
                            "private_issuer_installation_id": "installation-owner",
                            "private_expires_at": claim_expiry,
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    person = store.claim_exchange(
        "installation-peer",
        "op-claim-private",
        raw_token,
    )

    assert person.installationID == "installation-owner"
    assert person.version == 3
    assert person.card.phone == card.phone
    mutation_query, mutation_parameters = next(
        (query, parameters)
        for query, parameters in pool.transaction_calls
        if "UPDATE exchange_claims" in query
    )
    assert "UPSERT INTO connection_private_fields" in mutation_query
    assert "DELETE FROM exchange_private_fields" in mutation_query
    assert "$installation_id, $issuer_id, $fields_json, $now" in mutation_query
    assert _parameter(mutation_parameters, "$installation_id") == "installation-peer"
    assert _parameter(mutation_parameters, "$issuer_id") == "installation-owner"
    assert json.loads(_parameter(mutation_parameters, "$fields_json")) == {
        "phone": card.phone
    }
    assert json.loads(_parameter(mutation_parameters, "$result_json")) == {
        "issuerInstallationID": "installation-owner",
        "tokenHash": sha256(raw_token.encode()).hexdigest(),
    }


@pytest.mark.parametrize(
    ("method", "fields_json"),
    [
        ("qr", {"phone": "+79990000000"}),
        ("photo", {"phone": "+79990000000"}),
        ("unsupported", None),
    ],
)
def test_claim_exchange_rejects_corrupt_private_method_state(
    card: PersonCard,
    method: str,
    fields_json: object,
) -> None:
    claim_expiry = datetime.now(UTC) + timedelta(minutes=5)

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "FROM exchange_claims AS claim" in query:
            return [
                ResultSet(
                    [
                        {
                            "issuer_installation_id": "installation-owner",
                            "expires_at": claim_expiry,
                            "claimed_by_installation_id": None,
                            "method": method,
                            "version": 1,
                            "card_json": card.model_dump(mode="json"),
                            "fields_json": fields_json,
                            "private_issuer_installation_id": (
                                "installation-owner" if fields_json is not None else None
                            ),
                            "private_expires_at": (
                                claim_expiry if fields_json is not None else None
                            ),
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    with pytest.raises(StorageIntegrityError):
        store.claim_exchange("installation-peer", "op-claim-method", "raw-token")

    assert not any("UPDATE exchange_claims" in query for query, _ in pool.transaction_calls)


@pytest.mark.parametrize("mismatch", ["issuer", "expiry"])
def test_claim_exchange_rejects_private_issuer_or_expiry_mismatch(
    card: PersonCard,
    mismatch: str,
) -> None:
    claim_expiry = datetime.now(UTC) + timedelta(minutes=5)

    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "FROM exchange_claims AS claim" in query:
            return [
                ResultSet(
                    [
                        {
                            "issuer_installation_id": "installation-owner",
                            "method": "manual",
                            "expires_at": claim_expiry,
                            "claimed_by_installation_id": None,
                            "version": 1,
                            "card_json": card.model_dump(mode="json"),
                            "fields_json": {"phone": card.phone},
                            "private_issuer_installation_id": (
                                "installation-other"
                                if mismatch == "issuer"
                                else "installation-owner"
                            ),
                            "private_expires_at": (
                                claim_expiry + timedelta(seconds=1)
                                if mismatch == "expiry"
                                else claim_expiry
                            ),
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    with pytest.raises(StorageIntegrityError):
        store.claim_exchange("installation-peer", "op-claim-mismatch", "raw-token")

    assert not any("UPDATE exchange_claims" in query for query, _ in pool.transaction_calls)
    claim_query = next(
        query for query, _ in pool.transaction_calls if "FROM exchange_claims AS claim" in query
    )
    assert "claim.method AS method" in claim_query
    assert "exchange_fields.issuer_installation_id" in claim_query
    assert "exchange_fields.expires_at AS private_expires_at" in claim_query


def test_claim_exchange_replay_loads_current_public_card_and_directional_grant(
    card: PersonCard,
) -> None:
    raw_token = "replayed-claim-token"
    previous_result = {
        "issuerInstallationID": "installation-owner",
        "tokenHash": sha256(raw_token.encode()).hexdigest(),
    }
    updated_public_card = card.model_copy(
        update={"phone": "+71111111111", "meetingPlace": "Legacy room", "name": "Updated Owner"}
    )

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
        if "FROM cards AS card" in query:
            return [
                ResultSet(
                    [
                        {
                            "version": 8,
                            "card_json": updated_public_card.model_dump(mode="json"),
                            "fields_json": {"phone": card.phone},
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    person = store.claim_exchange(
        "installation-peer",
        "op-claim-replayed",
        raw_token,
    )

    assert person.version == 8
    assert person.card.name == "Updated Owner"
    assert person.card.phone == card.phone
    assert person.card.meetingPlace is None
    assert not any("FROM exchange_claims AS claim" in query for query, _ in pool.transaction_calls)


def test_refresh_private_fields_overlay_only_for_the_requester(
    card: PersonCard,
) -> None:
    public_card = card.model_copy(update={"phone": ""})

    def read_handler(_query: str, parameters: dict[str, Any]) -> list[ResultSet]:
        requester = _parameter(parameters, "$installation_id")
        fields: object = {"phone": card.phone} if requester == "installation-peer" else None
        return [
            ResultSet([]),
            ResultSet(
                [
                    {
                        "installation_id": "installation-owner",
                        "version": 4,
                        "card_json": public_card.model_dump(mode="json"),
                        "fields_json": fields,
                    }
                ]
            ),
            ResultSet([]),
        ]

    pool = ScriptedPool(
        transaction_handler=lambda _query, _parameters: [],
        read_handler=read_handler,
    )
    store = YDBSyncStore(pool)  # type: ignore[arg-type]

    peer = store.refresh("installation-peer", None)
    other = store.refresh("installation-other", None)

    assert peer.people[0].card.phone == card.phone
    assert other.people[0].card.phone == ""
    assert all("connection_private_fields" in query for query, _ in pool.read_calls)
    assert all(
        "grant_fields.owner_installation_id = connection.owner_installation_id" in query
        and "grant_fields.peer_installation_id = connection.peer_installation_id" in query
        for query, _ in pool.read_calls
    )


@pytest.mark.parametrize("fields_json", [b"{", {"phone": "+79990000000", "email": "x"}])
@pytest.mark.parametrize("path", ["refresh", "claim"])
def test_refresh_private_or_claim_private_rejects_malformed_or_unknown_fields(
    card: PersonCard,
    fields_json: object,
    path: str,
) -> None:
    public_card = card.model_copy(update={"phone": ""})
    claim_expiry = datetime.now(UTC) + timedelta(minutes=5)
    row = {
        "installation_id": "installation-owner",
        "issuer_installation_id": "installation-owner",
        "expires_at": claim_expiry,
        "claimed_by_installation_id": None,
        "method": "manual",
        "version": 1,
        "card_json": public_card.model_dump(mode="json"),
        "fields_json": fields_json,
        "private_issuer_installation_id": "installation-owner",
        "private_expires_at": claim_expiry,
    }

    if path == "refresh":
        def read_handler(_query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
            return [ResultSet([]), ResultSet([row]), ResultSet([])]

        store = YDBSyncStore(  # type: ignore[arg-type]
            ScriptedPool(
                transaction_handler=lambda _query, _parameters: [],
                read_handler=read_handler,
            )
        )
        with pytest.raises(StorageIntegrityError):
            store.refresh("installation-peer", None)
    else:
        def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
            if "FROM operations" in query:
                return [ResultSet([])]
            if "FROM exchange_claims AS claim" in query:
                return [ResultSet([row])]
            return []

        store = YDBSyncStore(ScriptedPool(transaction_handler=transaction_handler))  # type: ignore[arg-type]
        with pytest.raises(StorageIntegrityError):
            store.claim_exchange("installation-peer", "op-claim-corrupt", "raw-token")


def test_delete_private_exchange_on_cancel_and_persist_only_token_hash() -> None:
    raw_token = "prepared-token-never-persist-me"
    token_hash = sha256(raw_token.encode()).digest()

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
                            "claimed_by_installation_id": None,
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]
    store.cancel_exchange("installation-owner", "cancel-operation-1", raw_token)

    all_queries = "\n".join(query for query, _ in pool.transaction_calls)
    assert "DELETE FROM exchange_claims" in all_queries
    assert "DELETE FROM exchange_private_fields" in all_queries
    assert raw_token not in repr(pool.transaction_calls)
    assert any(
        _parameter(parameters, "$token_hash") == token_hash
        for _, parameters in pool.transaction_calls
        if "$token_hash" in parameters
    )


def test_cancel_replay_is_bound_to_original_token_and_never_reopens_exchange() -> None:
    raw_token = "original-token"
    persisted = json.dumps({"tokenHash": sha256(raw_token.encode()).hexdigest()})

    def replay_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([{"operation_type": "cancelExchange", "result_json": persisted}])]
        return []

    replay_pool = ScriptedPool(transaction_handler=replay_handler)
    store = YDBSyncStore(replay_pool)  # type: ignore[arg-type]
    store.cancel_exchange("installation-owner", "cancel-operation-1", raw_token)
    assert not any(
        "FROM exchange_claims AS claim" in query for query, _ in replay_pool.transaction_calls
    )

    conflict_pool = ScriptedPool(transaction_handler=replay_handler)
    conflict_store = YDBSyncStore(conflict_pool)  # type: ignore[arg-type]
    with pytest.raises(StorageConflict):
        conflict_store.cancel_exchange(
            "installation-owner", "cancel-operation-1", "different-token"
        )


@pytest.mark.parametrize(
    ("issuer", "claimed_by", "expires_at"),
    [
        ("installation-other", None, datetime.now(UTC) + timedelta(minutes=5)),
        ("installation-owner", "installation-peer", datetime.now(UTC) + timedelta(minutes=5)),
        ("installation-owner", None, datetime.now(UTC) - timedelta(seconds=1)),
    ],
)
def test_cancel_rejects_non_owner_or_already_claimed_exchange(
    issuer: str,
    claimed_by: str | None,
    expires_at: datetime,
) -> None:
    def transaction_handler(query: str, _parameters: dict[str, Any]) -> list[ResultSet]:
        if "FROM operations" in query:
            return [ResultSet([])]
        if "FROM exchange_claims AS claim" in query:
            return [
                ResultSet(
                    [
                        {
                            "issuer_installation_id": issuer,
                            "expires_at": expires_at,
                            "claimed_by_installation_id": claimed_by,
                        }
                    ]
                )
            ]
        return []

    pool = ScriptedPool(transaction_handler=transaction_handler)
    store = YDBSyncStore(pool)  # type: ignore[arg-type]
    with pytest.raises(StorageConflict):
        store.cancel_exchange("installation-owner", "cancel-operation-1", "raw-token")
    assert not any("DELETE FROM exchange_claims" in query for query, _ in pool.transaction_calls)


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
            PersonCard(
                id="card-owner",
                name="Owner",
                role="Designer",
                company="YPerson",
                phone="",
                email="owner@example.invalid",
                tagline="Hello",
                hasAudioGreeting=False,
                isBlocked=False,
            ),
            None,
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
                            "method": "qr",
                            "expires_at": datetime.now(UTC) + timedelta(minutes=5),
                            "claimed_by_installation_id": None,
                            "version": 1,
                            "card_json": json.dumps(card.model_dump(mode="json")),
                            "fields_json": None,
                            "private_issuer_installation_id": None,
                            "private_expires_at": None,
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
            PersonCard(
                id="card-deleted",
                name="Deleted",
                role="Designer",
                company="YPerson",
                phone="",
                email="deleted@example.invalid",
                tagline="Hello",
                hasAudioGreeting=False,
                isBlocked=False,
            ),
            None,
            "raw-token",
            datetime.now(UTC) + timedelta(minutes=5),
        ),
        lambda store: store.cancel_exchange(
            "installation-deleted",
            "op-cancel-delayed",
            "raw-token",
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

    with pytest.raises(SchemaMismatch, match="schema version 2"):
        apply_schema(SchemaPool(), describe_table)  # type: ignore[arg-type]


def test_schema_v2_describes_private_field_tables_and_applies_all_nine() -> None:
    from app.ydb_schema import EXPECTED_TABLES, SCHEMA_VERSION, apply_schema

    applied: list[str] = []

    class SchemaPool:
        def execute_with_retries(
            self,
            query: str,
            *,
            retry_settings: ydb.RetrySettings,
        ) -> None:
            assert retry_settings.idempotent
            applied.append(query)

    class Description:
        def __init__(self, columns: list[ydb.Column], primary_key: list[str]) -> None:
            self.columns = columns
            self.primary_key = primary_key

    def describe_table(table_name: str) -> Description:
        table = EXPECTED_TABLES[table_name]
        return Description(
            [ydb.Column(name, column_type) for name, column_type in table.columns],
            list(table.primary_key),
        )

    assert SCHEMA_VERSION == 2
    assert EXPECTED_TABLES["exchange_private_fields"].primary_key == ("token_hash",)
    assert EXPECTED_TABLES["exchange_private_fields"].columns == (
        ("token_hash", ydb.PrimitiveType.String),
        ("issuer_installation_id", ydb.PrimitiveType.Utf8),
        ("fields_json", ydb.PrimitiveType.JsonDocument),
        ("expires_at", ydb.PrimitiveType.Timestamp),
    )
    assert EXPECTED_TABLES["connection_private_fields"].primary_key == (
        "owner_installation_id",
        "peer_installation_id",
    )
    assert EXPECTED_TABLES["connection_private_fields"].columns == (
        ("owner_installation_id", ydb.PrimitiveType.Utf8),
        ("peer_installation_id", ydb.PrimitiveType.Utf8),
        ("fields_json", ydb.PrimitiveType.JsonDocument),
        ("updated_at", ydb.PrimitiveType.Timestamp),
    )
    assert apply_schema(SchemaPool(), describe_table) == 9  # type: ignore[arg-type]
    assert len(applied) == 9
