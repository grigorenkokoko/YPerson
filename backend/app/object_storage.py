"""Private Yandex Object Storage adapter for short-lived audio access."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

S3_ENDPOINT = "https://storage.yandexcloud.net"
S3_REGION = "ru-central1"


@dataclass(frozen=True, slots=True)
class ObjectMetadata:
    """Trusted subset of metadata returned by a private object HEAD."""

    content_type: str
    size_bytes: int


class ObjectStorage:
    """Create private signed URLs and inspect/delete private objects."""

    def __init__(
        self,
        bucket: str,
        access_key_id: str,
        secret_access_key: str,
        *,
        client: Any | None = None,
    ) -> None:
        self._bucket = bucket
        if client is None:
            import boto3
            from botocore.client import Config

            client = boto3.client(
                "s3",
                endpoint_url=S3_ENDPOINT,
                region_name=S3_REGION,
                aws_access_key_id=access_key_id,
                aws_secret_access_key=secret_access_key,
                config=Config(signature_version="s3v4"),
            )
        self._client = client

    def create_upload_url(
        self,
        object_key: str,
        content_type: str,
        expires_seconds: int = 300,
    ) -> str:
        return self._client.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self._bucket,
                "Key": object_key,
                "ContentType": content_type,
            },
            ExpiresIn=expires_seconds,
            HttpMethod="PUT",
        )

    def create_download_url(self, object_key: str, expires_seconds: int = 300) -> str:
        return self._client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": object_key},
            ExpiresIn=expires_seconds,
            HttpMethod="GET",
        )

    def head(self, object_key: str) -> ObjectMetadata:
        response = self._client.head_object(Bucket=self._bucket, Key=object_key)
        content_type = response.get("ContentType")
        size_bytes = response.get("ContentLength")
        if (
            not isinstance(content_type, str)
            or isinstance(size_bytes, bool)
            or not isinstance(size_bytes, int)
            or size_bytes < 0
        ):
            raise ValueError("invalid object metadata")
        return ObjectMetadata(content_type=content_type, size_bytes=size_bytes)

    def delete(self, object_key: str) -> None:
        self._client.delete_object(Bucket=self._bucket, Key=object_key)
