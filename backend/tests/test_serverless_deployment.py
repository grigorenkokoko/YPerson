"""Behavioral contract tests for the serverless API Gateway."""

from __future__ import annotations

import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = ROOT / "deploy" / "yandex" / "serverless" / "api-gateway.yaml"
CONFIG_EXAMPLE = ROOT / "deploy" / "yandex" / "serverless" / "config.example.env"

EXPECTED_CONFIG = {
    "YC_FOLDER_ID": "",
    "YC_REGISTRY_ID": "crp7vdmqvk61ce7oukqn",
    "YC_DEPLOYER_SA_ID": "",
    "YC_HTTP_CONTAINER_ID": "",
    "YC_RUNTIME_SA_ID": "",
    "YC_GATEWAY_SA_ID": "",
    "YC_HEALTH_URL": "",
    "YPERSON_CONFIG_VERSION": "2026-08-19.1",
    "YPERSON_PRIVACY_URL": "https://yperson.ru/privacy",
    "YPERSON_SUPPORT_URL": "https://yperson.ru/support",
}
DATABASE_ERA_CONFIG_KEYS = {
    "YC_MIGRATION_CONTAINER_ID",
    "YC_NETWORK_ID",
    "YC_LOCKBOX_SECRET_ID",
    "YC_LOCKBOX_SECRET_VERSION_ID",
}
FORBIDDEN_SECRET_KEY_PARTS = (
    "password",
    "token",
    "oauth",
    "authorized_key",
    "private_key",
    "apns",
)


def parse_env_pairs(contents: str) -> dict[str, str]:
    """Parse the release template while rejecting unsafe dotenv entries."""

    pairs: dict[str, str] = {}
    for line in contents.splitlines():
        key, separator, value = line.partition("=")
        assert separator and key, f"invalid dotenv entry: {line!r}"
        assert key not in pairs, f"duplicate dotenv key: {key}"
        assert not any(part in key.casefold() for part in FORBIDDEN_SECRET_KEY_PARTS), (
            f"secret-bearing dotenv key: {key}"
        )
        pairs[key] = value
    return pairs


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


def test_config_example_exposes_only_approved_non_secret_values() -> None:
    """The deployable template contains only reviewed public defaults."""

    pairs = parse_env_pairs(CONFIG_EXAMPLE.read_text())

    assert pairs == EXPECTED_CONFIG
    assert DATABASE_ERA_CONFIG_KEYS.isdisjoint(pairs)


def test_config_parser_rejects_duplicate_and_secret_bearing_keys() -> None:
    """A release template cannot quietly gain duplicate or credential entries."""

    for invalid_contents in (
        "YC_FOLDER_ID=first\nYC_FOLDER_ID=second\n",
        "YC_DEPLOYER_TOKEN=value\n",
        "YC_LOCKBOX_SECRET_ID=\nYC_RUNTIME_PRIVATE_KEY=value\n",
    ):
        try:
            parse_env_pairs(invalid_contents)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe dotenv contents were accepted: {invalid_contents!r}")


def test_config_local_values_are_ignored_without_ignoring_the_template() -> None:
    """Local deployment values stay untracked while the safe template is committed."""

    assert "deploy/yandex/serverless/config.env" in (ROOT / ".gitignore").read_text().splitlines()

    local_config = subprocess.run(
        ["git", "check-ignore", "--no-index", "deploy/yandex/serverless/config.env"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    template = subprocess.run(
        ["git", "check-ignore", "--no-index", "deploy/yandex/serverless/config.example.env"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert local_config.returncode == 0
    assert template.returncode == 1
