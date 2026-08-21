"""Versioned, idempotent YDB schema for durable synchronization state."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Final

import ydb

SCHEMA_VERSION: Final = 2


class SchemaMismatch(RuntimeError):
    """The deployed schema does not match the application schema version."""


@dataclass(frozen=True, slots=True)
class TableSchema:
    columns: tuple[tuple[str, object], ...]
    primary_key: tuple[str, ...]
    indexes: tuple[str, ...] = ()


_UTF8_OPTIONAL = ydb.OptionalType(ydb.PrimitiveType.Utf8)
_UINT64_OPTIONAL = ydb.OptionalType(ydb.PrimitiveType.Uint64)
_TIMESTAMP_OPTIONAL = ydb.OptionalType(ydb.PrimitiveType.Timestamp)

EXPECTED_TABLES: Final[dict[str, TableSchema]] = {
    "installations": TableSchema(
        columns=(
            ("installation_id", ydb.PrimitiveType.Utf8),
            ("credential_hash", ydb.PrimitiveType.String),
            ("apns_token", _UTF8_OPTIONAL),
            ("created_at", ydb.PrimitiveType.Timestamp),
            ("updated_at", ydb.PrimitiveType.Timestamp),
            ("deleted_at", _TIMESTAMP_OPTIONAL),
        ),
        primary_key=("installation_id",),
    ),
    "cards": TableSchema(
        columns=(
            ("installation_id", ydb.PrimitiveType.Utf8),
            ("card_id", ydb.PrimitiveType.Utf8),
            ("version", ydb.PrimitiveType.Uint64),
            ("card_json", ydb.PrimitiveType.JsonDocument),
            ("audio_asset_id", _UTF8_OPTIONAL),
            ("published_at", ydb.PrimitiveType.Timestamp),
            ("updated_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=("installation_id",),
    ),
    "connections": TableSchema(
        columns=(
            ("owner_installation_id", ydb.PrimitiveType.Utf8),
            ("peer_installation_id", ydb.PrimitiveType.Utf8),
            ("status", ydb.PrimitiveType.Utf8),
            ("created_at", ydb.PrimitiveType.Timestamp),
            ("updated_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=("owner_installation_id", "peer_installation_id"),
    ),
    "exchange_claims": TableSchema(
        columns=(
            ("token_hash", ydb.PrimitiveType.String),
            ("issuer_installation_id", ydb.PrimitiveType.Utf8),
            ("method", ydb.PrimitiveType.Utf8),
            ("expires_at", ydb.PrimitiveType.Timestamp),
            ("claimed_by_installation_id", _UTF8_OPTIONAL),
        ),
        primary_key=("token_hash",),
    ),
    "media_assets": TableSchema(
        columns=(
            ("asset_id", ydb.PrimitiveType.Utf8),
            ("owner_installation_id", ydb.PrimitiveType.Utf8),
            ("object_key", ydb.PrimitiveType.Utf8),
            ("content_type", ydb.PrimitiveType.Utf8),
            ("size_bytes", _UINT64_OPTIONAL),
            ("duration_ms", _UINT64_OPTIONAL),
            ("state", ydb.PrimitiveType.Utf8),
            ("created_at", ydb.PrimitiveType.Timestamp),
            ("updated_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=("asset_id",),
    ),
    "moderation_actions": TableSchema(
        columns=(
            ("reporter_installation_id", ydb.PrimitiveType.Utf8),
            ("subject_installation_id", ydb.PrimitiveType.Utf8),
            ("action_id", ydb.PrimitiveType.Utf8),
            ("action", ydb.PrimitiveType.Utf8),
            ("category", _UTF8_OPTIONAL),
            ("created_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=(
            "reporter_installation_id",
            "subject_installation_id",
            "action_id",
        ),
    ),
    "operations": TableSchema(
        columns=(
            ("installation_id", ydb.PrimitiveType.Utf8),
            ("operation_id", ydb.PrimitiveType.Utf8),
            ("operation_type", ydb.PrimitiveType.Utf8),
            ("result_json", ydb.PrimitiveType.JsonDocument),
            ("completed_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=("installation_id", "operation_id"),
    ),
    "public_links": TableSchema(
        columns=(
            ("owner_installation_id", ydb.PrimitiveType.Utf8),
            ("token_hash", ydb.PrimitiveType.String),
            ("card_json", ydb.PrimitiveType.JsonDocument),
            ("created_at", ydb.PrimitiveType.Timestamp),
            ("updated_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=("owner_installation_id",),
        indexes=("by_token",),
    ),
    "public_replies": TableSchema(
        columns=(
            ("owner_installation_id", ydb.PrimitiveType.Utf8),
            ("reply_id", ydb.PrimitiveType.Utf8),
            ("public_token_hash", ydb.PrimitiveType.String),
            ("name", ydb.PrimitiveType.Utf8),
            ("email", _UTF8_OPTIONAL),
            ("phone", _UTF8_OPTIONAL),
            ("created_at", ydb.PrimitiveType.Timestamp),
            ("expires_at", ydb.PrimitiveType.Timestamp),
        ),
        primary_key=("owner_installation_id", "reply_id"),
    ),
}

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
    """
    CREATE TABLE IF NOT EXISTS public_links (
        owner_installation_id Utf8 NOT NULL,
        token_hash String NOT NULL,
        card_json JsonDocument NOT NULL,
        created_at Timestamp NOT NULL,
        updated_at Timestamp NOT NULL,
        PRIMARY KEY (owner_installation_id),
        INDEX by_token GLOBAL ON (token_hash)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS public_replies (
        owner_installation_id Utf8 NOT NULL,
        reply_id Utf8 NOT NULL,
        public_token_hash String NOT NULL,
        name Utf8 NOT NULL,
        email Utf8,
        phone Utf8,
        created_at Timestamp NOT NULL,
        expires_at Timestamp NOT NULL,
        PRIMARY KEY (owner_installation_id, reply_id)
    ) WITH (
        TTL = Interval("PT0S") ON expires_at
    )
    """,
)


def apply_schema(
    pool: ydb.QuerySessionPool,
    describe_table: Callable[[str], object],
) -> int:
    """Apply schema version 2 and verify every table's exact structure."""

    completed = 0
    retry_settings = ydb.RetrySettings(idempotent=True)
    for statement in TABLE_DDL:
        pool.execute_with_retries(statement, retry_settings=retry_settings)
        completed += 1
    _verify_schema(describe_table)
    return completed


def _verify_schema(describe_table: Callable[[str], object]) -> None:
    for table_name, expected in EXPECTED_TABLES.items():
        description = describe_table(table_name)
        actual_columns = {
            column.name: column.type for column in getattr(description, "columns", ())
        }
        expected_columns = dict(expected.columns)
        primary_key = tuple(getattr(description, "primary_key", ()))
        index_names = tuple(index.name for index in getattr(description, "indexes", ()))
        if (
            actual_columns.keys() != expected_columns.keys()
            or any(actual_columns[name] != column_type for name, column_type in expected.columns)
            or primary_key != expected.primary_key
            or any(index_name not in index_names for index_name in expected.indexes)
        ):
            raise SchemaMismatch(f"incompatible YDB schema version {SCHEMA_VERSION}: {table_name}")
