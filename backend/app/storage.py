"""Storage boundary for authenticated synchronization operations."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime
from typing import Final, Protocol

from .schemas import PersonCard, SyncedPerson

MAX_PENDING_PUBLIC_REPLIES: Final = 20


class InvalidCredential(Exception):
    """The installation credential did not match the stored digest."""


class StorageConflict(Exception):
    """A stable mutation could not be completed in the current state."""


class StorageIntegrityError(Exception):
    """Persisted state was malformed and cannot be trusted or exposed."""


@dataclass(frozen=True, slots=True)
class InstallationRecord:
    """Secret-safe installation state used by adapters and deterministic tests."""

    installation_id: str
    credential_hash: bytes
    apns_token: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    deleted_at: datetime | None = None


@dataclass(frozen=True, slots=True)
class PublicCardRecord:
    """A public card resolved without exposing its stored token digest."""

    owner_installation_id: str
    card: PersonCard


@dataclass(frozen=True, slots=True)
class PublicContactReplyRecord:
    """An owner-scoped pending response submitted through a public card."""

    id: str
    name: str
    email: str | None
    phone: str | None
    created_at: datetime


@dataclass(frozen=True, slots=True)
class SyncSnapshot:
    """The durable state needed to build a refresh response."""

    own_card: PersonCard | None = None
    own_card_version: int | None = None
    people: tuple[SyncedPerson, ...] = field(default_factory=tuple)
    revoked_card_ids: tuple[str, ...] = field(default_factory=tuple)
    next_cursor: str | None = None
    public_link_active: bool = False
    public_replies: Sequence[PublicContactReplyRecord] = field(default_factory=tuple)


class SyncStore(Protocol):
    """Installation-scoped persistence consumed by the sync service."""

    def authenticate_or_create(self, installation_id: str, bearer: str) -> None:
        """Create an installation digest or validate the existing digest."""

    def authenticate(self, installation_id: str, bearer: str) -> None:
        """Validate an existing installation without creating any state."""

    def publish_card(
        self,
        installation_id: str,
        operation_id: str,
        card: PersonCard,
        audio_asset_id: str | None,
    ) -> int:
        """Persist a card and return its monotonically increasing version."""

    def refresh(self, installation_id: str, cursor: str | None) -> SyncSnapshot:
        """Read the installation card, confirmed people, and revocations."""

    def prepare_exchange(
        self,
        installation_id: str,
        operation_id: str,
        method: str,
        raw_token: str,
        expires_at: datetime,
    ) -> None:
        """Persist a one-time exchange-token digest."""

    def claim_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> SyncedPerson:
        """Claim an exchange and create reciprocal confirmed connections."""

    def cancel_exchange(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
    ) -> None:
        """Durably invalidate an owned, unclaimed exchange."""

    def save_push_token(
        self,
        installation_id: str,
        operation_id: str,
        token: str | None,
    ) -> None:
        """Set or clear the installation APNs token idempotently."""

    def record_moderation(
        self,
        installation_id: str,
        operation_id: str,
        subject_id: str,
        action: str,
        category: str | None,
    ) -> None:
        """Record a report or block action without exposing its contents."""

    def delete_profile(self, installation_id: str, operation_id: str) -> list[str]:
        """Remove active profile state and return private object keys to delete."""

    def activate_public_link(
        self,
        installation_id: str,
        operation_id: str,
        raw_token: str,
        card: PersonCard,
    ) -> None:
        """Replace the owner's public link using a digest of the supplied token."""

    def revoke_public_link(self, installation_id: str, operation_id: str) -> None:
        """Remove the owner's public link idempotently."""

    def resolve_public_card(self, raw_token: str) -> PublicCardRecord | None:
        """Resolve an active public card by hashing the supplied token immediately."""

    def create_public_reply(
        self,
        raw_token: str,
        reply_id: str,
        name: str,
        email: str | None,
        phone: str | None,
        expires_at: datetime,
    ) -> None:
        """Persist a pending owner reply when the public link remains active."""

    def dismiss_public_reply(
        self,
        installation_id: str,
        operation_id: str,
        reply_id: str,
    ) -> None:
        """Idempotently delete one reply scoped to its owning installation."""

    def replay_deleted_profile(
        self,
        installation_id: str,
        operation_id: str,
        bearer: str,
    ) -> list[str] | None:
        """Authenticate and replay a completed deletion without bootstrapping state."""
