"""One focused contract for the YDB-backed production deployment path."""

from __future__ import annotations

import json
import subprocess
import uuid
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


def test_serverless_smoke_keeps_qr_and_manual_exchange_credentials_separate() -> None:
    """Deployment must exercise both credential shapes without printing either secret."""

    script = DEPLOY_SCRIPT.read_text()

    for operation_id in (
        "smoke-prepare-exchange-qr",
        "smoke-claim-exchange-qr",
        "smoke-prepare-exchange-manual",
        "smoke-claim-exchange-manual",
    ):
        assert script.count(operation_id) == 1

    assert 'payload["exchangeMethod"] = os.environ["SMOKE_EXCHANGE_METHOD"]' in script
    assert 'payload["exchangeToken"] = os.environ["SMOKE_EXCHANGE_TOKEN"]' in script
    assert 'payload["exchangeCode"] = os.environ["SMOKE_EXCHANGE_CODE"]' in script

    qr_start = script.index('SMOKE_CARD_ID="smoke-card-${GITHUB_SHA:0:12}"')
    manual_start = script.index(
        'SMOKE_CARD_ID="smoke-card-${GITHUB_SHA:0:12}"',
        qr_start + 1,
    )
    audio_start = script.index("printf 'YPerson smoke audio'", manual_start)
    qr_block = script[qr_start:manual_start]
    manual_block = script[manual_start:audio_start]

    _assert_fragments_in_order(
        qr_block,
        (
            "SMOKE_EXCHANGE_METHOD=qr",
            'prepare-exchange-qr.json" prepareExchange',
            "smoke-prepare-exchange-qr",
            'prepare-exchange-qr-response.json"',
            'prepare-exchange-qr-response.json" exchangeToken',
            'prepare-exchange-qr-response.json" exchangeExpiresAt',
            "SMOKE_EXCHANGE_FIELD=exchangeToken",
            'claim-exchange-qr.json" claimExchange',
            "smoke-claim-exchange-qr",
            'claim-exchange-qr-response.json"',
            "unset SMOKE_EXCHANGE_TOKEN",
        ),
    )
    assert qr_block.count("prepare-exchange-qr-response.json") == 3
    assert "SMOKE_EXCHANGE_METHOD=manual" not in qr_block
    assert "SMOKE_EXCHANGE_FIELD=exchangeCode" not in qr_block

    _assert_fragments_in_order(
        manual_block,
        (
            "SMOKE_EXCHANGE_METHOD=manual",
            'prepare-exchange-manual.json" prepareExchange',
            "smoke-prepare-exchange-manual",
            'prepare-exchange-manual-response.json"',
            'prepare-exchange-manual-response.json" exchangeCode',
            'prepare-exchange-manual-response.json" exchangeExpiresAt',
            "SMOKE_EXCHANGE_FIELD=exchangeCode",
            'claim-exchange-manual.json" claimExchange',
            "smoke-claim-exchange-manual",
            'claim-exchange-manual-response.json"',
            "unset SMOKE_EXCHANGE_CODE",
        ),
    )
    assert manual_block.count("prepare-exchange-manual-response.json") == 3
    assert "SMOKE_EXCHANGE_METHOD=qr" not in manual_block
    assert "SMOKE_EXCHANGE_FIELD=exchangeToken" not in manual_block

    cleanup = script[script.index("finish() {") : script.index("trap finish EXIT")]
    credential_unset = cleanup.index("unset SMOKE_EXCHANGE_TOKEN SMOKE_EXCHANGE_CODE")
    assert credential_unset < cleanup.index("delete_smoke_profile")
    assert credential_unset < cleanup.index("rollback_previous_revision")

    output_lines = [
        line for line in script.splitlines() if line.lstrip().startswith(("echo ", "printf "))
    ]
    assert all("SMOKE_EXCHANGE_TOKEN" not in line for line in output_lines)
    assert all("SMOKE_EXCHANGE_CODE" not in line for line in output_lines)


def test_inherited_xtrace_cannot_expose_deployment_environment() -> None:
    """A caller's ``bash -x`` must stop before required values are inspected."""

    nonce = uuid.uuid4().hex
    sentinels = {
        "YC_FOLDER_ID": f"folder-{nonce}",
        "YC_API_GATEWAY_ID": f"gateway-{nonce}",
        "YC_HTTP_CONTAINER_ID": f"container-{nonce}",
        "YC_RUNTIME_SA_ID": f"runtime-sa-{nonce}",
        "YC_GATEWAY_SA_ID": f"gateway-sa-{nonce}",
        "YC_HEALTH_URL": f"https://health-{nonce}.example.invalid/health",
        "YPERSON_CONFIG_VERSION": f"config-{nonce}",
        "YPERSON_PRIVACY_URL": f"https://privacy-{nonce}.example.invalid",
        "YPERSON_SUPPORT_URL": f"https://support-{nonce}.example.invalid",
        "YDB_ENDPOINT": f"grpcs://ydb-{nonce}.example.invalid:2135",
        "YDB_DATABASE": f"/database-{nonce}",
        "YPERSON_OBJECT_BUCKET": f"bucket-{nonce}",
        "YPERSON_S3_LOCKBOX_SECRET_ID": f"lockbox-secret-{nonce}",
        "YPERSON_S3_LOCKBOX_VERSION_ID": f"lockbox-version-{nonce}",
        "IMAGE_URL": f"registry.example.invalid/yperson:{nonce}",
        "GITHUB_SHA": f"invalid-sha-{nonce}",
        "YC_IAM_TOKEN": f"iam-token-{nonce}",
    }
    assert len(sentinels) == len(set(sentinels.values()))

    result = subprocess.run(
        ["/bin/bash", "-x", str(DEPLOY_SCRIPT)],
        cwd=ROOT,
        env={"PATH": "/usr/bin:/bin", **sentinels},
        capture_output=True,
        text=True,
        check=False,
    )
    combined_output = result.stdout + result.stderr
    leaked_names = [name for name, value in sentinels.items() if value in combined_output]

    assert result.returncode == 2
    assert "IMAGE_URL must use the full Git commit SHA tag" in combined_output
    assert not leaked_names, f"xtrace exposed deployment values for: {leaked_names}"
    assert DEPLOY_SCRIPT.read_text().splitlines()[:3] == [
        "#!/usr/bin/env bash",
        "set +x",
        "set -Eeuo pipefail",
    ]


def test_private_exchange_manifest_references_existing_evidence() -> None:
    """Every private-exchange evidence path must resolve to a real repository file."""

    manifest = json.loads((ROOT / "Release" / "release-manifest.json").read_text())
    evidence = manifest["privateExchange"]["evidence"]

    assert "YPerson/Networking/SyncCoordinator.swift" in evidence
    missing = [path for path in evidence if not (ROOT / path).is_file()]
    assert not missing, f"private-exchange evidence paths do not exist: {missing}"


def _assert_fragments_in_order(source: str, fragments: tuple[str, ...]) -> None:
    cursor = 0
    for fragment in fragments:
        position = source.find(fragment, cursor)
        assert position >= 0, f"missing ordered deployment fragment: {fragment}"
        cursor = position + len(fragment)
