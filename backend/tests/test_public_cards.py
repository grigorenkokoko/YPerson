"""Public universal-card routes and their privacy boundary."""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Generator
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from uuid import uuid4

import anyio
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.main import create_app
from app.observability import JsonRequestFormatter, request_logger
from app.public_cards import PublicCardService
from app.schemas import PersonCard
from app.settings import Settings
from app.storage import PublicCardRecord, StorageConflict

VALID_TOKEN = "A" * 43
REVOKED_TOKEN = "A" * 42 + "E"
UNKNOWN_TOKEN = "A" * 42 + "I"
VALID_PATH = f"/p/{VALID_TOKEN}"


@asynccontextmanager
async def noop_lifespan(_: FastAPI):
    yield


def public_record(**overrides: object) -> PublicCardRecord:
    values: dict[str, object] = {
        "id": "Закрытая заметка",
        "name": "Алексей Морозов",
        "role": "Product Lead",
        "company": "North Star",
        "phone": "+79005550102",
        "email": "alexey@example.com",
        "tagline": "Connecting people",
        "hasAudioGreeting": True,
        "meetingPlace": "meetingPlace",
        "isBlocked": True,
        "templateID": "mint-conference",
    }
    values.update(overrides)
    return PublicCardRecord(
        owner_installation_id="installation-owner-0001",
        card=PersonCard.model_validate(values),
    )


class FakePublicCardService:
    def __init__(self, record: PublicCardRecord | None = None) -> None:
        self.record = record or public_record()
        self.submissions: list[tuple[str, str, str, str | None, str | None]] = []
        self.conflict: str | None = None

    def card(self, raw_token: str) -> PublicCardRecord | None:
        if raw_token in {REVOKED_TOKEN, UNKNOWN_TOKEN}:
            return None
        return self.record

    def submit_reply(
        self,
        raw_token: str,
        reply_id: str,
        name: str,
        email: str | None,
        phone: str | None,
    ) -> None:
        if self.conflict is not None:
            raise StorageConflict(self.conflict)
        self.submissions.append((raw_token, reply_id, name, email, phone))


@pytest.fixture
def public_client() -> Generator[tuple[TestClient, FakePublicCardService]]:
    service = FakePublicCardService()
    application = create_app(
        Settings(_env_file=None),
        sync_service=None,
        public_card_service=service,
        lifespan=noop_lifespan,
    )
    with TestClient(application, base_url="https://cards.example") as client:
        yield client, service


def _direct_form_post(
    *,
    headers: list[tuple[bytes, bytes]],
    messages: list[dict[str, object]],
) -> tuple[int, int]:
    application = create_app(
        Settings(_env_file=None),
        public_card_service=FakePublicCardService(),
        lifespan=noop_lifespan,
    )

    async def scenario() -> tuple[int, int]:
        pending = list(messages)
        receive_calls = 0
        response_status: int | None = None

        async def receive() -> dict[str, object]:
            nonlocal receive_calls
            receive_calls += 1
            if not pending:
                return {"type": "http.disconnect"}
            return pending.pop(0)

        async def send(message: dict[str, object]) -> None:
            nonlocal response_status
            if message["type"] == "http.response.start":
                response_status = int(message["status"])

        path = f"{VALID_PATH}/replies"
        await application(
            {
                "type": "http",
                "asgi": {"version": "3.0"},
                "http_version": "1.1",
                "method": "POST",
                "scheme": "https",
                "path": path,
                "raw_path": path.encode(),
                "query_string": b"",
                "headers": [(b"host", b"cards.example"), *headers],
                "client": ("127.0.0.1", 12345),
                "server": ("cards.example", 443),
                "root_path": "",
                "extensions": {},
            },
            receive,
            send,
        )
        assert response_status is not None
        return response_status, receive_calls

    return anyio.run(scenario)


