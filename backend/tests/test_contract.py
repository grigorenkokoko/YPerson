"""FastAPI public boundary tests without persistence dependencies."""

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
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


@pytest.mark.parametrize(
    ("content", "content_type"),
    [
        (b"{}", "application/json"),
        (b"not-json", "text/plain"),
        (b"x" * 65_537, "application/octet-stream"),
    ],
)
def test_sync_is_disabled_before_parsing(
    client: TestClient, content: bytes, content_type: str
) -> None:
    response = client.post("/sync", content=content, headers={"Content-Type": content_type})

    assert response.status_code == 503
    assert response.json()["error"] == "temporarily_unavailable"
    assert response.json()["message"] == "sync is not enabled"
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
        client.post("/sync", content=b"{}", headers={"Content-Type": "application/json"}),
        client.get("/not-a-route"),
    ]

    assert all(response.headers.get("x-request-id") for response in responses)
