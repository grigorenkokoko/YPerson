"""Regression tests for the database-free public API contract."""

import json
import logging
from collections.abc import Generator
from hashlib import sha256
from uuid import UUID

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.observability import JsonRequestFormatter, request_logger
from app.schemas import SyncResponse
from app.settings import Settings
from tests.test_contract import EXPECTED_CONFIG


@pytest.fixture
def settings() -> Settings:
    return Settings(_env_file=None)


@pytest.fixture
def client(settings: Settings) -> Generator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def assert_request_id(response) -> str:
    request_id = response.headers["x-request-id"]
    assert UUID(request_id).version == 4
    if response.content and response.headers["content-type"].startswith("application/json"):
        body = response.json()
        if "requestID" in body:
            assert body["requestID"] == request_id
    return request_id


def test_legacy_refresh_response_remains_accepted_without_public_fields() -> None:
    response = SyncResponse.model_validate(
        {
            "accepted": True,
            "serverVersion": "2",
            "updateCount": 0,
            "message": "refreshed",
            "nextCursor": None,
            "ownCardVersion": None,
            "people": [],
            "revokedCardIDs": [],
        }
    )

    assert response.publicLinkActive is None
    assert response.publicReplies == []


def test_config_bytes_and_etag_are_the_exact_canonical_sha256(client: TestClient) -> None:
    expected_bytes = json.dumps(
        EXPECTED_CONFIG, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    response = client.get("/config")

    assert response.content == expected_bytes
    assert response.headers["etag"] == f'"{sha256(expected_bytes).hexdigest()}"'


@pytest.mark.parametrize(
    ("method", "path", "allow"),
    [
        ("post", "/health", "GET"),
        ("post", "/config", "GET"),
        ("post", "/privacy", "GET"),
        ("post", "/support", "GET"),
        ("get", "/sync", "POST"),
    ],
)
def test_known_routes_return_exact_405_contract(
    client: TestClient, method: str, path: str, allow: str
) -> None:
    response = getattr(client, method)(path)

    request_id = assert_request_id(response)
    assert response.status_code == 405
    assert response.headers["allow"] == allow
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {"error": "method_not_allowed", "requestID": request_id}


def test_unknown_route_returns_exact_404_contract(client: TestClient) -> None:
    response = client.get("/unknown-review-route")

    request_id = assert_request_id(response)
    assert response.status_code == 404
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {"error": "not_found", "requestID": request_id}


def test_logs_exclude_hostile_url_and_sync_secrets(client: TestClient) -> None:
    logger = request_logger()
    captured: list[str] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            captured.append(self.format(record))

    handler = Capture()
    handler.setFormatter(JsonRequestFormatter())
    logger.addHandler(handler)
    secrets = [
        "hostile-path-sentinel",
        "hostile-query-sentinel",
        "installation-sentinel-0001",
        "bearer-sentinel-000000000000000000000000000",
        "apns-sentinel-0001",
        "exchange-sentinel-0001",
        "https://storage.invalid/signed-url-sentinel",
        "private/object-key-sentinel",
        "card-name-sentinel",
    ]
    try:
        client.get("/hostile-path-sentinel?value=hostile-query-sentinel")
        client.get("/privacy")
        client.get("/support")
        client.post(
            "/sync",
            headers={"Authorization": "Bearer bearer-sentinel-000000000000000000000000000"},
            json={
                "contractVersion": 2,
                "operationID": "log-sentinel-op-0001",
                "installationID": "installation-sentinel-0001",
                "operation": "updatePushToken",
                "apnsToken": "apns-sentinel-0001",
            },
        )
        client.post(
            "/sync",
            headers={"Authorization": "Bearer bearer-sentinel-000000000000000000000000000"},
            json={
                "contractVersion": 2,
                "operationID": "log-sentinel-op-0002",
                "installationID": "installation-sentinel-0001",
                "operation": "claimExchange",
                "exchangeToken": "exchange-sentinel-0001",
                "downloadURL": "https://storage.invalid/signed-url-sentinel",
                "objectKey": "private/object-key-sentinel",
            },
        )
        client.post(
            "/sync",
            headers={"Authorization": "Bearer bearer-sentinel-000000000000000000000000000"},
            json={
                "contractVersion": 2,
                "operationID": "log-sentinel-op-0003",
                "installationID": "installation-sentinel-0001",
                "operation": "publishCard",
                "card": {
                    "id": "card-sentinel-id",
                    "name": "card-name-sentinel",
                    "role": "Engineer",
                    "company": "YPerson",
                    "phone": "+70000000000",
                    "email": "sentinel@example.invalid",
                    "tagline": "Hello",
                    "hasAudioGreeting": False,
                    "isBlocked": False,
                },
            },
        )
    finally:
        logger.removeHandler(handler)

    output = "\n".join(captured)
    assert all(secret not in output for secret in secrets)
    assert all(
        json.loads(line)["route"] in {"/privacy", "/support", "/sync", "unknown"}
        for line in captured
    )


def test_public_responses_have_unique_uuid_request_ids_and_cache_contract(
    client: TestClient,
) -> None:
    config = client.get("/config")
    responses = [
        client.get("/health"),
        config,
        client.get("/config", headers={"If-None-Match": config.headers["etag"]}),
        client.get("/privacy"),
        client.get("/support"),
        client.post("/sync", content=b"{", headers={"Content-Type": "application/json"}),
        client.get("/status-review-missing"),
        client.get("/sync"),
    ]

    request_ids = [assert_request_id(response) for response in responses]
    assert len(set(request_ids)) == len(request_ids)
    for response in responses:
        expected_cache = (
            "public, max-age=60"
            if response.status_code in {200, 304} and response.url.path == "/config"
            else "no-store"
        )
        assert response.headers["cache-control"] == expected_cache
