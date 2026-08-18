"""Transactional PostgreSQL storage for YPerson's approved backend state."""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from typing import cast
from uuid import uuid4

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    create_engine,
    delete,
    func,
    select,
)
from sqlalchemy.dialects.postgresql import JSONB, insert
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

from app.settings import Settings

EXCHANGE_TOKEN_LIFETIME = timedelta(minutes=10)
MODERATION_CATEGORIES = frozenset({"spam", "abusive_content", "impersonation"})


class Base(DeclarativeBase):
    """Base metadata shared by Alembic and the application's models."""


class Profile(Base):
    """The durable state associated with one installed copy of the application."""

    __tablename__ = "profiles"

    installation_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    card: Mapped[dict[str, object] | None] = mapped_column(JSONB, nullable=True)
    apns_token: Mapped[str | None] = mapped_column(String(256), nullable=True)
    update_count: Mapped[int] = mapped_column(
        Integer, nullable=False, default=0, server_default="0"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class ExchangeToken(Base):
    """A hashed, short-lived record of an exchange claim."""

    __tablename__ = "exchange_tokens"

    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    owner_installation_id: Mapped[str] = mapped_column(
        String(128), ForeignKey("profiles.installation_id", ondelete="CASCADE"), nullable=False
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class ModerationAction(Base):
    """A report recorded without free-form local notes."""

    __tablename__ = "moderation_actions"
    __table_args__ = (
        CheckConstraint(
            "category IS NULL OR category IN ('spam', 'abusive_content', 'impersonation')",
            name="ck_moderation_actions_category",
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    reporter_installation_id: Mapped[str] = mapped_column(
        String(128), ForeignKey("profiles.installation_id", ondelete="CASCADE"), nullable=False
    )
    category: Mapped[str | None] = mapped_column(String(32), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class BlockedConnection(Base):
    """An installation-scoped block represented by an opaque identifier."""

    __tablename__ = "blocked_connections"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    installation_id: Mapped[str] = mapped_column(
        String(128), ForeignKey("profiles.installation_id", ondelete="CASCADE"), nullable=False
    )
    blocked_reference: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


@dataclass(frozen=True)
class ProfileSnapshot:
    """The route-safe representation of a profile after a storage operation."""

    installation_id: str
    card: dict[str, object] | None
    apns_token: str | None
    update_count: int


def create_database_engine(settings: Settings) -> Engine:
    """Build an app-owned engine rather than retaining a process-global pool."""

    return create_engine(
        settings.database_url,
        pool_pre_ping=True,
        pool_size=settings.database_pool_size,
        pool_timeout=settings.database_pool_timeout_seconds,
    )


def create_session_factory(settings: Settings) -> tuple[Engine, sessionmaker[Session]]:
    """Create the engine and session factory for one FastAPI application instance."""

    engine = create_database_engine(settings)
    return engine, sessionmaker(engine, expire_on_commit=False)


def ensure_profile(session: Session, installation_id: str) -> ProfileSnapshot:
    """Create an empty profile when absent and return its public storage snapshot."""

    session.execute(
        insert(Profile)
        .values(installation_id=installation_id)
        .on_conflict_do_nothing(index_elements=[Profile.installation_id])
    )
    session.flush()
    profile = session.scalar(select(Profile).where(Profile.installation_id == installation_id))
    assert profile is not None
    return _snapshot(profile)


def publish_card(
    session: Session, installation_id: str, card: dict[str, object] | None
) -> ProfileSnapshot:
    """Persist a validated card without opening or committing a transaction."""

    profile = _profile(session, installation_id)
    profile.card = card
    profile.updated_at = _utc_now()
    session.flush()
    return _snapshot(profile)


def store_exchange_claim(session: Session, installation_id: str, token: str, now: datetime) -> None:
    """Store only a hash of a claimed exchange token, expiring it in ten minutes."""

    current_time = _as_utc(now)
    prune_expired_exchange_tokens(session, current_time)
    _profile(session, installation_id)
    token_hash = sha256(token.encode()).hexdigest()
    expires_at = current_time + EXCHANGE_TOKEN_LIFETIME
    session.execute(
        insert(ExchangeToken)
        .values(
            token_hash=token_hash,
            owner_installation_id=installation_id,
            expires_at=expires_at,
            claimed_at=current_time,
        )
        .on_conflict_do_update(
            index_elements=[ExchangeToken.token_hash],
            set_={
                "owner_installation_id": installation_id,
                "expires_at": expires_at,
                "claimed_at": current_time,
            },
        )
    )
    session.flush()


def set_push_token(session: Session, installation_id: str, token: str | None) -> ProfileSnapshot:
    """Store or remove the current APNs device token for an installation."""

    profile = _profile(session, installation_id)
    profile.apns_token = token
    profile.updated_at = _utc_now()
    session.flush()
    return _snapshot(profile)


def record_report(session: Session, installation_id: str, category: str | None) -> None:
    """Record a fixed moderation category without retaining report text."""

    if category is not None and category not in MODERATION_CATEGORIES:
        raise ValueError("unsupported moderation category")
    _profile(session, installation_id)
    session.add(
        ModerationAction(
            id=str(uuid4()), reporter_installation_id=installation_id, category=category
        )
    )
    session.flush()


def record_block(session: Session, installation_id: str, now: datetime) -> None:
    """Record an opaque block reference for an installation."""

    current_time = _as_utc(now)
    _profile(session, installation_id)
    session.add(
        BlockedConnection(
            id=str(uuid4()),
            installation_id=installation_id,
            blocked_reference=sha256(str(uuid4()).encode()).hexdigest(),
            created_at=current_time,
        )
    )
    session.flush()


def delete_profile(session: Session, installation_id: str) -> None:
    """Delete a profile; PostgreSQL cascades all rows owned by it."""

    profile = session.get(Profile, installation_id)
    if profile is not None:
        session.delete(profile)
        session.flush()


def prune_expired_exchange_tokens(session: Session, now: datetime) -> int:
    """Remove expired exchange-token hashes in the caller's transaction."""

    result = session.execute(delete(ExchangeToken).where(ExchangeToken.expires_at <= _as_utc(now)))
    session.flush()
    return result.rowcount or 0


def database_is_ready(session: Session) -> bool:
    """Return database reachability without exposing database errors to a route."""

    try:
        session.execute(select(1))
    except SQLAlchemyError:
        return False
    return True


def _profile(session: Session, installation_id: str) -> Profile:
    ensure_profile(session, installation_id)
    profile = session.get(Profile, installation_id)
    assert profile is not None
    return profile


def _snapshot(profile: Profile) -> ProfileSnapshot:
    card = cast(dict[str, object] | None, profile.card)
    return ProfileSnapshot(
        installation_id=profile.installation_id,
        card=dict(card) if card is not None else None,
        apns_token=profile.apns_token,
        update_count=profile.update_count,
    )


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("datetime must be timezone-aware")
    return value.astimezone(UTC)


def _utc_now() -> datetime:
    return datetime.now(UTC)
