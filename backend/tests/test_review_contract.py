"""Regression behavior tests added in response to the Task 3 review."""

import asyncio
import json
import logging
from collections.abc import Generator
from datetime import timedelta
from hashlib import sha256
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker
from starlette.types import Message, Scope

from app import main as main_module
from app.main import create_app
from app.observability import JsonRequestFormatter, request_logger
from app.settings import Settings
from app.storage import BlockedConnection, ExchangeToken, ModerationAction, Profile
from tests.test_contract import EXPECTED_CONFIG, valid_sync


def review_card() -> dict[str, object]:
    return {
        "id": "person-review",
        "name": "Review Person",
        "role": "Engineer",
        "company": "YPerson",
        "phone": "+79005550000",
        "email": "review@example.com",
        "tagline": "Contract coverage",
        "hasAudioGreeting": False,
        "isBlocked": False,
    }


@pytest.fixture
def settings(session_factory: sessionmaker[Session]) -> Settings:
    database_url = str(session_factory.kw["bind"].url)
    return Settings(DATABASE_URL=database_url, _env_file=None)


@pytest.fixture
def client(settings: Settings) -> Generator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def assert_request_id(response) -> str:
    request_id = response.headers["x-request-id"]
    assert UUID(request_id).version == 4
    if response.content:
        body = response.json()
        if "requestID" in body:
            assert body["requestID"] == request_id
    return request_id


def test_config_bytes_and_etag_are_the_exact_canonical_sha256(client: TestClient) -> None:
    expected_bytes = json.dumps(
        EXPECTED_CONFIG, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    response = client.get("/config")

    assert response.content == expected_bytes
    assert response.headers["etag"] == f'"{sha256(expected_bytes).hexdigest()}"'


def test_sync_accepts_json_parameters_and_rejects_prefix_lookalikes(client: TestClient) -> None:
    serialized = json.dumps(valid_sync()).encode()
    parameterized = client.post(
        "/sync", content=serialized, headers={"Content-Type": "Application/JSON; charset=utf-8"}
    )
    jsonp = client.post("/sync", content=serialized, headers={"Content-Type": "application/jsonp"})
    json_evil = client.post(
        "/sync", content=serialized, headers={"Content-Type": "application/json-evil"}
    )

    assert parameterized.status_code == 200
    assert [response.status_code for response in (jsonp, json_evil)] == [415, 415]


def test_streaming_body_over_limit_without_content_length_returns_413(settings: Settings) -> None:
    application = create_app(settings)
    messages = iter(
        [
            {"type": "http.request", "body": b"x" * 32_768, "more_body": True},
            {"type": "http.request", "body": b"x" * 32_769, "more_body": False},
        ]
    )
    sent: list[Message] = []
    scope: Scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/sync",
        "raw_path": b"/sync",
        "query_string": b"",
        "headers": [(b"content-type", b"application/json")],
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
    }

    async def receive() -> Message:
        return next(messages)

    async def send(message: Message) -> None:
        sent.append(message)

    asyncio.run(application(scope, receive, send))

    start = next(message for message in sent if message["type"] == "http.response.start")
    body = b"".join(
        message.get("body", b"") for message in sent if message["type"] == "http.response.body"
    )
    headers = {name.lower(): value for name, value in start["headers"]}
    assert start["status"] == 413
    assert json.loads(body) == {
        "error": "invalid_request",
        "message": "request body exceeds 64 KiB",
        "requestID": headers[b"x-request-id"].decode(),
    }
    assert headers[b"cache-control"] == b"no-store"


def test_all_sync_operations_have_exact_messages_and_durable_effects(
    client: TestClient, session_factory: sessionmaker[Session]
) -> None:
    installation_id = "all-operations-installation"
    token = "successful-exchange-token"
    operations = [
        ("refresh", {}),
        ("publishCard", {"card": review_card()}),
        ("claimExchange", {"exchangeToken": token}),
        ("updatePushToken", {"apnsToken": "apns-review-token"}),
        ("removePushToken", {}),
        ("report", {"moderationCategory": "spam"}),
        ("block", {}),
    ]

    for operation, fields in operations:
        response = client.post(
            "/sync", json=valid_sync(installationID=installation_id, operation=operation, **fields)
        )
        assert response.json() == {
            "accepted": True,
            "serverVersion": "2026-08-18.1",
            "updateCount": 0,
            "message": f"{operation} accepted",
        }
        if operation == "updatePushToken":
            with session_factory() as session:
                profile = session.get(Profile, installation_id)
            assert profile is not None
            assert profile.apns_token == "apns-review-token"
        if operation == "removePushToken":
            with session_factory() as session:
                profile = session.get(Profile, installation_id)
            assert profile is not None
            assert profile.apns_token is None

    with session_factory() as session:
        profile = session.get(Profile, installation_id)
        exchange = session.scalar(select(ExchangeToken))
        report = session.scalar(select(ModerationAction))
        block = session.scalar(select(BlockedConnection))
    assert profile is not None
    assert profile.card == review_card()
    assert profile.apns_token is None
    assert exchange is not None
    assert exchange.token_hash == sha256(token.encode()).hexdigest()
    assert token not in str(exchange.token_hash)
    assert exchange.expires_at - exchange.claimed_at == timedelta(minutes=10)
    assert report is not None and report.category == "spam"
    assert block is not None and block.installation_id == installation_id

    deletion = client.post(
        "/sync", json=valid_sync(installationID=installation_id, operation="deleteProfile")
    )
    assert deletion.json() == {
        "accepted": True,
        "serverVersion": "2026-08-18.1",
        "updateCount": 0,
        "message": "profile deletion accepted; backup purge window is 30 days",
    }
    with session_factory() as session:
        assert session.get(Profile, installation_id) is None
        assert session.scalar(select(ExchangeToken)) is None
        assert session.scalar(select(ModerationAction)) is None
        assert session.scalar(select(BlockedConnection)) is None


