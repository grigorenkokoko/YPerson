"""FastAPI implementation of the established YPerson iOS API contract."""

import json
import re
from hashlib import sha256

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import Lifespan

from app.observability import RequestObservabilityMiddleware, request_logger
from app.public_cards import (
    MAX_FORM_BODY_BYTES,
    PUBLIC_CARD_HEADERS,
    PublicCardService,
    parse_reply_form,
    public_card_json,
    render_public_card_html,
    render_vcard,
)
from app.public_pages import PRIVACY_HTML, SUPPORT_HTML
from app.schemas import PublicConfigResponse, SyncRequest, validate_public_link_token
from app.settings import Settings
from app.storage import InvalidCredential, PublicCardRecord, StorageConflict, StorageIntegrityError
from app.sync_service import SyncService, SyncUnavailable

MAX_SYNC_BODY_BYTES = 64 * 1024
_TOKEN68 = r"[A-Za-z0-9\-._~+/]+=*"
_BEARER_TOKEN = re.compile(rf"{_TOKEN68}\Z")
_MIME_TOKEN = r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+"
_MIME_QUOTED = r'"(?:[\t\x20-\x21\x23-\x5B\x5D-\x7E]|\\[\x20-\x7E])*"'
_JSON_CONTENT_TYPE = re.compile(
    rf"\Aapplication/json(?:[ \t]*;[ \t]*{_MIME_TOKEN}[ \t]*=[ \t]*"
    rf"(?:{_MIME_TOKEN}|{_MIME_QUOTED}))*[ \t]*\Z",
    re.IGNORECASE,
)
_BEARER_AUTHORIZATION = re.compile(rf"\A(?i:Bearer) +(?P<token>{_TOKEN68})\Z")


def create_app(
    settings: Settings | None = None,
    *,
    sync_service: SyncService | None = None,
    public_card_service: PublicCardService | None = None,
    lifespan: Lifespan[FastAPI] | None = None,
) -> FastAPI:
    """Create an isolated app serving the public API contract."""

    app_settings = settings or Settings()
    application = FastAPI(lifespan=lifespan)
    application.state.settings = app_settings
    application.state.sync_service = sync_service
    application.state.public_card_service = public_card_service
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

    @application.get("/.well-known/apple-app-site-association")
    def apple_app_site_association() -> JSONResponse:
        return JSONResponse(
            content={
                "applinks": {
                    "details": [
                        {
                            "appID": app_settings.apple_application_identifier,
                            "components": [{"/": "/p/*"}],
                        }
                    ]
                }
            },
            headers={"Cache-Control": "public, max-age=3600"},
        )

    @application.get("/p/{token}")
    async def public_card(request: Request, token: str) -> Response:
        record, failure = await _resolve_public_card(token, public_card_service)
        if failure is not None:
            return failure
        assert record is not None
        path = request.url.path
        current_https_url = str(request.url.replace(scheme="https"))
        return HTMLResponse(
            content=render_public_card_html(
                record.card,
                replies_path=f"{path}/replies",
                json_path=f"{path}/card.json",
                vcard_path=f"{path}/contact.vcf",
                app_store_id=app_settings.app_store_id,
                current_https_url=current_https_url,
            ),
            headers=PUBLIC_CARD_HEADERS,
        )

    @application.get("/p/{token}/card.json")
    async def public_card_json_response(token: str) -> Response:
        record, failure = await _resolve_public_card(token, public_card_service)
        if failure is not None:
            return failure
        assert record is not None
        return JSONResponse(content=public_card_json(record.card), headers=PUBLIC_CARD_HEADERS)

    @application.get("/p/{token}/contact.vcf")
    async def public_card_vcard(token: str) -> Response:
        record, failure = await _resolve_public_card(token, public_card_service)
        if failure is not None:
            return failure
        assert record is not None
        return Response(
            content=render_vcard(record.card),
            media_type="text/vcard",
            headers=PUBLIC_CARD_HEADERS | {"Content-Disposition": 'attachment; filename="contact.vcf"'},
        )

    @application.post("/p/{token}/replies")
    async def public_card_reply(request: Request, token: str) -> Response:
        if public_card_service is None:
            return _public_text_response("Public card temporarily unavailable", 503)
        try:
            validate_public_link_token(token)
        except ValueError:
            return _public_text_response("Public card not found", 404)

        content_type = request.headers.get("content-type", "")
        if content_type.partition(";")[0].strip().lower() != "application/x-www-form-urlencoded":
            return _public_text_response("Unsupported form content", 415)
        raw = await _bounded_public_reply_body(request)
        if raw is None:
            return _public_text_response("Reply form is too large", 413)
        try:
            reply_id, name, email, phone = parse_reply_form(raw)
        except ValueError:
            return _public_text_response("Invalid reply form", 400)
        try:
            await run_in_threadpool(
                public_card_service.submit_reply,
                token,
                reply_id,
                name,
                email,
                phone,
            )
        except StorageConflict as error:
            if str(error) == "public link unavailable":
                return _public_text_response("Public card not found", 404)
            return _public_text_response("Reply could not be accepted", 409)
        except Exception:  # noqa: BLE001 - storage failures must not expose token or reply data.
            return _public_text_response("Public card temporarily unavailable", 503)
        return HTMLResponse(
            content=(
                "<!doctype html><html lang=\"ru\"><meta charset=\"utf-8\">"
                "<title>Контакт отправлен</title><p>Контакт отправлен владельцу карточки.</p></html>"
            ),
            headers=PUBLIC_CARD_HEADERS,
        )

    @application.post("/sync")
    async def sync(request: Request) -> JSONResponse:
        if not _is_json_content_type(request.headers.get("content-type")):
            return _error_response(request, 415, "unsupported_media_type")

        body = await _bounded_body(request)
        if body is None:
            return _error_response(request, 413, "payload_too_large")

        bearer = _bearer(request.headers.get("authorization"))
        if bearer is None:
            return _error_response(request, 401, "unauthorized")

        try:
            sync_request = SyncRequest.model_validate_json(body)
        except (ValidationError, ValueError):
            return _error_response(request, 400, "invalid_request")

        if sync_service is None:
            return _error_response(request, 503, "temporarily_unavailable")

        try:
            response = await run_in_threadpool(sync_service.handle, sync_request, bearer)
        except InvalidCredential:
            return _error_response(request, 401, "unauthorized")
        except StorageConflict:
            return _error_response(request, 409, "conflict")
        except (StorageIntegrityError, SyncUnavailable) as error:
            _log_sync_failure(request, sync_request, error)
            return _error_response(request, 503, "temporarily_unavailable")
        except Exception as error:  # noqa: BLE001 - cloud adapter failures must stay sanitized.
            _log_sync_failure(request, sync_request, error)
            return _error_response(request, 503, "temporarily_unavailable")
        return JSONResponse(status_code=200, content=response.model_dump(mode="json"))

    return application


