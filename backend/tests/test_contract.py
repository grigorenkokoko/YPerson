"""FastAPI boundary tests against a freshly migrated PostgreSQL schema."""

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from app.main import create_app
from app.settings import Settings
from app.storage import BlockedConnection, ModerationAction, Profile

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


def valid_sync(**overrides: object) -> dict[str, object]:
    return {"installationID": "ios-contract-installation", "operation": "refresh"} | overrides


@pytest.fixture
def settings(session_factory: sessionmaker[Session]) -> Settings:
    database_url = session_factory.kw["bind"].url.render_as_string(hide_password=False)
    return Settings(DATABASE_URL=database_url, _env_file=None)


@pytest.fixture
def client(settings: Settings) -> Generator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def test_health_returns_version_when_database_is_ready(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "2026-08-18.1"}
    assert response.headers["cache-control"] == "no-store"


def test_health_returns_503_when_database_is_unavailable() -> None:
    unavailable = Settings(
        DATABASE_URL="postgresql+psycopg://127.0.0.1:1/yperson_unavailable", _env_file=None
    )
    with TestClient(create_app(unavailable)) as client:
        response = client.get("/health")

    assert response.status_code == 503
    assert response.json() == {"status": "unavailable", "version": "2026-08-18.1"}


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


def test_valid_sync_returns_existing_response_shape(client: TestClient) -> None:
    response = client.post("/sync", json=valid_sync())

    assert response.status_code == 200
    assert response.json() == {
        "accepted": True,
        "serverVersion": "2026-08-18.1",
        "updateCount": 0,
        "message": "refresh accepted",
    }
    assert response.headers["cache-control"] == "no-store"


def test_fresh_installation_update_count_is_zero(client: TestClient) -> None:
    response = client.post("/sync", json=valid_sync(installationID="brand-new-installation"))

    assert response.status_code == 200
    assert response.json()["updateCount"] == 0


def test_publish_card_persists_across_app_instances(
    settings: Settings, session_factory: sessionmaker[Session]
) -> None:
    card = {
        "id": "person-ada",
        "name": "Ada Lovelace",
        "role": "Engineer",
        "company": "Analytical Engines",
        "phone": "+79005550101",
        "email": "ada@example.com",
        "tagline": "First programmer",
        "hasAudioGreeting": False,
        "isBlocked": False,
    }
    with TestClient(create_app(settings)) as first:
        assert (
            first.post("/sync", json=valid_sync(operation="publishCard", card=card)).status_code
            == 200
        )
    with TestClient(create_app(settings)) as second:
        response = second.post("/sync", json=valid_sync(operation="refresh"))

    assert response.status_code == 200
    assert response.json()["updateCount"] == 0
    with session_factory() as session:
        profile = session.get(Profile, "ios-contract-installation")
    assert profile is not None
    assert profile.card == card


def test_sync_rejects_non_json_with_415(client: TestClient) -> None:
    response = client.post("/sync", content=b"not json", headers={"Content-Type": "text/plain"})

    assert response.status_code == 415
    assert response.json()["error"] == "invalid_request"


def test_sync_rejects_invalid_json_with_400(client: TestClient) -> None:
    response = client.post("/sync", content=b"{", headers={"Content-Type": "application/json"})

    assert response.status_code == 400
    assert response.json()["error"] == "invalid_request"


def test_sync_rejects_unknown_and_nested_prohibited_fields_with_400(client: TestClient) -> None:
    unknown = client.post("/sync", json=valid_sync(cursor="unsupported"))
    prohibited = client.post(
        "/sync",
        json=valid_sync(card={"id": "card", "contacts": ["private"]}),
    )

    assert unknown.status_code == 400
    assert prohibited.status_code == 400
    assert unknown.json()["error"] == prohibited.json()["error"] == "invalid_request"


def test_sync_rejects_body_over_64_kib_with_413(client: TestClient) -> None:
    response = client.post(
        "/sync",
        content=b"x" * 65_537,
        headers={"Content-Type": "application/json"},
    )

    assert response.status_code == 413
    assert response.json()["error"] == "invalid_request"


def test_claim_exchange_requires_at_least_eight_characters(client: TestClient) -> None:
    response = client.post(
        "/sync", json=valid_sync(operation="claimExchange", exchangeToken="short")
    )

    assert response.status_code == 400
    assert response.json()["error"] == "invalid_request"


def test_report_block_push_and_delete_operations(
    client: TestClient, session_factory: sessionmaker[Session]
) -> None:
    installation_id = "operation-installation"
    assert (
        client.post(
            "/sync",
            json=valid_sync(
                installationID=installation_id, operation="updatePushToken", apnsToken="push"
            ),
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/sync", json=valid_sync(installationID=installation_id, operation="removePushToken")
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/sync",
            json=valid_sync(
                installationID=installation_id, operation="report", moderationCategory="spam"
            ),
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/sync", json=valid_sync(installationID=installation_id, operation="block")
        ).status_code
        == 200
    )
    deletion = client.post(
        "/sync", json=valid_sync(installationID=installation_id, operation="deleteProfile")
    )

    assert deletion.json()["message"] == "profile deletion accepted; backup purge window is 30 days"
    with session_factory() as session:
        assert session.get(Profile, installation_id) is None
        assert session.query(ModerationAction).count() == 0
        assert session.query(BlockedConnection).count() == 0


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
        client.post("/sync", json=valid_sync()),
        client.get("/not-a-route"),
    ]

    assert all(response.headers.get("x-request-id") for response in responses)
