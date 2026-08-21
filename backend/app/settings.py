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
    app_store_id: str = Field(default="", validation_alias="YPERSON_APP_STORE_ID")
    apple_application_identifier: str = Field(
        default="Q7A52Z2TS2.com.yperson.app",
        validation_alias="YPERSON_APPLE_APPLICATION_IDENTIFIER",
    )
    graceful_shutdown_seconds: int = Field(default=15, validation_alias="GRACEFUL_SHUTDOWN_SECONDS")
    ydb_endpoint: str = Field(default="", validation_alias="YDB_ENDPOINT")
    ydb_database: str = Field(default="", validation_alias="YDB_DATABASE")
    object_bucket: str = Field(default="", validation_alias="YPERSON_OBJECT_BUCKET")
    s3_access_key_id: str = Field(default="", validation_alias="YPERSON_S3_ACCESS_KEY_ID")
    s3_secret_access_key: str = Field(default="", validation_alias="YPERSON_S3_SECRET_ACCESS_KEY")
    sync_enabled: bool = Field(default=False, validation_alias="YPERSON_SYNC_ENABLED")

    @model_validator(mode="after")
    def require_approved_production_authentication(self) -> "Settings":
        durable_storage_values = (
            self.ydb_endpoint,
            self.ydb_database,
            self.object_bucket,
            self.s3_access_key_id,
            self.s3_secret_access_key,
        )
        if self.environment == "production" and (
            not self.sync_enabled or any(not value.strip() for value in durable_storage_values)
        ):
            raise ValueError("production requires enabled durable storage")
        return self
