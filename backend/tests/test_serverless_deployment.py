"""Behavioral contract tests for the serverless API Gateway."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
GATEWAY = ROOT / "deploy" / "yandex" / "serverless" / "api-gateway.yaml"
CONFIG_EXAMPLE = ROOT / "deploy" / "yandex" / "serverless" / "config.example.env"
RUNBOOK = ROOT / "deploy" / "yandex" / "serverless" / "README.md"

EXPECTED_CONFIG = {
    "YC_FOLDER_ID": "",
    "YC_REGISTRY_ID": "crp7vdmqvk61ce7oukqn",
    "YC_DEPLOYER_SA_ID": "",
    "YC_HTTP_CONTAINER_ID": "",
    "YC_RUNTIME_SA_ID": "",
    "YC_GATEWAY_SA_ID": "",
    "YC_HEALTH_URL": "",
    "YPERSON_CONFIG_VERSION": "2026-08-19.1",
    "YPERSON_PRIVACY_URL": "",
    "YPERSON_SUPPORT_URL": "",
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
WORKFLOW = ROOT / ".github" / "workflows" / "deploy-serverless.yml"
TEST_IAM_TOKEN = "test-iam-token"
ACTIVE_REVISION_JSON = (
    '[{"id":"inactive-revision","status":"INACTIVE"},{"id":"previous-revision","status":"ACTIVE"}]'
)
ACTIVE_REVISION_FILTER = 'map(select(.status == "ACTIVE")) | first | .id // empty'
REQUIRED_DEPLOYMENT_VALUES = (
    "YC_FOLDER_ID",
    "YC_HTTP_CONTAINER_ID",
    "YC_RUNTIME_SA_ID",
    "YC_HEALTH_URL",
    "YPERSON_CONFIG_VERSION",
    "YPERSON_PRIVACY_URL",
    "YPERSON_SUPPORT_URL",
    "IMAGE_URL",
    "GITHUB_SHA",
    "YC_IAM_TOKEN",
)


def write_fake_commands(bin_dir: Path) -> None:
    """Install deterministic command doubles for the deployment script."""

    bin_dir.mkdir(parents=True)
    commands = {
        "yc": """#!/bin/sh
printf '%s ' \"$@\" >> \"$COMMAND_LOG\"
printf '\\n' >> \"$COMMAND_LOG\"
case \" $* \" in
  *" serverless container revision list "*) printf '%s\\n' \"$FAKE_REVISION_JSON\" ;;
esac
""",
        "curl": """#!/bin/sh
printf '%s ' \"$@\" >> \"$CURL_COMMAND_LOG\"
printf '\\n' >> \"$CURL_COMMAND_LOG\"
exit \"${FAKE_CURL_EXIT:-0}\"
""",
        "jq": """#!/bin/sh
input=$(/bin/cat)
printf '%s' \"$input\" > \"$JQ_INPUT_LOG\"
printf '%s' \"${2:-}\" > \"$JQ_FILTER_LOG\"
if [ \"${1:-}\" != '-r' ] || [ \"${2:-}\" != 'map(select(.status == \"ACTIVE\")) | first | .id // empty' ]; then
  exit 9
fi
case \"$input\" in
  *'\"id\":\"previous-revision\",\"status\":\"ACTIVE\"'*) printf '%s\\n' previous-revision ;;
  *) printf '\\n' ;;
esac
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
        "CURL_COMMAND_LOG": str(tmp_path / "curl-command.log"),
        "JQ_INPUT_LOG": str(tmp_path / "jq-input.log"),
        "JQ_FILTER_LOG": str(tmp_path / "jq-filter.log"),
        "FAKE_REVISION_JSON": ACTIVE_REVISION_JSON,
        "YC_FOLDER_ID": "folder-id",
        "YC_HTTP_CONTAINER_ID": "http-container-id",
        "YC_RUNTIME_SA_ID": "runtime-sa-id",
        "YC_HEALTH_URL": "https://gateway.example/health",
        "YPERSON_CONFIG_VERSION": "2026-08-19.1",
        "YPERSON_PRIVACY_URL": "https://gateway.example/privacy",
        "YPERSON_SUPPORT_URL": "https://gateway.example/support",
        "IMAGE_URL": f"cr.yandex/registry/backend:{sha}",
        "GITHUB_SHA": sha,
        "YC_IAM_TOKEN": TEST_IAM_TOKEN,
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


