"""Strict request and response schemas for the versioned iOS wire contract."""

from collections.abc import Mapping
from datetime import datetime
from enum import Enum
from typing import Any, Literal

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, field_validator, model_validator

PROHIBITED_DATA_FIELDS = frozenset(
    {
        "contacts",
        "addressBook",
        "rawPhotos",
        "cameraFrames",
        "preciseLocation",
        "meetingNote",
        "biometricData",
        "analyticsParameters",
    }
)
ModerationCategory = Literal["spam", "abusive_content", "impersonation"]


class SyncOperation(str, Enum):
    """Operations available in the version 2 sync contract."""

    refresh = "refresh"
    publish_card = "publishCard"
    prepare_exchange = "prepareExchange"
    claim_exchange = "claimExchange"
    cancel_exchange = "cancelExchange"
    prepare_audio_upload = "prepareAudioUpload"
    update_push_token = "updatePushToken"
    remove_push_token = "removePushToken"
    delete_profile = "deleteProfile"
    report = "report"
    block = "block"


class PersonCard(BaseModel):
    """The published card representation already encoded by Swift."""

    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    role: str
    company: str
    phone: str
    email: str
    tagline: str
    hasAudioGreeting: bool
    meetingPlace: str | None = None
    isBlocked: bool
    templateID: str = Field(
        default="standard-clean",
        min_length=1,
        max_length=64,
        pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$",
    )


