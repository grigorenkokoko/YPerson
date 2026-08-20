"""Storage boundary for authenticated synchronization operations."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Protocol

from .schemas import PersonCard, SyncedPerson


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
class SyncSnapshot:
    """The durable state needed to build a refresh response."""

    own_card: PersonCard | None = None
    own_card_version: int | None = None
    people: tuple[SyncedPerson, ...] = field(default_factory=tuple)
    revoked_card_ids: tuple[str, ...] = field(default_factory=tuple)
    next_cursor: str | None = None


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

    def replay_deleted_profile(
        self,
        installation_id: str,
        operation_id: str,
        bearer: str,
    ) -> list[str] | None:
        """Authenticate and replay a completed deletion without bootstrapping state."""