def logged_command(command_log: Path) -> list[str]:
    """Read one whitespace-safe controlled command invocation."""

    return command_log.read_text().split()


def assert_token_is_not_printed(result: subprocess.CompletedProcess[str]) -> None:
    """Deployment diagnostics must not expose the controlled IAM token."""

    assert TEST_IAM_TOKEN not in result.stdout
    assert TEST_IAM_TOKEN not in result.stderr


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


def release_workflow() -> tuple[dict[str, object], str]:
    """Load the parsed release workflow and its source for contract checks."""

    workflow_source = WORKFLOW.read_text()
    workflow = yaml.safe_load(workflow_source)
    assert isinstance(workflow, dict)
    return workflow, workflow_source


def bootstrap_runbook() -> str:
    """Load the operator procedure that controls external production bootstrap."""

    return RUNBOOK.read_text()


def assert_runbook_order(source: str, *milestones: str) -> None:
    """Require security-sensitive bootstrap milestones to stay executable in order."""

    normalized_source = " ".join(source.split()).casefold()
    positions = [
        normalized_source.index(" ".join(milestone.split()).casefold()) for milestone in milestones
    ]
    assert positions == sorted(positions), milestones


def assert_release_workflow_contract(workflow: dict[str, object], workflow_source: str) -> None:
    """Assert the production release path tests, pushes, then deploys with OIDC only.

    Removing any of these safeguards would allow an untested, mutable, or
    credential-bearing release workflow to reach production.
    """

    # PyYAML 1.1 parses the YAML key ``on`` as boolean True.
    triggers = workflow.get("on", workflow.get(True))
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

    jobs = workflow["jobs"]
    assert set(jobs) == {"deploy"}
    deploy_job = jobs["deploy"]
    assert set(deploy_job) == {"runs-on", "steps"}
    assert deploy_job["runs-on"] == "ubuntu-latest"
    steps = deploy_job["steps"]

    checkout_step = {"uses": "actions/checkout@v4"}
    setup_python_step = {
        "uses": "actions/setup-python@v5",
        "with": {"python-version": "3.12"},
    }
    install_dependencies_step = {
        "name": "Install backend test dependencies",
        "run": "pip install --require-hashes -r backend/requirements-dev.lock",
    }
    test_step = {
        "name": "Test backend",
        "working-directory": "backend",
        "run": "python -m pytest tests -q",
    }

    iam_step = {
        "name": "Get Yandex Cloud IAM token",
        "id": "iam-token",
        "uses": "docker://ghcr.io/yc-actions/yc-iam-token-fed:1.0.0",
        "with": {"yc-sa-id": "${{ vars.YC_DEPLOYER_SA_ID }}"},
    }
    image_step = {
        "name": "Build and push backend image",
        "uses": "docker/build-push-action@v6",
        "with": {
            "context": ".",
            "file": "backend/Dockerfile",
            "platforms": "linux/amd64",
            "push": True,
            "tags": "cr.yandex/${{ vars.YC_REGISTRY_ID }}/backend:${{ github.sha }}",
        },
    }
    login_step = {
        "name": "Login to Yandex Container Registry",
        "env": {"YC_IAM_TOKEN": "${{ steps.iam-token.outputs.token }}"},
        "run": (
            "printf '%s' \"${YC_IAM_TOKEN}\" | docker login --username iam "
            "--password-stdin cr.yandex"
        ),
    }
    buildx_step = {"uses": "docker/setup-buildx-action@v3"}
    deploy_step = {
        "name": "Deploy HTTP revision",
        "env": {
            "YC_FOLDER_ID": "${{ vars.YC_FOLDER_ID }}",
            "YC_HTTP_CONTAINER_ID": "${{ vars.YC_HTTP_CONTAINER_ID }}",
            "YC_RUNTIME_SA_ID": "${{ vars.YC_RUNTIME_SA_ID }}",
            "YC_HEALTH_URL": "${{ vars.YC_HEALTH_URL }}",
            "YPERSON_CONFIG_VERSION": "${{ vars.YPERSON_CONFIG_VERSION }}",
            "YPERSON_PRIVACY_URL": "${{ vars.YPERSON_PRIVACY_URL }}",
            "YPERSON_SUPPORT_URL": "${{ vars.YPERSON_SUPPORT_URL }}",
            "YC_IAM_TOKEN": "${{ steps.iam-token.outputs.token }}",
            "IMAGE_URL": "cr.yandex/${{ vars.YC_REGISTRY_ID }}/backend:${{ github.sha }}",
            "GITHUB_SHA": "${{ github.sha }}",
        },
        "run": "deploy/yandex/serverless/deploy.sh",
    }
    install_cli_step = {
        "name": "Install Yandex Cloud CLI",
        "run": (
            "curl --fail --silent --show-error --location \\\n"
            "  https://storage.yandexcloud.net/yandexcloud-yc/install.sh \\\n"
            '  | bash -s -- -i "${RUNNER_TEMP}/yandex-cloud" -n\n'
            'echo "${RUNNER_TEMP}/yandex-cloud/bin" >> "${GITHUB_PATH}"\n'
            '"${RUNNER_TEMP}/yandex-cloud/bin/yc" version\n'
        ),
    }
    assert steps == [
        checkout_step,
        setup_python_step,
        install_dependencies_step,
        test_step,
        iam_step,
        login_step,
        buildx_step,
        image_step,
        install_cli_step,
        deploy_step,
    ]

    forbidden_references = (
        "secrets.",
        "authorized_key",
        "authorized key",
        "postgres",
        "test_database_url",
        "database",
        "lockbox",
        "migration",
        "vpc",
    )
    normalized_source = workflow_source.casefold()
    assert not any(reference in normalized_source for reference in forbidden_references)


