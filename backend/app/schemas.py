"""Strict request and response schemas for the existing iOS wire contract."""

from collections.abc import Mapping
from enum import Enum
from typing import Any, Literal

from pydantic import AnyHttpUrl, BaseModel, ConfigDict, Field, model_validator

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
    """Operations currently emitted by the iOS client."""

    refresh = "refresh"
    publish_card = "publishCard"
    claim_exchange = "claimExchange"
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


class SyncRequest(BaseModel):
    """A sync request constrained to the existing public wire contract."""

    model_config = ConfigDict(extra="forbid")

    installationID: str = Field(min_length=3, max_length=128)
    bearer: str | None = None
    apnsToken: str | None = Field(default=None, max_length=256)
    operation: SyncOperation
    card: PersonCard | None = None
    exchangeToken: str | None = Field(default=None, max_length=256)
    moderationCategory: ModerationCategory | None = None

    @model_validator(mode="before")
    @classmethod
    def reject_prohibited_data_fields(cls, value: Any) -> Any:
        _reject_prohibited_data_fields(value)
        return value


class SyncResponse(BaseModel):
    """The response shape consumed by the iOS sync client."""

    model_config = ConfigDict(extra="forbid")

    accepted: bool
    serverVersion: str
    updateCount: int
    message: str


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
