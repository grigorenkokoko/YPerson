"""FastAPI implementation of the established YPerson iOS API contract."""

import json
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from hashlib import sha256
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from pydantic import ValidationError
from sqlalchemy.orm import Session
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.observability import RequestObservabilityMiddleware
from app.schemas import PublicConfigResponse, SyncOperation, SyncRequest, SyncResponse
from app.settings import Settings
from app.storage import (
    create_session_factory,
    database_is_ready,
    delete_profile,
    ensure_profile,
    publish_card,
    record_block,
    record_report,
    set_push_token,
    store_exchange_claim,
)


class InvalidRequestError(Exception):
    """A deliberately generic client error which never echoes submitted data."""


class UnsupportedMediaTypeError(Exception):
    """Raised when `/sync` is sent something other than JSON."""


class BodyLimitMiddleware:
    """Buffer `/sync` bodies with an ASGI byte limit before application parsing."""

    def __init__(self, app: ASGIApp, max_body_bytes: int) -> None:
        self.app = app
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] != "/sync":
            await self.app(scope, receive, send)
            return

        content_length = _content_length(scope)
        if content_length is not None and content_length > self.max_body_bytes:
            await _body_too_large_response(scope, receive, send)
            return

        chunks: list[bytes] = []
        size = 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            if message["type"] != "http.request":
                continue
            body = message.get("body", b"")
            size += len(body)
            if size > self.max_body_bytes:
                await _body_too_large_response(scope, receive, send)
                return
            chunks.append(body)
            if not message.get("more_body", False):
                break

        body = b"".join(chunks)
        sent = False

        async def receive_body() -> Message:
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body, "more_body": False}
            return {"type": "http.disconnect"}

        await self.app(scope, receive_body, send)


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create an isolated app with its own settings, engine, and session factory."""

    app_settings = settings or Settings()
    engine, session_factory = create_session_factory(app_settings)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            engine.dispose()

    application = FastAPI(lifespan=lifespan)
    application.state.settings = app_settings
    application.state.session_factory = session_factory
    application.add_middleware(BodyLimitMiddleware, max_body_bytes=app_settings.max_body_bytes)
    application.add_middleware(RequestObservabilityMiddleware)

    @application.exception_handler(InvalidRequestError)
    async def invalid_request_handler(request: Request, _: InvalidRequestError) -> JSONResponse:
        return _error_response(request, 400, "invalid_request", "invalid request")

    @application.exception_handler(UnsupportedMediaTypeError)
    async def unsupported_media_type_handler(
        request: Request, _: UnsupportedMediaTypeError
    ) -> JSONResponse:
        return _error_response(
            request, 415, "invalid_request", "content type must be application/json"
        )

    @application.exception_handler(ValidationError)
    async def validation_error_handler(request: Request, _: ValidationError) -> JSONResponse:
        return _error_response(request, 400, "invalid_request", "invalid request")

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
        with session_factory() as session:
            ready = database_is_ready(session)
        status = "ok" if ready else "unavailable"
        return JSONResponse(
            status_code=200 if ready else 503,
            content={"status": status, "version": app_settings.config_version},
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

    @application.post("/sync", response_model=SyncResponse)
    async def sync(request: Request) -> SyncResponse:
        _require_json_content_type(request)
        payload = _parse_sync_payload(await request.body())
        with session_factory.begin() as session:
            response = _apply_sync(session, payload, app_settings.config_version)
        return response

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


def _require_json_content_type(request: Request) -> None:
    media_type = request.headers.get("content-type", "").partition(";")[0].strip().lower()
    if media_type != "application/json":
        raise UnsupportedMediaTypeError()


def _parse_sync_payload(body: bytes) -> SyncRequest:
    try:
        payload: Any = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidRequestError() from error
    try:
        return SyncRequest.model_validate(payload)
    except ValidationError as error:
        raise InvalidRequestError() from error


def _apply_sync(session: Session, payload: SyncRequest, version: str) -> SyncResponse:
    update_count = 0
    if payload.operation is SyncOperation.publish_card:
        card = (
            payload.card.model_dump(mode="json", exclude_none=True)
            if payload.card is not None
            else None
        )
        update_count = publish_card(session, payload.installationID, card).update_count
    elif payload.operation is SyncOperation.claim_exchange:
        if payload.exchangeToken is None or len(payload.exchangeToken) < 8:
            raise InvalidRequestError()
        store_exchange_claim(
            session, payload.installationID, payload.exchangeToken, datetime.now(UTC)
        )
        update_count = ensure_profile(session, payload.installationID).update_count
    elif payload.operation is SyncOperation.update_push_token:
        update_count = set_push_token(
            session, payload.installationID, payload.apnsToken
        ).update_count
    elif payload.operation is SyncOperation.remove_push_token:
        update_count = set_push_token(session, payload.installationID, None).update_count
    elif payload.operation is SyncOperation.delete_profile:
        delete_profile(session, payload.installationID)
        return SyncResponse(
            accepted=True,
            serverVersion=version,
            updateCount=0,
            message="profile deletion accepted; backup purge window is 30 days",
        )
    elif payload.operation is SyncOperation.report:
        record_report(session, payload.installationID, payload.moderationCategory)
        update_count = ensure_profile(session, payload.installationID).update_count
    elif payload.operation is SyncOperation.block:
        record_block(session, payload.installationID, datetime.now(UTC))
        update_count = ensure_profile(session, payload.installationID).update_count
    else:
        update_count = ensure_profile(session, payload.installationID).update_count
    return SyncResponse(
        accepted=True,
        serverVersion=version,
        updateCount=update_count,
        message=f"{payload.operation.value} accepted",
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


async def _body_too_large_response(scope: Scope, receive: Receive, send: Send) -> None:
    request_id = scope["state"]["request_id"]
    response = JSONResponse(
        status_code=413,
        content={
            "error": "invalid_request",
            "message": "request body exceeds 64 KiB",
            "requestID": request_id,
        },
    )
    await response(scope, receive, send)


def _content_length(scope: Scope) -> int | None:
    for name, value in scope["headers"]:
        if name.lower() == b"content-length":
            try:
                return int(value)
            except ValueError:
                return None
    return None


app = create_app()
