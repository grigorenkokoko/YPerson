"""One focused contract for the YDB-backed production deployment path."""

from __future__ import annotations

import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "deploy-serverless.yml"
GATEWAY = ROOT / "deploy" / "yandex" / "serverless" / "api-gateway.yaml"
DEPLOY_SCRIPT = ROOT / "deploy" / "yandex" / "serverless" / "deploy.sh"
CONFIG_EXAMPLE = ROOT / "deploy" / "yandex" / "serverless" / "config.example.env"
RUNBOOK = ROOT / "deploy" / "yandex" / "serverless" / "README.md"

EXPECTED_CONFIG_KEYS = {
    "YC_FOLDER_ID",
    "YC_REGISTRY_ID",
    "YC_DEPLOYER_SA_ID",
    "YC_API_GATEWAY_ID",
    "YC_HTTP_CONTAINER_ID",
    "YC_RUNTIME_SA_ID",
    "YC_GATEWAY_SA_ID",
    "YC_HEALTH_URL",
    "YPERSON_CONFIG_VERSION",
    "YPERSON_PRIVACY_URL",
    "YPERSON_SUPPORT_URL",
    "YDB_ENDPOINT",
    "YDB_DATABASE",
    "YPERSON_OBJECT_BUCKET",
    "YPERSON_S3_LOCKBOX_SECRET_ID",
    "YPERSON_S3_LOCKBOX_VERSION_ID",
}


def load_yaml(path: Path) -> dict[str, object]:
    value = yaml.safe_load(path.read_text())
    assert isinstance(value, dict)
    return value


def parse_config() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in CONFIG_EXAMPLE.read_text().splitlines():
        key, separator, value = line.partition("=")
        assert separator and key and key not in values
        values[key] = value
    return values


