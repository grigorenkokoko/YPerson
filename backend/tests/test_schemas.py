from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from app.schemas import (
    AudioAsset,
    AudioUpload,
    PersonCard,
    PrivateCardFields,
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


def public_card() -> dict[str, object]:
    return {
        "id": "card-owner",
        "name": "Owner",
        "role": "Engineer",
        "company": "YPerson",
        "phone": "",
        "email": "owner@example.invalid",
        "tagline": "Hello",
        "hasAudioGreeting": False,
        "meetingPlace": None,
        "isBlocked": False,
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
        "cancelExchange",
        "prepareAudioUpload",
        "updatePushToken",
        "removePushToken",
        "deleteProfile",
        "report",
        "block",
    }


def test_claim_and_cancel_exchange_require_exactly_one_credential() -> None:
    token_request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "claimExchange",
            "exchangeToken": "prepared-token",
        }
    )
    code_request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "cancelExchange",
            "exchangeCode": "YP-0123-4567-89AB",
        }
    )

    assert token_request.exchangeToken == "prepared-token"
    assert code_request.exchangeCode == "YP-0123-4567-89AB"
    for operation in ("claimExchange", "cancelExchange"):
        with pytest.raises(ValidationError, match="exactly one"):
            SyncRequest.model_validate(valid_request() | {"operation": operation})
        with pytest.raises(ValidationError, match="exactly one"):
            SyncRequest.model_validate(
                valid_request()
                | {
                    "operation": operation,
                    "exchangeToken": "opaque-token",
                    "exchangeCode": "YP-0123-4567-89AB",
                }
            )
    with pytest.raises(ValidationError, match="cancelExchange does not accept card"):
        SyncRequest.model_validate(
            valid_request()
            | {
                "operation": "cancelExchange",
                "exchangeToken": "prepared-token",
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


def test_prepare_exchange_accepts_strict_private_phone() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "prepareExchange",
            "card": public_card(),
            "exchangeMethod": "manual",
            "privateFields": {"phone": "  +7 900 555-10-20  "},
        }
    )

    assert request.privateFields == PrivateCardFields(phone="+7 900 555-10-20")


@pytest.mark.parametrize("phone", ["", "   ", "1" * 65])
def test_private_phone_is_bounded(phone: str) -> None:
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(
            valid_request()
            | {
                "operation": "prepareExchange",
                "card": public_card(),
                "privateFields": {"phone": phone},
            }
        )


def test_private_fields_reject_unknown_fields_and_other_operations() -> None:
    with pytest.raises(ValidationError):
        SyncRequest.model_validate(
            valid_request()
            | {
                "operation": "prepareExchange",
                "card": public_card(),
                "privateFields": {"email": "private@example.invalid"},
            }
        )
    with pytest.raises(ValidationError, match="refresh does not accept privateFields"):
        SyncRequest.model_validate(valid_request() | {"privateFields": {"phone": "+79005550102"}})


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
            },
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


def test_person_card_template_defaults_for_legacy_clients() -> None:
    request = SyncRequest.model_validate(
        valid_request()
        | {
            "operation": "publishCard",
            "card": {
                "id": "legacy-card",
                "name": "Legacy",
                "role": "Designer",
                "company": "YPerson",
                "phone": "",
                "email": "legacy@example.invalid",
                "tagline": "Hello",
                "hasAudioGreeting": False,
                "isBlocked": False,
            },
        }
    )

    assert request.card is not None
    assert request.card.templateID == "standard-clean"


def test_person_card_accepts_a_public_template_identifier() -> None:
    styled = PersonCard(
        id="styled-card",
        name="Styled",
        role="Designer",
        company="YPerson",
        phone="",
        email="styled@example.invalid",
        tagline="Hello",
        hasAudioGreeting=False,
        isBlocked=False,
        templateID="mint-conference",
    )

    assert styled.model_dump(mode="json")["templateID"] == "mint-conference"


@pytest.mark.parametrize("template_id", ["", "Mint Conference", "../mint", "a" * 65])
def test_person_card_rejects_invalid_template_identifiers(template_id: str) -> None:
    with pytest.raises(ValidationError):
        PersonCard(
            id="invalid-template",
            name="Invalid",
            role="Designer",
            company="YPerson",
            phone="",
            email="invalid@example.invalid",
            tagline="Hello",
            hasAudioGreeting=False,
            isBlocked=False,
            templateID=template_id,
        )


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


def test_exchange_response_preserves_v1_fields_and_adds_people_audio() -> None:
    request = SyncRequest.model_validate(valid_request())
    response = SyncResponse.model_validate(
        {
            "accepted": True,
            "serverVersion": "2",
            "updateCount": 1,
            "message": "refreshed",
            "nextCursor": "7",
            "exchangeCode": "YP-0123-4567-89AB",
            "exchangeExpiresAt": "2026-08-20T12:10:00Z",
            "people": [
                {
                    "installationID": "installation-peer-00002",
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
    assert response.exchangeCode == "YP-0123-4567-89AB"
    assert response.exchangeExpiresAt == datetime(2026, 8, 20, 12, 10, tzinfo=UTC)
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