def test_release_workflow_deploys_an_immutable_database_free_backend() -> None:
    """The committed workflow satisfies the release deployment contract."""

    workflow, workflow_source = release_workflow()

    assert_release_workflow_contract(workflow, workflow_source)


@pytest.mark.parametrize(
    "regression",
    (
        "job_permissions",
        "job_matrix",
        "job_continue_on_error",
        "early_extra_deploy",
        "cli_after_deploy",
    ),
)
def test_release_workflow_contract_rejects_security_and_order_regressions(
    regression: str,
) -> None:
    """The checker rejects permission escalation and unsafe release sequencing."""

    workflow, workflow_source = release_workflow()
    steps = workflow["jobs"]["deploy"]["steps"]

    if regression == "job_permissions":
        workflow["jobs"]["deploy"]["permissions"] = "write-all"
    elif regression == "job_matrix":
        workflow["jobs"]["deploy"]["strategy"] = {"matrix": {"replica": [1, 2]}}
    elif regression == "job_continue_on_error":
        workflow["jobs"]["deploy"]["continue-on-error"] = True
    elif regression == "early_extra_deploy":
        steps.insert(0, {"name": "Early deploy", "run": "deploy/yandex/serverless/deploy.sh"})
    else:
        cli_index = next(
            index
            for index, step in enumerate(steps)
            if step.get("name") == "Install Yandex Cloud CLI"
        )
        steps.append(steps.pop(cli_index))

    with pytest.raises(AssertionError):
        assert_release_workflow_contract(workflow, workflow_source)


