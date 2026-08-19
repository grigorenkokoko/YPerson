"""Behavioral contract tests for the serverless API Gateway."""

from __future__ import annotations

import os
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
DEPLOY_SCRIPT = ROOT / "deploy" / "yandex" / "serverless" / "deploy.sh"


def write_fake_commands(bin_dir: Path) -> None:
    """Install deterministic command doubles for the deployment script."""

    bin_dir.mkdir(parents=True)
    commands = {
        "yc": """#!/bin/sh
printf '%s ' \"$@\" >> \"$COMMAND_LOG\"
printf '\\n' >> \"$COMMAND_LOG\"
case \" $* \" in
  *" serverless container revision list "*) printf '%s\\n' '[]' ;;
esac
""",
        "curl": """#!/bin/sh
exit \"${FAKE_CURL_EXIT:-0}\"
""",
        "jq": """#!/bin/sh
/bin/cat >/dev/null
printf '%s\\n' \"${FAKE_PREVIOUS_REVISION:-}\"
""",
    }
    for name, contents in commands.items():
        command = bin_dir / name
        command.write_text(contents)
        command.chmod(0o755)


def deployment_environment(tmp_path: Path, sha: str = "a" * 40) -> tuple[dict[str, str], Path]:
    """Create the complete deployment environment and controlled command log."""

    bin_dir = tmp_path / "bin"
    write_fake_commands(bin_dir)
    command_log = tmp_path / "yc-command.log"
    environment = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "COMMAND_LOG": str(command_log),
        "YC_FOLDER_ID": "folder-id",
        "YC_HTTP_CONTAINER_ID": "http-container-id",
        "YC_RUNTIME_SA_ID": "runtime-sa-id",
        "YC_HEALTH_URL": "https://gateway.example/health",
        "YPERSON_CONFIG_VERSION": "2026-08-19.1",
        "YPERSON_PRIVACY_URL": "https://yperson.ru/privacy",
        "YPERSON_SUPPORT_URL": "https://yperson.ru/support",
        "IMAGE_URL": f"cr.yandex/registry/backend:{sha}",
        "GITHUB_SHA": sha,
        "YC_IAM_TOKEN": "test-iam-token",
    }
    return environment, command_log


def run_deploy(environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
    """Execute the real deployment script with controlled external commands."""

    return subprocess.run(
        ["/bin/bash", str(DEPLOY_SCRIPT)],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def logged_yc_commands(command_log: Path) -> list[list[str]]:
    """Read the command arguments captured by the fake Yandex Cloud CLI."""

    if not command_log.exists():
        return []
    return [line.split() for line in command_log.read_text().splitlines()]


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


def test_deploy_script_rejects_invalid_or_missing_full_sha_before_yc(tmp_path: Path) -> None:
    """Invalid immutable image input must not reach the cloud CLI."""

    for sha, image_url in (("short-sha", "cr.yandex/registry/backend:short-sha"), ("", "")):
        environment, command_log = deployment_environment(tmp_path / (sha or "missing"))
        environment["GITHUB_SHA"] = sha
        environment["IMAGE_URL"] = image_url

        result = run_deploy(environment)

        assert result.returncode == 2
        assert logged_yc_commands(command_log) == []
        assert "test-iam-token" not in result.stdout
        assert "test-iam-token" not in result.stderr


def test_deploy_script_rejects_missing_command_before_cloud_calls(tmp_path: Path) -> None:
    """Validated inputs still fail safely when a required local command is absent."""

    environment, command_log = deployment_environment(tmp_path)
    (tmp_path / "bin" / "jq").unlink()
    environment["PATH"] = str(tmp_path / "bin")

    result = run_deploy(environment)

    assert result.returncode == 2
    assert logged_yc_commands(command_log) == []
    assert "Required deployment command is unavailable: jq" in result.stderr
    assert "test-iam-token" not in result.stdout
    assert "test-iam-token" not in result.stderr


def test_deploy_script_deploys_http_revision_without_database_era_options(tmp_path: Path) -> None:
    """A healthy release deploys exactly one HTTP-only revision."""

    environment, command_log = deployment_environment(tmp_path)

    result = run_deploy(environment)

    assert result.returncode == 0
    commands = logged_yc_commands(command_log)
    deployments = [command for command in commands if "revision" in command and "deploy" in command]
    assert len(deployments) == 1
    deployment = deployments[0]
    assert ["--runtime", "http"] == deployment[deployment.index("--runtime") : deployment.index("--runtime") + 2]
    assert "--network-id" not in deployment
    assert "--secret" not in deployment
    assert "task" not in deployment
    assert not any("anonymous" in argument for command in commands for argument in command)
    assert "test-iam-token" not in result.stdout
    assert "test-iam-token" not in result.stderr


def test_deploy_script_rolls_back_active_revision_after_failed_health_check(tmp_path: Path) -> None:
    """A failed health check restores the revision that was active before deploy."""

    environment, command_log = deployment_environment(tmp_path)
    environment["FAKE_CURL_EXIT"] = "1"
    environment["FAKE_PREVIOUS_REVISION"] = "previous-revision"

    result = run_deploy(environment)

    assert result.returncode != 0
    commands = logged_yc_commands(command_log)
    rollback = next(command for command in commands if "rollback" in command)
    assert rollback[-2:] == ["--revision-id", "previous-revision"]
    assert "test-iam-token" not in result.stdout
    assert "test-iam-token" not in result.stderr


def test_deploy_script_skips_rollback_without_active_revision_after_failed_health_check(
    tmp_path: Path,
) -> None:
    """Bootstrap failures remain failures but have no revision to restore."""

    environment, command_log = deployment_environment(tmp_path)
    environment["FAKE_CURL_EXIT"] = "1"

    result = run_deploy(environment)

    assert result.returncode != 0
    assert not any("rollback" in command for command in logged_yc_commands(command_log))
    assert "test-iam-token" not in result.stdout
    assert "test-iam-token" not in result.stderr
