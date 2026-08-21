"""FastAPI public boundary tests without persistence dependencies."""

import asyncio
import json
import time
from collections.abc import Generator
from types import SimpleNamespace

import anyio
import httpx
import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.main import MAX_SYNC_BODY_BYTES, _bounded_body, create_app
from app.schemas import PersonCard, SyncResponse
from app.settings import Settings
from app.storage import PublicCardRecord

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
        (
            json.dumps(VALID_SYNC_BODY).encode(),
            {
                "Content-Type": "application/json; charset",
                "Authorization": "Bearer valid-bearer-value-0000000000000000",
            },
            415,
            "unsupported_media_type",
        ),
        (
            json.dumps(VALID_SYNC_BODY).encode(),
            {
                "Content-Type": "application/json; charset=",
                "Authorization": "Bearer valid-bearer-value-0000000000000000",
            },
            415,
            "unsupported_media_type",
        ),
        (
            json.dumps(VALID_SYNC_BODY).encode(),
            {
                "Content-Type": 'application/json; charset="unterminated',
                "Authorization": "Bearer valid-bearer-value-0000000000000000",
            },
            415,
            "unsupported_media_type",
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


@pytest.mark.parametrize(
    ("content_type", "authorization"),
    [
        ("application/json; charset=utf-8", "Bearer valid-bearer-value-0000000000000000"),
        (
            'Application/JSON; charset="utf-8"; profile=mobile',
            "bearer   valid-bearer-value-0000000000000000",
        ),
    ],
)
def test_sync_accepts_valid_mime_parameters_and_rfc_bearer_spacing(
    client: TestClient,
    content_type: str,
    authorization: str,
) -> None:
    response = client.post(
        "/sync",
        content=json.dumps(VALID_SYNC_BODY).encode(),
        headers={"Content-Type": content_type, "Authorization": authorization},
    )

    assert response.status_code == 503
    assert response.json()["error"] == "temporarily_unavailable"


def test_bounded_body_accepts_exact_limit_and_rejects_oversized_single_chunk() -> None:
    async def read_body(chunk: bytes) -> bytes | None:
        messages = [
            {"type": "http.request", "body": chunk, "more_body": False},
        ]

        async def receive():
            return messages.pop(0)

        request = Request({"type": "http", "headers": []}, receive)
        return await _bounded_body(request)

    exact = b"x" * MAX_SYNC_BODY_BYTES
    assert anyio.run(read_body, exact) == exact
    assert anyio.run(read_body, exact + b"x") is None


def test_sync_service_work_runs_off_the_async_request_loop() -> None:
    class SlowService:
        def handle(self, request, bearer):
            del request, bearer
            time.sleep(0.2)
            return SyncResponse(
                accepted=True,
                serverVersion="2",
                updateCount=0,
                message="refreshed",
            )

    async def scenario() -> tuple[int, int, float]:
        app = create_app(Settings(_env_file=None), sync_service=SlowService())  # type: ignore[arg-type]
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(
            transport=transport, base_url="https://test.invalid"
        ) as client:
            started = time.perf_counter()
            sync_task = asyncio.create_task(
                client.post(
                    "/sync",
                    json=VALID_SYNC_BODY,
                    headers={"Authorization": "Bearer valid-bearer-value-0000000000000000"},
                )
            )
            await anyio.sleep(0.02)
            health = await client.get("/health")
            elapsed = time.perf_counter() - started
            sync = await sync_task
        return health.status_code, sync.status_code, elapsed

    health_status, sync_status, elapsed = anyio.run(scenario)
    assert health_status == sync_status == 200
    assert elapsed < 0.12


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


def test_enabled_runtime_serves_public_cards_from_its_durable_store(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from app import serve

    class FakeResources:
        def __init__(self, settings: Settings) -> None:
            del settings
            self.pool = object()

        def close(self) -> None:
            pass

    class FakeStore:
        def __init__(self, pool: object, *, clock=None) -> None:
            del pool, clock

        def resolve_public_card(self, raw_token: str) -> PublicCardRecord | None:
            del raw_token
            return PublicCardRecord(
                owner_installation_id="installation-owner-0001",
                card=PersonCard(
                    id="public-card",
                    name="Runtime Person",
                    role="Engineer",
                    company="YPerson",
                    phone="private-phone",
                    email="runtime@example.invalid",
                    tagline="Hello",
                    hasAudioGreeting=False,
                    isBlocked=False,
                ),
            )

    monkeypatch.setattr(serve, "RuntimeResources", FakeResources)
    monkeypatch.setattr(serve, "YDBSyncStore", FakeStore)
    monkeypatch.setattr(serve, "ObjectStorage", lambda *_args: object())
    monkeypatch.setattr(
        serve,
        "MediaService",
        lambda *_args, **_kwargs: SimpleNamespace(delete_objects=lambda _keys: None),
    )
    application = serve.build_app(
        Settings(
            YPERSON_SYNC_ENABLED="true",
            YDB_ENDPOINT="grpcs://ydb.example:2135",
            YDB_DATABASE="/test/database",
            YPERSON_OBJECT_BUCKET="private-bucket",
            YPERSON_S3_ACCESS_KEY_ID="access",
            YPERSON_S3_SECRET_ACCESS_KEY="secret",
            _env_file=None,
        )
    )

    with TestClient(application, base_url="https://cards.example") as runtime_client:
        response = runtime_client.get(f"/p/{'A' * 43}/card.json")

    assert response.status_code == 200
    assert response.json()["name"] == "Runtime Person"