class PrivateCardFields(BaseModel):
    """Private data supplied only while preparing an exchange."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    phone: str = Field(min_length=1, max_length=64)


class SyncRequest(BaseModel):
    """A single authenticated, versioned synchronization operation."""

    model_config = ConfigDict(extra="forbid")

    contractVersion: Literal[2] = 2
    operationID: str = Field(min_length=8, max_length=128)
    installationID: str = Field(min_length=16, max_length=128)
    apnsToken: str | None = Field(default=None, max_length=256)
    operation: SyncOperation
    cursor: str | None = Field(default=None, max_length=64)
    card: PersonCard | None = None
    privateFields: PrivateCardFields | None = None
    exchangeToken: str | None = Field(default=None, max_length=256)
    exchangeCode: str | None = Field(default=None, min_length=1, max_length=32)
    exchangeMethod: Literal["qr", "bluetooth", "photo", "manual"] | None = None
    audioAssetID: str | None = Field(default=None, max_length=128)
    audioSizeBytes: int | None = Field(default=None, ge=1, le=1_048_576)
    audioDurationMS: int | None = Field(default=None, ge=1, le=10_000)
    moderationCategory: ModerationCategory | None = None
    subjectInstallationID: str | None = Field(default=None, max_length=128)

    @model_validator(mode="before")
    @classmethod
    def reject_prohibited_data_fields(cls, value: Any) -> Any:
        _reject_prohibited_data_fields(value)
        return value

    @model_validator(mode="after")
    def validate_operation_fields(self) -> "SyncRequest":
        required_by_operation: dict[SyncOperation, tuple[str, ...]] = {
            SyncOperation.refresh: (),
            SyncOperation.publish_card: ("card",),
            SyncOperation.prepare_exchange: ("card",),
            SyncOperation.claim_exchange: (),
            SyncOperation.cancel_exchange: (),
            SyncOperation.prepare_audio_upload: ("audioSizeBytes", "audioDurationMS"),
            SyncOperation.update_push_token: ("apnsToken",),
            SyncOperation.remove_push_token: (),
            SyncOperation.delete_profile: (),
            SyncOperation.report: ("subjectInstallationID", "moderationCategory"),
            SyncOperation.block: ("subjectInstallationID",),
        }
        allowed_by_operation: dict[SyncOperation, frozenset[str]] = {
            SyncOperation.refresh: frozenset({"cursor"}),
            SyncOperation.publish_card: frozenset({"card", "audioAssetID"}),
            SyncOperation.prepare_exchange: frozenset({"card", "privateFields", "exchangeMethod"}),
            SyncOperation.claim_exchange: frozenset({"exchangeToken", "exchangeCode"}),
            SyncOperation.cancel_exchange: frozenset({"exchangeToken", "exchangeCode"}),
            SyncOperation.prepare_audio_upload: frozenset({"audioSizeBytes", "audioDurationMS"}),
            SyncOperation.update_push_token: frozenset({"apnsToken"}),
            SyncOperation.remove_push_token: frozenset(),
            SyncOperation.delete_profile: frozenset(),
            SyncOperation.report: frozenset({"subjectInstallationID", "moderationCategory"}),
            SyncOperation.block: frozenset({"subjectInstallationID"}),
        }
        operation_field_names = frozenset(
            {
                "cursor",
                "apnsToken",
                "card",
                "privateFields",
                "exchangeToken",
                "exchangeCode",
                "exchangeMethod",
                "audioAssetID",
                "audioSizeBytes",
                "audioDurationMS",
                "moderationCategory",
                "subjectInstallationID",
            }
        )
        supplied_fields = operation_field_names.intersection(self.model_fields_set)
        missing_fields = [
            field_name
            for field_name in required_by_operation[self.operation]
            if getattr(self, field_name) is None
        ]
        if missing_fields:
            raise ValueError(f"{self.operation.value} requires {', '.join(sorted(missing_fields))}")

        if (
            self.operation is SyncOperation.prepare_exchange
            and self.privateFields is not None
            and self.exchangeMethod in {"qr", "photo"}
        ):
            raise ValueError("prepareExchange does not accept privateFields with public-only exchange methods")

        if self.operation in {SyncOperation.claim_exchange, SyncOperation.cancel_exchange}:
            credential_count = sum(
                credential is not None for credential in (self.exchangeToken, self.exchangeCode)
            )
            if credential_count != 1:
                raise ValueError(f"{self.operation.value} requires exactly one exchange credential")

        prohibited_fields = supplied_fields - allowed_by_operation[self.operation]
        if prohibited_fields:
            raise ValueError(
                f"{self.operation.value} does not accept {', '.join(sorted(prohibited_fields))}"
            )
        return self


class AudioAsset(BaseModel):
    """A short-lived download authorization for a ready audio greeting."""

    model_config = ConfigDict(extra="forbid")

    assetID: str = Field(min_length=1, max_length=128)
    downloadURL: AnyHttpUrl
    expiresAt: datetime

    @field_validator("downloadURL")
    @classmethod
    def require_https_download_url(cls, value: AnyHttpUrl) -> AnyHttpUrl:
        return _require_https_url(value)


class AudioUpload(BaseModel):
    """A short-lived upload authorization for a pending audio greeting."""

    model_config = ConfigDict(extra="forbid")

    assetID: str = Field(min_length=1, max_length=128)
    uploadURL: AnyHttpUrl
    expiresAt: datetime

    @field_validator("uploadURL")
    @classmethod
    def require_https_upload_url(cls, value: AnyHttpUrl) -> AnyHttpUrl:
        return _require_https_url(value)


class SyncedPerson(BaseModel):
    """A confirmed peer card and, when present, its authorized audio asset."""

    model_config = ConfigDict(extra="forbid")

    installationID: str = Field(min_length=16, max_length=128)
    card: PersonCard
    version: int = Field(ge=1)
    audio: AudioAsset | None = None


class SyncResponse(BaseModel):
    """The response shape consumed by the version 2 iOS sync client."""

    model_config = ConfigDict(extra="forbid")

    accepted: bool
    serverVersion: str
    updateCount: int
    message: str
    nextCursor: str | None = Field(default=None, max_length=64)
    ownCardVersion: int | None = Field(default=None, ge=1)
    people: list[SyncedPerson] = Field(default_factory=list)
    revokedCardIDs: list[str] = Field(default_factory=list)
    exchangeToken: str | None = Field(default=None, max_length=256)
    exchangeCode: str | None = Field(default=None, min_length=1, max_length=32)
    exchangeExpiresAt: datetime | None = None
    audioUpload: AudioUpload | None = None
    notificationConfiguration: dict[str, bool] | None = None


class FeatureAvailability(BaseModel):
    """Public feature flags which cannot alter the application's privacy contract."""

    model_config = ConfigDict(extra="forbid")

    nearbyExchange: bool
    sponsoredTemplates: bool
    remoteNotifications: bool


class SponsoredTemplate(BaseModel):
    """Public display data for a sponsored card template."""

    model_config = ConfigDict(extra="forbid")

    id: str
    title: str
    accentHex: str


class PublicConfigResponse(BaseModel):
    """The exact public configuration shape decoded by the iOS client."""

    model_config = ConfigDict(extra="forbid")

    version: str
    minimumContract: int
    maintenance: bool
    features: FeatureAvailability
    sponsoredTemplates: list[SponsoredTemplate]
    privacyURL: AnyHttpUrl
    supportURL: AnyHttpUrl
    moderationCategories: list[ModerationCategory]
    analyticsKillSwitch: bool


def _reject_prohibited_data_fields(value: Any) -> None:
    if isinstance(value, Mapping):
        for key, nested_value in value.items():
            if key in PROHIBITED_DATA_FIELDS:
                raise ValueError(f"prohibited data field: {key}")
            _reject_prohibited_data_fields(nested_value)
    elif isinstance(value, list):
        for nested_value in value:
            _reject_prohibited_data_fields(nested_value)


def _require_https_url(value: AnyHttpUrl) -> AnyHttpUrl:
    if value.scheme != "https":
        raise ValueError("signed audio URLs require HTTPS")
    return value
