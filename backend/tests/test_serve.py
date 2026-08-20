"""Production-entrypoint behavior tests."""

import uvicorn
from fastapi.testclient import TestClient
from pytest import MonkeyPatch

from app import serve
from app.settings import Settings


def test_production_app_serves_health_with_current_fastapi_lifecycle(
    monkeypatch: MonkeyPatch,
) -> None:
    monkeypatch.setenv("YDB_ANONYMOUS_CREDENTIALS", "1")
    application = serve.build_app(
        Settings(
            environment="production",
            ydb_endpoint="grpcs://ydb.serverless.yandexcloud.net:2135",
            ydb_database="/ru-central1/test-folder/test-database",
            object_bucket="private-audio",
            s3_access_key_id="test-access-key",
            s3_secret_access_key="test-secret-key",
            sync_enabled=True,
        )
    )

    with TestClient(application) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "2026-08-18.1"}


def test_entrypoint_reuses_module_app_and_disables_uvicorn_access_logging() -> None:
    config = serve.build_config()

    assert isinstance(config, uvicorn.Config)
    assert config.app is serve.app
    assert config.host == serve.app.state.settings.host
    assert config.port == serve.app.state.settings.port
    assert config.access_log is False
    assert config.log_config is None