def test_gateway_exposes_only_fail_closed_routes() -> None:
    """Only approved routes may be reachable through the public gateway."""

    spec = gateway_spec()
    paths = spec["paths"]
    assert set(paths) == {"/health", "/config", "/privacy", "/support", "/sync"}
    assert all("{" not in path and "}" not in path for path in paths)

    for route in ("/health", "/config", "/privacy", "/support"):
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
            return [value] + [
                mapping for child in value.values() for mapping in all_mappings(child)
            ]
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
    assert paths["/health"]["get"]["responses"] == {"200": {"description": "Service is ready"}}
    assert paths["/config"]["get"]["operationId"] == "config"
    assert paths["/config"]["get"]["responses"] == {
        "200": {"description": "Public application configuration"}
    }
    assert paths["/privacy"]["get"]["operationId"] == "privacy"
    assert paths["/privacy"]["get"]["responses"] == {
        "200": {"description": "Technical privacy information"}
    }
    assert paths["/support"]["get"]["operationId"] == "support"
    assert paths["/support"]["get"]["responses"] == {
        "200": {"description": "Technical support information"}
    }
    assert paths["/sync"]["post"]["operationId"] == "syncDisabled"
    assert paths["/sync"]["post"]["responses"] == {
        "503": {"description": "Sync is disabled until installation authentication is enabled"}
    }


def test_config_example_exposes_only_approved_non_secret_values() -> None:
    """The deployable template contains only reviewed public defaults."""

    pairs = parse_env_pairs(CONFIG_EXAMPLE.read_text())

    assert pairs == EXPECTED_CONFIG
    assert DATABASE_ERA_CONFIG_KEYS.isdisjoint(pairs)


def test_production_deployment_artifacts_do_not_name_a_custom_domain_or_tls() -> None:
    """Bootstrap must work before a custom domain or its TLS certificate exists."""

    production_artifacts = (GATEWAY, CONFIG_EXAMPLE, WORKFLOW)
    prohibited_fragments = ("yperson.ru", "api.yperson", "certificate", "reg.ru")

    for artifact in production_artifacts:
        artifact_source = artifact.read_text().casefold()
        assert not any(fragment in artifact_source for fragment in prohibited_fragments)


def test_runbook_creates_container_before_container_scoped_bindings_and_gateway() -> None:
    """Container roles must target an existing private container before Gateway creation."""

    source = bootstrap_runbook()

    assert_runbook_order(
        source,
        "Create the three service accounts",
        "Grant the registry-scoped bindings",
        "Create the empty private `yperson-api` container object",
        "Grant the container-scoped bindings",
        "create `yperson-api-gateway`",
        "manually dispatch",
    )


def test_runbook_creates_named_federation_and_separate_exact_credential() -> None:
    """GitHub OIDC needs both Yandex IAM objects and the exact production subject."""

    source = bootstrap_runbook()

    assert "Federation name: `yperson-github-oidc`" in source
    assert "Issuer: https://token.actions.githubusercontent.com" in source
    assert "Audience: https://github.com/grigorenkokoko" in source
    assert "JWKS: https://token.actions.githubusercontent.com/.well-known/jwks" in source
    assert ("External subject ID: `repo:grigorenkokoko/YPerson:ref:refs/heads/main`") in source
    assert_runbook_order(
        source,
        "Create the workload identity federation `yperson-github-oidc`",
        "Create a separate federated credential",
        "manually dispatch",
    )
    assert "Do not create an authorized-key JSON or GitHub secret" in source


def test_runbook_protects_main_before_enabling_production_oidc() -> None:
    """A protected production branch must gate the credential and automatic deploy path."""

    source = bootstrap_runbook()

    normalized_source = " ".join(source.split())
    assert "Require a pull request before merging" in normalized_source
    assert "Do not allow bypassing the above settings" in normalized_source
    assert "Leave **Allow force pushes** disabled" in normalized_source
    assert "Leave **Allow deletions** disabled" in normalized_source
    assert_runbook_order(
        source,
        "Verify the effective `main` branch protection rule",
        "Create a separate federated credential",
        "manually dispatch",
    )