async def _resolve_public_card(
    token: str,
    service: PublicCardService | None,
) -> tuple[PublicCardRecord | None, Response | None]:
    if service is None:
        return None, _public_text_response("Public card temporarily unavailable", 503)
    try:
        validate_public_link_token(token)
    except ValueError:
        return None, _public_text_response("Public card not found", 404)
    try:
        record = await run_in_threadpool(service.card, token)
    except Exception:  # noqa: BLE001 - storage failures must not expose raw public tokens.
        return None, _public_text_response("Public card temporarily unavailable", 503)
    if record is None:
        return None, _public_text_response("Public card not found", 404)
    return record, None


def _public_text_response(content: str, status_code: int) -> Response:
    return Response(
        content=content,
        status_code=status_code,
        media_type="text/plain",
        headers=PUBLIC_CARD_HEADERS,
    )


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
    response_headers = dict(headers or {})
    if request.url.path.startswith("/p/"):
        response_headers = PUBLIC_CARD_HEADERS | response_headers
    return JSONResponse(status_code=status_code, content=content, headers=response_headers)


def _log_sync_failure(
    request: Request,
    sync_request: SyncRequest,
    error: BaseException,
) -> None:
    request_logger().error(
        "sync_failed",
        extra={
            "event": "sync_failed",
            "request_id": request.state.request_id,
            "method": "POST",
            "route": "/sync",
            "status": 503,
            "latency_ms": 0.0,
            "operation": sync_request.operation.value,
            "failure_types": _failure_types(error),
        },
    )


def _failure_types(error: BaseException) -> list[str]:
    result: list[str] = []
    seen: set[int] = set()
    current: BaseException | None = error
    while current is not None and id(current) not in seen and len(result) < 4:
        seen.add(id(current))
        error_type = type(current)
        result.append(f"{error_type.__module__}.{error_type.__qualname__}")
        current = current.__cause__ or current.__context__
    return result


def _is_json_content_type(content_type: str | None) -> bool:
    return content_type is not None and _JSON_CONTENT_TYPE.fullmatch(content_type) is not None


async def _bounded_body(request: Request) -> bytes | None:
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            if int(content_length) > MAX_SYNC_BODY_BYTES:
                return None
        except ValueError:
            return None

    body = bytearray()
    async for chunk in request.stream():
        if len(chunk) > MAX_SYNC_BODY_BYTES - len(body):
            return None
        body.extend(chunk)
    return bytes(body)


async def _bounded_public_reply_body(request: Request) -> bytes | None:
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            if int(content_length) > MAX_FORM_BODY_BYTES:
                return None
        except ValueError:
            return None

    body = bytearray()
    async for chunk in request.stream():
        if len(chunk) > MAX_FORM_BODY_BYTES - len(body):
            return None
        body.extend(chunk)
    return bytes(body)


def _bearer(authorization: str | None) -> str | None:
    if authorization is None:
        return None
    match = _BEARER_AUTHORIZATION.fullmatch(authorization)
    if match is None:
        return None
    token = match.group("token")
    if not 32 <= len(token) <= 512 or _BEARER_TOKEN.fullmatch(token) is None:
        return None
    return token


app = create_app()
