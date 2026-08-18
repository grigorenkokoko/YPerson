"""Persistence behavior exercised against an isolated PostgreSQL database."""

import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta, timezone
from hashlib import sha256
from pathlib import Path
from threading import Event

import pytest
from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError

from app.storage import (
    BlockedConnection,
    ExchangeToken,
    ModerationAction,
    Profile,
    delete_profile,
    ensure_profile,
    prune_expired_exchange_tokens,
    publish_card,
    record_block,
    record_report,
    set_push_token,
    store_exchange_claim,
)


def test_new_profile_has_zero_updates(session_factory) -> None:
    with session_factory.begin() as session:
        assert session.scalar(text("SELECT current_schema()")).startswith("yperson_test_")
        profile = ensure_profile(session, "installation-new")

    assert profile.installation_id == "installation-new"
    assert profile.card is None
    assert profile.apns_token is None
    assert profile.update_count == 0


def test_published_card_survives_a_new_session(session_factory) -> None:
    card = {"id": "card-1", "name": "Ada Lovelace"}
    with session_factory.begin() as session:
        publish_card(session, "installation-card", card)

    with session_factory.begin() as session:
        profile = ensure_profile(session, "installation-card")

    assert profile.card == card


def test_apns_token_can_be_added_and_removed(session_factory) -> None:
    with session_factory.begin() as session:
        added = set_push_token(session, "installation-push", "apns-device-token")

    with session_factory.begin() as session:
        removed = set_push_token(session, "installation-push", None)

    assert added.apns_token == "apns-device-token"
    assert removed.apns_token is None


def test_exchange_token_is_hashed_and_expires_after_ten_minutes(session_factory) -> None:
    token = "raw-exchange-token"
    now = datetime(2026, 8, 18, 12, 0, tzinfo=UTC)
    expected_hash = sha256(token.encode()).hexdigest()

    with session_factory.begin() as session:
        store_exchange_claim(session, "installation-exchange", token, now)

    with session_factory.begin() as session:
        token_row = session.execute(text("SELECT * FROM exchange_tokens")).mappings().one()
        pruned = prune_expired_exchange_tokens(session, now + timedelta(minutes=10))

    assert expected_hash in token_row.values()
    assert all(token not in str(value) for value in token_row.values())
    assert token_row["expires_at"] == now + timedelta(minutes=10)
    assert pruned == 1


def test_report_and_block_are_durable(session_factory) -> None:
    now = datetime(2026, 8, 18, 12, 0, tzinfo=UTC)
    with session_factory.begin() as session:
        record_report(session, "installation-moderation", "spam")
        record_block(session, "installation-moderation", now)

    with session_factory.begin() as session:
        report = session.scalar(select(ModerationAction))
        block = session.scalar(select(BlockedConnection))

    assert report is not None
    assert report.reporter_installation_id == "installation-moderation"
    assert report.category == "spam"
    assert block is not None
    assert block.installation_id == "installation-moderation"
    assert block.blocked_reference


def test_delete_profile_removes_owned_rows(session_factory) -> None:
    now = datetime(2026, 8, 18, 12, 0, tzinfo=UTC)
    with session_factory.begin() as session:
        publish_card(session, "installation-delete", {"id": "card-delete"})
        store_exchange_claim(session, "installation-delete", "delete-exchange-token", now)
        record_report(session, "installation-delete", None)
        record_block(session, "installation-delete", now)
        delete_profile(session, "installation-delete")

    with session_factory.begin() as session:
        assert session.scalar(select(Profile)) is None
        assert session.scalar(select(ExchangeToken)) is None
        assert session.scalar(select(ModerationAction)) is None
        assert session.scalar(select(BlockedConnection)) is None