def test_runbook_audits_effective_access_and_rejects_direct_public_invocation() -> None:
    """Gateway-only public access needs IAM and direct-container negative verification."""

    source = bootstrap_runbook()

    for required_fragment in (
        "yc serverless container list-access-bindings",
        "yc resource-manager folder list-access-bindings",
        "yc resource-manager cloud list-access-bindings",
        "allUsers",
        "allAuthenticatedUsers",
        "serverless-containers.containerInvoker",
        "serverless-containers.editor",
        "serverless-containers.admin",
        "CONTAINER_URL",
        "without an `Authorization` header",
        "outside `200` through `299`",
        "Do not make the container public",
    ):
        assert required_fragment in source

    assert_runbook_order(
        source,
        "Run the pre-revision effective-access audit",
        "create `yperson-api-gateway`",
        "manually dispatch",
        "Repeat the post-revision effective-access audit",
        "CONTAINER_URL",
        "Through `https://${GATEWAY_DOMAIN}`, verify",
    )


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


@pytest.mark.parametrize("missing_name", REQUIRED_DEPLOYMENT_VALUES)
def test_deploy_script_rejects_each_missing_required_value_before_yc(
    tmp_path: Path, missing_name: str
) -> None:
    """Every required deployment value is rejected before a cloud call."""

    environment, command_log = deployment_environment(tmp_path)
    environment.pop(missing_name)

    result = run_deploy(environment)

    assert result.returncode == 2
    assert logged_yc_commands(command_log) == []
    assert f"Missing required deployment value: {missing_name}" in result.stderr
    assert_token_is_not_printed(result)


@pytest.mark.parametrize(
    ("sha", "image_url"),
    (
        ("short-sha", "cr.yandex/registry/backend:short-sha"),
        ("A" * 40, f"cr.yandex/registry/backend:{'A' * 40}"),
        ("g" * 40, f"cr.yandex/registry/backend:{'g' * 40}"),
        ("a" * 39, f"cr.yandex/registry/backend:{'a' * 39}"),
        ("a" * 41, f"cr.yandex/registry/backend:{'a' * 41}"),
        ("a" * 40, f"cr.yandex/registry/backend:{'b' * 40}"),
    ),
)
def test_deploy_script_rejects_invalid_sha_or_image_tag_before_yc(
    tmp_path: Path, sha: str, image_url: str
) -> None:
    """The image tag must be the same lowercase, full commit SHA."""

    environment, command_log = deployment_environment(tmp_path)
    environment["GITHUB_SHA"] = sha
    environment["IMAGE_URL"] = image_url

    result = run_deploy(environment)

    assert result.returncode == 2
    assert logged_yc_commands(command_log) == []
    assert "IMAGE_URL must use the full Git commit SHA tag" in result.stderr
    assert_token_is_not_printed(result)


@pytest.mark.parametrize("missing_command", ("yc", "curl", "jq"))
def test_deploy_script_rejects_each_missing_command_before_cloud_calls(
    tmp_path: Path, missing_command: str
) -> None:
    """The three local executables are all validated before cloud calls."""

    environment, command_log = deployment_environment(tmp_path)
    (tmp_path / "bin" / missing_command).unlink()
    environment["PATH"] = str(tmp_path / "bin")

    result = run_deploy(environment)

    assert result.returncode == 2
    assert logged_yc_commands(command_log) == []
    assert f"Required deployment command is unavailable: {missing_command}" in result.stderr
    assert_token_is_not_printed(result)


