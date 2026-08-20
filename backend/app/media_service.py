"""Authorization and validation for private audio greeting objects."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from typing import Literal, Protocol

from .object_storage import ObjectStorage
from .schemas import AudioAsset, AudioUpload

AUDIO_CONTENT_TYPE = "audio/mp4"
MAX_AUDIO_SIZE_BYTES = 1_048_576
MAX_AUDIO_DURATION_MS = 10_000
SIGNED_URL_LIFETIME_SECONDS = 300


class MediaForbidden(Exception):
    """The requester is not allowed to access this private media object."""


class MediaInvalid(Exception):
    """The media request or uploaded object does not match the approved contract."""


@dataclass(frozen=True, slots=True)
class MediaRecord:
    """Durable metadata for one private audio object."""

    asset_id: str
    owner_installation_id: str
    object_key: str
    content_type: str
    size_bytes: int
    duration_ms: int
    state: Literal["pending", "ready", "deleting"]


class MediaStore(Protocol):
    """Media-specific durable operations implemented by the YDB adapter."""

    def prepare_media(
        self,
        owner_installation_id: str,
        operation_id: str,
        asset_id: str,
        object_key: str,
        size_bytes: int,
        duration_ms: int,
    ) -> MediaRecord: ...

    def media_for_owner(
        self,
        owner_installation_id: str,
        asset_id: str,
    ) -> MediaRecord | None: ...

    def mark_media_ready(
        self,
        owner_installation_id: str,
        asset_id: str,
        content_type: str,
        size_bytes: int,
    ) -> MediaRecord: ...

    def authorized_ready_media(
        self,
        requester_installation_id: str,
        asset_id: str,
    ) -> MediaRecord | None: ...

    def authorized_ready_media_for_owner(
        self,
        requester_installation_id: str,
        owner_installation_id: str,
    ) -> MediaRecord | None: ...


class MediaService:
    """Issue five-minute URLs only around verified, authorized audio state."""

    def __init__(
        self,
        store: MediaStore,
        object_storage: ObjectStorage,
        *,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._store = store
        self._objects = object_storage
        self._clock = clock or (lambda: datetime.now(UTC))

    def prepare_upload(
        self,
        owner_installation_id: str,
        operation_id: str,
        size_bytes: int,
        duration_ms: int,
    ) -> AudioUpload:
        _validate_audio_bounds(size_bytes, duration_ms)
        asset_id = _asset_id(owner_installation_id, operation_id)
        object_key = _object_key(owner_installation_id, asset_id)
        record = self._store.prepare_media(
            owner_installation_id,
            operation_id,
            asset_id,
            object_key,
            size_bytes,
            duration_ms,
        )
        if (
            record.asset_id != asset_id
            or record.owner_installation_id != owner_installation_id
            or record.object_key != object_key
            or record.content_type != AUDIO_CONTENT_TYPE
            or record.size_bytes != size_bytes
            or record.duration_ms != duration_ms
            or record.state != "pending"
        ):
            raise MediaInvalid
        return AudioUpload(
            assetID=record.asset_id,
            uploadURL=self._objects.create_upload_url(
                record.object_key,
                AUDIO_CONTENT_TYPE,
                SIGNED_URL_LIFETIME_SECONDS,
            ),
            expiresAt=self._expires_at(),
        )

    def finalize_upload(self, owner_installation_id: str, asset_id: str) -> MediaRecord:
        record = self._store.media_for_owner(owner_installation_id, asset_id)
        if record is None or record.state not in {"pending", "ready"}:
            raise MediaInvalid
        if record.state == "ready":
            return record
        metadata = self._objects.head(record.object_key)
        if (
            metadata.content_type != AUDIO_CONTENT_TYPE
            or metadata.size_bytes != record.size_bytes
            or metadata.size_bytes > MAX_AUDIO_SIZE_BYTES
        ):
            raise MediaInvalid
        return self._store.mark_media_ready(
            owner_installation_id,
            asset_id,
            metadata.content_type,
            metadata.size_bytes,
        )

    def download_for(self, requester_installation_id: str, asset_id: str) -> AudioAsset:
        record = self._store.authorized_ready_media(requester_installation_id, asset_id)
        if record is None:
            raise MediaForbidden
        return self._signed_download(record)

    def download_for_owner(
        self,
        requester_installation_id: str,
        owner_installation_id: str,
    ) -> AudioAsset | None:
        record = self._store.authorized_ready_media_for_owner(
            requester_installation_id,
            owner_installation_id,
        )
        return self._signed_download(record) if record is not None else None

    def delete_objects(self, object_keys: Sequence[str]) -> None:
        for object_key in object_keys:
            self._objects.delete(object_key)

    def _signed_download(self, record: MediaRecord) -> AudioAsset:
        if record.state != "ready" or record.content_type != AUDIO_CONTENT_TYPE:
            raise MediaForbidden
        return AudioAsset(
            assetID=record.asset_id,
            downloadURL=self._objects.create_download_url(
                record.object_key,
                SIGNED_URL_LIFETIME_SECONDS,
            ),
            expiresAt=self._expires_at(),
        )

    def _expires_at(self) -> datetime:
        return self._clock() + timedelta(seconds=SIGNED_URL_LIFETIME_SECONDS)


def _validate_audio_bounds(size_bytes: int, duration_ms: int) -> None:
    if (
        isinstance(size_bytes, bool)
        or not 1 <= size_bytes <= MAX_AUDIO_SIZE_BYTES
        or isinstance(duration_ms, bool)
        or not 1 <= duration_ms <= MAX_AUDIO_DURATION_MS
    ):
        raise MediaInvalid


def _asset_id(owner_installation_id: str, operation_id: str) -> str:
    payload = f"yperson.audio.v1\0{owner_installation_id}\0{operation_id}".encode()
    return f"aud_{sha256(payload).hexdigest()[:40]}"


def _object_key(owner_installation_id: str, asset_id: str) -> str:
    installation_hash = sha256(owner_installation_id.encode()).hexdigest()
    return f"audio/{installation_hash}/{asset_id}.m4a"
