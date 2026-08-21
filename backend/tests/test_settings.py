import pytest
from pydantic import ValidationError

from app.settings import Settings


def test_development_defaults_are_safe() -> None:
    settings = Settings(_env_file=None)

    assert settings.environment == "development"
    assert settings.host == "127.0.0.1"
    assert settings.port == 8080
    assert settings.app_store_id == ""
    assert settings.apple_application_identifier == "Q7A52Z2TS2.com.yperson.app"


def test_environment_aliases_override_configuration() -> None:
    settings = Settings(
        YPERSON_ENV="staging",
        HOST="0.0.0.0",
        PORT="9090",
        YPERSON_CONFIG_VERSION="2026-08-18.2",
        YPERSON_PRIVACY_URL="https://privacy.example/yperson",
        YPERSON_SUPPORT_URL="https://support.example/yperson",
        YPERSON_ANALYTICS_KILL_SWITCH="true",
        YPERSON_APP_STORE_ID="123456789",
        YPERSON_APPLE_APPLICATION_IDENTIFIER="TEAMID.com.example.yperson",
        GRACEFUL_SHUTDOWN_SECONDS="20",
        _env_file=None,
    )

    assert settings.environment == "staging"
    assert settings.host == "0.0.0.0"
    assert settings.port == 9090
    assert settings.config_version == "2026-08-18.2"
    assert settings.graceful_shutdown_seconds == 20
    assert settings.analytics_kill_switch is True
    assert settings.app_store_id == "123456789"
    assert settings.apple_application_identifier == "TEAMID.com.example.yperson"


def test_production_requires_enabled_durable_storage() -> None:
    with pytest.raises(ValidationError, match="durable storage"):
        Settings(YPERSON_ENV="production", YPERSON_SYNC_ENABLED="true", _env_file=None)


def test_production_accepts_enabled_durable_storage() -> None:
    settings = Settings(
        YPERSON_ENV="production",
        YPERSON_SYNC_ENABLED="true",
        YDB_ENDPOINT="grpcs://ydb.example:2135",
        YDB_DATABASE="/ru-central1/b1g/example",
        YPERSON_OBJECT_BUCKET="yperson-private-audio",
        YPERSON_S3_ACCESS_KEY_ID="access-key",
        YPERSON_S3_SECRET_ACCESS_KEY="secret-key",
        _env_file=None,
    )

    assert settings.sync_enabled is True
    assert settings.ydb_database == "/ru-central1/b1g/example"