def test_deploy_script_deploys_http_revision_without_database_era_options(tmp_path: Path) -> None:
    """A healthy release deploys exactly one HTTP-only revision."""

    environment, command_log = deployment_environment(tmp_path)

    result = run_deploy(environment)

    assert result.returncode == 0
    commands = logged_yc_commands(command_log)
    prefix = ["--folder-id", "folder-id", "--token", TEST_IAM_TOKEN]
    assert commands == [
        prefix
        + [
            "serverless",
            "container",
            "revision",
            "list",
            "--container-id",
            "http-container-id",
            "--format",
            "json",
        ],
        prefix
        + [
            "serverless",
            "container",
            "revision",
            "deploy",
            "--container-id",
            "http-container-id",
            "--image",
            f"cr.yandex/registry/backend:{'a' * 40}",
            "--runtime",
            "http",
            "--memory",
            "512MB",
            "--cores",
            "1",
            "--concurrency",
            "4",
            "--execution-timeout",
            "30s",
            "--min-instances",
            "0",
            "--service-account-id",
            "runtime-sa-id",
            "--environment",
            (
                "YPERSON_ENV=staging,YPERSON_CONFIG_VERSION=2026-08-19.1,"
                "YPERSON_PRIVACY_URL=https://gateway.example/privacy,"
                "YPERSON_SUPPORT_URL=https://gateway.example/support,"
                "YPERSON_ANALYTICS_KILL_SWITCH=false,GRACEFUL_SHUTDOWN_SECONDS=15"
            ),
        ],
    ]
    assert logged_command(Path(environment["CURL_COMMAND_LOG"])) == [
        "--fail",
        "--silent",
        "--show-error",
        "--retry",
        "12",
        "--retry-delay",
        "5",
        "--retry-all-errors",
        "--max-time",
        "10",
        "https://gateway.example/health",
    ]
    assert Path(environment["JQ_INPUT_LOG"]).read_text() == ACTIVE_REVISION_JSON
    assert Path(environment["JQ_FILTER_LOG"]).read_text() == ACTIVE_REVISION_FILTER
    assert_token_is_not_printed(result)


def test_deploy_script_rolls_back_active_revision_after_failed_health_check(tmp_path: Path) -> None:
    """A failed health check restores the revision that was active before deploy."""

    environment, command_log = deployment_environment(tmp_path)
    environment["FAKE_CURL_EXIT"] = "1"

    result = run_deploy(environment)

    assert result.returncode != 0
    commands = logged_yc_commands(command_log)
    prefix = ["--folder-id", "folder-id", "--token", TEST_IAM_TOKEN]
    assert commands[-1] == prefix + [
        "serverless",
        "container",
        "rollback",
        "--id",
        "http-container-id",
        "--revision-id",
        "previous-revision",
    ]
    assert (
        commands.index(next(command for command in commands if "list" in command))
        < commands.index(next(command for command in commands if "deploy" in command))
        < commands.index(commands[-1])
    )
    assert Path(environment["JQ_INPUT_LOG"]).read_text() == ACTIVE_REVISION_JSON
    assert Path(environment["JQ_FILTER_LOG"]).read_text() == ACTIVE_REVISION_FILTER
    assert_token_is_not_printed(result)


def test_deploy_script_skips_rollback_without_active_revision_after_failed_health_check(
    tmp_path: Path,
) -> None:
    """Bootstrap failures remain failures but have no revision to restore."""

    environment, command_log = deployment_environment(tmp_path)
    environment["FAKE_CURL_EXIT"] = "1"
    environment["FAKE_REVISION_JSON"] = "[]"

    result = run_deploy(environment)

    assert result.returncode != 0
    assert not any("rollback" in command for command in logged_yc_commands(command_log))
    assert Path(environment["JQ_INPUT_LOG"]).read_text() == "[]"
    assert Path(environment["JQ_FILTER_LOG"]).read_text() == ACTIVE_REVISION_FILTER
    assert_token_is_not_printed(result)
