import pytest
from pydantic import ValidationError

from app.schemas import PersonCard, PublicConfigResponse, SyncOperation, SyncRequest


def valid_request() -> dict[str, object]:
    return {"installationID": "ios-installation", "operation": "refresh"}


def test_sync_request_rejects_unknown_fields() -> None:
    payload = valid_request() | {"cursor": "not-in-current-wire-contract"}

    with pytest.raises(ValidationError):
        SyncRequest.model_validate(payload)


@pytest.mark.parametrize(
    "field",
    [
        "contacts",
        "addressBook",
        "rawPhotos",
        "cameraFrames",
        "preciseLocation",
        "meetingNote",
        "biometricData",
        "analyticsParameters",
    ],
)
def test_sync_request_rejects_prohibited_nested_fields(field: str) -> None:
    payload = valid_request() | {"card": {"id": "card", field: "secret"}}

    with pytest.raises(ValidationError, match="prohibited data field"):
        SyncRequest.model_validate(payload)


def test_all_existing_operations_remain_supported() -> None:
    assert {item.value for item in SyncOperation} == {
        "refresh",
        "publishCard",
        "claimExchange",
        "updatePushToken",
        "removePushToken",
        "deleteProfile",
        "report",
        "block",
    }


def test_sync_request_accepts_the_published_person_card_contract() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "card": {
                "id": "person-alexey",
                "name": "Alexey Morozov",
                "role": "Product Lead",
                "company": "North Star",
                "phone": "+79005550102",
                "email": "alexey@example.com",
                "tagline": "Connecting people",
                "hasAudioGreeting": False,
                "meetingPlace": "Moscow",
                "isBlocked": False,
            }
        }
    )

    assert request.card == PersonCard(
        id="person-alexey",
        name="Alexey Morozov",
        role="Product Lead",
        company="North Star",
        phone="+79005550102",
        email="alexey@example.com",
        tagline="Connecting people",
        hasAudioGreeting=False,
        meetingPlace="Moscow",
        isBlocked=False,
    )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("installationID", "ab"),
        ("installationID", "i" * 129),
        ("apnsToken", "a" * 257),
        ("exchangeToken", "e" * 257),
    ],
)
def test_sync_request_enforces_identifier_and_token_length_limits(field: str, value: str) -> None:
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(valid_request() | {field: value})


def test_sync_request_rejects_unknown_moderation_categories() -> None:
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(valid_request() | {"moderationCategory": "harassment"})


def test_public_configuration_matches_the_ios_contract() -> None:
    configuration = PublicConfigResponse.model_validate(
        {
            "version": "2026-08-18.1",
            "minimumContract": 1,
            "maintenance": False,
            "features": {
                "nearbyExchange": True,
                "sponsoredTemplates": True,
                "remoteNotifications": True,
            },
            "sponsoredTemplates": [
                {"id": "mint-conference", "title": "Mint Conference", "accentHex": "#AEEBD3"}
            ],
            "privacyURL": "https://example.invalid/yperson/privacy",
            "supportURL": "https://example.invalid/yperson/support",
            "moderationCategories": ["spam", "abusive_content", "impersonation"],
            "analyticsKillSwitch": False,
        }
    )

    assert configuration.features.remoteNotifications is True
    assert configuration.sponsoredTemplates[0].accentHex == "#AEEBD3"
