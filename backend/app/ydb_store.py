"""YDB implementation of the installation-authenticated sync store."""

from __future__ import annotations

import json
from collections.abc import Callable
from datetime import UTC, datetime
from hashlib import sha256
from hmac import compare_digest
from typing import Any

import ydb
from pydantic import ValidationError

from .schemas import PersonCard, SyncedPerson
from .storage import (
    InstallationRecord,
    InvalidCredential,
    StorageConflict,
    StorageIntegrityError,
    SyncSnapshot,
)


class YDBSyncStore:
    """Persist sync state through a ready QuerySessionPool."""

    def __init__(
        self,
        pool: ydb.QuerySessionPool,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._pool = pool
        self._clock = clock or (lambda: datetime.now(UTC))

    def authenticate_or_create(self, installation_id: str, bearer: str) -> None:
        candidate_hash = _digest(bearer)
        now = self._clock()
        query = """
        DECLARE $installation_id AS Utf8;
        DECLARE $credential_hash AS String;
        DECLARE $now AS Timestamp;

        $existing = SELECT installation_id
                    FROM installations
                    WHERE installation_id = $installation_id;
        $deleted = SELECT operation_id
                   FROM operations
                   WHERE installation_id = $installation_id
                     AND operation_type = "deleteProfile"u
                   LIMIT 1;

        UPSERT INTO installations (
            installation_id, credential_hash, apns_token,
            created_at, updated_at, deleted_at
        )
        SELECT $installation_id, $credential_hash,
               CAST(NULL AS Utf8?), $now, $now, CAST(NULL AS Timestamp?)
        WHERE NOT EXISTS ($existing) AND NOT EXISTS ($deleted);

        SELECT credential_hash, apns_token, created_at, updated_at, deleted_at
        FROM installations
        WHERE installation_id = $installation_id;
        """
        rows = self._execute(
            query,
            {
                "$installation_id": _utf8(installation_id),
                "$credential_hash": _string(candidate_hash),
                "$now": _timestamp(now),
            },
        )[0]
        stored_hash = _stored_credential_hash(rows)
        if stored_hash is None or not compare_digest(stored_hash, candidate_hash):
            raise InvalidCredential

    def authenticate(self, installation_id: str, bearer: str) -> None:
        candidate_hash = _digest(bearer)
        rows = self._execute(
            """
            DECLARE $installation_id AS Utf8;
            SELECT credential_hash
            FROM installations
            WHERE installation_id = $installation_id
              AND deleted_at IS NULL;
            """,
            {"$installation_id": _utf8(installation_id)},
        )[0]
        stored_hash = _stored_credential_hash(rows)
        if stored_hash is None or not compare_digest(stored_hash, candidate_hash):
            raise InvalidCredential

    def publish_card(
        self,
        installation_id: str,
        operation_id: str,
        card: PersonCard,
        audio_asset_id: str | None,
    ) -> int:
        now = self._clock()

        def publish(tx: ydb.QueryTxContext) -> int:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(tx, installation_id, operation_id, "publishCard")
            if previous is not None:
                return _stored_positive_int(previous, "version")

            current_rows = self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                SELECT version FROM cards WHERE installation_id = $installation_id;
                """,
                {"$installation_id": _utf8(installation_id)},
            )[0]
            if len(current_rows) > 1:
                raise StorageIntegrityError
            version = (_stored_version(current_rows[0]) if current_rows else 0) + 1
            result_json = _json({"version": version})
            self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $card_id AS Utf8;
                DECLARE $version AS Uint64;
                DECLARE $card_json AS JsonDocument;
                DECLARE $audio_asset_id AS Utf8?;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                UPSERT INTO cards (
                    installation_id, card_id, version, card_json,
                    audio_asset_id, published_at, updated_at
                ) VALUES (
                    $installation_id, $card_id, $version, $card_json,
                    $audio_asset_id, $now, $now
                );
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES (
                    $installation_id, $operation_id, "publishCard"u, $result_json, $now
                );
                """,
                {
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$card_id": _utf8(card.id),
                    "$version": _uint64(version),
                    "$card_json": _json_document(
                        _json(card.model_dump(mode="json", exclude={"meetingPlace"}))
                    ),
                    "$audio_asset_id": _optional_utf8(audio_asset_id),
                    "$result_json": _json_document(result_json),
                    "$now": _timestamp(now),
                },
            )
            return version

        return self._transaction(publish)

    def refresh(self, installation_id: str, cursor: str | None) -> SyncSnapshot:
        query = """
        DECLARE $installation_id AS Utf8;

        SELECT version, card_json
        FROM cards
        WHERE installation_id = $installation_id;

        SELECT connection.peer_installation_id AS installation_id,
               peer.version AS version, peer.card_json AS card_json
        FROM connections AS connection
        INNER JOIN connections AS reverse
            ON reverse.owner_installation_id = connection.peer_installation_id
           AND reverse.peer_installation_id = connection.owner_installation_id
        INNER JOIN cards AS peer
            ON peer.installation_id = connection.peer_installation_id
        WHERE connection.owner_installation_id = $installation_id
          AND connection.status = "confirmed"u
          AND reverse.status = "confirmed"u;

        SELECT operation_id, result_json
        FROM operations
        WHERE installation_id = $installation_id
          AND operation_type = "revocation"u
        ORDER BY completed_at, operation_id;
        """
        result_sets = self._execute(
            query,
            {"$installation_id": _utf8(installation_id)},
        )
        if len(result_sets) != 3:
            raise StorageIntegrityError
        own_rows = result_sets[0]
        people_rows = result_sets[1]
        revocation_rows = result_sets[2]
        if len(own_rows) > 1:
            raise StorageIntegrityError
        own_card = _stored_card(own_rows[0]) if own_rows else None
        own_version = _stored_version(own_rows[0]) if own_rows else None
        people = tuple(
            SyncedPerson(
                installationID=_stored_text(row, "installation_id"),
                card=_stored_card(row),
                version=_stored_version(row),
            )
            for row in people_rows
        )
        unseen_revocations = _unseen_revocations(revocation_rows, cursor)
        revoked_card_ids = tuple(
            dict.fromkeys(_stored_revoked_card_id(row) for row in unseen_revocations)
        )
        next_cursor = _stored_cursor(unseen_revocations[-1]) if unseen_revocations else cursor
        return SyncSnapshot(
            own_card=own_card,
            own_card_version=own_version,
            people=people,
            revoked_card_ids=revoked_card_ids,
            next_cursor=next_cursor,
        )

    def prepare_exchange(
        self,
        installation_id: str,
        operation_id: str,
        method: str,
        raw_token: str,
        expires_at: datetime,
    ) -> None:
        token_hash = _digest(raw_token)
        now = self._clock()

        def prepare(tx: ydb.QueryTxContext) -> None:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(
                tx,
                installation_id,
                operation_id,
                "prepareExchange",
            )
            if previous is not None:
                previous_hash = _stored_digest(previous, "tokenHash")
                if not compare_digest(previous_hash, token_hash):
                    raise StorageConflict("operation identifier already used")
                return
            token_rows = self._tx_rows(
                tx,
                """
                DECLARE $token_hash AS String;
                SELECT token_hash FROM exchange_claims WHERE token_hash = $token_hash;
                """,
                {"$token_hash": _string(token_hash)},
            )[0]
            if token_rows:
                raise StorageConflict("exchange unavailable")
            self._tx_rows(
                tx,
                """
                DECLARE $token_hash AS String;
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $method AS Utf8;
                DECLARE $expires_at AS Timestamp;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                UPSERT INTO exchange_claims (
                    token_hash, issuer_installation_id, method,
                    expires_at, claimed_by_installation_id
                ) VALUES (
                    $token_hash, $installation_id, $method,
                    $expires_at, CAST(NULL AS Utf8?)
                );
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES (
                    $installation_id, $operation_id, "prepareExchange"u, $result_json, $now
                );
                """,
                {
                    "$token_hash": _string(token_hash),
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$method": _utf8(method),
                    "$expires_at": _timestamp(expires_at),
                    "$result_json": _json_document(_json({"tokenHash": token_hash.hex()})),
                    "$now": _timestamp(now),
                },
            )

        self._transaction(prepare)

    def claim_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> SyncedPerson:
        token_hash = _digest(raw_token)
        now = self._clock()

        def claim(tx: ydb.QueryTxContext) -> SyncedPerson:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(tx, installation_id, operation_id, "claimExchange")
            if previous is not None:
                previous_hash = _stored_digest(previous, "tokenHash")
                if not compare_digest(previous_hash, token_hash):
                    raise StorageConflict("operation identifier already used")
                try:
                    return SyncedPerson.model_validate(previous["person"], strict=True)
                except (KeyError, TypeError, ValidationError) as error:
                    raise StorageIntegrityError from error
            claim_rows = self._tx_rows(
                tx,
                """
                DECLARE $token_hash AS String;
                SELECT claim.issuer_installation_id AS issuer_installation_id,
                       claim.expires_at AS expires_at,
                       claim.claimed_by_installation_id AS claimed_by_installation_id,
                       card.version AS version,
                       card.card_json AS card_json
                FROM exchange_claims AS claim
                INNER JOIN cards AS card
                    ON card.installation_id = claim.issuer_installation_id
                WHERE claim.token_hash = $token_hash;
                """,
                {"$token_hash": _string(token_hash)},
            )[0]
            if not claim_rows:
                raise StorageConflict("exchange unavailable")
            if len(claim_rows) != 1:
                raise StorageIntegrityError
            row = claim_rows[0]
            issuer_id = _stored_text(row, "issuer_installation_id")
            claimed_by = _stored_optional_text(row, "claimed_by_installation_id")
            if (
                issuer_id == installation_id
                or _stored_datetime(row, "expires_at") <= _as_utc(now)
                or claimed_by is not None
            ):
                raise StorageConflict("exchange unavailable")
            person = SyncedPerson(
                installationID=issuer_id,
                card=_stored_card(row),
                version=_stored_version(row),
            )
            result_json = _json(
                {
                    "person": person.model_dump(mode="json"),
                    "tokenHash": token_hash.hex(),
                }
            )
            self._tx_rows(
                tx,
                """
                DECLARE $token_hash AS String;
                DECLARE $issuer_id AS Utf8;
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                UPDATE exchange_claims
                SET claimed_by_installation_id = $installation_id
                WHERE token_hash = $token_hash;
                UPSERT INTO connections (
                    owner_installation_id, peer_installation_id,
                    status, created_at, updated_at
                ) VALUES
                    ($installation_id, $issuer_id, "confirmed"u, $now, $now),
                    ($issuer_id, $installation_id, "confirmed"u, $now, $now);
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES (
                    $installation_id, $operation_id, "claimExchange"u, $result_json, $now
                );
                """,
                {
                    "$token_hash": _string(token_hash),
                    "$issuer_id": _utf8(issuer_id),
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$result_json": _json_document(result_json),
                    "$now": _timestamp(now),
                },
            )
            return person

        return self._transaction(claim)

    def cancel_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> None:
        token_hash = _digest(raw_token)
        now = self._clock()

        def cancel(tx: ydb.QueryTxContext) -> None:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(
                tx,
                installation_id,
                operation_id,
                "cancelExchange",
            )
            if previous is not None:
                previous_hash = _stored_digest(previous, "tokenHash")
                if not compare_digest(previous_hash, token_hash):
                    raise StorageConflict("operation identifier already used")
                return
            claim_rows = self._tx_rows(
                tx,
                """
                DECLARE $token_hash AS String;
                SELECT claim.issuer_installation_id AS issuer_installation_id,
                       claim.expires_at AS expires_at,
                       claim.claimed_by_installation_id AS claimed_by_installation_id
                FROM exchange_claims AS claim
                WHERE claim.token_hash = $token_hash;
                """,
                {"$token_hash": _string(token_hash)},
            )[0]
            if len(claim_rows) != 1:
                if claim_rows:
                    raise StorageIntegrityError
                raise StorageConflict("exchange unavailable")
            row = claim_rows[0]
            if (
                _stored_text(row, "issuer_installation_id") != installation_id
                or _stored_datetime(row, "expires_at") <= _as_utc(now)
                or _stored_optional_text(row, "claimed_by_installation_id") is not None
            ):
                raise StorageConflict("exchange unavailable")
            self._tx_rows(
                tx,
                """
                DECLARE $token_hash AS String;
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                DELETE FROM exchange_claims WHERE token_hash = $token_hash;
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES (
                    $installation_id, $operation_id, "cancelExchange"u, $result_json, $now
                );
                """,
                {
                    "$token_hash": _string(token_hash),
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$result_json": _json_document(_json({"tokenHash": token_hash.hex()})),
                    "$now": _timestamp(now),
                },
            )

        self._transaction(cancel)

    def save_push_token(
        self,
        installation_id: str,
        operation_id: str,
        token: str | None,
    ) -> None:
        now = self._clock()
        operation_type = "updatePushToken" if token is not None else "removePushToken"

        def save(tx: ydb.QueryTxContext) -> None:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(tx, installation_id, operation_id, operation_type)
            if previous is not None:
                return
            self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $operation_type AS Utf8;
                DECLARE $token AS Utf8?;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                UPDATE installations
                SET apns_token = $token, updated_at = $now
                WHERE installation_id = $installation_id;
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES (
                    $installation_id, $operation_id, $operation_type, $result_json, $now
                );
                """,
                {
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$operation_type": _utf8(operation_type),
                    "$token": _optional_utf8(token),
                    "$result_json": _json_document(_json({})),
                    "$now": _timestamp(now),
                },
            )

        self._transaction(save)

    def record_moderation(
        self,
        installation_id: str,
        operation_id: str,
        subject_id: str,
        action: str,
        category: str | None,
    ) -> None:
        now = self._clock()

        def record(tx: ydb.QueryTxContext) -> None:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(tx, installation_id, operation_id, action)
            if previous is not None:
                return
            card_ids: dict[str, str] = {}
            if action == "block":
                card_rows = self._tx_rows(
                    tx,
                    """
                    DECLARE $installation_id AS Utf8;
                    DECLARE $subject_id AS Utf8;
                    SELECT installation_id, card_id
                    FROM cards
                    WHERE installation_id IN ($installation_id, $subject_id);
                    """,
                    {
                        "$installation_id": _utf8(installation_id),
                        "$subject_id": _utf8(subject_id),
                    },
                )[0]
                card_ids = {
                    _stored_text(row, "installation_id"): _stored_text(row, "card_id")
                    for row in card_rows
                }
            self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $subject_id AS Utf8;
                DECLARE $action AS Utf8;
                DECLARE $category AS Utf8?;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                UPSERT INTO moderation_actions (
                    reporter_installation_id, subject_installation_id,
                    action_id, action, category, created_at
                ) VALUES (
                    $installation_id, $subject_id, $operation_id, $action, $category, $now
                );
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES ($installation_id, $operation_id, $action, $result_json, $now);
                """,
                {
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$subject_id": _utf8(subject_id),
                    "$action": _utf8(action),
                    "$category": _optional_utf8(category),
                    "$result_json": _json_document(_json({})),
                    "$now": _timestamp(now),
                },
            )
            if action == "block":
                self._tx_rows(
                    tx,
                    """
                    DECLARE $installation_id AS Utf8;
                    DECLARE $subject_id AS Utf8;
                    DECLARE $now AS Timestamp;
                    UPSERT INTO connections (
                        owner_installation_id, peer_installation_id,
                        status, created_at, updated_at
                    ) VALUES
                        ($installation_id, $subject_id, "blocked"u, $now, $now),
                        ($subject_id, $installation_id, "blocked"u, $now, $now);
                    """,
                    {
                        "$installation_id": _utf8(installation_id),
                        "$subject_id": _utf8(subject_id),
                        "$now": _timestamp(now),
                    },
                )
                if subject_card_id := card_ids.get(subject_id):
                    self._store_revocation(
                        tx,
                        installation_id,
                        operation_id,
                        subject_card_id,
                        now,
                    )
                if reporter_card_id := card_ids.get(installation_id):
                    self._store_revocation(
                        tx,
                        subject_id,
                        operation_id,
                        reporter_card_id,
                        now,
                    )

        self._transaction(record)

    def delete_profile(self, installation_id: str, operation_id: str) -> list[str]:
        now = self._clock()

        def delete(tx: ydb.QueryTxContext) -> list[str]:
            self._ensure_active(tx, installation_id)
            previous = self._operation_result(tx, installation_id, operation_id, "deleteProfile")
            if previous is not None:
                return _object_keys(previous)
            credential_rows = self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                SELECT credential_hash FROM installations
                WHERE installation_id = $installation_id;
                """,
                {"$installation_id": _utf8(installation_id)},
            )[0]
            credential_hash = _stored_credential_hash(credential_rows)
            if credential_hash is None:
                raise StorageConflict("profile unavailable")
            media_rows = self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                SELECT object_key FROM media_assets
                WHERE owner_installation_id = $installation_id;
                """,
                {"$installation_id": _utf8(installation_id)},
            )[0]
            object_keys = [_stored_object_key(row, "object_key") for row in media_rows]
            card_rows = self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                SELECT card_id FROM cards
                WHERE installation_id = $installation_id;
                """,
                {"$installation_id": _utf8(installation_id)},
            )[0]
            if len(card_rows) > 1:
                raise StorageIntegrityError
            connection_rows = self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                SELECT owner_installation_id, peer_installation_id
                FROM connections
                WHERE owner_installation_id = $installation_id
                   OR peer_installation_id = $installation_id;
                """,
                {"$installation_id": _utf8(installation_id)},
            )[0]
            if card_rows:
                revoked_card_id = _stored_text(card_rows[0], "card_id")
                peers = {
                    _stored_text(row, "peer_installation_id")
                    if _stored_text(row, "owner_installation_id") == installation_id
                    else _stored_text(row, "owner_installation_id")
                    for row in connection_rows
                }
                for peer_installation_id in peers:
                    self._store_revocation(
                        tx,
                        peer_installation_id,
                        operation_id,
                        revoked_card_id,
                        now,
                    )
            result_json = _json(
                {
                    "credentialHash": credential_hash.hex(),
                    "objectKeys": object_keys,
                }
            )
            self._tx_rows(
                tx,
                """
                DECLARE $installation_id AS Utf8;
                DECLARE $operation_id AS Utf8;
                DECLARE $result_json AS JsonDocument;
                DECLARE $now AS Timestamp;

                DELETE FROM connections
                WHERE owner_installation_id = $installation_id
                   OR peer_installation_id = $installation_id;
                DELETE FROM exchange_claims
                WHERE issuer_installation_id = $installation_id
                   OR claimed_by_installation_id = $installation_id;
                DELETE FROM media_assets WHERE owner_installation_id = $installation_id;
                DELETE FROM cards WHERE installation_id = $installation_id;
                DELETE FROM installations WHERE installation_id = $installation_id;
                DELETE FROM operations WHERE installation_id = $installation_id;
                UPSERT INTO operations (
                    installation_id, operation_id, operation_type, result_json, completed_at
                ) VALUES (
                    $installation_id, $operation_id, "deleteProfile"u, $result_json, $now
                );
                """,
                {
                    "$installation_id": _utf8(installation_id),
                    "$operation_id": _utf8(operation_id),
                    "$result_json": _json_document(result_json),
                    "$now": _timestamp(now),
                },
            )
            return object_keys

        return self._transaction(delete)

    def replay_deleted_profile(
        self,
        installation_id: str,
        operation_id: str,
        bearer: str,
    ) -> list[str] | None:
        rows = self._execute(
            """
            DECLARE $installation_id AS Utf8;
            DECLARE $operation_id AS Utf8;
            SELECT operation_type, result_json
            FROM operations
            WHERE installation_id = $installation_id
              AND operation_id = $operation_id
              AND operation_type = "deleteProfile"u;
            """,
            {
                "$installation_id": _utf8(installation_id),
                "$operation_id": _utf8(operation_id),
            },
        )[0]
        if not rows:
            return None
        if len(rows) != 1:
            raise StorageIntegrityError
        result = _stored_json(rows[0], "result_json")
        stored_hash = _stored_digest(result, "credentialHash")
        if not compare_digest(stored_hash, _digest(bearer)):
            raise InvalidCredential
        return _object_keys(result)

    def debug_installation(self, installation_id: str) -> InstallationRecord | None:
        """Return secret-safe adapter state for deterministic injected-pool tests."""

        rows = self._execute(
            """
            DECLARE $installation_id AS Utf8;
            SELECT credential_hash, apns_token, created_at, updated_at, deleted_at
            FROM installations WHERE installation_id = $installation_id;
            """,
            {"$installation_id": _utf8(installation_id)},
        )[0]
        if not rows:
            return None
        if len(rows) != 1:
            raise StorageIntegrityError
        row = rows[0]
        return InstallationRecord(
            installation_id=installation_id,
            credential_hash=_stored_bytes(row, "credential_hash", expected_length=32),
            apns_token=_stored_optional_text(row, "apns_token"),
            created_at=_stored_datetime(row, "created_at"),
            updated_at=_stored_datetime(row, "updated_at"),
            deleted_at=_stored_optional_datetime(row, "deleted_at"),
        )

    def _operation_result(
        self,
        tx: ydb.QueryTxContext,
        installation_id: str,
        operation_id: str,
        expected_type: str,
    ) -> dict[str, Any] | None:
        rows = self._tx_rows(
            tx,
            """
            DECLARE $installation_id AS Utf8;
            DECLARE $operation_id AS Utf8;
            SELECT operation_type, result_json
            FROM operations
            WHERE installation_id = $installation_id AND operation_id = $operation_id;
            """,
            {
                "$installation_id": _utf8(installation_id),
                "$operation_id": _utf8(operation_id),
            },
        )[0]
        if not rows:
            return None
        if len(rows) != 1:
            raise StorageIntegrityError
        row = rows[0]
        operation_type = _stored_text(row, "operation_type")
        if operation_type != expected_type:
            raise StorageConflict("operation identifier already used")
        return _stored_json(row, "result_json")

    def _ensure_active(self, tx: ydb.QueryTxContext, installation_id: str) -> None:
        result_sets = self._tx_rows(
            tx,
            """
            -- active-installation-guard
            DECLARE $installation_id AS Utf8;
            SELECT installation_id FROM installations
            WHERE installation_id = $installation_id;
            SELECT operation_id FROM operations
            WHERE installation_id = $installation_id
              AND operation_type = "deleteProfile"u
            LIMIT 1;
            """,
            {"$installation_id": _utf8(installation_id)},
        )
        if len(result_sets[0]) != 1 or result_sets[1]:
            raise StorageConflict("installation unavailable")

    def _store_revocation(
        self,
        tx: ydb.QueryTxContext,
        installation_id: str,
        source_operation_id: str,
        revoked_card_id: str,
        now: datetime,
    ) -> None:
        revocation_id = _revocation_cursor(source_operation_id, revoked_card_id)
        self._tx_rows(
            tx,
            """
            DECLARE $installation_id AS Utf8;
            DECLARE $operation_id AS Utf8;
            DECLARE $revoked_card_id AS Utf8;
            DECLARE $result_json AS JsonDocument;
            DECLARE $now AS Timestamp;
            UPSERT INTO operations (
                installation_id, operation_id, operation_type, result_json, completed_at
            ) VALUES (
                $installation_id, $operation_id, "revocation"u, $result_json, $now
            );
            """,
            {
                "$installation_id": _utf8(installation_id),
                "$operation_id": _utf8(revocation_id),
                "$revoked_card_id": _utf8(revoked_card_id),
                "$result_json": _json_document(_json({"cardID": revoked_card_id})),
                "$now": _timestamp(now),
            },
        )

    def _execute(self, query: str, parameters: dict[str, Any]) -> list[list[Any]]:
        result_sets = self._pool.execute_with_retries(
            query,
            parameters,
            retry_settings=ydb.RetrySettings(idempotent=True),
        )
        return [list(result_set.rows) for result_set in result_sets]

    def _transaction(self, callee: Callable[[ydb.QueryTxContext], Any]) -> Any:
        return self._pool.retry_tx_sync(
            callee,
            tx_mode=ydb.QuerySerializableReadWrite(),
            retry_settings=ydb.RetrySettings(idempotent=True),
        )

    @staticmethod
    def _tx_rows(
        tx: ydb.QueryTxContext,
        query: str,
        parameters: dict[str, Any],
    ) -> list[list[Any]]:
        with tx.execute(query, parameters=parameters) as result_sets:
            return [list(result_set.rows) for result_set in result_sets]