def test_release_runs_schema_before_revision_and_routes_sync_to_container() -> None:
    """The only release job keeps OIDC, schema, private routing, smoke, and rollback."""

    workflow_source = WORKFLOW.read_text()
    workflow = load_yaml(WORKFLOW)
    triggers = workflow.get("on", workflow.get(True))  # PyYAML 1.1 parses ``on`` as True.
    assert triggers == {
        "push": {
            "branches": ["main"],
            "paths": [
                "backend/**",
                "deploy/yandex/serverless/**",
                ".github/workflows/deploy-serverless.yml",
            ],
        },
        "workflow_dispatch": None,
    }
    assert workflow["permissions"] == {"contents": "read", "id-token": "write"}
    assert workflow["concurrency"] == {
        "group": "production-backend",
        "cancel-in-progress": False,
    }
    assert set(workflow["jobs"]) == {"deploy"}
    steps = workflow["jobs"]["deploy"]["steps"]
    names = [step.get("name", step.get("uses", "")) for step in steps]
    assert names.index("Test backend") < names.index("Build and push backend image")
    assert names.index("Build and push backend image") < names.index("Apply YDB schema")
    assert names.index("Apply YDB schema") < names.index("Deploy HTTP revision")

    iam = next(step for step in steps if step.get("name") == "Get Yandex Cloud IAM token")
    assert iam == {
        "name": "Get Yandex Cloud IAM token",
        "id": "iam-token",
        "uses": "docker://ghcr.io/yc-actions/yc-iam-token-fed:1.0.0",
        "with": {"yc-sa-id": "${{ vars.YC_DEPLOYER_SA_ID }}"},
    }
    image = next(step for step in steps if step.get("name") == "Build and push backend image")
    assert image["with"]["platforms"] == "linux/amd64"
    assert image["with"]["push"] is True
    assert image["with"]["tags"].endswith(":${{ github.sha }}")
    schema = next(step for step in steps if step.get("name") == "Apply YDB schema")
    assert schema["run"] == "python backend/scripts/apply_ydb_schema.py"
    assert schema["env"] == {
        "YDB_ENDPOINT": "${{ vars.YDB_ENDPOINT }}",
        "YDB_DATABASE": "${{ vars.YDB_DATABASE }}",
        "YDB_ACCESS_TOKEN_CREDENTIALS": "${{ steps.iam-token.outputs.token }}",
    }
    deploy = next(step for step in steps if step.get("name") == "Deploy HTTP revision")
    for key in EXPECTED_CONFIG_KEYS - {"YC_REGISTRY_ID", "YC_DEPLOYER_SA_ID"}:
        assert key in deploy["env"]
    assert deploy["env"]["IMAGE_URL"].endswith(":${{ github.sha }}")
    assert deploy["env"]["GITHUB_SHA"] == "${{ github.sha }}"
    assert "secrets." not in workflow_source
    assert "authorized_key" not in workflow_source.casefold()

    gateway = load_yaml(GATEWAY)
    assert gateway["openapi"] == "3.0.0"
    assert set(gateway["paths"]) == {"/health", "/config", "/privacy", "/support", "/sync"}
    expected_integration = {
        "type": "serverless_containers",
        "container_id": "${YC_HTTP_CONTAINER_ID}",
        "service_account_id": "${YC_GATEWAY_SA_ID}",
    }
    for path, method in {
        "/health": "get",
        "/config": "get",
        "/privacy": "get",
        "/support": "get",
        "/sync": "post",
    }.items():
        assert gateway["paths"][path][method]["x-yc-apigateway-integration"] == expected_integration
    assert set(gateway["paths"]["/sync"]["post"]["responses"]) == {
        "200",
        "400",
        "401",
        "409",
        "413",
        "415",
        "503",
    }

    syntax = subprocess.run(
        ["/bin/bash", "-n", str(DEPLOY_SCRIPT)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert syntax.returncode == 0, syntax.stderr
    script = DEPLOY_SCRIPT.read_text()
    for key in EXPECTED_CONFIG_KEYS - {"YC_REGISTRY_ID", "YC_DEPLOYER_SA_ID"}:
        assert key in script
    assert "YDB_METADATA_CREDENTIALS=1" in script
    assert "YPERSON_SYNC_ENABLED=true" in script
    assert (
        "environment-variable=YPERSON_S3_ACCESS_KEY_ID,id=${YPERSON_S3_LOCKBOX_SECRET_ID},"
        "version-id=${YPERSON_S3_LOCKBOX_VERSION_ID},key=access_key_id"
    ) in script
    assert (
        "environment-variable=YPERSON_S3_SECRET_ACCESS_KEY,id=${YPERSON_S3_LOCKBOX_SECRET_ID},"
        "version-id=${YPERSON_S3_LOCKBOX_VERSION_ID},key=secret_access_key"
    ) in script
    for operation in (
        "refresh",
        "prepareExchange",
        "claimExchange",
        "prepareAudioUpload",
        "publishCard",
        "deleteProfile",
    ):
        assert operation in script
    assert "serverless container rollback" in script
    assert "set -x" not in script

    config = parse_config()
    assert set(config) == EXPECTED_CONFIG_KEYS
    assert "YPERSON_S3_ACCESS_KEY_ID" not in config
    assert "YPERSON_S3_SECRET_ACCESS_KEY" not in config
    assert config["YC_DEPLOYER_SA_ID"] == "ajeo8kqgko5ftmdlqq43"
    assert config["YC_API_GATEWAY_ID"] == "d5dl7dc4rc07v7jnvlf2"

    runbook = RUNBOOK.read_text()
    for fragment in (
        "ajeo8kqgko5ftmdlqq43",
        "aje9djqjtuacd2fk39a0",
        "aje2u4ailt53p0338o7p",
        "repo:grigorenkokoko@89942789/YPerson@1337270808:ref:refs/heads/main",
        "Bearer",
        "подписанные URL",
        "APNs token",
        "401",
        "403",
    ):
        assert fragment in runbook


def test_ios_debug_and_release_use_the_existing_gateway() -> None:
    gateway = "d5dl7dc4rc07v7jnvlf2.p8361f8z.apigw.yandexcloud.net"
    debug = (ROOT / "Config" / "Debug.xcconfig").read_text()
    release = (ROOT / "Config" / "Release.xcconfig").read_text()
    base = (ROOT / "Config" / "Base.xcconfig").read_text()

    assert f"API_BASE_URL = https:/$()/{gateway}" in debug
    assert f"API_BASE_URL = https:/$()/{gateway}" in release
    assert f"PRIVACY_POLICY_URL = https:/$()/{gateway}/privacy" in base
    assert f"SUPPORT_URL = https:/$()/{gateway}/support" in base
