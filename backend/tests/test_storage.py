"""Persistence behavior exercised against an isolated PostgreSQL database."""

from datetime import UTC, datetime, timedelta
from hashlib import sha256

from sqlalchemy import select

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
        token_rows = session.scalars(select(ExchangeToken)).all()
        pruned = prune_expired_exchange_tokens(session, now + timedelta(minutes=10))

    assert len(token_rows) == 1
    assert token_rows[0].token_hash == expected_hash
    assert token not in token_rows[0].token_hash
    assert token_rows[0].expires_at == now + timedelta(minutes=10)
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