def _digest(value: str) -> bytes:
    return sha256(value.encode("utf-8")).digest()


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _json_value(value: Any) -> dict[str, Any]:
    try:
        if isinstance(value, bytes):
            value = value.decode("utf-8")
        if not isinstance(value, str):
            raise StorageIntegrityError
        parsed = json.loads(value)
    except (TypeError, ValueError, UnicodeDecodeError) as error:
        raise StorageIntegrityError from error
    if not isinstance(parsed, dict):
        raise StorageIntegrityError
    return parsed


def _card(value: Any) -> PersonCard:
    try:
        return PersonCard.model_validate(_json_value(value), strict=True)
    except ValidationError as error:
        raise StorageIntegrityError from error


def _stored_value(row: Any, key: str) -> Any:
    try:
        return row[key]
    except (KeyError, TypeError) as error:
        raise StorageIntegrityError from error


def _stored_text(row: Any, key: str) -> str:
    value = _stored_value(row, key)
    if not isinstance(value, str):
        raise StorageIntegrityError
    return value


def _stored_optional_text(row: Any, key: str) -> str | None:
    value = _stored_value(row, key)
    if value is not None and not isinstance(value, str):
        raise StorageIntegrityError
    return value


def _stored_bytes(row: Any, key: str, *, expected_length: int | None = None) -> bytes:
    value = _stored_value(row, key)
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise StorageIntegrityError
    stored = bytes(value)
    if expected_length is not None and len(stored) != expected_length:
        raise StorageIntegrityError
    return stored


