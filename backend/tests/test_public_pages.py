"""Contract tests for the public technical information pages."""

from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.settings import Settings


@pytest.fixture
def client() -> Generator[TestClient]:
    with TestClient(create_app(Settings(_env_file=None))) as test_client:
        yield test_client


@pytest.mark.parametrize(
    ("path", "title"),
    (("/privacy", "Конфиденциальность YPerson"), ("/support", "Поддержка YPerson")),
)
def test_public_page_is_small_safe_utf8_html(client: TestClient, path: str, title: str) -> None:
    response = client.get(path)
    source = response.text.casefold()

    assert response.status_code == 200
    assert response.headers["content-type"] == "text/html; charset=utf-8"
    assert response.headers["cache-control"] == "no-store"
    assert title in response.text
    assert len(response.content) < 8_192
    for prohibited in ("<script", "<form", "<img", "document.cookie", "localstorage", "http://"):
        assert prohibited not in source


def test_privacy_page_describes_only_the_database_free_technical_release(
    client: TestClient,
) -> None:
    source = client.get("/privacy").text

    assert "GET /config" in source
    assert "POST /sync" in source
    assert "не сохраняет профили или APNs-токены" in source
    assert "не является окончательной юридической политикой" in source


def test_support_page_uses_the_public_issue_tracker_and_discloses_disabled_flows(
    client: TestClient,
) -> None:
    source = client.get("/support").text

    assert 'href="https://github.com/grigorenkokoko/YPerson/issues"' in source
    assert "Синхронизация и удалённые push-уведомления пока недоступны" in source
    assert source.count("https://") == 1
