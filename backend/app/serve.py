"""Production-style executable entry point for the YPerson ASGI service."""

import uvicorn

from app.main import create_app
from app.settings import Settings


def main() -> None:
    """Load validated settings once, then run Uvicorn with graceful shutdown settings."""

    settings = Settings()
    config = uvicorn.Config(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        timeout_graceful_shutdown=settings.graceful_shutdown_seconds,
    )
    uvicorn.Server(config).run()


if __name__ == "__main__":
    main()
