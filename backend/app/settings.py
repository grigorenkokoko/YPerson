"""Environment-backed settings for the YPerson service."""

from typing import Literal

from pydantic import AnyHttpUrl, Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Load only the explicitly approved service configuration."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore", populate_by_name=True)

    environment: Literal["development", "staging", "production"] = Field(
        default="development", validation_alias="YPERSON_ENV"
    )
    host: str = Field(default="127.0.0.1", validation_alias="HOST")
    port: int = Field(default=8080, validation_alias="PORT")
    config_version: str = Field(default="2026-08-18.1", validation_alias="YPERSON_CONFIG_VERSION")
    privacy_url: AnyHttpUrl = Field(
        default="https://example.invalid/yperson/privacy", validation_alias="YPERSON_PRIVACY_URL"
    )
    support_url: AnyHttpUrl = Field(
        default="https://example.invalid/yperson/support", validation_alias="YPERSON_SUPPORT_URL"
    )
    analytics_kill_switch: bool = Field(
        default=False, validation_alias="YPERSON_ANALYTICS_KILL_SWITCH"
    )
    graceful_shutdown_seconds: int = Field(default=15, validation_alias="GRACEFUL_SHUTDOWN_SECONDS")

    @model_validator(mode="after")
    def require_approved_production_authentication(self) -> "Settings":
        if self.environment == "production":
            raise ValueError("production requires separately approved authentication")
        return self
