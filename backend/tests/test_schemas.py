import pytest
from pydantic import ValidationError

from app.schemas import (
    AudioAsset,
    AudioUpload,
    PersonCard,
    PublicConfigResponse,
    SyncOperation,
    SyncRequest,
    SyncResponse,
)


def valid_request() -> dict[str, object]:
    return {
        "contractVersion": 2,
        "operationID": "op-12345678",
        "installationID": "ios-installation-123",
        "operation": "refresh",
    }


def test_sync_request_rejects_unknown_fields() -> None:
    payload = valid_request() | {"unknown": "not-in-current-wire-contract"}

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
        "prepareExchange",
        "claimExchange",
        "prepareAudioUpload",
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
            "operation": "publishCard",
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


def test_sync_request_accepts_a_swift_card_without_a_meeting_place() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "publishCard",
            "card": {
                "id": "person-maria",
                "name": "Maria Orlova",
                "role": "Founder",
                "company": "Orlova Studio",
                "phone": "+79005550304",
                "email": "maria@example.com",
                "tagline": "Connecting people and useful ideas",
                "hasAudioGreeting": False,
                "isBlocked": False,
            },
        }
    )

    assert request.card is not None
    assert request.card.meetingPlace is None


@pytest.mark.parametrize(
        ("field", "value"),
    [
        ("installationID", "i" * 15),
        ("installationID", "i" * 129),
        ("operationID", "short"),
        ("operationID", "o" * 129),
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


def test_sync_request_requires_a_card_to_publish() -> None:
    with pytest.raises(ValidationError, match="card"):
        SyncRequest.model_validate(valid_request() | {"operation": "publishCard"})


def test_sync_request_rejects_card_data_for_refresh() -> None:
    with pytest.raises(ValidationError, match="refresh"):
        SyncRequest.model_validate(
            valid_request()
            | {
                "card": {
                    "id": "card-peer",
                    "name": "Peer",
                    "role": "Designer",
                    "company": "Studio",
                    "phone": "",
                    "email": "",
                    "tagline": "Hello",
                    "hasAudioGreeting": False,
                    "isBlocked": False,
                }
            }
        )


def test_prepare_exchange_requires_card_and_accepts_optional_method() -> None:
    card = {
        "id": "card-peer",
        "name": "Peer",
        "role": "Designer",
        "company": "Studio",
        "phone": "",
        "email": "",
        "tagline": "Hello",
        "hasAudioGreeting": False,
        "isBlocked": False,
    }

    request = SyncRequest.model_validate(
        valid_request() | {"operation": "prepareExchange", "card": card, "exchangeMethod": "qr"}
    )

    assert request.exchangeMethod == "qr"


def test_prepare_exchange_accepts_card_without_exchange_method() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "prepareExchange",
            "card": {
                "id": "card-peer",
                "name": "Peer",
                "role": "Designer",
                "company": "Studio",
                "phone": "",
                "email": "",
                "tagline": "Hello",
                "hasAudioGreeting": False,
                "isBlocked": False,
            },
        }
    )

    assert request.exchangeMethod is None


def test_sync_request_rejects_irrelevant_field_explicitly_set_to_null() -> None:
    with pytest.raises(ValidationError, match="refresh does not accept card"):
        SyncRequest.model_validate(valid_request() | {"card": None})


@pytest.mark.parametrize(
    ("model", "url_field"),
    [
        (AudioAsset, "downloadURL"),
        (AudioUpload, "uploadURL"),
    ],
)
def test_audio_signed_urls_require_https(model: type, url_field: str) -> None:
    payload = {
        "assetID": "asset-1",
        url_field: "https://storage.yandexcloud.net/private/object?signature=test",
        "expiresAt": "2026-08-20T12:05:00Z",
    }

    assert str(model.model_validate(payload).__getattribute__(url_field)).startswith("https://")
    with pytest.raises(ValidationError, match="HTTPS"):
        model.model_validate(payload | {url_field: "http://storage.example/private/object"})


def test_sync_v2_models_preserve_v1_fields_and_add_people_audio() -> None:
    request = SyncRequest.model_validate(valid_request())
    response = SyncResponse.model_validate(
        {
            "accepted": True,
            "serverVersion": "2",
            "updateCount": 1,
            "message": "refreshed",
            "nextCursor": "7",
            "people": [
                {
                    "card": {
                        "id": "card-peer",
                        "name": "Peer",
                        "role": "Designer",
                        "company": "Studio",
                        "phone": "",
                        "email": "",
                        "tagline": "Hello",
                        "hasAudioGreeting": True,
                        "meetingPlace": None,
                        "isBlocked": False,
                    },
                    "version": 3,
                    "audio": {
                        "assetID": "asset-1",
                        "downloadURL": "https://storage.yandexcloud.net/private/object?signature=test",
                        "expiresAt": "2026-08-20T12:05:00Z",
                    },
                }
            ],
        }
    )

    assert request.contractVersion == 2
    assert response.people[0].audio is not None
    assert response.people[0].audio.assetID == "asset-1"
    assert response.model_dump()["accepted"] is True


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
