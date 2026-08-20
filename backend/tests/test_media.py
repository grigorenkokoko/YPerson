from __future__ import annotations

from dataclasses import replace
from datetime import UTC, datetime

import pytest

from app.media_service import (
    MediaForbidden,
    MediaInvalid,
    MediaRecord,
    MediaService,
)
from app.object_storage import ObjectMetadata


class FakeMediaStore:
    def __init__(self) -> None:
        self.records: dict[str, MediaRecord] = {}
        self.operations: dict[tuple[str, str], str] = {}
        self.connections: set[tuple[str, str]] = set()

    def prepare_media(
        self,
        owner_installation_id: str,
        operation_id: str,
        asset_id: str,
        object_key: str,
        size_bytes: int,
        duration_ms: int,
    ) -> MediaRecord:
        operation_key = (owner_installation_id, operation_id)
        existing_asset_id = self.operations.get(operation_key)
        if existing_asset_id is not None:
            return self.records[existing_asset_id]
        record = MediaRecord(
            asset_id=asset_id,
            owner_installation_id=owner_installation_id,
            object_key=object_key,
            content_type="audio/mp4",
            size_bytes=size_bytes,
            duration_ms=duration_ms,
            state="pending",
        )
        self.records[asset_id] = record
        self.operations[operation_key] = asset_id
        return record

    def media_for_owner(self, owner_installation_id: str, asset_id: str) -> MediaRecord | None:
        record = self.records.get(asset_id)
        return record if record and record.owner_installation_id == owner_installation_id else None

    def mark_media_ready(
        self,
        owner_installation_id: str,
        asset_id: str,
        content_type: str,
        size_bytes: int,
    ) -> MediaRecord:
        record = self.media_for_owner(owner_installation_id, asset_id)
        if record is None:
            raise AssertionError("missing media")
        ready = replace(
            record,
            content_type=content_type,
            size_bytes=size_bytes,
            state="ready",
        )
        self.records[asset_id] = ready
        return ready

    def authorized_ready_media(
        self,
        requester_installation_id: str,
        asset_id: str,
    ) -> MediaRecord | None:
        record = self.records.get(asset_id)
        if record is None or record.state != "ready":
            return None
        owner = record.owner_installation_id
        if requester_installation_id == owner:
            return record
        if (
            requester_installation_id,
            owner,
        ) in self.connections and (owner, requester_installation_id) in self.connections:
            return record
        return None

    def authorized_ready_media_for_owner(
        self,
        requester_installation_id: str,
        owner_installation_id: str,
    ) -> MediaRecord | None:
        records = [
            record
            for record in self.records.values()
            if record.owner_installation_id == owner_installation_id and record.state == "ready"
        ]
        if not records:
            return None
        return self.authorized_ready_media(requester_installation_id, records[0].asset_id)


class FakeObjectStorage:
    def __init__(self) -> None:
        self.metadata: dict[str, ObjectMetadata] = {}
        self.upload_expiry: int | None = None
        self.download_expiry: int | None = None

    def create_upload_url(
        self,
        object_key: str,
        content_type: str,
        expires_seconds: int = 300,
    ) -> str:
        assert content_type == "audio/mp4"
        self.upload_expiry = expires_seconds
        return f"https://storage.example/{object_key}?put"

    def create_download_url(self, object_key: str, expires_seconds: int = 300) -> str:
        self.download_expiry = expires_seconds
        return f"https://storage.example/{object_key}?get"

    def head(self, object_key: str) -> ObjectMetadata:
        return self.metadata[object_key]

    def delete(self, object_key: str) -> None:
        self.metadata.pop(object_key, None)


def test_audio_download_is_signed_only_after_verified_upload_for_confirmed_connection() -> None:
    store = FakeMediaStore()
    objects = FakeObjectStorage()
    service = MediaService(
        store,
        objects,
        clock=lambda: datetime(2026, 8, 20, 12, 0, tzinfo=UTC),
    )

    upload = service.prepare_upload("installation-owner", "op-audio-1", 240_000, 8_000)
    assert str(upload.uploadURL).startswith("https://")
    assert objects.upload_expiry == 300

    record = store.media_for_owner("installation-owner", upload.assetID)
    assert record is not None
    objects.metadata[record.object_key] = ObjectMetadata(
        content_type="audio/mpeg",
        size_bytes=240_000,
    )
    with pytest.raises(MediaInvalid):
        service.finalize_upload("installation-owner", upload.assetID)
    assert store.records[upload.assetID].state == "pending"

    objects.metadata[record.object_key] = ObjectMetadata(
        content_type="audio/mp4",
        size_bytes=240_000,
    )
    service.finalize_upload("installation-owner", upload.assetID)
    store.connections.update(
        {
            ("installation-owner", "installation-peer"),
            ("installation-peer", "installation-owner"),
        }
    )

    authorized = service.download_for("installation-peer", upload.assetID)
    assert str(authorized.downloadURL).startswith("https://")
    assert authorized.expiresAt == datetime(2026, 8, 20, 12, 5, tzinfo=UTC)
    assert objects.download_expiry == 300
    with pytest.raises(MediaForbidden):
        service.download_for("installation-stranger", upload.assetID)
