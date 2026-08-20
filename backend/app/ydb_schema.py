"""Versioned, idempotent YDB schema for durable synchronization state."""

from __future__ import annotations

from typing import Final

import ydb

SCHEMA_VERSION: Final = 1

TABLE_DDL: Final[tuple[str, ...]] = (
    """
    CREATE TABLE IF NOT EXISTS installations (
        installation_id Utf8 NOT NULL,
        credential_hash String NOT NULL,
        apns_token Utf8,
        created_at Timestamp NOT NULL,
        updated_at Timestamp NOT NULL,
        deleted_at Timestamp,
        PRIMARY KEY (installation_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS cards (
        installation_id Utf8 NOT NULL,
        card_id Utf8 NOT NULL,
        version Uint64 NOT NULL,
        card_json JsonDocument NOT NULL,
        audio_asset_id Utf8,
        published_at Timestamp NOT NULL,
        updated_at Timestamp NOT NULL,
        PRIMARY KEY (installation_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS connections (
        owner_installation_id Utf8 NOT NULL,
        peer_installation_id Utf8 NOT NULL,
        status Utf8 NOT NULL,
        created_at Timestamp NOT NULL,
        updated_at Timestamp NOT NULL,
        PRIMARY KEY (owner_installation_id, peer_installation_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS exchange_claims (
        token_hash String NOT NULL,
        issuer_installation_id Utf8 NOT NULL,
        method Utf8 NOT NULL,
        expires_at Timestamp NOT NULL,
        claimed_by_installation_id Utf8,
        PRIMARY KEY (token_hash)
    ) WITH (
        TTL = Interval("PT0S") ON expires_at
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS media_assets (
        asset_id Utf8 NOT NULL,
        owner_installation_id Utf8 NOT NULL,
        object_key Utf8 NOT NULL,
        content_type Utf8 NOT NULL,
        size_bytes Uint64,
        duration_ms Uint64,
        state Utf8 NOT NULL,
        created_at Timestamp NOT NULL,
        updated_at Timestamp NOT NULL,
        PRIMARY KEY (asset_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS moderation_actions (
        reporter_installation_id Utf8 NOT NULL,
        subject_installation_id Utf8 NOT NULL,
        action_id Utf8 NOT NULL,
        action Utf8 NOT NULL,
        category Utf8,
        created_at Timestamp NOT NULL,
        PRIMARY KEY (reporter_installation_id, subject_installation_id, action_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS operations (
        installation_id Utf8 NOT NULL,
        operation_id Utf8 NOT NULL,
        operation_type Utf8 NOT NULL,
        result_json JsonDocument NOT NULL,
        completed_at Timestamp NOT NULL,
        PRIMARY KEY (installation_id, operation_id)
    )
    """,
)


def apply_schema(pool: ydb.QuerySessionPool) -> int:
    """Apply every schema statement and return the completed statement count."""

    completed = 0
    retry_settings = ydb.RetrySettings(idempotent=True)
    for statement in TABLE_DDL:
        pool.execute_with_retries(statement, retry_settings=retry_settings)
        completed += 1
    return completed
