"""Production-style executable entry point for the YPerson ASGI service."""

import uvicorn

from app.main import app


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