def test_alembic_accepts_percent_encoded_database_url() -> None:
    database_url = "postgresql+psycopg://grigornkokoko:p%40ss@127.0.0.1:55432/yperson_test"
    environment = os.environ | {"DATABASE_URL": database_url}
    result = subprocess.run(
        [sys.executable, "-m", "alembic", "current"],
        cwd=Path(__file__).parents[1],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "20260818_0001 (head)" in result.stdout


def test_concurrent_first_profile_creation_succeeds(session_factory) -> None:
    allow_first_commit = Event()
    first_inserted = Event()
    second_started = Event()
    second_finished = Event()

    def first_writer() -> str:
        with session_factory.begin() as session:
            profile = ensure_profile(session, "installation-concurrent")
            first_inserted.set()
            assert allow_first_commit.wait(timeout=5)
            return profile.installation_id

    def second_writer() -> str:
        assert first_inserted.wait(timeout=5)
        with session_factory.begin() as session:
            second_started.set()
            profile = ensure_profile(session, "installation-concurrent")
            second_finished.set()
            return profile.installation_id

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(first_writer)
        second = executor.submit(second_writer)
        assert first_inserted.wait(timeout=5)
        assert second_started.wait(timeout=5)
        assert not second_finished.wait(timeout=0.2)
        allow_first_commit.set()
        assert first.result(timeout=5) == "installation-concurrent"
        assert second.result(timeout=5) == "installation-concurrent"

    with session_factory.begin() as session:
        assert len(session.scalars(select(Profile)).all()) == 1


def test_concurrent_exchange_claims_complete_with_last_writer_winning(session_factory) -> None:
    now = datetime(2026, 8, 18, 12, 0, tzinfo=UTC)
    allow_first_commit = Event()
    first_inserted = Event()
    second_started = Event()
    second_finished = Event()

    with session_factory.begin() as session:
        ensure_profile(session, "installation-first")
        ensure_profile(session, "installation-second")

    def first_writer() -> None:
        with session_factory.begin() as session:
            store_exchange_claim(session, "installation-first", "concurrent-token", now)
            first_inserted.set()
            assert allow_first_commit.wait(timeout=5)

    def second_writer() -> None:
        assert first_inserted.wait(timeout=5)
        with session_factory.begin() as session:
            second_started.set()
            store_exchange_claim(session, "installation-second", "concurrent-token", now)
            second_finished.set()

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(first_writer)
        second = executor.submit(second_writer)
        assert first_inserted.wait(timeout=5)
        assert second_started.wait(timeout=5)
        assert not second_finished.wait(timeout=0.2)
        allow_first_commit.set()
        first.result(timeout=5)
        second.result(timeout=5)

    with session_factory.begin() as session:
        claim = session.scalar(select(ExchangeToken))

    assert claim is not None
    assert claim.owner_installation_id == "installation-second"
    assert claim.token_hash == sha256(b"concurrent-token").hexdigest()
    assert claim.expires_at == now + timedelta(minutes=10)


def test_report_categories_are_fixed_and_arbitrary_values_are_not_durable(session_factory) -> None:
    with (
        session_factory.begin() as session,
        pytest.raises(ValueError, match="unsupported moderation category"),
    ):
        record_report(session, "installation-invalid-report", "free-form report text")

    with session_factory.begin() as session:
        ensure_profile(session, "installation-invalid-direct")

    with session_factory() as session:
        session.add(
            ModerationAction(
                id="00000000-0000-0000-0000-000000000001",
                reporter_installation_id="installation-invalid-direct",
                category="free-form report text",
            )
        )
        with pytest.raises(IntegrityError):
            session.flush()
        session.rollback()

    with session_factory.begin() as session:
        assert session.scalar(select(ModerationAction)) is None


def test_storage_rejects_naive_datetimes_and_normalizes_aware_values(session_factory) -> None:
    naive = datetime(2026, 8, 18, 12, 0)  # noqa: DTZ001 - this is the invalid input under test.
    moscow_time = datetime(2026, 8, 18, 15, 0, tzinfo=timezone(timedelta(hours=3)))

    with session_factory.begin() as session:
        with pytest.raises(ValueError, match="timezone-aware"):
            store_exchange_claim(session, "installation-naive", "naive-token", naive)
        with pytest.raises(ValueError, match="timezone-aware"):
            record_block(session, "installation-naive", naive)
        store_exchange_claim(session, "installation-aware", "aware-token", moscow_time)
        record_block(session, "installation-aware", moscow_time)

    with session_factory.begin() as session:
        claim = session.scalar(select(ExchangeToken))
        block = session.scalar(select(BlockedConnection))

    assert claim is not None
    assert claim.expires_at == datetime(2026, 8, 18, 12, 10, tzinfo=UTC)
    assert block is not None
    assert block.created_at == datetime(2026, 8, 18, 12, 0, tzinfo=UTC)