def test_public_card_route_fails_closed_when_service_is_unavailable() -> None:
    with TestClient(create_app(Settings(_env_file=None))) as client:
        response = client.get(VALID_PATH)

    assert response.status_code == 503
    assert response.text == "Public card temporarily unavailable"


def test_revoked_and_unknown_tokens_share_the_same_safe_404(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, _ = public_client

    unknown = client.get(f"/p/{UNKNOWN_TOKEN}")
    revoked = client.get(f"/p/{REVOKED_TOKEN}")

    assert unknown.status_code == revoked.status_code == 404
    assert unknown.text == revoked.text == "Public card not found"


def test_private_fields_never_appear_in_public_outputs(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, _ = public_client

    outputs = (
        client.get(VALID_PATH).text
        + client.get(f"{VALID_PATH}/card.json").text
        + client.get(f"{VALID_PATH}/contact.vcf").text
    )

    for secret in ("+79005550102", "Закрытая заметка", "meetingPlace"):
        assert secret not in outputs


def test_html_escapes_every_public_text_field() -> None:
    marker = '<script>alert("unsafe")</script>'
    service = FakePublicCardService(
        public_record(name=marker, role=marker, company=marker, email=marker, tagline=marker)
    )
    application = create_app(
        Settings(_env_file=None),
        public_card_service=service,
        lifespan=noop_lifespan,
    )

    with TestClient(application, base_url="https://cards.example") as client:
        response = client.get(VALID_PATH)

    assert marker not in response.text
    assert response.text.count("&lt;script&gt;") >= 5


def test_json_is_no_store_and_contains_only_approved_person_card_keys(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, _ = public_client

    response = client.get(f"{VALID_PATH}/card.json")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.json() == {
        "name": "Алексей Морозов",
        "role": "Product Lead",
        "company": "North Star",
        "email": "alexey@example.com",
        "tagline": "Connecting people",
        "templateID": "mint-conference",
    }


def test_guest_html_has_no_navigation_to_native_json_endpoint(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, _ = public_client

    response = client.get(VALID_PATH)

    assert response.status_code == 200
    assert "Открыть JSON" not in response.text
    assert f"{VALID_PATH}/card.json" not in response.text


def test_vcard_escapes_cr_lf_backslash_semicolon_and_comma() -> None:
    unsafe = "A\\B;\r\n,C"
    service = FakePublicCardService(
        public_record(name=unsafe, role=unsafe, company=unsafe, email=unsafe, tagline=unsafe)
    )
    application = create_app(
        Settings(_env_file=None),
        public_card_service=service,
        lifespan=noop_lifespan,
    )

    with TestClient(application) as client:
        response = client.get(f"{VALID_PATH}/contact.vcf")

    assert response.status_code == 200
    assert "FN:A\\\\B\\;\\n\\,C\r\n" in response.text
    assert "TITLE:A\\\\B\\;\\n\\,C\r\n" in response.text
    assert "ORG:A\\\\B\\;\\n\\,C\r\n" in response.text
    assert "EMAIL:A\\\\B\\;\\n\\,C\r\n" in response.text
    assert "NOTE:A\\\\B\\;\\n\\,C\r\n" in response.text


@pytest.mark.parametrize(
    "body",
    [
        "replyID=not-a-uuid&name=Anna&email=a%40example.invalid&phone=&consent=on",
        f"replyID={uuid4()}&name=+&email=a%40example.invalid&phone=&consent=on",
        f"replyID={uuid4()}&name=Anna&email=&phone=&consent=on",
        f"replyID={uuid4()}&name=Anna&email=a%40example.invalid&phone=%2B7000&consent=on",
        f"replyID={uuid4()}&name=Anna&email=a%40example.invalid&phone=&consent=off",
        f"replyID={uuid4()}&replyID={uuid4()}&name=Anna&email=a%40example.invalid&consent=on",
    ],
)
def test_invalid_reply_forms_are_rejected_without_persistence(
    public_client: tuple[TestClient, FakePublicCardService],
    body: str,
) -> None:
    client, service = public_client

    response = client.post(
        f"{VALID_PATH}/replies",
        content=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    assert response.status_code == 400
    assert service.submissions == []


def test_reply_form_rejects_non_form_content_and_body_above_four_kib(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, service = public_client

    wrong_type = client.post(f"{VALID_PATH}/replies", content=b"{}")
    oversized = client.post(
        f"{VALID_PATH}/replies",
        content=b"x" * 4_097,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    assert wrong_type.status_code == 415
    assert oversized.status_code == 413
    assert service.submissions == []


def test_reply_form_rejects_oversized_content_length_without_reading_body() -> None:
    status, receive_calls = _direct_form_post(
        headers=[
            (b"content-type", b"application/x-www-form-urlencoded"),
            (b"content-length", b"4097"),
        ],
        messages=[{"type": "http.request", "body": b"x" * 4_097, "more_body": False}],
    )

    assert status == 413
    assert receive_calls == 0


def test_reply_form_stops_reading_chunked_body_as_soon_as_limit_is_exceeded() -> None:
    status, receive_calls = _direct_form_post(
        headers=[(b"content-type", b"application/x-www-form-urlencoded")],
        messages=[
            {"type": "http.request", "body": b"x" * 2_048, "more_body": True},
            {"type": "http.request", "body": b"x" * 2_048, "more_body": True},
            {"type": "http.request", "body": b"x", "more_body": True},
            {"type": "http.request", "body": b"must-not-be-read", "more_body": False},
        ],
    )

    assert status == 413
    assert receive_calls == 3


def test_valid_reply_is_trimmed_and_success_page_echoes_no_contact_data(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, service = public_client
    reply_id = str(uuid4())

    response = client.post(
        f"{VALID_PATH}/replies",
        data={
            "replyID": reply_id,
            "name": "  Anna  ",
            "email": "  anna@example.invalid  ",
            "phone": "",
            "consent": "on",
        },
    )

    assert response.status_code == 200
    assert service.submissions == [
        (VALID_TOKEN, reply_id, "Anna", "anna@example.invalid", None)
    ]
    assert "Anna" not in response.text
    assert "anna@example.invalid" not in response.text


def test_valid_reply_uses_a_server_side_thirty_day_expiry() -> None:
    now = datetime(2026, 8, 21, 12, 30, tzinfo=UTC)

    class RecordingStore:
        def __init__(self) -> None:
            self.expires_at: datetime | None = None

        def resolve_public_card(self, raw_token: str) -> PublicCardRecord | None:
            del raw_token
            return public_record()

        def create_public_reply(
            self,
            raw_token: str,
            reply_id: str,
            name: str,
            email: str | None,
            phone: str | None,
            expires_at: datetime,
        ) -> None:
            del raw_token, reply_id, name, email, phone
            self.expires_at = expires_at

    store = RecordingStore()
    service = PublicCardService(store, clock=lambda: now)

    service.submit_reply(
        VALID_TOKEN,
        str(uuid4()),
        "Anna",
        "anna@example.invalid",
        None,
    )

    assert store.expires_at == now + timedelta(days=30)


def test_storage_conflicts_are_safely_mapped_without_swallowing_all_causes(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, service = public_client
    body = {
        "replyID": str(uuid4()),
        "name": "Anna",
        "email": "anna@example.invalid",
        "phone": "",
        "consent": "on",
    }

    service.conflict = "public link unavailable"
    revoked = client.post(f"{VALID_PATH}/replies", data=body)
    service.conflict = "reply limit reached"
    limit = client.post(f"{VALID_PATH}/replies", data=body)

    assert revoked.status_code == 404
    assert revoked.text == "Public card not found"
    assert limit.status_code == 409
    assert limit.text == "Reply could not be accepted"


def test_public_page_has_security_headers_no_script_and_no_default_smart_banner(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, _ = public_client

    response = client.get(VALID_PATH)

    assert response.status_code == 200
    assert response.headers["x-robots-tag"] == "noindex, nofollow"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["content-security-policy"] == (
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    )
    assert "<script" not in response.text.lower()
    assert "apple-itunes-app" not in response.text
    assert "set-cookie" not in response.headers
    assert re.search(r"<meta[^>]+robots", response.text, re.IGNORECASE) is None


@pytest.mark.parametrize(
    ("method", "path", "status"),
    [
        ("put", VALID_PATH, 405),
        ("get", f"{VALID_PATH}/unknown", 404),
    ],
)
def test_framework_errors_under_public_paths_keep_public_security_headers(
    public_client: tuple[TestClient, FakePublicCardService],
    method: str,
    path: str,
    status: int,
) -> None:
    client, _ = public_client

    response = getattr(client, method)(path)

    assert response.status_code == status
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-robots-tag"] == "noindex, nofollow"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["content-security-policy"].startswith("default-src 'none'")


def test_smart_app_banner_uses_only_configured_id_and_current_https_url() -> None:
    service = FakePublicCardService()
    application = create_app(
        Settings(YPERSON_APP_STORE_ID="123456789", _env_file=None),
        public_card_service=service,
        lifespan=noop_lifespan,
    )

    with TestClient(application, base_url="https://cards.example") as client:
        response = client.get(VALID_PATH)

    assert (
        '<meta name="apple-itunes-app" '
        f'content="app-id=123456789, app-argument=https://cards.example{VALID_PATH}">'
        in response.text
    )


def test_aasa_contains_only_configured_app_id_and_public_path_components() -> None:
    application = create_app(Settings(_env_file=None), lifespan=noop_lifespan)

    with TestClient(application) as client:
        response = client.get("/.well-known/apple-app-site-association", follow_redirects=False)

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json"
    assert response.headers["cache-control"] == "public, max-age=3600"
    assert response.json() == {
        "applinks": {
            "details": [
                {
                    "appID": "Q7A52Z2TS2.com.yperson.app",
                    "components": [{"/": "/p/*"}],
                }
            ]
        }
    }


def test_observability_uses_route_templates_and_never_emits_public_input(
    public_client: tuple[TestClient, FakePublicCardService],
) -> None:
    client, _ = public_client
    logger = request_logger()
    captured: list[str] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            captured.append(self.format(record))

    handler = Capture()
    handler.setFormatter(JsonRequestFormatter())
    logger.addHandler(handler)
    reply_id = str(uuid4())
    try:
        client.get(VALID_PATH)
        client.get(f"{VALID_PATH}/card.json")
        client.get(f"{VALID_PATH}/contact.vcf")
        client.post(
            f"{VALID_PATH}/replies",
            data={
                "replyID": reply_id,
                "name": "private-name-sentinel",
                "email": "private-contact-sentinel@example.invalid",
                "phone": "",
                "consent": "on",
            },
        )
    finally:
        logger.removeHandler(handler)

    records = [json.loads(line) for line in captured]
    assert [record["route"] for record in records] == [
        "/p/{token}",
        "/p/{token}/card.json",
        "/p/{token}/contact.vcf",
        "/p/{token}/replies",
    ]
    output = "\n".join(captured)
    assert VALID_TOKEN not in output
    assert "private-name-sentinel" not in output
    assert "private-contact-sentinel@example.invalid" not in output


def test_invalid_tokens_are_not_passed_to_the_public_service() -> None:
    service = SimpleNamespace(card=lambda _token: pytest.fail("service must not be called"))
    application = create_app(
        Settings(_env_file=None),
        public_card_service=service,
        lifespan=noop_lifespan,
    )

    with TestClient(application) as client:
        response = client.get("/p/not-a-canonical-token")

    assert response.status_code == 404
    assert response.text == "Public card not found"