def _stored_digest(result: Any, key: str) -> bytes:
    encoded = _stored_text(result, key)
    if len(encoded) != 64 or any(character not in "0123456789abcdef" for character in encoded):
        raise StorageIntegrityError
    try:
        digest = bytes.fromhex(encoded)
    except ValueError as error:
        raise StorageIntegrityError from error
    if len(digest) != sha256().digest_size:
        raise StorageIntegrityError
    return digest


def _stored_positive_int(row: Any, key: str) -> int:
    value = _stored_value(row, key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise StorageIntegrityError
    return value


def _stored_datetime(row: Any, key: str) -> datetime:
    value = _stored_value(row, key)
    if not isinstance(value, datetime):
        raise StorageIntegrityError
    return _as_utc(value)


def _stored_optional_datetime(row: Any, key: str) -> datetime | None:
    value = _stored_value(row, key)
    if value is None:
        return None
    if not isinstance(value, datetime):
        raise StorageIntegrityError
    return _as_utc(value)


def _stored_json(row: Any, key: str) -> dict[str, Any]:
    return _json_value(_stored_value(row, key))


def _stored_card(row: Any) -> PersonCard:
    return _card(_stored_value(row, "card_json"))


def _stored_object_key(row: Any, key: str) -> str:
    object_key = _stored_text(row, key)
    if not object_key.strip():
        raise StorageIntegrityError
    return object_key


def _object_keys(result: dict[str, Any]) -> list[str]:
    object_keys = result.get("objectKeys")
    if not isinstance(object_keys, list) or any(
        not isinstance(key, str) or not key.strip() for key in object_keys
    ):
        raise StorageIntegrityError
    return object_keys


def _stored_credential_hash(rows: list[Any]) -> bytes | None:
    if not rows:
        return None
    if len(rows) != 1:
        raise StorageIntegrityError
    return _stored_bytes(rows[0], "credential_hash", expected_length=32)


def _stored_version(row: Any) -> int:
    return _stored_positive_int(row, "version")


def _stored_revoked_card_id(row: Any) -> str:
    return _stored_text(_stored_json(row, "result_json"), "cardID")


def _stored_cursor(row: Any) -> str:
    cursor = _stored_text(row, "operation_id")
    if len(cursor) > 64:
        raise StorageIntegrityError
    return cursor


def _revocation_cursor(source_operation_id: str, revoked_card_id: str) -> str:
    payload = b"\0".join(
        (
            b"yperson.revocation.v1",
            source_operation_id.encode("utf-8"),
            revoked_card_id.encode("utf-8"),
        )
    )
    return f"rv1_{sha256(payload).hexdigest()[:60]}"


def _unseen_revocations(rows: list[Any], cursor: str | None) -> list[Any]:
    if cursor is None:
        return rows
    for index, row in enumerate(rows):
        if _stored_cursor(row) == cursor:
            return rows[index + 1 :]
    return rows


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _utf8(value: str) -> tuple[str, ydb.PrimitiveType]:
    return value, ydb.PrimitiveType.Utf8


def _optional_utf8(value: str | None) -> tuple[str | None, ydb.OptionalType]:
    return value, ydb.OptionalType(ydb.PrimitiveType.Utf8)


def _string(value: bytes) -> tuple[bytes, ydb.PrimitiveType]:
    return value, ydb.PrimitiveType.String


def _uint64(value: int) -> tuple[int, ydb.PrimitiveType]:
    return value, ydb.PrimitiveType.Uint64


def _timestamp(value: datetime) -> tuple[datetime, ydb.PrimitiveType]:
    return value, ydb.PrimitiveType.Timestamp


def _json_document(value: str) -> tuple[str, ydb.PrimitiveType]:
    return value, ydb.PrimitiveType.JsonDocument
