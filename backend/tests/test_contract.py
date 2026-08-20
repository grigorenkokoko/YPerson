"""FastAPI public boundary tests without persistence dependencies."""

import json
from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from app.main import MAX_SYNC_BODY_BYTES, create_app
from app.settings import Settings

EXPECTED_CONFIG = {
    "version": "2026-08-18.1",
    "minimumContract": 1,
    "maintenance": False,
    "features": {
        "nearbyExchange": True,
        "sponsoredTemplates": True,
        "remoteNotifications": True,
    },
    "sponsoredTemplates": [
        {"id": "mint-conference", "title": "Mint Conference", "accentHex": "#AEEBD3"},
        {"id": "indigo-studio", "title": "Indigo Studio", "accentHex": "#4F5FE7"},
    ],
    "privacyURL": "https://example.invalid/yperson/privacy",
    "supportURL": "https://example.invalid/yperson/support",
    "moderationCategories": ["spam", "abusive_content", "impersonation"],
    "analyticsKillSwitch": False,
}


@pytest.fixture
def settings() -> Settings:
    return Settings(_env_file=None)


@pytest.fixture
def client(settings: Settings) -> Generator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def test_health_reports_process_readiness_without_database(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "2026-08-18.1"}
    assert response.headers["cache-control"] == "no-store"


def test_config_matches_swift_shape_and_contains_no_personal_data(client: TestClient) -> None:
    response = client.get("/config")

    assert response.status_code == 200
    assert response.json() == EXPECTED_CONFIG
    assert response.headers["cache-control"] == "public, max-age=60"
    assert set(response.json()) == set(EXPECTED_CONFIG)


def test_config_etag_is_stable_and_if_none_match_returns_empty_304(client: TestClient) -> None:
    first = client.get("/config")
    second = client.get("/config", headers={"If-None-Match": first.headers["etag"]})

    assert first.headers["etag"].startswith('"') and first.headers["etag"].endswith('"')
    assert first.content == client.get("/config").content
    assert second.status_code == 304
    assert second.content == b""
    assert second.headers["etag"] == first.headers["etag"]
    assert second.headers["cache-control"] == "public, max-age=60"


VALID_SYNC_BODY = {
    "contractVersion": 2,
    "operationID": "contract-op-0001",
    "installationID": "installation-contract-0001",
    "operation": "refresh",
}


@pytest.mark.parametrize(
    ("content", "headers", "status", "error"),
    [
        (
            b"{}",
            {
                "Content-Type": "text/plain",
                "Authorization": "Bearer valid-bearer-value-0000000000000000",
            },
            415,
            "unsupported_media_type",
        ),
        (
            b"{" + b" " * MAX_SYNC_BODY_BYTES,
            {
                "Content-Type": "application/json",
                "Authorization": "Bearer valid-bearer-value-0000000000000000",
            },
            413,
            "payload_too_large",
        ),
        (
            b"{",
            {
                "Content-Type": "application/json",
                "Authorization": "Bearer valid-bearer-value-0000000000000000",
            },
            400,
            "invalid_request",
        ),
        (
            json.dumps(VALID_SYNC_BODY).encode(),
            {"Content-Type": "application/json"},
            401,
            "unauthorized",
        ),
        (
            json.dumps(VALID_SYNC_BODY).encode(),
            {"Content-Type": "application/json", "Authorization": "Basic secret"},
            401,
            "unauthorized",
        ),
        (
            json.dumps(VALID_SYNC_BODY).encode(),
            {"Content-Type": "application/json", "Authorization": "Bearer short"},
            401,
            "unauthorized",
        ),
    ],
)
def test_sync_rejects_unsafe_transport_before_storage(
    client: TestClient,
    content: bytes,
    headers: dict[str, str],
    status: int,
    error: str,
) -> None:
    response = client.post("/sync", content=content, headers=headers)

    assert response.status_code == status
    assert response.json()["error"] == error
    assert response.json()["requestID"] == response.headers["x-request-id"]


def test_sync_fails_closed_after_valid_authentication_and_validation(
    client: TestClient,
) -> None:
    response = client.post(
        "/sync",
        json=VALID_SYNC_BODY,
        headers={"Authorization": "Bearer valid-bearer-value-0000000000000000"},
    )

    assert response.status_code == 503
    assert response.json()["error"] == "temporarily_unavailable"
    assert response.json()["requestID"] == response.headers["x-request-id"]


def test_known_route_wrong_method_returns_405_and_allow_header(client: TestClient) -> None:
    response = client.put("/sync")

    assert response.status_code == 405
    assert response.headers["allow"] == "POST"
    assert response.json()["error"] == "method_not_allowed"


def test_unknown_route_returns_404(client: TestClient) -> None:
    response = client.get("/not-a-route")

    assert response.status_code == 404
    assert response.json()["error"] == "not_found"


def test_every_response_has_request_id(client: TestClient) -> None:
    responses = [
        client.get("/health"),
        client.get("/config"),
        client.get("/privacy"),
        client.get("/support"),
        client.post("/sync", content=b"{}", headers={"Content-Type": "application/json"}),
        client.get("/not-a-route"),
    ]

    assert all(response.headers.get("x-request-id") for response in responses)