@pytest.mark.parametrize(
    ("method", "path", "allow"),
    [("post", "/health", "GET"), ("post", "/config", "GET"), ("get", "/sync", "POST")],
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


def test_unexpected_route_failure_is_sanitized_headered_and_not_logged(
    settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    sentinel = "exception-sentinel-must-not-leak"

    def explode(_: Session) -> bool:
        raise RuntimeError(sentinel)

    logger = request_logger()
    captured: list[str] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            captured.append(self.format(record))

    handler = Capture()
    handler.setFormatter(JsonRequestFormatter())
    logger.addHandler(handler)
    monkeypatch.setattr(main_module, "database_is_ready", explode)
    try:
        with TestClient(create_app(settings)) as client:
            response = client.get("/health?query-sentinel=private")
    finally:
        logger.removeHandler(handler)

    request_id = assert_request_id(response)
    assert response.status_code == 500
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "error": "internal_error",
        "message": "internal error",
        "requestID": request_id,
    }
    assert sentinel not in "\n".join(captured)


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
        "installation-sentinel",
        "bearer-sentinel",
        "apns-sentinel",
        "card-sentinel",
    ]
    try:
        client.get("/hostile-path-sentinel?value=hostile-query-sentinel")
        client.post(
            "/sync",
            json=valid_sync(
                installationID="installation-sentinel",
                bearer="bearer-sentinel",
                apnsToken="apns-sentinel",
                operation="publishCard",
                card=review_card() | {"tagline": "card-sentinel"},
            ),
        )
    finally:
        logger.removeHandler(handler)

    output = "\n".join(captured)
    assert all(secret not in output for secret in secrets)
    assert all(json.loads(line)["route"] in {"/sync", "unknown"} for line in captured)


def test_every_status_has_unique_uuid_request_id_and_cache_contract(
    client: TestClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    response_200 = client.get("/health")
    config = client.get("/config")
    response_304 = client.get("/config", headers={"If-None-Match": config.headers["etag"]})
    response_400 = client.post("/sync", content=b"{", headers={"Content-Type": "application/json"})
    response_404 = client.get("/status-review-missing")
    response_405 = client.get("/sync")
    response_413 = client.post(
        "/sync", content=b"x" * 65_537, headers={"Content-Type": "application/json"}
    )
    response_415 = client.post(
        "/sync", content=b"{}", headers={"Content-Type": "application/jsonp"}
    )

    def explode(_: Session) -> bool:
        raise RuntimeError("status-sentinel")

    with monkeypatch.context() as failing_patch:
        failing_patch.setattr(main_module, "database_is_ready", explode)
        with TestClient(create_app(settings), raise_server_exceptions=False) as failing_client:
            response_500 = failing_client.get("/health")
    unavailable = Settings(
        DATABASE_URL="postgresql+psycopg://127.0.0.1:1/yperson_unavailable", _env_file=None
    )
    with TestClient(create_app(unavailable)) as unavailable_client:
        response_503 = unavailable_client.get("/health")

    responses = [
        response_200,
        config,
        response_304,
        response_400,
        response_404,
        response_405,
        response_413,
        response_415,
        response_500,
        response_503,
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


def test_sync_rolls_back_mutations_when_a_route_operation_fails(
    settings: Settings, session_factory: sessionmaker[Session], monkeypatch: pytest.MonkeyPatch
) -> None:
    original_publish = main_module.publish_card

    def mutate_then_fail(session: Session, installation_id: str, card: dict[str, object] | None):
        original_publish(session, installation_id, card)
        raise RuntimeError("rollback-sentinel")

    monkeypatch.setattr(main_module, "publish_card", mutate_then_fail)
    with TestClient(create_app(settings), raise_server_exceptions=False) as client:
        response = client.post(
            "/sync",
            json=valid_sync(
                installationID="rollback-installation", operation="publishCard", card=review_card()
            ),
        )

    assert response.status_code == 500
    with session_factory() as session:
        assert session.get(Profile, "rollback-installation") is None


def test_lifespan_disposes_the_app_owned_engine(
    settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    class Engine:
        disposed = False

        def dispose(self) -> None:
            self.disposed = True

    engine = Engine()
    monkeypatch.setattr(main_module, "create_session_factory", lambda _: (engine, object()))

    with TestClient(create_app(settings)):
        pass

    assert engine.disposed is True


def test_factory_loads_settings_and_creates_one_engine_for_one_app_lifecycle(
    settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    class Engine:
        disposed = False

        def dispose(self) -> None:
            self.disposed = True

    engine = Engine()
    settings_loads = 0
    engine_creations: list[Settings] = []

    def load_settings() -> Settings:
        nonlocal settings_loads
        settings_loads += 1
        return settings

    def create_factory(received_settings: Settings):
        engine_creations.append(received_settings)
        return engine, object()

    monkeypatch.setattr(main_module, "Settings", load_settings)
    monkeypatch.setattr(main_module, "create_session_factory", create_factory)
    with TestClient(create_app()):
        pass

    assert settings_loads == 1
    assert engine_creations == [settings]
    assert engine.disposed is True
