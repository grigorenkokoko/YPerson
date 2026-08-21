"""Production-style executable entry point for the YPerson ASGI service."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime

import uvicorn
import ydb
from fastapi import FastAPI

from app.main import create_app
from app.media_service import MediaService
from app.object_storage import ObjectStorage
from app.public_cards import PublicCardService
from app.settings import Settings
from app.sync_service import SyncService
from app.ydb_store import YDBSyncStore


class RuntimeResources:
    """Own the YDB driver and pool for one server process."""

    def __init__(self, settings: Settings) -> None:
        config = ydb.DriverConfig(
            endpoint=settings.ydb_endpoint,
            database=settings.ydb_database,
            credentials=ydb.credentials_from_env_variables(),
            root_certificates=ydb.load_ydb_root_certificate(),
        )
        self.driver = ydb.Driver(config)
        self.pool = ydb.QuerySessionPool(self.driver)

    def close(self) -> None:
        self.pool.stop(timeout=10)
        self.driver.stop(timeout=10)


def build_app(settings: Settings | None = None) -> FastAPI:
    """Build the fail-closed public app and its optional durable sync runtime."""

    app_settings = settings or Settings()
    if not app_settings.sync_enabled:
        return create_app(app_settings)

    resources = RuntimeResources(app_settings)
    clock = lambda: datetime.now(UTC)
    store = YDBSyncStore(resources.pool, clock=clock)
    object_storage = ObjectStorage(
        app_settings.object_bucket,
        app_settings.s3_access_key_id,
        app_settings.s3_secret_access_key,
    )
    media_service = MediaService(store, object_storage, clock=clock)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            resources.close()

    application = create_app(
        app_settings,
        sync_service=SyncService(
            store,
            clock=clock,
            media_service=media_service,
            object_cleanup=media_service.delete_objects,
        ),
        public_card_service=PublicCardService(store, clock=clock),
        lifespan=lifespan,
    )
    application.state.runtime_resources = resources
    return application


app = build_app()


def build_config() -> uvicorn.Config:
    """Configure Uvicorn around the single validated module application."""

    settings = app.state.settings
    return uvicorn.Config(
        app,
        host=settings.host,
        port=settings.port,
        timeout_graceful_shutdown=settings.graceful_shutdown_seconds,
        access_log=False,
        log_config=None,
    )


def main() -> None:
    """Run the one module application and its app-owned lifecycle."""

    uvicorn.Server(build_config()).run()


if __name__ == "__main__":
    main()
