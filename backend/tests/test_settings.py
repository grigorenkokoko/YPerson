import pytest
from pydantic import ValidationError

from app.settings import Settings


def test_development_defaults_are_safe() -> None:
    settings = Settings(_env_file=None)

    assert settings.environment == "development"
    assert settings.host == "127.0.0.1"
    assert settings.port == 8080


def test_environment_aliases_override_configuration() -> None:
    settings = Settings(
        YPERSON_ENV="staging",
        HOST="0.0.0.0",
        PORT="9090",
        YPERSON_CONFIG_VERSION="2026-08-18.2",
        YPERSON_PRIVACY_URL="https://privacy.example/yperson",
        YPERSON_SUPPORT_URL="https://support.example/yperson",
        YPERSON_ANALYTICS_KILL_SWITCH="true",
        GRACEFUL_SHUTDOWN_SECONDS="20",
        _env_file=None,
    )

    assert settings.environment == "staging"
    assert settings.host == "0.0.0.0"
    assert settings.port == 9090
    assert settings.config_version == "2026-08-18.2"
    assert settings.graceful_shutdown_seconds == 20
    assert settings.analytics_kill_switch is True


def test_production_is_fail_closed_without_approved_authentication() -> None:
    with pytest.raises(ValidationError, match="approved authentication"):
        Settings(YPERSON_ENV="production", _env_file=None)
