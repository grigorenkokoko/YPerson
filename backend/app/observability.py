"""Request-safe structured logging and ASGI response safeguards."""

import json
import logging
from datetime import UTC, datetime
from time import perf_counter
from uuid import uuid4

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class JsonRequestFormatter(logging.Formatter):
    """Render only approved request metadata as one JSON line."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps(
            {
                "timestamp": datetime.now(UTC).isoformat(),
                "level": record.levelname,
                "event": record.event,
                "requestID": record.request_id,
                "method": record.method,
                "route": record.route,
                "status": record.status,
                "latencyMs": record.latency_ms,
            },
            separators=(",", ":"),
        )


def request_logger() -> logging.Logger:
    """Return the dedicated logger without adding unsafe default formatting."""

    logger = logging.getLogger("yperson.requests")
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(JsonRequestFormatter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


class RequestObservabilityMiddleware:
    """Attach request IDs, cache defaults, and safe request-completion logs."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app
        self.logger = request_logger()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        request_id = str(uuid4())
        scope.setdefault("state", {})["request_id"] = request_id
        started = perf_counter()
        response_status = 500
        response_started = False

        async def send_with_headers(message: Message) -> None:
            nonlocal response_started, response_status
            if message["type"] == "http.response.start":
                response_started = True
                response_status = message["status"]
                headers = list(message.get("headers", []))
                header_names = {name.lower() for name, _ in headers}
                if b"x-request-id" not in header_names:
                    headers.append((b"x-request-id", request_id.encode()))
                if b"cache-control" not in header_names:
                    headers.append((b"cache-control", b"no-store"))
                message = {**message, "headers": headers}
            await send(message)

        try:
            await self.app(scope, receive, send_with_headers)
        except Exception:  # noqa: BLE001 - the middleware must sanitize every route exception.
            if not response_started:
                response_status = 500
                response = JSONResponse(
                    status_code=500,
                    content={
                        "error": "internal_error",
                        "message": "internal error",
                        "requestID": request_id,
                    },
                )
                await response(scope, receive, send_with_headers)
        finally:
            route = _safe_route(scope)
            self.logger.info(
                "request_completed",
                extra={
                    "event": "request_completed",
                    "request_id": request_id,
                    "method": scope["method"],
                    "route": route,
                    "status": response_status,
                    "latency_ms": round((perf_counter() - started) * 1000, 2),
                },
            )


def _safe_route(scope: Scope) -> str:
    route = scope.get("route")
    route_path = getattr(route, "path", None)
    if route_path in {"/health", "/config", "/sync"}:
        return route_path
    return "unknown"
