"""FastAPI implementation of the established YPerson iOS API contract."""

import json
from hashlib import sha256

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.observability import RequestObservabilityMiddleware
from app.public_pages import PRIVACY_HTML, SUPPORT_HTML
from app.schemas import PublicConfigResponse
from app.settings import Settings


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create an isolated app serving the public API contract."""

    app_settings = settings or Settings()
    application = FastAPI()
    application.state.settings = app_settings
    application.add_middleware(RequestObservabilityMiddleware)

    @application.exception_handler(StarletteHTTPException)
    async def http_exception_handler(
        request: Request, exception: StarletteHTTPException
    ) -> JSONResponse:
        if exception.status_code == 404:
            return _error_response(request, 404, "not_found")
        if exception.status_code == 405:
            return _error_response(
                request,
                405,
                "method_not_allowed",
                headers=exception.headers,
            )
        return _error_response(request, exception.status_code, "invalid_request", "invalid request")

    @application.exception_handler(Exception)
    async def unexpected_error_handler(request: Request, _: Exception) -> JSONResponse:
        return _error_response(request, 500, "internal_error", "internal error")

    @application.get("/health")
    def health() -> JSONResponse:
        return JSONResponse(
            status_code=200,
            content={"status": "ok", "version": app_settings.config_version},
        )

    config = _public_config(app_settings)
    config_bytes = json.dumps(
        config.model_dump(mode="json"), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    config_etag = f'"{sha256(config_bytes).hexdigest()}"'

    @application.get("/config")
    def config_response(request: Request) -> Response:
        headers = {"ETag": config_etag, "Cache-Control": "public, max-age=60"}
        if request.headers.get("if-none-match") == config_etag:
            return Response(status_code=304, headers=headers)
        return Response(content=config_bytes, media_type="application/json", headers=headers)

    @application.get("/privacy", response_class=HTMLResponse)
    def privacy() -> HTMLResponse:
        return HTMLResponse(content=PRIVACY_HTML)

    @application.get("/support", response_class=HTMLResponse)
    def support() -> HTMLResponse:
        return HTMLResponse(content=SUPPORT_HTML)

    @application.post("/sync")
    def sync(request: Request) -> JSONResponse:
        return _error_response(
            request,
            503,
            "temporarily_unavailable",
            "sync is not enabled",
        )

    return application


def _public_config(settings: Settings) -> PublicConfigResponse:
    return PublicConfigResponse.model_validate(
        {
            "version": settings.config_version,
            "minimumContract": 1,
            "maintenance": False,
            "features": {
                "nearbyExchange": True,
                "sponsoredTemplates": True,
                "remoteNotifications": True,
            },
            "sponsoredTemplates": [
                {"id": "mint-conference", "title": "Mint Conference", "accentHex": "#AEEBD3"},
                {"id": "indigo-studio", "title": "Indigo Studio", "accentHex": "#4F5FE7"},
            ],
            "privacyURL": str(settings.privacy_url),
            "supportURL": str(settings.support_url),
            "moderationCategories": ["spam", "abusive_content", "impersonation"],
            "analyticsKillSwitch": settings.analytics_kill_switch,
        }
    )


def _error_response(
    request: Request,
    status_code: int,
    error: str,
    message: str | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    content: dict[str, str] = {"error": error, "requestID": request.state.request_id}
    if message is not None:
        content["message"] = message
    return JSONResponse(status_code=status_code, content=content, headers=headers)


app = create_app()
