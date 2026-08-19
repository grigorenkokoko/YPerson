"""Behavioral contract tests for the serverless API Gateway."""

from __future__ import annotations

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = ROOT / "deploy" / "yandex" / "serverless" / "api-gateway.yaml"


def gateway_spec() -> dict[str, object]:
    """Load the OpenAPI document consumed by Yandex API Gateway."""

    spec = yaml.safe_load(GATEWAY.read_text())
    assert isinstance(spec, dict)
    return spec


def test_gateway_exposes_only_fail_closed_routes() -> None:
    """Only approved routes may be reachable through the public gateway."""

    spec = gateway_spec()
    paths = spec["paths"]
    assert set(paths) == {"/health", "/config", "/sync"}
    assert all("{" not in path and "}" not in path for path in paths)

    for route in ("/health", "/config"):
        operations = paths[route]
        assert set(operations) == {"get"}
        operation = operations["get"]
        integration = operation["x-yc-apigateway-integration"]
        assert integration == {
            "type": "serverless_containers",
            "container_id": "${YC_HTTP_CONTAINER_ID}",
            "service_account_id": "${YC_GATEWAY_SA_ID}",
        }

    sync_operations = paths["/sync"]
    assert set(sync_operations) == {"post"}
    sync = sync_operations["post"]
    assert sync["x-yc-apigateway-integration"] == {
        "type": "dummy",
        "http_code": 503,
        "http_headers": {"Content-Type": "application/json"},
        "content": {
            "application/json": (
                '{"error":"temporarily_unavailable","message":"sync is not enabled"}'
            )
        },
    }

    def all_mappings(value: object) -> list[dict[str, object]]:
        if isinstance(value, dict):
            return [value] + [mapping for child in value.values() for mapping in all_mappings(child)]
        if isinstance(value, list):
            return [mapping for child in value for mapping in all_mappings(child)]
        return []

    for mapping in all_mappings(paths):
        assert "x-yc-apigateway-any-method" not in mapping
        integration = mapping.get("x-yc-apigateway-integration")
        if isinstance(integration, dict) and integration.get("type") == "serverless_containers":
            assert integration.get("service_account_id") == "${YC_GATEWAY_SA_ID}"


def test_gateway_matches_the_approved_openapi_operations() -> None:
    """Gateway response metadata remains the precise reviewed API contract."""

    spec = gateway_spec()
    assert spec["openapi"] == "3.0.0"
    assert spec["info"] == {"title": "YPerson API", "version": "1.0.0"}

    paths = spec["paths"]
    assert paths["/health"]["get"]["operationId"] == "health"
    assert paths["/health"]["get"]["responses"] == {
        "200": {"description": "Service and database are ready"},
        "503": {"description": "Service or database is unavailable"},
    }
    assert paths["/config"]["get"]["operationId"] == "config"
    assert paths["/config"]["get"]["responses"] == {
        "200": {"description": "Public application configuration"}
    }
    assert paths["/sync"]["post"]["operationId"] == "syncDisabled"
    assert paths["/sync"]["post"]["responses"] == {
        "503": {
            "description": "Sync is disabled until installation authentication is enabled"
        }
    }
